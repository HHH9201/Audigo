import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import 'media_cache_service.dart';

/// WebDAV 云盘同步服务（123 云盘等标准 WebDAV 服务）。
///
/// - 歌曲与歌词自动备份到云盘（命名 "歌手 - 歌名.ext"，均放在授权目录）
/// - 在线接口失败（无 VIP / 上游故障）时从云盘兜底获取音频与歌词
/// - 云盘音频镜像下载到本地镜像目录，二次播放直接走本地
class WebDavService {
  WebDavService._();

  static final WebDavService instance = WebDavService._();

  static const _propfindBody = '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:">'
      '<d:prop><d:resourcetype/><d:getcontentlength/></d:prop>'
      '</d:propfind>';

  Dio? _dio;
  String _baseUrl = '';
  String _authHeader = '';
  String _remoteDir = '';
  bool _enabled = false;
  bool _autoUpload = true;
  bool _configLoaded = false;

  /// 进行中的同步（按歌曲去重，避免重复上传）。
  final Set<String> _syncInFlight = {};

  Directory? _mirrorDirectory;

  bool get isReady => _enabled && _baseUrl.isNotEmpty;

  bool get canAutoUpload => isReady && _autoUpload;

  /// 读取配置（首次调用或设置页保存后调用）。
  Future<void> reload() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl =
        (prefs.getString('webdav_url') ?? '').trim().replaceAll(RegExp(r'/+$'), '');
    final user = (prefs.getString('webdav_user') ?? '').trim();
    final password = prefs.getString('webdav_password') ?? '';
    var remoteDir = (prefs.getString('webdav_dir') ?? '/').trim();
    if (remoteDir.isNotEmpty && !remoteDir.startsWith('/')) {
      remoteDir = '/$remoteDir';
    }
    _remoteDir = remoteDir.replaceAll(RegExp(r'/+$'), '');
    _enabled = prefs.getBool('webdav_enabled') ?? false;
    _autoUpload = prefs.getBool('webdav_auto_upload') ?? true;
    _authHeader = user.isEmpty || password.isEmpty
        ? ''
        : 'Basic ${base64Encode(utf8.encode('$user:$password'))}';
    // 信息不全时强制视为未启用，避免半配置状态发起请求。
    if (_baseUrl.isEmpty || user.isEmpty || password.isEmpty) {
      _enabled = false;
    }
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      // 上传/下载大文件可能较慢（123 云盘免费版限速）。
      receiveTimeout: const Duration(minutes: 20),
      sendTimeout: const Duration(minutes: 20),
      validateStatus: (status) => status != null && status < 500,
    ));
    _configLoaded = true;
  }

  Future<void> _ensureConfig() async {
    if (!_configLoaded) await reload();
  }

  Map<String, String> get _authHeaders =>
      _authHeader.isEmpty ? const {} : {'Authorization': _authHeader};

  /// WebDAV 路径按段 URL 编码（中文文件名）。
  String _encodePath(String path) => path
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .map(Uri.encodeComponent)
      .join('/');

  Uri _remoteUri(String path) {
    final encoded = _encodePath(path);
    return Uri.parse('$_baseUrl${encoded.isEmpty ? '' : '/$encoded'}');
  }

  /// 远端完整路径（拼接授权目录）。
  String _remotePath(String fileName) =>
      '$_remoteDir/$fileName'.replaceAll('//', '/');

  /// 云盘目录布局：歌曲与歌词分目录存放，便于管理。
  /// 布局可随 [subDir] 切换（歌词/音乐各自调用）。
  String _remoteAudioPath(String fileName) =>
      _remotePath('音乐文件/$fileName');

  String _remoteLyricPath(String fileName) =>
      _remotePath('歌词文件/$fileName');

  /// 生成安全的远端文件名："歌手 - 歌名"。
  String safeFileName(String artist, String songName) {
    final prefix = artist.trim().isEmpty ? '' : '${artist.trim()} - ';
    var name = '$prefix${songName.trim()}';
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return name.isEmpty ? '未知歌曲' : name;
  }

  Future<Response<String>> _propfind(String path, {required bool depthOne}) {
    return _dio!.request<String>(
      _remoteUri(path).toString(),
      data: _propfindBody,
      options: Options(
        method: 'PROPFIND',
        contentType: 'application/xml',
        headers: {..._authHeaders, 'Depth': depthOne ? '1' : '0'},
        responseType: ResponseType.plain,
      ),
    );
  }

  /// 测试连接；成功返回 null，失败返回错误描述。
  Future<String?> testConnection() async {
    await _ensureConfig();
    if (!isReady || _dio == null) return '请先填写服务器地址、账号与应用密码';
    try {
      final root = _remoteDir.isEmpty ? '/' : _remoteDir;
      final response = await _propfind(root, depthOne: false);
      return switch (response.statusCode) {
        207 => null,
        401 => '账号或应用密码错误',
        403 => '无权访问该目录',
        404 => '远端目录不存在',
        _ => '服务器返回 ${response.statusCode}',
      };
    } on DioException catch (e) {
      return '连接失败: ${e.message ?? e.type.name}';
    }
  }

  /// 判断远端文件是否存在。
  Future<bool> exists(String remotePath) async {
    try {
      final response = await _propfind(remotePath, depthOne: false);
      return response.statusCode == 207;
    } on DioException {
      return false;
    }
  }

  /// 逐级创建远端目录（已存在时服务端返回 405，忽略即可）。
  Future<void> _ensureRemoteDirs(String remotePath) async {
    final segments =
        remotePath.split('/').where((s) => s.isNotEmpty).toList();
    for (var i = 1; i < segments.length; i++) {
      final dir = '/${segments.sublist(0, i).join('/')}';
      try {
        await _dio!.request(
          _remoteUri(dir).toString(),
          options: Options(method: 'MKCOL', headers: _authHeaders),
        );
      } on DioException {
        // 网络抖动时交给后续 PUT 报错。
      }
    }
  }

  /// 上传本地文件到远端路径。
  Future<void> uploadFile(File local, String remotePath) async {
    await _ensureRemoteDirs(remotePath);
    final response = await _dio!.put(
      _remoteUri(remotePath).toString(),
      data: local.openRead(),
      options: Options(
        headers: {
          ..._authHeaders,
          'Content-Length': await local.length(),
        },
      ),
    );
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw HttpException('上传失败: HTTP $status');
    }
  }

  /// 从云盘下载歌词（krc 优先，lrc 兜底）；未命中返回空串。
  Future<String> fetchLyrics({
    required String songName,
    required String artist,
  }) async {
    await _ensureConfig();
    if (!isReady || _dio == null) return '';
    final base = safeFileName(artist, songName);
    for (final extension in const ['.krc', '.lrc']) {
      try {
        final response = await _dio!.get<String>(
          _remoteUri(_remoteLyricPath('$base$extension')).toString(),
          options: Options(
            responseType: ResponseType.plain,
            headers: _authHeaders,
          ),
        );
        if (response.statusCode == 200) {
          final content = (response.data ?? '').trim();
          if (content.isNotEmpty) return content;
        }
      } on DioException {
        continue;
      }
    }
    return '';
  }

  Future<Directory> _mirrorDir() async {
    if (_mirrorDirectory != null) return _mirrorDirectory!;
    final cache = await getApplicationCacheDirectory();
    _mirrorDirectory = Directory(p.join(cache.path, 'webdav', 'audio'));
    await _mirrorDirectory!.create(recursive: true);
    return _mirrorDirectory!;
  }

  /// 从云盘获取歌曲音频：本地镜像命中直接返回，否则下载。
  /// 未配置 / 未命中返回 null。
  Future<File?> fetchAudio({required Song song}) async {
    await _ensureConfig();
    if (!isReady || _dio == null) return null;
    final dir = await _mirrorDir();
    final base = safeFileName(song.authorName, song.songName);
    for (final extension in const ['.flac', '.mp3']) {
      final local = File(p.join(dir.path, '$base$extension'));
      if (await local.exists() && await local.length() > 0) {
        print('云盘同步: 本地镜像命中 ${local.path}');
        return local;
      }
      try {
        final response = await _dio!.download(
          _remoteUri(_remoteAudioPath('$base$extension')).toString(),
          local.path,
          options: Options(headers: _authHeaders),
        );
        if (response.statusCode == 200 && await local.length() > 0) {
          print('云盘同步: 音频已从云盘下载 ${local.path}');
          return local;
        }
        await _deleteLocal(local);
      } on DioException {
        await _deleteLocal(local);
        continue;
      }
    }
    return null;
  }

  Future<void> _deleteLocal(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 忽略清理失败。
    }
  }

  /// 播放成功后自动同步：歌曲 + 歌词备份到云盘（已存在则跳过）。
  Future<void> syncSongIfNeeded(Song song, File localAudio) async {
    await _ensureConfig();
    if (!canAutoUpload) return;
    final key = song.hash.isEmpty
        ? '${song.authorName}|${song.songName}'
        : song.hash;
    if (_syncInFlight.contains(key)) return;
    _syncInFlight.add(key);
    try {
      final base = safeFileName(song.authorName, song.songName);
      final extension = p.extension(localAudio.path).toLowerCase();
      final remoteAudio = _remoteAudioPath('$base$extension');
      if (!await exists(remoteAudio)) {
        print('云盘同步: 上传歌曲 $base$extension');
        await uploadFile(localAudio, remoteAudio);
      }
      await syncLyricsIfNeeded(song);
    } catch (e) {
      print('云盘同步: 歌曲上传失败 $e');
    } finally {
      _syncInFlight.remove(key);
    }
  }

  /// 歌词同步：优先用 [content]，否则读本地歌词缓存；已存在则跳过。
  Future<void> syncLyricsIfNeeded(Song song, {String? content}) async {
    await _ensureConfig();
    if (!canAutoUpload) return;
    try {
      var text = content?.trim() ?? '';
      if (text.isEmpty && song.hash.isNotEmpty) {
        final cache = await MediaCacheService.instance;
        text = await cache.readCachedLyrics(song.hash);
      }
      if (text.isEmpty) return;
      // KRC 解码后含逐字时间标记 <mm,ms,dur>，据此区分扩展名。
      final isKrc = RegExp(r'<\d+,\d+,\d+>').hasMatch(text);
      final extension = isKrc ? '.krc' : '.lrc';
      final base = safeFileName(song.authorName, song.songName);
      final remoteLyrics = _remoteLyricPath('$base$extension');
      if (await exists(remoteLyrics)) return;
      print('云盘同步: 上传歌词 $base$extension');
      final temp = File(
          '${await _tempLyricPath()}.${DateTime.now().millisecondsSinceEpoch}');
      await temp.writeAsString(text, flush: true);
      try {
        await uploadFile(temp, remoteLyrics);
      } finally {
        await _deleteLocal(temp);
      }
    } catch (e) {
      print('云盘同步: 歌词上传失败 $e');
    }
  }

  Future<String> _tempLyricPath() async {
    final dir = await _mirrorDir();
    return p.join(dir.path, 'lyric.tmp');
  }
}
