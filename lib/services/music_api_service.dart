import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/play_history.dart';
import '../models/song.dart';
import '../models/user_playlist.dart';
import 'media_cache_service.dart';

class SearchPage<T> {
  final List<T> items;
  final int total;

  const SearchPage({required this.items, required this.total});
}

class HotSearchCategory {
  final String name;
  final List<String> keywords;

  const HotSearchCategory({required this.name, required this.keywords});
}

class SearchSuggestion {
  final String keyword;
  final String type;

  const SearchSuggestion({required this.keyword, required this.type});
}

class LyricsContent {
  final String content;
  final String format;

  const LyricsContent({required this.content, required this.format});

  bool get isKrc => format == 'krc';
}

class MusicApiService {
  // 后端 API 地址（KuGouMusicApi 部署地址，部署方式见 README）
  // 可通过 --dart-define=AUDIGO_API=http://localhost:40000 指向自建/本地 KuGouMusicApi
  static String baseApi = const String.fromEnvironment(
    'AUDIGO_API',
    defaultValue: 'http://localhost:40000',
  );

  // 云网关鉴权 token（可选：后端启用了 token 校验时需提供，
  // 通过 --dart-define=AUDIGO_API_TOKEN=your_token 注入，留空则不附加鉴权头）
  static const String apiToken = String.fromEnvironment('AUDIGO_API_TOKEN');

  static final Dio _dio = _createDio();
  static DateTime? _lastVipClaim;
  static Future<void>? _vipClaimRequest;
  static Future<SharedPreferences>? _prefsFuture;
  static DateTime? _vipActiveUntil;

  /// 概念版 VIP 有效期持久化 key（epoch 毫秒）。
  /// 领取/查询成功后写入，重启后有效期内直接跳过领取，
  /// 避免每次启动都打 8 次领取接口触发风控。
  static const String _vipUntilPrefKey = 'youth_vip_active_until_ms';

  static Future<SharedPreferences> _getPrefs() {
    return _prefsFuture ??= SharedPreferences.getInstance();
  }

  /// 是否为发往后端（baseApi）的请求。
  static bool _isGatewayRequest(String url) => url.startsWith(baseApi);

  static bool _isRetryableNetworkError(DioException error) {
    if (error.response?.statusCode case final status? when status >= 500) {
      return true;
    }
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError =>
        true,
      DioExceptionType.unknown =>
        error.error is HandshakeException || error.error is SocketException,
      _ => false,
    };
  }

  static Dio _createDio() {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'application/json, text/plain, */*',
      },
    ));

    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        // 遵循系统真实网络环境（有代理走代理，无代理走直连）
        client.findProxy = HttpClient.findProxyFromEnvironment;
        client.badCertificateCallback =
            (X509Certificate cert, String host, int port) => true;
        return client;
      },
    );

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          // 发往后端的请求自动附加鉴权头（若配置了 token）
          if (_isGatewayRequest(options.uri.toString()) &&
              apiToken.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $apiToken';
          }
          handler.next(options);
        },
        onResponse: (response, handler) {
          // 服务端每个请求都会下发整套设备 Cookie，后台异步合并保存，
          // 保证后续请求回传完整 Cookie（token 与设备参数绑定）。
          if (_isGatewayRequest(response.requestOptions.uri.toString())) {
            unawaited(_mergeDeviceCookies(response));
          }
          handler.next(response);
        },
        onError: (error, handler) async {
          final request = error.requestOptions;
          final retryCount = request.extra['retryCount'] as int? ?? 0;
          if (request.method.toUpperCase() != 'GET' ||
              retryCount >= 1 ||
              !_isRetryableNetworkError(error)) {
            handler.next(error);
            return;
          }

          request.extra['retryCount'] = retryCount + 1;
          await Future<void>.delayed(const Duration(milliseconds: 600));
          try {
            handler.resolve(await dio.fetch<dynamic>(request));
          } on DioException catch (retryError) {
            handler.next(retryError);
          }
        },
      ),
    );

    return dio;
  }

  // ==================== 设备参数管理（每客户端独立） ====================
  //
  // 多用户共用后端时，每个客户端必须使用自己独立的设备参数
  // （KUGOU_API_GUID/DEV/MAC/WEBGL + dfid），否则所有用户会被酷狗识别为
  // "同一台设备"，触发风控（20018 / 滑块验证 / 封号）。
  //
  // 设计：设备参数属于"客户端实例"而非"登录用户"，首次使用时生成并
  // 独立保存（device_*），不随用户切换而变化；请求时与用户 cookie 合并携带。

  static const _kDeviceGuid = 'device_guid';
  static const _kDeviceDev = 'device_dev';
  static const _kDeviceMac = 'device_mac';
  static const _kDeviceWebgl = 'device_webgl';
  static const _kDeviceMid = 'device_mid';
  static const _kDeviceDfid = 'device_dfid';
  static const _kDevicePlatform = 'device_platform';

  static Map<String, String>? _deviceCache;
  static String? _userCookieCache;

  /// 登录/登出/导入设置后失效 cookie 缓存。
  static void invalidateCookieCache() {
    _userCookieCache = null;
  }

  /// 生成 UUID v4 字符串（用于 KUGOU_API_GUID）。
  static String _generateUuidV4() {
    final rng = Random();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// 生成 10 位大写字母数字（用于 KUGOU_API_DEV）。
  static String _generateDeviceDev() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rng = Random();
    return List.generate(10, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  /// 生成 19 位数字（用于 KUGOU_API_WEBGL 指纹）。
  static String _generateWebglHash() {
    final rng = Random();
    return List.generate(19, (_) => rng.nextInt(10).toString()).join();
  }

  /// 获取（必要时生成并保存）本客户端的独立设备参数。
  static Future<Map<String, String>> _ensureDeviceParams() async {
    if (_deviceCache != null) return _deviceCache!;
    final prefs = await SharedPreferences.getInstance();

    var guid = prefs.getString(_kDeviceGuid) ?? '';
    if (guid.isEmpty) {
      guid = _generateUuidV4();
      await prefs.setString(_kDeviceGuid, guid);
    }
    var dev = prefs.getString(_kDeviceDev) ?? '';
    if (dev.isEmpty) {
      dev = _generateDeviceDev();
      await prefs.setString(_kDeviceDev, dev);
    }
    var mac = prefs.getString(_kDeviceMac) ?? '';
    if (mac.isEmpty) {
      mac = '02:00:00:00:00:00';
      await prefs.setString(_kDeviceMac, mac);
    }
    var webgl = prefs.getString(_kDeviceWebgl) ?? '';
    if (webgl.isEmpty) {
      webgl = _generateWebglHash();
      await prefs.setString(_kDeviceWebgl, webgl);
    }
    var mid = prefs.getString(_kDeviceMid) ?? '';
    var dfid = prefs.getString(_kDeviceDfid) ?? '';
    var platform = prefs.getString(_kDevicePlatform) ?? 'lite';

    final params = <String, String>{
      'KUGOU_API_GUID': guid,
      'KUGOU_API_DEV': dev,
      'KUGOU_API_MAC': mac,
      'KUGOU_API_WEBGL': webgl,
      'KUGOU_API_PLATFORM': platform,
      if (mid.isNotEmpty) 'KUGOU_API_MID': mid,
      if (dfid.isNotEmpty) 'dfid': dfid,
    };
    _deviceCache = params;
    return params;
  }

  /// 合并用户 cookie 与设备参数，生成最终请求 cookie。
  /// 使用内存缓存避免每次请求都同步读 SharedPreferences（主线程阻塞源）。
  static Future<String> _buildFullCookie() async {
    if (_userCookieCache != null) return _userCookieCache!;
    final prefs = await SharedPreferences.getInstance();
    final userCookie = prefs.getString('user_cookie') ?? '';
    final parts = userCookie
        .split(';')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();

    // 设备参数优先覆盖同名字段（保证每客户端独立设备标识）
    final device = await _ensureDeviceParams();
    final userKeys = parts.map((p) => p.split('=').first.trim()).toSet();
    device.forEach((key, value) {
      final part = '$key=$value';
      if (userKeys.contains(key)) {
        final idx = parts.indexWhere((p) => p.split('=').first.trim() == key);
        parts[idx] = part;
      } else {
        parts.add(part);
      }
    });

    final full = parts.join(';');
    _userCookieCache = full;
    return full;
  }

  // 获取本地保存的 Cookie（用户 + 设备参数合并后的完整 cookie）
  static Future<String> _getCookie() => _buildFullCookie();

  /// 从响应头 Set-Cookie 中提取设备参数并保存到独立的 device_* 字段。
  /// 服务端会下发 KUGOU_API_MID/dfid 等由酷狗签发的值；GUID/DEV/MAC/WEBGL
  /// 若客户端已生成则以客户端为准（服务端 ensureCookie 不会覆盖）。
  ///
  /// 防抖：设备参数通常稳定，仅在值真正变化时才写 prefs 并刷新缓存，
  /// 避免每个请求都做无谓的同步 IO（主线程阻塞源）。
  static Future<void> _mergeDeviceCookies(Response<dynamic> response) async {
    try {
      final setCookies = response.headers['set-cookie'];
      if (setCookies == null || setCookies.isEmpty) return;
      final map = <String, String>{};
      for (final cookieHeader in setCookies) {
        final firstSegment = cookieHeader.split(';').first.trim();
        final eq = firstSegment.indexOf('=');
        if (eq <= 0) continue;
        final key = firstSegment.substring(0, eq).trim();
        final value = firstSegment.substring(eq + 1).trim();
        if (value.isNotEmpty) map[key] = value;
      }
      if (map.isEmpty) return;

      final prefs = await SharedPreferences.getInstance();
      var changed = false;

      Future<void> updateIfChanged(String prefsKey, String? newValue) async {
        if (newValue == null || newValue.isEmpty) return;
        if (prefs.getString(prefsKey) == newValue) return;
        await prefs.setString(prefsKey, newValue);
        changed = true;
      }

      await updateIfChanged(_kDeviceMid, map['KUGOU_API_MID']);
      await updateIfChanged(_kDeviceDfid, map['dfid']);
      await updateIfChanged(_kDevicePlatform, map['KUGOU_API_PLATFORM']);
      // 客户端未生成时才采用服务端值（正常情况下客户端已生成 GUID/DEV 等）
      if ((prefs.getString(_kDeviceGuid) ?? '').isEmpty) {
        await updateIfChanged(_kDeviceGuid, map['KUGOU_API_GUID']);
      }
      if ((prefs.getString(_kDeviceDev) ?? '').isEmpty) {
        await updateIfChanged(_kDeviceDev, map['KUGOU_API_DEV']);
      }
      if ((prefs.getString(_kDeviceMac) ?? '').isEmpty) {
        await updateIfChanged(_kDeviceMac, map['KUGOU_API_MAC']);
      }
      if ((prefs.getString(_kDeviceWebgl) ?? '').isEmpty) {
        await updateIfChanged(_kDeviceWebgl, map['KUGOU_API_WEBGL']);
      }

      if (changed) {
        _deviceCache = null;
        await _ensureDeviceParams();
        _userCookieCache = null;
      }
    } catch (_) {
      // 静默失败：设备参数合并失败不影响请求。
    }
  }

  // 1. 获取每日推荐歌曲
  static Future<List<Song>> getDailyRecommend({String platform = 'ios'}) async {
    try {
      final cookie = await _getCookie();
      final queryParams = <String, dynamic>{
        'platform': platform,
      };
      if (cookie.isNotEmpty) queryParams['cookie'] = cookie;

      final response = await _dio.get('$baseApi/everyday/recommend',
          queryParameters: queryParams);
      if (response.data != null) {
        final raw = response.data;
        List list = [];
        if (raw['data'] is List) {
          list = raw['data'];
        } else if (raw['data'] is Map && raw['data']['song_list'] is List) {
          list = raw['data']['song_list'];
        } else if (raw['data'] is Map && raw['data']['songs'] is List) {
          list = raw['data']['songs'];
        } else if (raw['data'] is Map &&
            raw['data']['daily_recommend'] is List) {
          list = raw['data']['daily_recommend'];
        }
        return list.map((item) => Song.fromJson(item)).toList();
      }
    } catch (e) {
      print('获取每日推荐失败: $e');
    }
    return [];
  }

  // 2. 获取私人 FM (支持模式 normal/small/peak 与 AI pool)
  // 高级参数：isOverplay/remainSongCnt/playTime。
  static Future<List<Song>> getPersonalFM({
    String mode = 'normal',
    int songPoolId = 0,
    String hash = '',
    String songId = '',
    int playTime = 0,
    bool isOverplay = false,
    int remainSongCnt = 0,
  }) async {
    try {
      final cookie = await _getCookie();
      final queryParams = <String, dynamic>{
        'mode': mode,
        'action': 'play',
      };
      if (cookie.isNotEmpty) queryParams['cookie'] = cookie;
      if (hash.isNotEmpty) queryParams['hash'] = hash;
      if (songId.isNotEmpty) queryParams['songid'] = songId;
      if (songPoolId > 0) queryParams['song_pool_id'] = songPoolId;
      if (playTime > 0) queryParams['playtime'] = playTime;
      if (isOverplay) queryParams['is_overplay'] = 1;
      if (remainSongCnt > 0) queryParams['remain_song_cnt'] = remainSongCnt;

      final response =
          await _dio.get('$baseApi/personal/fm', queryParameters: queryParams);
      if (response.data != null) {
        final raw = response.data;
        List list = [];
        if (raw['data'] is List) {
          list = raw['data'];
        } else if (raw['data'] is Map && raw['data']['song_list'] is List) {
          list = raw['data']['song_list'];
        } else if (raw['data'] is Map && raw['data']['songs'] is List) {
          list = raw['data']['songs'];
        }
        return list.map((item) => Song.fromJson(item)).toList();
      }
    } catch (e) {
      print('获取私人FM失败: $e');
    }
    return [];
  }

  static Future<bool> reportFMAction({
    required String hash,
    required String action,
    String songId = '',
    int playTime = 0,
  }) async {
    if (hash.trim().isEmpty) return false;
    try {
      final cookie = await _getCookie();
      final queryParams = <String, dynamic>{
        'hash': hash,
        'mode': 'normal',
        'action': action,
      };
      if (songId.isNotEmpty) queryParams['songid'] = songId;
      if (playTime > 0) queryParams['playtime'] = playTime;
      if (cookie.isNotEmpty) queryParams['cookie'] = cookie;

      final response =
          await _dio.get('$baseApi/personal/fm', queryParameters: queryParams);
      return response.data?['error_code'] == 0 || response.data?['status'] == 1;
    } catch (_) {
      return false;
    }
  }

  // 3. 获取 AI 推荐歌曲
  static Future<List<Song>> getAIRecommend() async {
    try {
      final cookie = await _getCookie();
      final queryParams = <String, dynamic>{};
      if (cookie.isNotEmpty) queryParams['cookie'] = cookie;
      final response =
          await _dio.get('$baseApi/ai/recommend', queryParameters: queryParams);

      if (response.data != null &&
          (response.data['error_code'] == 0 || response.data['status'] == 1)) {
        final list = (response.data['data'] is List
                ? response.data['data']
                : response.data['data']?['song_list']) as List? ??
            [];
        return list.map((item) => Song.fromJson(item)).toList();
      }
    } catch (e) {
      print('获取AI推荐失败: $e');
    }
    return [];
  }

  // 4. 获取推荐歌曲分类 (personal/vip/classic/popular/treasure/trendy)
  static Future<List<Song>> getRecommendSongs(String category) async {
    try {
      final cookie = await _getCookie();
      final queryParams = <String, dynamic>{'category': category};
      if (cookie.isNotEmpty) queryParams['cookie'] = cookie;
      final response = await _dio.get('$baseApi/recommend/songs',
          queryParameters: queryParams);

      if (response.data != null &&
          (response.data['error_code'] == 0 || response.data['status'] == 1)) {
        final list = (response.data['data'] is List
                ? response.data['data']
                : response.data['data']?['song_list']) as List? ??
            [];
        return list.map((item) => Song.fromJson(item)).toList();
      }
    } catch (e) {
      print('获取分类推荐歌曲失败 ($category): $e');
    }
    return [];
  }

  // 5. 搜索
  static Future<List<Song>> searchSongs(String keyword,
      {int page = 1, int pageSize = 30}) async {
    final result =
        await searchSongPage(keyword, page: page, pageSize: pageSize);
    return result.items;
  }

  static Future<SearchPage<Song>> searchSongPage(String keyword,
      {int page = 1, int pageSize = 30}) async {
    // 主路径：/search?type=song（酷狗 v1，解析 data.lists 的大写字段）
    final songResult =
        await _searchSongsByTypeSong(keyword, page: page, pageSize: pageSize);
    if (songResult.items.isNotEmpty) return songResult;
    // 兜底：/search/complex
    return _searchSongsByComplex(keyword, page: page, pageSize: pageSize);
  }

  /// 酷狗 v1 /search?type=song：返回 data.lists，字段为大写（FileHash/OriSongName/...）。
  static Future<SearchPage<Song>> _searchSongsByTypeSong(String keyword,
      {int page = 1, int pageSize = 30}) async {
    if (keyword.trim().isEmpty) return const SearchPage(items: [], total: 0);
    try {
      final cookie = await _getCookie();
      final response = await _dio.get('$baseApi/search', queryParameters: {
        'keywords': keyword,
        'type': 'song',
        'page': page,
        'pagesize': pageSize,
        'cookie': cookie,
      });
      final data = response.data?['data'];
      if (response.data?['error_code'] == 0 && data is Map) {
        final list = data['lists'] as List? ?? [];
        return SearchPage(
          items: list
              .whereType<Map>()
              .map((item) => Song.fromJson(Map<String, dynamic>.from(item)))
              .toList(),
          total: _asInt(data['total']),
        );
      }
    } catch (_) {}
    return const SearchPage(items: [], total: 0);
  }

  /// 酷狗 v6 /search/complex（分节结构，备用）。
  static Future<SearchPage<Song>> _searchSongsByComplex(String keyword,
      {int page = 1, int pageSize = 30}) async {
    if (keyword.trim().isEmpty) return const SearchPage(items: [], total: 0);
    try {
      final cookie = await _getCookie();
      final response =
          await _dio.get('$baseApi/search/complex', queryParameters: {
        'keyword': keyword,
        'page': page,
        'pagesize': pageSize,
        'cookie': cookie,
      });
      final songs = response.data?['data']?['songs'];
      if (response.data?['error_code'] == 0 && songs is Map) {
        final list = songs['list'] as List? ?? [];
        return SearchPage(
          items: list
              .whereType<Map>()
              .map((item) => Song.fromJson(Map<String, dynamic>.from(item)))
              .toList(),
          total: _asInt(songs['total']),
        );
      }
    } catch (_) {}
    return const SearchPage(items: [], total: 0);
  }

  static Future<SearchPage<Map<String, dynamic>>> searchArtists(String keyword,
          {int page = 1, int pageSize = 30}) =>
      _searchCollection(
          keyword,
          'author',
          page,
          pageSize,
          (raw) => {
                'id': _first(raw, ['AuthorId', 'SingerID', 'author_id']),
                'title': _first(raw, ['AuthorName', 'author_name']),
                'cover': _image(_first(raw, ['Avatar', 'avatar'])),
                'subtitle':
                    '${_asInt(_first(raw, ['AudioCount', 'song_count']))} 首歌曲',
              });

  static Future<SearchPage<Map<String, dynamic>>> searchPlaylists(
          String keyword,
          {int page = 1,
          int pageSize = 30}) =>
      _searchCollection(
          keyword,
          'special',
          page,
          pageSize,
          (raw) => {
                'id': _first(raw, ['gid', 'specialid', 'special_id']),
                'title': _first(raw, ['specialname', 'special_name']),
                'cover': _image(_first(raw, ['img', 'img_url'])),
                'subtitle': _first(raw, ['nickname', 'author_name']),
                'count': _asInt(_first(raw, ['song_count', 'songcount'])),
              });

  static Future<SearchPage<Map<String, dynamic>>> searchAlbums(String keyword,
          {int page = 1, int pageSize = 30}) =>
      _searchCollection(
          keyword,
          'album',
          page,
          pageSize,
          (raw) => {
                'id': _first(raw, ['albumid', 'album_id']),
                'title': _first(raw, ['albumname', 'album_name']),
                'cover': _image(_first(raw, ['img', 'img_url'])),
                'subtitle': _first(raw, ['singer', 'author_name']),
                'count': _asInt(_first(raw, ['songcount', 'song_count'])),
              });

  static Future<SearchPage<Map<String, dynamic>>> searchMVs(String keyword,
          {int page = 1, int pageSize = 30}) =>
      _searchCollection(
          keyword,
          'mv',
          page,
          pageSize,
          (raw) => {
                'id': _first(raw, ['MvHash', 'hash']),
                'title': _first(raw, ['MvName', 'mv_name']),
                'cover': _image(_first(raw, ['ThumbGif', 'img_url'])),
                'subtitle': _first(raw, ['SingerName', 'author_name']),
                'duration': _asInt(_first(raw, ['Duration', 'time_length'])),
              });

  static Future<SearchPage<Map<String, dynamic>>> _searchCollection(
    String keyword,
    String type,
    int page,
    int pageSize,
    Map<String, dynamic> Function(Map<String, dynamic>) convert,
  ) async {
    if (keyword.trim().isEmpty) return const SearchPage(items: [], total: 0);
    try {
      final cookie = await _getCookie();
      final response = await _dio.get('$baseApi/search', queryParameters: {
        'keywords': keyword,
        'type': type,
        'page': page,
        'pagesize': pageSize,
        'cookie': cookie,
      });
      final data = response.data?['data'];
      if (response.data?['error_code'] == 0 && data is Map) {
        final list = data['lists'] as List? ?? [];
        return SearchPage(
          items: list
              .whereType<Map>()
              .map((item) => convert(Map<String, dynamic>.from(item)))
              .toList(),
          total: _asInt(data['total']),
        );
      }
    } catch (_) {}
    return const SearchPage(items: [], total: 0);
  }

  /// 获取 MV 播放地址（KuGouMusicApi /mv/url，hash 来自搜索结果的 MvHash）。
  /// 返回可直连的 mp4 地址；失败/无版权时返回 null。
  static Future<String?> getMvUrl(String mvHash) async {
    if (mvHash.trim().isEmpty) return null;
    try {
      final cookie = await _getCookie();
      final response = await _dio.get(
        '$baseApi/mv/url',
        queryParameters: {
          'hash': mvHash,
          'cookie': cookie,
        },
      );
      final data = response.data?['data'];
      // 常见结构：{data: [{url: ..., quality: ...}, ...]} 或直接 url 字段。
      String? url;
      if (data is List) {
        for (final entry in data) {
          if (entry is Map && entry['url'] is String) {
            url = entry['url'] as String;
            break;
          }
        }
      } else if (data is Map) {
        url = data['url']?.toString();
      }
      if (url != null && url.startsWith('http')) return url;
      print('MV 地址响应无可用 url: ${response.data}');
    } catch (e) {
      print('获取 MV 播放地址失败: $e');
    }
    return null;
  }

  static Future<List<HotSearchCategory>> getHotSearch() async {
    try {
      final cookie = await _getCookie();
      final response = await _dio.get(
        '$baseApi/search/hot',
        queryParameters: {'cookie': cookie},
      );
      final list = response.data?['data']?['list'];
      if (response.data?['status'] == 1 && list is List) {
        return list.whereType<Map>().map((category) {
          final keywords = category['keywords'];
          return HotSearchCategory(
            name: category['name']?.toString() ?? '热搜',
            keywords: keywords is List
                ? keywords
                    .whereType<Map>()
                    .map((item) => item['keyword']?.toString() ?? '')
                    .where((item) => item.isNotEmpty)
                    .toList()
                : const [],
          );
        }).toList();
      }
    } catch (e) {
      print('获取热搜失败: $e');
    }
    return [];
  }

  static Future<List<SearchSuggestion>> getSearchSuggestions(
      String keyword) async {
    if (keyword.trim().isEmpty) return [];
    try {
      final cookie = await _getCookie();
      final response = await _dio.get(
        '$baseApi/search/suggest',
        queryParameters: {'keywords': keyword, 'cookie': cookie},
      );
      final data = response.data?['data'];
      if (data is Map) {
        final suggestions = <SearchSuggestion>[];
        for (final entry in const {
          'music_tip': 'song',
          'album_tip': 'album',
          'mv_tip': 'mv',
        }.entries) {
          final values = data[entry.key];
          if (values is List) {
            suggestions.addAll(values.map((value) => SearchSuggestion(
                  keyword: value.toString(),
                  type: entry.value,
                )));
          }
        }
        return suggestions;
      }
      if (data is List) {
        final suggestions = <SearchSuggestion>[];
        for (final group in data.whereType<Map>()) {
          final label = group['LableName']?.toString() ?? '';
          final type = label == 'MV'
              ? 'mv'
              : label == '专辑'
                  ? 'album'
                  : 'song';
          final records = group['RecordDatas'];
          if (records is! List) continue;
          suggestions
              .addAll(records.whereType<Map>().map((record) => SearchSuggestion(
                    keyword: record['HintInfo']?.toString() ?? '',
                    type: type,
                  )));
        }
        return suggestions
            .where((suggestion) => suggestion.keyword.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    return [];
  }

  static dynamic _first(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value != null && value.toString().isNotEmpty) return value;
    }
    return '';
  }

  static int _asInt(dynamic value) =>
      value is num ? value.toInt() : int.tryParse(value?.toString() ?? '') ?? 0;

  static String _image(dynamic value) {
    final url = value?.toString().replaceAll('{size}', '400') ?? '';
    return url.startsWith('http://')
        ? url.replaceFirst('http://', 'https://')
        : url;
  }

  // 6. 获取新歌速递
  static Future<List<Song>> getNewSongs() async {
    try {
      final cookie = await _getCookie();
      final response = await _dio.get(
        '$baseApi/top/song',
        queryParameters: {'cookie': cookie},
      );
      final data = response.data?['data'];
      if (response.data?['status'] == 1 && data is List) {
        return data.whereType<Map>().map((item) {
          final song = Map<String, dynamic>.from(item);
          final transParam = song['trans_param'];
          if (transParam is Map && transParam['union_cover'] != null) {
            song['union_cover'] = transParam['union_cover'];
          }
          final timeLength = song['timelength'];
          if (timeLength is num) {
            song['time_length'] = (timeLength / 1000).round();
          }
          return Song.fromJson(song);
        }).toList();
      }
    } catch (e) {
      print('获取新歌速递失败: $e');
    }
    return [];
  }

  // 7. 获取新碟上架
  static Future<List<Map<String, dynamic>>> getNewAlbums() async {
    final categories = await getNewAlbumsByCategory();
    return [
      for (final category in categories.values) ...category,
    ];
  }

  /// 获取新碟上架并按分类（chn 华语/eur 欧美/jpn 日韩/kor 韩国）返回。
  static Future<Map<String, List<Map<String, dynamic>>>> getNewAlbumsByCategory() async {
    try {
      final cookie = await _getCookie();
      final response = await _dio.get(
        '$baseApi/top/album',
        queryParameters: {'cookie': cookie},
      );
      final data = response.data?['data'];
      if (response.data?['status'] == 1 && data is Map) {
        final result = <String, List<Map<String, dynamic>>>{};
        for (final category in ['chn', 'eur', 'jpn', 'kor']) {
          final categoryAlbums = data[category];
          if (categoryAlbums is! List) continue;
          result[category] = categoryAlbums.whereType<Map>().map((item) {
            final album = Map<String, dynamic>.from(item);
            final cover = album['imgurl']?.toString() ?? '';
            final publishTime = album['publishtime']?.toString() ?? '';
            return <String, dynamic>{
              'id': album['albumid']?.toString() ?? '',
              'title': album['albumname']?.toString() ?? '未知专辑',
              'author_name': album['singername']?.toString() ?? '未知歌手',
              'songCount': album['songcount'] ?? 0,
              'releaseDate': publishTime.length > 10
                  ? publishTime.substring(0, 10)
                  : publishTime,
              'cover': cover.replaceAll('{size}', '400').replaceFirst(
                    'http://',
                    'https://',
                  ),
              'description': album['intro']?.toString() ?? '',
            };
          }).toList();
        }
        return result;
      }
    } catch (e) {
      print('获取新碟上架分类失败: $e');
    }
    return const {};
  }

  // 8. 解析真实播放地址，兼容 Go 服务和上游接口的不同响应结构。
  static Future<List<String>> getPlayUrls(
    String hash, {
    String songName = '',
    String artist = '',
    String quality = '128k',
  }) async {
    if (hash.trim().isEmpty) return [];
    final normalizedQuality = _normalizeAudioQuality(quality);
    final qualityChain = normalizedQuality == 'flac'
        ? const ['flac', '320', '128']
        : normalizedQuality == '320'
            ? const ['320', '128']
            : const ['128'];
    final cookie = await _getCookie();
    await _claimYouthVipIfNeeded(cookie);
    final urls = await _requestPlayUrls(hash, qualityChain, cookie);
    if (urls.isNotEmpty) return urls;

    // 版权受限或 Hash 失效时，寻找同名可播放资源。
    if (songName.trim().isNotEmpty) {
      final candidates = await searchSongs(songName, pageSize: 10);
      for (final candidate in candidates) {
        if (candidate.hash.isEmpty || candidate.hash == hash) continue;
        if (artist.trim().isNotEmpty &&
            !candidate.authorName
                .toLowerCase()
                .contains(artist.trim().toLowerCase())) {
          continue;
        }
        final alternative =
            await _requestPlayUrls(candidate.hash, qualityChain, cookie);
        if (alternative.isNotEmpty) {
          print('已切换到同名歌曲的可播放资源: ${candidate.hash}');
          return alternative;
        }
      }
    }
    return [];
  }

  static Future<List<String>> _requestPlayUrls(
    String hash,
    List<String> qualityChain,
    String cookie,
  ) async {
    for (final requestedQuality in qualityChain) {
      try {
        final response = await _dio.get('$baseApi/song/url', queryParameters: {
          'hash': hash,
          'quality': requestedQuality,
          'cookie': cookie.contains('KUGOU_API_PLATFORM')
              ? cookie
              : '$cookie;KUGOU_API_PLATFORM=lite',
        });
        print(
            '播放调试: /song/url 响应 status=${response.statusCode} data=${response.data}');
        final urls = _extractPlayUrls(response.data);
        if (urls.isNotEmpty) return urls;
        print('歌曲播放地址为空: hash=$hash quality=$requestedQuality '
            'response=${response.data}');
      } catch (e) {
        print('获取歌曲播放地址失败: hash=$hash quality=$requestedQuality error=$e');
      }
    }
    return [];
  }

  /// 播放地址 + 歌词（响应中直接返回 Lyrics）。
  /// 云端 /song/url 正常情况下会携带歌词，避免单独调 /search/lyric
  /// （该接口在部分部署下返回空）。
  static Future<({List<String> urls, String lyrics, String quality})>
      getPlayUrlsWithLyrics(
    String hash, {
    String songName = '',
    String artist = '',
    String quality = '128k',
  }) async {
    if (hash.trim().isEmpty) {
      return (urls: <String>[], lyrics: '', quality: '128k');
    }
    final normalizedQuality = _normalizeAudioQuality(quality);
    final qualityChain = normalizedQuality == 'flac'
        ? const ['flac', '320', '128']
        : normalizedQuality == '320'
            ? const ['320', '128']
            : const ['128'];
    final cookie = await _getCookie();
    await _claimYouthVipIfNeeded(cookie);

    for (final requestedQuality in qualityChain) {
      try {
        final response = await _dio.get('$baseApi/song/url', queryParameters: {
          'hash': hash,
          'quality': requestedQuality,
          'cookie': cookie.contains('KUGOU_API_PLATFORM')
              ? cookie
              : '$cookie;KUGOU_API_PLATFORM=lite',
        });
        final data = response.data;
        final urls = _extractPlayUrls(data);
        if (urls.isEmpty) continue;
        // 播放地址响应中的歌词字段。KuGouMusicApi 的
        // /song/url 响应 data 可能是 Map（单音质）也可能是 List
        // （多音质数组，lyrics 在每个元素里），递归查找。
        final lyrics = _extractLyricsField(data) ?? '';
        print('播放调试: quality=$requestedQuality 播放响应携带歌词 '
            '${lyrics.trim().length} 字符');
        // 从 CDN URL 识别实际音质：请求无损但无 VIP 时服务器会降级
        // 返回 128K MP3（URL 标记 qu128），缓存必须按实际音质命名，
        // 否则 MP3 内容会被存成 .flac 文件。
        final requestedActualStyle = switch (requestedQuality) {
          'flac' => 'flac',
          '320' => '320k',
          _ => '128k',
        };
        final actualQuality =
            _detectActualQuality(urls.first) ?? requestedActualStyle;
        if (actualQuality != requestedActualStyle) {
          print('播放调试: 实际音质为 $actualQuality（请求 $requestedQuality 被降级）');
        }
        return (urls: urls, lyrics: lyrics, quality: actualQuality);
      } catch (e) {
        print('获取播放地址(含歌词)失败: hash=$hash quality=$requestedQuality error=$e');
      }
    }

    // 兜底：主路径失败时，独立获取播放地址（不因歌词接口失败而阻塞播放）。
    final fallbackUrls = await getPlayUrls(hash, quality: quality);
    if (fallbackUrls.isEmpty) {
      return (urls: <String>[], lyrics: '', quality: normalizedQuality);
    }
    // 歌词尽力而为：失败不影响播放。
    String fallbackLyrics = '';
    try {
      fallbackLyrics =
          await _loadRawLyrics(hash, songName: songName, artist: artist);
    } catch (_) {
      fallbackLyrics = '';
    }
    return (
      urls: fallbackUrls,
      lyrics: fallbackLyrics,
      quality: _detectActualQuality(fallbackUrls.first) ?? normalizedQuality,
    );
  }

  /// 从播放地址响应中递归提取歌词字符串。
  /// 兼容顶层 lyrics、data.lyrics（Map）、data[i].lyrics（List）三种形态。
  static String? _extractLyricsField(dynamic payload) {
    if (payload is String) {
      return payload.trim().isEmpty ? null : payload;
    }
    if (payload is Map) {
      // 直接命中 lyrics 字段（可能为 krc 或 lrc 文本）。
      final lyrics = payload['lyrics'];
      if (lyrics is String && lyrics.trim().isNotEmpty) return lyrics;
      if (lyrics is Map) {
        final content = lyrics['content'];
        if (content is String && content.trim().isNotEmpty) return content;
      }
      // 跳过状态字段，仅深入 data 容器，避免误读无关文本。
      return _extractLyricsField(payload['data']);
    }
    if (payload is List) {
      for (final item in payload) {
        final found = _extractLyricsField(item);
        if (found != null) return found;
      }
    }
    return null;
  }

  /// 从 CDN URL 提取实际音质（quflac/qu320/qu128 标记或扩展名），
  /// 返回与设置一致的命名（flac/320k/128k）；无法识别时返回 null。
  static String? _detectActualQuality(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('quflac') || lower.endsWith('.flac')) return 'flac';
    if (lower.contains('qu320')) return '320k';
    if (lower.contains('qu128')) return '128k';
    return null;
  }

  static Future<String?> getPlayUrl(String hash,
      {String quality = '128k'}) async {
    final urls = await getPlayUrls(hash, quality: quality);
    return urls.isEmpty ? null : urls.first;
  }

  /// 持久化概念版 VIP 有效期。
  static Future<void> _persistVipUntil(DateTime until) async {
    _vipActiveUntil = until;
    try {
      final prefs = await _getPrefs();
      await prefs.setInt(_vipUntilPrefKey, until.millisecondsSinceEpoch);
    } catch (_) {}
  }

  static Future<void> _claimYouthVipIfNeeded(String cookie) async {
    if (cookie.trim().isEmpty) return;
    final now = DateTime.now();
    // 有效期内（含重启后从本地恢复的记录）直接跳过，不打任何接口。
    var activeUntil = _vipActiveUntil;
    if (activeUntil == null) {
      try {
        final prefs = await _getPrefs();
        final ms = prefs.getInt(_vipUntilPrefKey);
        if (ms != null && ms > now.millisecondsSinceEpoch) {
          activeUntil =
              DateTime.fromMillisecondsSinceEpoch(ms);
        }
      } catch (_) {}
    }
    if (activeUntil != null && activeUntil.isAfter(now)) {
      _lastVipClaim = now;
      return;
    }
    final lastClaim = _lastVipClaim;
    if (lastClaim != null && now.difference(lastClaim).inHours < 2) {
      return;
    }
    if (_vipClaimRequest != null) return _vipClaimRequest!;

    final request = () async {
      try {
        final conceptCookie = cookie.contains('KUGOU_API_PLATFORM')
            ? cookie
            : '$cookie;KUGOU_API_PLATFORM=lite';

        // 1. 查询当前畅听 VIP 状态：/youth/day/vip 返回
        //    data.ad_vip_end_time / server_time，有效期内存续则无需领取。
        var hasVip = false;
        try {
          final query =
              await _dio.get('$baseApi/youth/day/vip', queryParameters: {
            'cookie': conceptCookie,
            'receive_day': _todayDate(),
          });
          await _mergeDeviceCookies(query);
          final data = query.data;
          if (data is Map) {
            final inner = data['data'];
            if (inner is Map) {
              final endTime = inner['ad_vip_end_time'];
              final serverTime = inner['server_time'];
              if (endTime is num && serverTime is num && endTime > serverTime) {
                hasVip = true;
                print('概念版 VIP 状态: 有效期内（$endTime > $serverTime），无需领取');
                // 记录有效期（按服务器时间差换算本地时钟），
                // 后续 2 小时冷却 + 重启后有效期内均不再请求。
                final validMs = ((endTime - serverTime) * 1000).toInt();
                if (validMs > 0) {
                  unawaited(_persistVipUntil(DateTime.now()
                      .add(Duration(milliseconds: validMs))));
                }
              } else {
                print('概念版 VIP 状态: 无有效权益（ad_vip_num='
                    '${inner['ad_vip_num']}, end_time=$endTime）');
              }
            }
          }
        } on DioException catch (e) {
          print('查询概念版 VIP 状态失败: HTTP ${e.response?.statusCode ?? '未知'}');
        }

        // 2. 无有效权益时领取：/youth/vip（KG 概念版畅听 VIP，
        //    每次领取 3 小时，需领 8 次凑满一天；已领满/风控时接口报错即停）。
        if (!hasVip) {
          var claimedTimes = 0;
          var remainHours = 0;
          for (var i = 0; i < 8; i++) {
            try {
              final claim = await _dio.get('$baseApi/youth/vip',
                  queryParameters: {'cookie': conceptCookie});
              await _mergeDeviceCookies(claim);
              final data = claim.data;
              final ok = data is Map &&
                  (data['status'] == 1 || data['success'] == true) &&
                  (data['error_code'] == null || data['error_code'] == 0);
              print('概念版 VIP 领取(${i + 1}/8): '
                  '${ok ? '成功' : '停止'} ${claim.data}');
              if (!ok) break;
              claimedTimes++;
              // 响应携带领取进度：remain=今天剩余可领次数，
              // remain_vip_hour=当前 VIP 剩余小时数。
              // remain 归零说明今天已领满，立即停止，
              // 不再空打接口（避免触发云端风控/限流）。
              var dayRemain = -1;
              if (data['data'] is Map) {
                final inner = data['data'] as Map;
                if (inner['remain'] is num) {
                  dayRemain = (inner['remain'] as num).toInt();
                }
                if (inner['remain_vip_hour'] is num) {
                  remainHours = (inner['remain_vip_hour'] as num).toInt();
                }
              }
              if (dayRemain == 0) {
                print('概念版 VIP 今日已领满（remain=0），停止领取');
                break;
              }
              // 每次领取间隔短延时，避免触发风控/限流。
              await Future<void>.delayed(const Duration(milliseconds: 600));
            } on DioException catch (e) {
              print('概念版 VIP 领取异常(${i + 1}/8): '
                  'HTTP ${e.response?.statusCode ?? '未知'}，停止领取');
              break;
            }
          }
          if (claimedTimes > 0) {
            print('概念版 VIP 领取完成: 共 $claimedTimes 次 × 3 小时');
          }
          // 按最后一次响应的剩余小时数持久化有效期；
          // 无字段时按已领次数 × 3 小时估算。
          final validHours =
              remainHours > 0 ? remainHours : claimedTimes * 3;
          if (validHours > 0) {
            unawaited(_persistVipUntil(
                DateTime.now().add(Duration(hours: validHours))));
          }
        }
        _lastVipClaim = DateTime.now();
      } on DioException catch (e) {
        print('领取概念版 VIP 失败: HTTP ${e.response?.statusCode ?? '未知'}，继续尝试播放');
      } catch (e) {
        print('领取概念版 VIP 失败: $e，继续尝试播放');
      } finally {
        _vipClaimRequest = null;
      }
    }();
    _vipClaimRequest = request;
    await request;
  }

  static String _todayDate() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }

  static List<String> _extractPlayUrls(dynamic payload) {
    final urls = <String>[];
    void add(dynamic value) {
      if (value is String && value.trim().isNotEmpty) {
        final url = value.trim();
        if (url.startsWith('http://') || url.startsWith('https://')) {
          if (!urls.contains(url)) urls.add(url);
        }
      } else if (value is List) {
        for (final item in value) add(item);
      } else if (value is Map) {
        for (final key in const [
          'url',
          'play_url',
          'playUrl',
          'download_url'
        ]) {
          add(value[key]);
        }
      }
    }

    if (payload is Map) {
      for (final key in const ['urls', 'url', 'backupUrl', 'backup_url']) {
        add(payload[key]);
      }
      add(payload['data']);
    } else {
      add(payload);
    }
    return urls;
  }

  static String _normalizeAudioQuality(String quality) {
    switch (quality.toLowerCase()) {
      case 'flac':
      case 'high':
        return 'flac';
      case '320':
      case '320k':
      case 'medium':
        return '320';
      default:
        return '128';
    }
  }

  // 7. 获取专辑详情
  static Future<Map<String, dynamic>> getAlbumDetail(String albumId) async {
    return _getCollectionDetail('/album/detail', albumId);
  }

  // 8. 获取歌单详情
  static Future<Map<String, dynamic>> getPlaylistDetail(
      String playlistId) async {
    return _getCollectionDetail('/playlist/detail', playlistId);
  }

  static Future<Map<String, dynamic>> _getCollectionDetail(
      String path, String id) async {
    if (id.trim().isEmpty) return {};
    try {
      final cookie = await _getCookie();
      final response = await _dio
          .get('$baseApi$path', queryParameters: {'id': id, 'cookie': cookie});
      final data = response.data?['data'];
      if (data is Map) return Map<String, dynamic>.from(data);
    } catch (e) {
      print('获取集合详情失败 ($id): $e');
    }
    return {};
  }

  // 9. 获取专辑歌曲
  static Future<List<Song>> getAlbumSongs(String albumId,
      {int page = 1, int pageSize = 30}) async {
    return _getCollectionSongs('/album/songs', albumId,
        page: page, pageSize: pageSize);
  }

  // 8. 获取歌单歌曲
  static Future<List<Song>> getPlaylistSongs(String playlistId,
      {int page = 1, int pageSize = 50}) async {
    return _getCollectionSongs('/playlist/songs', playlistId,
        page: page, pageSize: pageSize);
  }

  static Future<List<Song>> _getCollectionSongs(String path, String id,
      {required int page, required int pageSize}) async {
    if (id.trim().isEmpty) return [];
    try {
      final cookie = await _getCookie();
      final response = await _dio.get('$baseApi$path', queryParameters: {
        'id': id,
        'page': page,
        'pagesize': pageSize,
        'cookie': cookie,
      });
      final data = response.data?['data'];
      final list = data is List
          ? data
          : data is Map
              ? (data['songs'] ?? data['song_list'] ?? data['list'] ?? [])
              : [];
      return (list as List)
          .whereType<Map>()
          .map((item) => Song.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    } catch (e) {
      print('获取集合歌曲失败 ($id): $e');
      return [];
    }
  }

  // 账号歌单与普通公开歌单使用不同的接口和 ID 体系。
  static Future<List<UserPlaylist>> getUserPlaylists() async {
    try {
      final cookie = await _getCookie();
      if (cookie.isEmpty) return [];
      final response =
          await _dio.get('$baseApi/user/playlist', queryParameters: {
        'cookie': cookie,
        'pagesize': 100,
      });
      final data = response.data?['data'];
      final list = data is Map ? data['info'] : data;
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map((item) => UserPlaylist.fromJson(Map<String, dynamic>.from(item)))
          .where((playlist) => playlist.globalCollectionId.isNotEmpty)
          .toList();
    } catch (e) {
      print('获取账号歌单失败: $e');
      return [];
    }
  }

  static Future<List<Song>> getAccountPlaylistSongs(
    String globalCollectionId,
  ) async {
    if (globalCollectionId.trim().isEmpty) return [];
    try {
      final cookie = await _getCookie();
      if (cookie.isEmpty) return [];
      final response = await _dio.get(
        '$baseApi/playlist/track/all',
        queryParameters: {
          'id': globalCollectionId,
          'pagesize': 200,
          'cookie': cookie,
        },
      );
      final data = response.data?['data'];
      final list = data is Map ? (data['info'] ?? data['songs'] ?? []) : [];
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map((item) => Song.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    } catch (e) {
      print('获取账号歌单歌曲失败 ($globalCollectionId): $e');
      return [];
    }
  }

  /// 为 AI 推荐获取我喜欢的歌曲（更大的 pagesize）。
  static Future<List<Song>> getFavoriteSongsForAI(
    String globalCollectionId,
  ) async {
    if (globalCollectionId.trim().isEmpty) return [];
    try {
      final cookie = await _getCookie();
      if (cookie.isEmpty) return [];
      final response = await _dio.get(
        '$baseApi/playlist/track/all',
        queryParameters: {
          'id': globalCollectionId,
          'pagesize': 150,
          'cookie': cookie,
        },
      );
      final data = response.data?['data'];
      final list = data is Map ? (data['info'] ?? data['songs'] ?? []) : [];
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map((item) => Song.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    } catch (e) {
      print('获取AI推荐收藏歌曲失败 ($globalCollectionId): $e');
      return [];
    }
  }

  // 9. 添加播放历史
  static Future<bool> addPlayHistory(Song song) async {
    if (song.hash.isEmpty) return false;

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('analytics_enabled') ?? true) {
      Map<String, dynamic> counts;
      try {
        counts = Map<String, dynamic>.from(
          jsonDecode(prefs.getString('play_statistics') ?? '{}'),
        );
      } on FormatException {
        counts = {};
      }
      counts[song.hash] = (counts[song.hash] as num? ?? 0).toInt() + 1;
      await prefs.setString('play_statistics', jsonEncode(counts));
    }
    if (!(prefs.getBool('save_history') ?? true)) return true;

    final now = DateTime.now();
    final records = _loadPlayHistoryRecords(prefs);
    final existingIndex =
        records.indexWhere((record) => record.hash == song.hash);
    if (existingIndex >= 0) {
      records[existingIndex] = records[existingIndex].replayed(song, now);
    } else {
      records.add(PlayHistoryRecord.fromSong(song, now));
    }
    records.sort((a, b) => b.playTime.compareTo(a.playTime));
    await prefs.setStringList(
      'play_history',
      records.take(1000).map((record) => jsonEncode(record.toJson())).toList(),
    );
    await prefs.setString('play_history_update_time', now.toIso8601String());
    return true;
  }

  // 10. 获取播放历史
  static Future<PlayHistoryData> getPlayHistory({
    int page = 1,
    int pageSize = 50,
    String filter = 'all',
    DateTime? now,
  }) async {
    if (page <= 0) page = 1;
    if (pageSize <= 0) pageSize = 50;
    if (filter.isEmpty) filter = 'all';

    final prefs = await SharedPreferences.getInstance();
    final currentTime = now ?? DateTime.now();
    final records = _loadPlayHistoryRecords(prefs)
      ..sort((a, b) => b.playTime.compareTo(a.playTime));
    final filteredRecords = records
        .where((record) => _matchesHistoryFilter(record, filter, currentTime))
        .toList();
    final totalCount = filteredRecords.length;
    final start = (page - 1) * pageSize;
    final pagedRecords = start >= totalCount
        ? <PlayHistoryRecord>[]
        : filteredRecords.skip(start).take(pageSize).toList();
    final updateTime = DateTime.tryParse(
          prefs.getString('play_history_update_time') ?? '',
        ) ??
        currentTime;
    return PlayHistoryData(
      records: pagedRecords,
      totalCount: totalCount,
      updateTime: updateTime,
    );
  }

  static List<PlayHistoryRecord> _loadPlayHistoryRecords(
    SharedPreferences prefs,
  ) {
    final records = <PlayHistoryRecord>[];
    for (final item in prefs.getStringList('play_history') ?? const []) {
      try {
        final decoded = jsonDecode(item);
        if (decoded is Map) {
          records.add(
            PlayHistoryRecord.fromJson(Map<String, dynamic>.from(decoded)),
          );
        }
      } on FormatException {
        continue;
      }
    }
    return records;
  }

  static bool _matchesHistoryFilter(
    PlayHistoryRecord record,
    String filter,
    DateTime now,
  ) {
    switch (filter) {
      case 'all':
        return true;
      case 'today':
        return _isSameDay(record.playTime, now);
      case 'yesterday':
        return _isSameDay(record.playTime, _addCalendarDays(now, -1));
      case 'week':
        return record.playTime.isAfter(_addCalendarDays(now, -7));
      default:
        return false;
    }
  }

  static DateTime _addCalendarDays(DateTime time, int days) => DateTime(
        time.year,
        time.month,
        time.day + days,
        time.hour,
        time.minute,
        time.second,
        time.millisecond,
        time.microsecond,
      );

  static bool _isSameDay(DateTime first, DateTime second) =>
      first.year == second.year &&
      first.month == second.month &&
      first.day == second.day;

  static Future<PlayHistoryData> clearPlayHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    await prefs.setStringList('play_history', const []);
    await prefs.setString('play_history_update_time', now.toIso8601String());
    return PlayHistoryData(records: const [], totalCount: 0, updateTime: now);
  }

  // 11. 收藏歌曲。登录后优先同步账号“我喜欢的”歌单，未登录时使用本地收藏。
  static Future<bool> addFavorite(Song song) async {
    final cookie = await _getCookie();
    if (cookie.isNotEmpty) {
      try {
        final response = await _dio.get(
          '$baseApi/playlist/tracks/add',
          queryParameters: {
            'listid': 2,
            'data': '${song.songName}|${song.hash}',
            'cookie': cookie,
          },
        );
        if (response.data?['status'] == 1 ||
            response.data?['error_code'] == 0) {
          return true;
        }
      } catch (_) {}
    }
    return _addLocalFavorite(song);
  }

  static Future<bool> removeFavorite(String hash) async {
    final cookie = await _getCookie();
    if (cookie.isNotEmpty) {
      try {
        final response = await _dio.get(
          '$baseApi/playlist/tracks/del',
          queryParameters: {'listid': 2, 'hash': hash, 'cookie': cookie},
        );
        if (response.data?['status'] == 1 ||
            response.data?['error_code'] == 0) {
          return true;
        }
      } catch (_) {}
    }
    final prefs = await SharedPreferences.getInstance();
    final records = prefs.getStringList('my_favorites') ?? [];
    records.removeWhere((item) => jsonDecode(item)['hash'] == hash);
    await prefs.setStringList('my_favorites', records);
    return true;
  }

  static Future<List<Song>> getFavorites() async {
    final cookie = await _getCookie();
    if (cookie.isNotEmpty) {
      final playlists = await getUserPlaylists();
      final favorite = playlists.where((playlist) => playlist.listId == 2);
      if (favorite.isNotEmpty) {
        return getAccountPlaylistSongs(favorite.first.globalCollectionId);
      }
    }
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList('my_favorites') ?? [])
        .map((item) => Song.fromJson(jsonDecode(item)))
        .toList();
  }

  static Future<bool> _addLocalFavorite(Song song) async {
    final prefs = await SharedPreferences.getInstance();
    final records = prefs.getStringList('my_favorites') ?? [];
    if (!records.any((item) => jsonDecode(item)['hash'] == song.hash)) {
      records.add(jsonEncode(song.toJson()));
      await prefs.setStringList('my_favorites', records);
    }
    return true;
  }

  // 12. 下载管理
  static Future<String?> downloadSong(Song song, {String? quality}) async {
    if (song.hash.trim().isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    var effectiveQuality =
        quality ?? prefs.getString('audio_quality') ?? '128k';
    if ((prefs.getBool('wifi_only_high_quality') ?? false) &&
        effectiveQuality != '128k') {
      final connections = await Connectivity().checkConnectivity();
      if (!connections.contains(ConnectivityResult.wifi) &&
          !connections.contains(ConnectivityResult.ethernet)) {
        effectiveQuality = '128k';
      }
    }
    final documents = await getApplicationDocumentsDirectory();
    // 优先使用设置中保存的自定义下载路径。
    var directory = prefs.getString('download_path')?.trim();
    if (directory == null || directory.isEmpty) {
      directory = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择歌曲保存目录',
        initialDirectory: documents.path,
      );
      if (directory == null || directory.isEmpty) return null;
      await prefs.setString('download_path', directory);
    }
    final downloadDirectory = Directory(directory);
    if (!await downloadDirectory.exists()) {
      try {
        await downloadDirectory.create(recursive: true);
      } catch (_) {
        directory = null;
      }
    }
    if (directory == null) return null;

    final playUrl = await getPlayUrl(song.hash, quality: effectiveQuality);
    if (playUrl == null || playUrl.isEmpty) return null;

    final extension = effectiveQuality == 'flac' ? '.flac' : '.mp3';
    final filename = _safeFilename(
      '${song.songName} - ${song.authorName}$extension',
    );
    final filePath = p.join(directory, filename);
    final tempPath = '$filePath.part';
    try {
      await _dio.download(playUrl, tempPath,
          options: Options(responseType: ResponseType.bytes));
      final file = File(tempPath);
      if (!await file.exists() || await file.length() == 0) return null;
      final target = File(filePath);
      if (await target.exists()) await target.delete();
      await file.rename(filePath);
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('download_lyrics') ?? true) {
        final lyrics =
            await getRawLyricsWithFormat(song.hash,
                songName: song.songName, artist: song.authorName);
        if (lyrics != null && lyrics.content.isNotEmpty) {
          await File(p.setExtension(filePath, '.${lyrics.format}'))
              .writeAsString(lyrics.content);
        }
      }
      await addDownloadRecord(song,
          filePath: filePath,
          fileSize: await target.length(),
          filename: filename);
      return filePath;
    } catch (e) {
      final partial = File(tempPath);
      if (await partial.exists()) await partial.delete();
      print('下载歌曲失败: $e');
      return null;
    }
  }

  static String _safeFilename(String filename) {
    final sanitized = filename.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return sanitized.isEmpty ? 'music.mp3' : sanitized;
  }

  static Future<bool> addDownloadRecord(Song song,
      {String filePath = '', int fileSize = 0, String filename = ''}) async {
    final prefs = await SharedPreferences.getInstance();
    final records = prefs.getStringList('download_records') ?? [];
    records.removeWhere((item) => jsonDecode(item)['hash'] == song.hash);
    records.insert(
        0,
        jsonEncode({
          ...song.toJson(),
          'filename': filename,
          'file_path': filePath,
          'file_size': fileSize,
          'download_time': DateTime.now().toIso8601String()
        }));
    await prefs.setStringList('download_records', records);
    return true;
  }

  static Future<List<Map<String, dynamic>>> getDownloadRecords(
      {int page = 1, int pageSize = 50}) async {
    final prefs = await SharedPreferences.getInstance();
    final records = (prefs.getStringList('download_records') ?? [])
        .map((item) => jsonDecode(item) as Map<String, dynamic>)
        .toList();
    final start = (page - 1) * pageSize;
    return start >= records.length
        ? []
        : records.skip(start).take(pageSize).toList();
  }

  static Future<void> removeDownloadRecord(Map<String, dynamic> record) async {
    final path = record['file_path']?.toString() ?? '';
    if (path.isNotEmpty) {
      final file = File(path);
      if (await file.exists()) await file.delete();
      for (final extension in const ['.krc', '.lrc']) {
        final lyrics = File(p.setExtension(path, extension));
        if (await lyrics.exists()) await lyrics.delete();
      }
    }
    final prefs = await SharedPreferences.getInstance();
    final records = prefs.getStringList('download_records') ?? [];
    records.removeWhere((item) =>
        jsonDecode(item)['hash'] == record['hash'] &&
        jsonDecode(item)['file_path'] == record['file_path']);
    await prefs.setStringList('download_records', records);
  }

  static Future<void> clearDownloadRecords() async {
    final records = await getDownloadRecords(pageSize: 100000);
    for (final record in records) {
      final path = record['file_path']?.toString() ?? '';
      if (path.isNotEmpty) {
        final file = File(path);
        if (await file.exists()) await file.delete();
        for (final extension in const ['.krc', '.lrc']) {
          final lyrics = File(p.setExtension(path, extension));
          if (await lyrics.exists()) await lyrics.delete();
        }
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('download_records');
  }

  // 13. 获取歌词
  static Future<LyricsContent?> getRawLyricsWithFormat(String hash,
      {String songName = '', String artist = ''}) async {
    if (hash.trim().isEmpty) return null;
    try {
      final cache = await MediaCacheService.instance;
      final cached = await cache.getLyrics(
        hash: hash,
        loader: () => _loadRawLyrics(hash, songName: songName, artist: artist),
      );
      return cached.content.trim().isEmpty
          ? null
          : LyricsContent(content: cached.content, format: cached.format);
    } catch (e) {
      print('获取歌词失败: $e');
      return null;
    }
  }

  static Future<String> _loadRawLyrics(String hash,
      {String songName = '', String artist = ''}) async {
    final cookie = await _getCookie();
    var content = await _fetchLyricsByHash(hash, cookie);
    print('播放调试: 歌词兜底 hash 直查取到 ${content.length} 字符');
    if (content.isEmpty && songName.trim().isNotEmpty) {
      // 兜底2：按 hash 查不到歌词时，用"歌名 + 歌手"联网搜索，
      // 取搜索结果的 hash 重新获取歌词；成功后由缓存层按原 hash 落盘。
      content = await _loadLyricsByNameSearch(songName, artist, cookie);
      print('播放调试: 歌词兜底歌名搜索取到 ${content.length} 字符');
    }
    return content;
  }

  /// 按 hash 获取歌词：/search/lyric 候选 → 官方 krcs 直搜 → /lyric 下载 → hash 直取兜底。
  static Future<String> _fetchLyricsByHash(String hash, String cookie) async {
    var content = '';
    var candidates = <Map<String, dynamic>>[];
    try {
      final search = await _getWithRateLimitRetry(
        '$baseApi/search/lyric',
        queryParameters: {
          'hash': hash,
          'cookie': cookie,
          'man': 'no',
        },
      );
      final raw = search?['candidates'];
      if (raw is List) {
        candidates =
            raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      }
      print('播放调试: /search/lyric candidates=${candidates.length}');
    } catch (e) {
      print('播放调试: 云端歌词搜索失败: $e');
    }

    if (candidates.isEmpty) {
      // 部署的 /search/lyric 模块异常（返回空）时，直连酷狗官方
      // krcs.kugou.com 按 hash 搜索歌词候选，拿 id/accesskey。
      candidates = await _searchKrcCandidatesOfficial(hash);
    }

    if (candidates.isNotEmpty) {
      final candidate = candidates.first;
      final id = candidate['id']?.toString() ?? '';
      final accessKey = candidate['accesskey']?.toString() ?? '';
      if (id.isNotEmpty && accessKey.isNotEmpty) {
        content = await _downloadLyricById(id, accessKey, cookie);
      }
    }

    if (content.isEmpty) {
      // 兜底1：部分部署下 /search/lyric 返回空但 /lyric 支持按 hash 直取。
      print('播放调试: /search/lyric 无候选，尝试 /lyric hash 直取');
      content = await _loadLyricsByHashDirect(hash, cookie);
    }
    return content;
  }

  /// 直连酷狗官方 krcs.kugou.com 按 hash 搜索歌词候选。
  /// 用于部署 API 的 /search/lyric 模块异常时的替代通道。
  static Future<List<Map<String, dynamic>>> _searchKrcCandidatesOfficial(
      String hash) async {
    try {
      final response = await _dio.get(
        'https://krcs.kugou.com/search',
        queryParameters: {'ver': 1, 'man': 'no', 'hash': hash},
      );
      final data = response.data;
      if (data is Map && data['errcode'] == 200) {
        final raw = data['candidates'];
        if (raw is List && raw.isNotEmpty) {
          print('播放调试: 官方 krcs 直搜命中 ${raw.length} 个候选');
          return raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
      }
    } catch (e) {
      print('播放调试: 官方 krcs 直搜失败: $e');
    }
    return [];
  }

  /// 按歌词候选的 id/accesskey 下载歌词：优先 krc（逐字），失败降级 lrc。
  static Future<String> _downloadLyricById(
      String id, String accessKey, String cookie) async {
    for (final format in const ['krc', 'lrc']) {
      try {
        final response = await _getWithRateLimitRetry(
          '$baseApi/lyric',
          queryParameters: {
            'id': id,
            'accesskey': accessKey,
            'decode': 'true',
            'fmt': format,
            'cookie': cookie,
          },
        );
        final decoded = response?['decodeContent']?.toString().trim() ?? '';
        if (decoded.isNotEmpty) return decoded;
      } catch (_) {
        // Continue with the lower fidelity format.
      }
    }
    return '';
  }

  /// 歌词兜底搜索：按"歌名 + 歌手"搜歌曲，用结果 hash 重取歌词（最多尝试 3 个）。
  static Future<String> _loadLyricsByNameSearch(
      String songName, String artist, String cookie) async {
    try {
      final keyword = artist.trim().isEmpty
          ? songName.trim()
          : '${songName.trim()} ${artist.trim()}';
      if (keyword.isEmpty) return '';
      final results = await searchSongs(keyword, pageSize: 10);
      var tried = 0;
      for (final candidate in results) {
        if (candidate.hash.trim().isEmpty) continue;
        if (++tried > 3) break;
        final content = await _fetchLyricsByHash(candidate.hash, cookie);
        if (content.isNotEmpty) {
          print('歌词兜底命中: "$keyword" -> '
              '${candidate.songName} - ${candidate.authorName}');
          return content;
        }
      }
    } catch (e) {
      print('按歌名搜索歌词失败: $e');
    }
    return '';
  }


  /// 兜底：直接按 hash 请求歌词（部分 KuGouMusicApi 部署支持 /lyric?hash=）。
  static Future<String> _loadLyricsByHashDirect(
      String hash, String cookie) async {
    for (final format in const ['krc', 'lrc']) {
      try {
        final response = await _getWithRateLimitRetry(
          '$baseApi/lyric',
          queryParameters: {
            'hash': hash,
            'decode': 'true',
            'fmt': format,
            'cookie': cookie,
          },
        );
        final content = response?['decodeContent']?.toString().trim() ?? '';
        if (content.isNotEmpty) return content;
      } catch (_) {
        // Continue with the lower fidelity format.
      }
    }
    return '';
  }

  /// 带限流退避的 GET：遇 429 时按 Retry-After 头（默认 5 秒，
  /// 上限 30 秒）等待后重试，最多重试 2 次，其余异常原样抛出。
  static Future<dynamic> _getWithRateLimitRetry(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    const maxRetries = 2;
    for (var attempt = 0;; attempt++) {
      try {
        final response =
            await _dio.get(path, queryParameters: queryParameters);
        return response.data;
      } on DioException catch (e) {
        if (e.response?.statusCode != 429 || attempt >= maxRetries) rethrow;
        var waitSeconds = 5;
        final retryAfter = e.response?.headers.value('retry-after');
        final parsed = retryAfter == null ? null : int.tryParse(retryAfter);
        if (parsed != null && parsed > 0 && parsed <= 30) waitSeconds = parsed;
        print('播放调试: 接口限流 429，$waitSeconds秒后重试 '
            '${path.replaceAll('$baseApi/', '')}（第${attempt + 1}次）');
        await Future<void>.delayed(Duration(seconds: waitSeconds));
      }
    }
  }

  static Future<String> getRawLyrics(String hash,
      {String songName = '', String artist = ''}) async {
    return (await getRawLyricsWithFormat(hash,
            songName: songName, artist: artist))
        ?.content ??
        '';
  }

  static Future<List<LyricLine>> getLyrics(String hash,
      {String songName = '', String artist = ''}) async {
    return parseLyrics(
        await getRawLyrics(hash, songName: songName, artist: artist));
  }

  // 8. 登录/用户体系 API

  /// 将登录相关异常转为用户可读文案。
  /// KuGouMusicApi 把上游业务失败（验证码错误/过期/风控等）统一包装成
  /// HTTP 502 返回，真实原因在响应体 data 字段里，优先提取展示。
  static String _friendlyLoginError(Object e) {
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map<String, dynamic>) {
        final detail = data['data'] ?? data['message'] ?? data['msg'];
        if (detail is String && detail.trim().isNotEmpty) {
          if (data['error_code'] == 20018) {
            return '触发酷狗风控，请稍后重试或改用二维码登录';
          }
          return detail;
        }
      }
      final status = e.response?.statusCode;
      if (status != null && status >= 500) {
        // 云端 CDN 收到 502 时会吞掉响应体拿不到具体原因，
        // 最常见原因是验证码错误或过期。
        return '登录失败（$status）：验证码可能错误或已过期，请重试或改用二维码登录';
      }
      if (status == 401 || status == 403) {
        return '请求被拒绝（$status），请稍后重试';
      }
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return '网络连接超时，请检查网络后重试';
        case DioExceptionType.connectionError:
          return '网络连接失败，请检查网络后重试';
        default:
          return '请求失败${status != null ? '（$status）' : ''}，请稍后重试';
      }
    }
    return e.toString();
  }

  static Future<Map<String, dynamic>> sendCaptcha(String mobile) async {
    try {
      final response = await _dio
          .get('$baseApi/captcha/sent', queryParameters: {'mobile': mobile});
      return response.data is Map<String, dynamic>
          ? response.data
          : {'status': 0, 'message': '发送失败'};
    } catch (e) {
      return {'status': 0, 'message': _friendlyLoginError(e)};
    }
  }

  static Future<Map<String, dynamic>> loginWithPhone(
      String mobile, String code) async {
    try {
      final cookie = await _getCookie();
      final queryParams = <String, dynamic>{
        'mobile': mobile,
        'code': code,
      };
      // 携带已保存的设备 Cookie，保证 token 与设备参数绑定。
      if (cookie.isNotEmpty) queryParams['cookie'] = cookie;
      final response =
          await _dio.get('$baseApi/login/cellphone', queryParameters: queryParams);
      if (response.data != null &&
          (response.data['error_code'] == 0 || response.data['status'] == 1)) {
        final token = response.data['data']?['token'] ?? '';
        final userid = response.data['data']?['userid'] ?? 0;
        final cookie = 'token=$token; userid=$userid';
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('user_cookie', cookie);
        await prefs.setString('user_token', token.toString());
        await prefs.setInt('user_id', int.tryParse(userid.toString()) ?? 0);
        await prefs.setString('login_method', 'phone');
        invalidateCookieCache();
        // 合并服务端下发的整套设备 Cookie，后续请求回传完整 Cookie。
        await _mergeDeviceCookies(response);
        return {'success': true, 'data': response.data['data']};
      }
      return {'success': false, 'message': response.data?['message'] ?? '登录失败'};
    } catch (e) {
      return {'success': false, 'message': _friendlyLoginError(e)};
    }
  }

  static Future<Map<String, dynamic>> generateQRKey() async {
    _qrLog('开始获取二维码 Key');
    try {
      final cookie = await _getCookie();
      final queryParams = <String, dynamic>{
        'platform': 'pc',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      if (cookie.isNotEmpty) queryParams['cookie'] = cookie;
      final response =
          await _dio.get('$baseApi/login/qr/key', queryParameters: queryParams);
      _qrLog('二维码 Key 响应: ${_qrSummary(response.data)}');
      return response.data is Map<String, dynamic> ? response.data : {};
    } catch (e) {
      _qrLog('二维码 Key 请求异常: $e');
      return {'status': 0, 'message': e.toString()};
    }
  }

  static Future<Map<String, dynamic>> createQRCode(String key) async {
    _qrLog('开始生成二维码图片，key=${_maskQrKey(key)}');
    try {
      final cookie = await _getCookie();
      final queryParams = <String, dynamic>{
        'key': key,
        'qrimg': 'true',
        'platform': 'pc',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      if (cookie.isNotEmpty) queryParams['cookie'] = cookie;
      final response =
          await _dio.get('$baseApi/login/qr/create', queryParameters: queryParams);
      final data = response.data is Map ? response.data['data'] : null;
      final base64 = data is Map ? data['base64']?.toString() : null;
      _qrLog(
          '二维码图片响应: ${_qrSummary(response.data)}, base64=${base64?.isNotEmpty == true ? '有' : '无'}');
      return response.data is Map<String, dynamic> ? response.data : {};
    } catch (e) {
      _qrLog('二维码图片请求异常: $e');
      return {'status': 0, 'message': e.toString()};
    }
  }

  static Future<Map<String, dynamic>> checkQRStatus(String key) async {
    _qrLog('检查二维码状态，key=${_maskQrKey(key)}');
    try {
      final cookie = await _getCookie();
      final queryParams = <String, dynamic>{
        'key': key,
        'platform': 'pc',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      // 关键：扫码确认时必须携带已保存的整套设备 Cookie，否则酷狗
      // 返回的 token 未正确绑定设备，后续 /user/detail 等接口会 20018。
      if (cookie.isNotEmpty) queryParams['cookie'] = cookie;
      final response =
          await _dio.get('$baseApi/login/qr/check', queryParameters: queryParams);
      final payload = response.data;
      if (payload is Map<String, dynamic>) {
        final data = payload['data'];
        final status =
            data is Map ? int.tryParse('${data['status']}') ?? -1 : -1;
        _qrLog('二维码状态响应: status=$status, ${_qrSummary(payload)}');
        if (data is Map && status == 4) {
          final token = '${data['token'] ?? ''}'.trim();
          final userid = int.tryParse('${data['userid'] ?? 0}') ?? 0;
          _qrLog(
              '检测到扫码登录成功: userid=$userid, token=${token.isNotEmpty ? '有' : '无'}');
          if (token.isNotEmpty && userid != 0) {
            final cookie = 'token=$token;userid=$userid';
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('user_cookie', cookie);
            await prefs.setString('user_token', token);
            await prefs.setInt('user_id', userid);
            await prefs.setString('login_method', 'qrcode');
            invalidateCookieCache();
            _qrLog('扫码登录 Cookie 已保存，长度=${cookie.length}');
            // 吸收服务端签发的设备参数（KUGOU_API_MID/dfid 等），
            // 后续请求由 _getCookie 合并携带完整 Cookie。
            await _mergeDeviceCookies(response);
            _qrLog('扫码登录完成，设备参数已吸收');
          } else {
            _qrLog('扫码成功但缺少 token 或 userid，未保存登录状态');
          }
        }
        return payload;
      }
      _qrLog('二维码状态响应格式错误: ${payload.runtimeType}');
      return {'status': 0, 'message': '二维码状态响应格式错误'};
    } catch (e) {
      _qrLog('二维码状态请求异常: $e');
      // 429/瞬时网络错误不能当作二维码过期（status 0 会终止 UI 轮询），
      // 返回 -1 让轮询继续、仅提示稍候重试。
      final isTransient = e is DioException &&
          (e.response?.statusCode == 429 ||
              e.type == DioExceptionType.connectionTimeout ||
              e.type == DioExceptionType.receiveTimeout ||
              e.type == DioExceptionType.connectionError);
      if (isTransient) {
        return {'status': -1, 'message': '查询频繁，稍候自动重试…'};
      }
      return {'status': -1, 'message': '网络异常，稍候自动重试…'};
    }
  }

  static void _qrLog(String message) {
    print('[扫码登录] $message');
  }

  static String _maskQrKey(String key) {
    if (key.length <= 8) return '***';
    return '${key.substring(0, 4)}...${key.substring(key.length - 4)}';
  }

  static String _qrSummary(dynamic payload) {
    if (payload is! Map) return 'type=${payload.runtimeType}';
    final data = payload['data'];
    final dataKeys = data is Map ? data.keys.join(',') : 'none';
    return 'code=${payload['code']}, error_code=${payload['error_code']}, '
        'status=${payload['status']}, dataKeys=[$dataKeys], '
        'message=${payload['message'] ?? payload['msg'] ?? ''}';
  }

  static Future<Map<String, dynamic>> getUserDetail() async {
    try {
      final cookie = await _getCookie();
      if (cookie.isEmpty) return {'success': false, 'message': '未登录'};
      final response = await _dio.get('$baseApi/user/detail', queryParameters: {
        'cookie': cookie,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      if (response.data != null && response.data['status'] == 1) {
        return {'success': true, 'data': response.data['data']};
      }
    } catch (e) {
      print('获取用户详情失败: $e');
    }
    return {'success': false};
  }

  static Future<Map<String, dynamic>> getVipDetail() async {
    try {
      final cookie = await _getCookie();
      if (cookie.isEmpty) return {'success': false, 'message': '未登录'};
      final response =
          await _dio.get('$baseApi/user/vip/detail', queryParameters: {
        'cookie': cookie,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      final payload = response.data;
      if (payload is Map) {
        final success = payload['success'] == true || payload['status'] == 1;
        if (success) {
          return {'success': true, 'data': payload['data']};
        }
        return {
          'success': false,
          'message': payload['message'] ?? payload['msg'] ?? '获取 VIP 详情失败',
        };
      }
    } on DioException catch (e) {
      print('获取 VIP 详情失败: HTTP ${e.response?.statusCode ?? '未知'}');
    } catch (e) {
      print('获取 VIP 详情失败: $e');
    }
    return {'success': false};
  }

  static Future<Map<String, dynamic>> claimDailyVip() async {
    try {
      final cookie = await _getCookie();
      final response = await _dio
          .get('$baseApi/youth/day/vip', queryParameters: {'cookie': cookie});
      return response.data is Map<String, dynamic>
          ? response.data
          : {'status': 0};
    } catch (e) {
      return {'status': 0, 'message': e.toString()};
    }
  }

  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('user_cookie');
    await prefs.remove('user_token');
    await prefs.remove('user_id');
    invalidateCookieCache();
  }

  /// 本地是否已保存登录凭证（登录成功时会写入 user_token/user_cookie）。
  static Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    final token = (prefs.getString('user_token') ?? '').trim();
    if (token.isNotEmpty) return true;
    final cookie = prefs.getString('user_cookie') ?? '';
    return cookie.contains('token=');
  }

  static List<LyricLine> parseLyrics(String content) {
    final result = _parseKrc(content);
    return result.isNotEmpty ? result : parseLrc(content);
  }

  static List<LyricLine> _parseKrc(String content) {
    final result = <LyricLine>[];
    final linePattern = RegExp(r'^\[(\d+),(\d+)\](.*)$');
    final wordPattern = RegExp(r'<(\d+),(\d+),\d+>([^<]*)');
    for (final rawLine in content.split(RegExp(r'\r?\n'))) {
      final lineMatch = linePattern.firstMatch(rawLine.trim());
      if (lineMatch == null) continue;
      final lineStart = int.parse(lineMatch.group(1)!);
      final lineDuration = int.parse(lineMatch.group(2)!);
      final words = <LyricWord>[];
      final text = StringBuffer();
      for (final match in wordPattern.allMatches(lineMatch.group(3)!)) {
        final wordText = match.group(3)!;
        text.write(wordText);
        words.add(LyricWord(
          time: Duration(milliseconds: lineStart + int.parse(match.group(1)!)),
          duration: Duration(milliseconds: int.parse(match.group(2)!)),
          text: wordText,
        ));
      }
      if (text.toString().trim().isNotEmpty) {
        result.add(LyricLine(
          time: Duration(milliseconds: lineStart),
          duration: Duration(milliseconds: lineDuration),
          text: text.toString(),
          words: words,
        ));
      }
    }
    result.sort((a, b) => a.time.compareTo(b.time));
    return result;
  }

  static List<LyricLine> parseLrc(String lrcContent) {
    final result = <LyricLine>[];
    final regExp = RegExp(r'\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]');
    for (final rawLine in lrcContent.split(RegExp(r'\r?\n'))) {
      final matches = regExp.allMatches(rawLine).toList();
      if (matches.isEmpty) continue;
      final text = rawLine.substring(matches.last.end).trim();
      if (text.isEmpty) continue;
      for (final match in matches) {
        final fraction = match.group(3) ?? '0';
        final millis = int.parse(fraction.padRight(3, '0').substring(0, 3));
        result.add(LyricLine(
          time: Duration(
            minutes: int.parse(match.group(1)!),
            seconds: int.parse(match.group(2)!),
            milliseconds: millis,
          ),
          text: text,
        ));
      }
    }
    result.sort((a, b) => a.time.compareTo(b.time));
    return result;
  }
}
