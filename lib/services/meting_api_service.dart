import 'dart:convert';
import 'package:dio/dio.dart';

/// Meting 备用播放源客户端。
///
/// 调用自建 Meting API（PHP 版，index.php 已打 `type=search` 补丁）：
///   search: GET {base}?server=netease&type=search&id=<query>  -> JSON 数组
///   url:    GET {base}?server=netease&type=url&id=<id>        -> 302 重定向到真实 mp3
///   lrc:    GET {base}?server=netease&type=lrc&id=<id>        -> 裸 LRC 文本
///
/// 用途：酷狗拿不到播放 URL（VIP/版权/风控）时，按「歌名 + 歌手」在 meting
/// 聚合源（默认网易云）搜索同名歌曲兜底播放。
class MetingSong {
  final String name;
  final String artist;
  final String album;
  final String id;

  /// 封面代理地址（meting ?type=pic 302 到 CDN，可直接作为 Image URL）。
  final String pic;

  const MetingSong({
    required this.name,
    required this.artist,
    required this.album,
    required this.id,
    this.pic = '',
  });

  factory MetingSong.fromJson(Map<String, dynamic> json) => MetingSong(
        name: (json['name'] as String?) ?? '',
        artist: (json['artist'] as String?) ?? '',
        album: (json['album'] as String?) ?? '',
        id: (json['id']?.toString()) ?? '',
        pic: (json['pic'] as String?) ?? '',
      );

  @override
  String toString() => 'MetingSong($name / $artist / id=$id)';
}

class MetingApiService {
  /// 自建 Meting API 地址（宝塔 nginx /meting/ 反代到 Docker 127.0.0.1:8088）。
  static const String baseUrl = 'http://101.35.164.122/meting/';

  /// 默认聚合源：netease | qq | kugou | kuwo | migu。
  static const String server = 'netease';

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
    // Meting `?type=url` 是 302 重定向到真实媒体地址，dio 默认跟随。
    followRedirects: true,
    maxRedirects: 5,
    headers: {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    },
  ));

  /// 搜索并按「原唱优先」启发式重排。
  ///
  /// netease 源的搜索相关性对原唱不友好（翻唱/Live/DJ 版常排在前面，
  /// 例如搜「晴天 周杰伦」首条是翻唱），这里按以下信号重排：
  ///  - 歌名/歌手含「原唱」标记（如「晴天 (原唱 周杰伦)」）几乎必是翻唱，重罚
  ///  - 括号内含 Live/DJ/版/女声/男声/翻唱/伴奏 等版本词罚分
  ///  - 搜索词含歌手段时，歌手精确匹配强加分（合作曲目次之，不匹配罚分）
  ///  - 歌名与搜索词歌名段精确相等加分
  ///  - 同分时保持网易云原始相关性顺序（含信息量，做稳定 tie-breaker）
  static Future<List<MetingSong>> searchRanked(String query) async {
    final results = await search(query);
    if (results.length < 2) return results;

    // 约定搜索词为「歌名 歌手」或纯歌名。
    final parts = query.trim().split(RegExp(r'\s+'));
    final nameQuery = parts.isNotEmpty ? parts.first : '';
    final artistQuery = parts.length > 1 ? parts.sublist(1).join(' ') : '';

    final indexed = List<int>.generate(results.length, (i) => i);
    indexed.sort((a, b) {
      final sa = _originalScore(results[a], nameQuery, artistQuery, a);
      final sb = _originalScore(results[b], nameQuery, artistQuery, b);
      return sb.compareTo(sa);
    });
    return [for (final i in indexed) results[i]];
  }

  /// 原唱优先评分，分数越高越靠前。
  static int _originalScore(
    MetingSong song,
    String nameQuery,
    String artistQuery,
    int index,
  ) {
    var score = 0;
    final name = song.name.toLowerCase();
    final artist = song.artist.toLowerCase();
    final nq = nameQuery.toLowerCase();
    final aq = artistQuery.toLowerCase();

    // 翻唱强信号：「(原唱 周杰伦)」这类标记几乎必是翻唱。
    if (name.contains('原唱') || artist.contains('原唱')) score -= 100;

    // 括号内的版本/二创标记（女声版、DJ版、Live、伴奏……）。
    if (RegExp(
            r'[（(][^)）]*(live|dj|版|女声|男声|深情|钢琴|吉他|remix|cover|翻|伴奏|铃声|片段|串烧)[^)）]*[)）]')
        .hasMatch(name)) {
      score -= 40;
    }

    // 歌手匹配：搜索词带歌手段时精确匹配最优。
    if (aq.isNotEmpty) {
      if (artist == aq) {
        score += 100;
      } else if (artist.contains(aq) || aq.contains(artist)) {
        // 合作曲目（如「周杰伦/温岚」）。
        score += 70;
      } else {
        score -= 60;
      }
    }

    // 歌名匹配：精确相等最优，前缀匹配次之。
    if (nq.isNotEmpty) {
      if (name == nq) {
        score += 30;
      } else if (name.startsWith(nq)) {
        score += 15;
      }
    }

    // 原始相关性做稳定排序的 tie-breaker。
    return score * 1000 - index;
  }

  /// 按关键字搜索（建议 "歌名 歌手"）。
  static Future<List<MetingSong>> search(String query) async {
    if (query.trim().isEmpty) return const [];
    try {
      final resp = await _dio.get(baseUrl, queryParameters: {
        'server': server,
        'type': 'search',
        'id': query,
      });
      // 自建 meting 返回 Content-Type "application/json; charset=utf-8;"
      // （结尾多一个分号），dio 不会自动解码为 List，需手动 jsonDecode。
      dynamic data = resp.data;
      if (data is String) {
        try {
          data = jsonDecode(data);
        } catch (_) {
          return const [];
        }
      }
      if (data is List) {
        return data
            .whereType<Map>()
            .map((m) => MetingSong.fromJson(Map<String, dynamic>.from(m)))
            .toList();
      }
    } catch (e) {
      print('Meting 搜索失败: $e');
    }
    return const [];
  }

  /// 获取真实播放地址（跟随 302 后返回最终直链）。
  ///
  /// 仅当请求确实发生了重定向（`redirects` 非空）才返回 `realUri`，
  /// 避免 meting 端点以 200 JSON 兜底时误把 API 地址当播放地址。
  static Future<String?> getPlayUrl(String id) async {
    if (id.trim().isEmpty) return null;
    try {
      final resp = await _dio.get(baseUrl, queryParameters: {
        'server': server,
        'type': 'url',
        'id': id,
      });
      if (resp.redirects.isEmpty) {
        print('Meting url 未发生重定向（可能无权限）: id=$id');
        return null;
      }
      final finalUrl = resp.realUri.toString();
      if (finalUrl.startsWith('http://') || finalUrl.startsWith('https://')) {
        return finalUrl;
      }
    } catch (e) {
      print('Meting 播放地址失败: id=$id error=$e');
    }
    return null;
  }

  /// 获取歌词（裸 LRC 文本）。
  static Future<String?> getLyrics(String id, {String server = 'netease'}) async {
    if (id.trim().isEmpty) return null;
    try {
      final resp = await _dio.get(baseUrl, queryParameters: {
        'server': server,
        'type': 'lrc',
        'id': id,
      });
      final data = resp.data;
      if (data is String && data.trim().isNotEmpty) return data.trim();
    } catch (e) {
      print('Meting 歌词失败: server=$server id=$id error=$e');
    }
    return null;
  }

  /// 酷狗歌词兜底：Meting 的 kugou 源直接以歌曲 hash（小写）作为 id，
  /// 因此无需搜索即可按 hash 直取歌词。
  static Future<String?> getKugouLyricsByHash(String hash) {
    if (hash.trim().isEmpty) return Future.value(null);
    return getLyrics(hash.trim().toLowerCase(), server: 'kugou');
  }

  /// 网易云歌词兜底：按「歌名 + 歌手」搜索，歌手匹配过滤后，
  /// 返回第一个能拿到歌词的结果的 LRC 文本。
  static Future<String?> getLyricsBySearch(String songName, String artist) async {
    final name = songName.trim();
    if (name.isEmpty) return null;

    final results =
        await search(artist.trim().isNotEmpty ? '$name $artist' : name);
    for (final song in results) {
      if (!_artistMatches(song.artist, artist)) continue;
      final lyrics = await getLyrics(song.id);
      if (lyrics != null && lyrics.isNotEmpty) return lyrics;
    }
    return null;
  }

  /// 兜底入口：按「歌名 + 歌手」搜索 meting，歌手匹配过滤后，
  /// 返回第一个能拿到真实播放地址的结果。
  ///
  /// [artist] 为空时不做歌手过滤；候选为空时也放行（不拦截翻唱）。
  static Future<({String url, MetingSong song})?> findFallbackPlayUrl({
    required String songName,
    required String artist,
  }) async {
    final name = songName.trim();
    if (name.isEmpty) return null;

    final query = artist.trim().isNotEmpty ? '$name $artist' : name;
    final results = await searchRanked(query);
    if (results.isEmpty) return null;

    for (final song in results) {
      if (!_artistMatches(song.artist, artist)) continue;
      final url = await getPlayUrl(song.id);
      if (url != null) return (url: url, song: song);
    }
    return null;
  }

  /// 歌手包含匹配（不区分大小写）。任一侧为空视为匹配。
  static bool _artistMatches(String candidate, String target) {
    final t = target.trim().toLowerCase();
    final c = candidate.trim().toLowerCase();
    if (t.isEmpty || c.isEmpty) return true;
    return c.contains(t) || t.contains(c);
  }
}
