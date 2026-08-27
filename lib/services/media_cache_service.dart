import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

typedef AudioDownloader = Future<void> Function(String url, String path);
typedef LyricsLoader = Future<String> Function();

class CachedLyrics {
  final String content;
  final String format;

  const CachedLyrics({required this.content, required this.format});
}

class MediaCacheService {
  MediaCacheService({
    required Directory rootDirectory,
    AudioDownloader? audioDownloader,
  })  : _audioDirectory = Directory(p.join(rootDirectory.path, 'audio')),
        _lyricsDirectory = Directory(p.join(rootDirectory.path, 'lyrics')),
        _audioDownloader = audioDownloader ?? _downloadAudio;

  final Directory _audioDirectory;
  final Directory _lyricsDirectory;
  final AudioDownloader _audioDownloader;
  final Map<String, Future<File>> _audioRequests = {};
  final Map<String, Future<CachedLyrics>> _lyricsRequests = {};

  static Future<MediaCacheService>? _instance;

  static Future<MediaCacheService> get instance =>
      _instance ??= _createDefault();

  static Future<MediaCacheService> _createDefault() async {
    final cacheDirectory = await getApplicationCacheDirectory();
    return MediaCacheService(
      rootDirectory: Directory(p.join(cacheDirectory.path, 'media')),
    );
  }

  Future<File> getAudio({
    required String hash,
    required String quality,
    required String url,
  }) {
    final normalizedQuality = _normalizeQuality(quality);
    final key = '$hash|$normalizedQuality';
    return _audioRequests.putIfAbsent(
      key,
      () => _trackAudioRequest(key, hash, normalizedQuality, url),
    );
  }

  /// 探测本地已缓存的音频文件（不发起下载）：返回该 hash 下
  /// 音质最高且校验通过的一份；无缓存返回 null。
  /// [minQuality] 指定时只接受音质不低于它的缓存（低音质缓存
  /// 会回退到在线路径获取高音质）；传 null 接受任意音质。
  /// 供播放器实现"缓存命中直接播"的快路径，跳过取 URL/VIP 等网络请求。
  Future<File?> peekCachedAudio(String hash, {String? minQuality}) async {
    if (hash.isEmpty) return null;
    if (!await _audioDirectory.exists()) return null;
    final key = _fileKey(hash);
    final pattern =
        RegExp('^${RegExp.escape(key)}_(128k|320k|flac)\\.(mp3|flac)\$');
    final requiredRank = minQuality == null ? 0 : _qualityRank[_normalizeQuality(minQuality)] ?? 0;
    File? best;
    var bestRank = 0;
    for (final entity in _audioDirectory.listSync()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final match = pattern.firstMatch(name);
      if (match == null) continue;
      final rank = _qualityRank[match.group(1)] ?? 0;
      if (rank <= bestRank) continue;
      final metadata = File('${entity.path}.meta');
      if (!await _isValidAudio(entity, metadata)) continue;
      best = entity;
      bestRank = rank;
    }
    if (best == null) return null;
    if (bestRank < requiredRank) return null;
    return best;
  }

  /// 删除某 hash 的全部音频缓存（含 .meta）。
  /// 用于播放中发现文件损坏（解码失败/停滞）时失效缓存，下次播放重新下载。
  Future<void> invalidateAudio(String hash) async {
    if (hash.isEmpty) return;
    if (!await _audioDirectory.exists()) return;
    final key = _fileKey(hash);
    final pattern = RegExp(
        '^${RegExp.escape(key)}_(128k|320k|flac)\\.(mp3|flac)(\\.meta)?\$');
    for (final entity in _audioDirectory.listSync()) {
      if (entity is! File) continue;
      if (!pattern.hasMatch(p.basename(entity.path))) continue;
      try {
        await entity.delete();
      } on FileSystemException {
        // 删除失败：文件可能被播放器占用，下次再试。
      }
    }
  }

  Future<CachedLyrics> getLyrics({
    required String hash,
    required LyricsLoader loader,
  }) {
    return _lyricsRequests.putIfAbsent(
      hash,
      () => _trackLyricsRequest(hash, loader),
    );
  }

  Future<File> _trackAudioRequest(
    String key,
    String hash,
    String quality,
    String url,
  ) async {
    try {
      return await _loadAudio(hash, quality, url);
    } finally {
      _audioRequests.remove(key);
    }
  }

  Future<CachedLyrics> _trackLyricsRequest(
    String hash,
    LyricsLoader loader,
  ) async {
    try {
      return await _loadLyrics(hash, loader);
    } finally {
      _lyricsRequests.remove(hash);
    }
  }

  Future<File> _loadAudio(String hash, String quality, String url) async {
    await _audioDirectory.create(recursive: true);
    final normalized = _normalizeQuality(quality);
    final extension = normalized == 'flac' ? '.flac' : '.mp3';
    final path =
        p.join(_audioDirectory.path, '${_fileKey(hash)}_$normalized$extension');
    final target = File(path);
    final metadata = File('$path.meta');
    if (await _isValidAudio(target, metadata)) return target;

    await _deleteIfExists(target);
    await _deleteIfExists(metadata);
    final temporary =
        File('$path.${DateTime.now().microsecondsSinceEpoch}.part');
    try {
      await _audioDownloader(url, temporary.path);
      final length = await temporary.length();
      if (length <= 0) throw const FileSystemException('下载的音频为空');
      if (!_isValidAudioHeader(temporary)) {
        throw FileSystemException(
            '下载的内容不是有效的音频文件（可能是 HTML 错误页）', temporary.path);
      }
      // 拦截音质不符的响应（如请求无损但无 VIP 被降级为 MP3），
      // 避免把 MP3 内容存成 .flac 文件。
      if (normalized == 'flac' && !await _isFlacFile(temporary)) {
        throw FileSystemException(
            '下载的内容不是无损格式（服务器降级）', temporary.path);
      }
      await temporary.rename(target.path);
      await _writeMetadata(metadata, length);
      // 缓存写入成功后，就地清理同一首歌更低音质的重复缓存（只留最高音质）。
      await _dedupeAudioByKey(_fileKey(hash));
      return target;
    } catch (_) {
      await _deleteIfExists(temporary);
      await _deleteIfExists(target);
      await _deleteIfExists(metadata);
      rethrow;
    }
  }

  /// 读取本地歌词缓存内容（krc/lrc）；无缓存或校验失败返回空串。
  /// 供云盘同步等外部模块读取已缓存的歌词。
  Future<String> readCachedLyrics(String hash) async {
    if (hash.isEmpty) return '';
    final prefix = p.join(_lyricsDirectory.path, _fileKey(hash));
    for (final format in const ['krc', 'lrc']) {
      final file = File('$prefix.$format');
      final metadata = File('${file.path}.meta');
      if (!await _isValid(file, metadata)) continue;
      try {
        return await file.readAsString();
      } on FileSystemException {
        // 尝试下一个格式。
      }
    }
    return '';
  }

  Future<CachedLyrics> _loadLyrics(String hash, LyricsLoader loader) async {
    await _lyricsDirectory.create(recursive: true);
    final prefix = p.join(_lyricsDirectory.path, _fileKey(hash));
    for (final format in const ['krc', 'lrc']) {
      final file = File('$prefix.$format');
      final metadata = File('${file.path}.meta');
      if (await _isValid(file, metadata)) {
        try {
          return CachedLyrics(
              content: await file.readAsString(), format: format);
        } on FileSystemException {
          await _deleteIfExists(file);
          await _deleteIfExists(metadata);
        }
      }
    }

    final content = await loader();
    if (content.trim().isEmpty) {
      return const CachedLyrics(content: '', format: 'lrc');
    }
    final format = _detectLyricsFormat(content);
    final target = File('$prefix.$format');
    final metadata = File('${target.path}.meta');
    final temporary = File(
      '${target.path}.${DateTime.now().microsecondsSinceEpoch}.part',
    );
    try {
      await temporary.writeAsString(content, flush: true);
      final length = await temporary.length();
      await temporary.rename(target.path);
      await _writeMetadata(metadata, length);
      return CachedLyrics(content: content, format: format);
    } catch (_) {
      await _deleteIfExists(temporary);
      await _deleteIfExists(target);
      await _deleteIfExists(metadata);
      rethrow;
    }
  }

  /// 音频缓存校验：元数据一致 + 文件头必须是有效音频格式，
  /// 防止此前缓存的 HTML 错误页被当作音频。
  /// 另外 .flac 文件必须是真实 FLAC 头，清理历史上被误存为
  /// .flac 的降级 MP3（无 VIP 请求无损时服务器会返回 128K MP3）。
  Future<bool> _isValidAudio(File file, File metadata) async {
    if (!await _isValid(file, metadata)) return false;
    if (!_isValidAudioHeader(file) ||
        (file.path.toLowerCase().endsWith('.flac') &&
            !await _isFlacFile(file))) {
      await _deleteIfExists(file);
      await _deleteIfExists(metadata);
      return false;
    }
    return true;
  }

  /// 校验文件头是否为 FLAC（'fLaC' 魔数）。
  Future<bool> _isFlacFile(File file) async {
    try {
      final raf = await file.open();
      try {
        final header = await raf.read(4);
        return header.length == 4 &&
            header[0] == 0x66 && // f
            header[1] == 0x4C && // L
            header[2] == 0x61 && // a
            header[3] == 0x43; // C
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// 缓存文件基础校验：存在、非空、长度与 .meta 记录一致。
  Future<bool> _isValid(File file, File metadata) async {
    try {
      if (!await file.exists() || !await metadata.exists()) return false;
      final length = await file.length();
      if (length <= 0) return false;
      final decoded = jsonDecode(await metadata.readAsString());
      if (decoded is! Map || decoded['length'] != length) return false;
      return true;
    } on Object {
      await _deleteIfExists(file);
      await _deleteIfExists(metadata);
      return false;
    }
  }

  Future<void> _writeMetadata(File target, int length) async {
    final temporary = File(
      '${target.path}.${DateTime.now().microsecondsSinceEpoch}.part',
    );
    await temporary.writeAsString(jsonEncode({'length': length}), flush: true);
    await temporary.rename(target.path);
  }

  static bool _isValidAudioHeader(File file) {
    try {
      final raf = file.openSync(mode: FileMode.read);
      try {
        final header = raf.readSync(16);
        if (header.length < 4) return false;
        // MP3: ID3 tag or sync word 0xFF 0xFB/0xFF 0xF3/0xFF 0xF2
        if (header[0] == 0x49 && header[1] == 0x44 && header[2] == 0x33) {
          return true; // 'ID3'
        }
        if (header[0] == 0xFF &&
            (header[1] == 0xFB || header[1] == 0xF3 || header[1] == 0xF2)) {
          return true; // MP3 sync word
        }
        // FLAC: 'fLaC'
        if (header[0] == 0x66 &&
            header[1] == 0x4C &&
            header[2] == 0x61 &&
            header[3] == 0x43) {
          return true;
        }
        // RIFF (WAV)
        if (header[0] == 0x52 &&
            header[1] == 0x49 &&
            header[2] == 0x46 &&
            header[3] == 0x46) {
          return true;
        }
        // AAC ADTS: 0xFF 0xF1 or 0xFF 0xF9
        if (header[0] == 0xFF && (header[1] == 0xF1 || header[1] == 0xF9)) {
          return true;
        }
        // OGG: 'OggS'
        if (header[0] == 0x4F &&
            header[1] == 0x67 &&
            header[2] == 0x67 &&
            header[3] == 0x53) {
          return true;
        }
        // m4a/mp4: 'ftyp' at offset 4
        if (header.length >= 8 &&
            header[4] == 0x66 &&
            header[5] == 0x74 &&
            header[6] == 0x79 &&
            header[7] == 0x70) {
          return true;
        }
        return false;
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return false;
    }
  }

  static Future<void> _downloadAudio(String url, String path) async {
    await Dio().download(
      url,
      path,
      options: Options(headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36',
        'Accept': 'audio/mpeg,audio/*,*/*',
        'Accept-Encoding': 'identity',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        'Cache-Control': 'no-cache',
        'Referer': 'https://www.kugou.com/',
      }),
    );
  }

  static String _normalizeQuality(String quality) {
    switch (quality.toLowerCase()) {
      case '320':
      case '320k':
      case 'medium':
        return '320k';
      case 'flac':
      case 'high':
        return 'flac';
      default:
        return '128k';
    }
  }

  static String _fileKey(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  static String _detectLyricsFormat(String content) {
    final krcLine = RegExp(r'^\[\d+,\d+\](?:<\d+,\d+,\d+>)', multiLine: true);
    return krcLine.hasMatch(content) ? 'krc' : 'lrc';
  }

  static Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // A later validation or write will surface an unusable cache path.
    }
  }

  /// 音频音质优先级：值越大音质越高。
  static const Map<String, int> _qualityRank = {
    '128k': 1,
    '320k': 2,
    'flac': 3,
  };

  /// 删除文件返回其字节数（用于统计释放空间）。
  Future<int> _deleteWithMeta(File file) async {
    var freed = 0;
    try {
      if (await file.exists()) {
        freed += await file.length();
        await file.delete();
      }
    } on FileSystemException {
      // 删除失败由下次去重/校验兜底。
    }
    await _deleteIfExists(File('${file.path}.meta'));
    return freed;
  }

  /// 针对单个 key：只保留最高音质的一份缓存，删除低音质重复与其 .meta。
  /// 返回被释放的字节数。
  Future<int> _dedupeAudioByKey(String key) async {
    if (!await _audioDirectory.exists()) return 0;
    final pattern = RegExp(
        '^${RegExp.escape(key)}_(128k|320k|flac)\\.(mp3|flac)\$');
    final found = <MapEntry<File, int>>[];
    var keepRank = 0;
    var freed = 0;
    for (final e in _audioDirectory.listSync()) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (name.endsWith('.meta')) continue;
      final m = pattern.firstMatch(name);
      if (m == null) continue;
      // 文件名与实际内容不符（历史上被误存成 .flac 的降级 MP3）
      // 不参与排名，直接删除，避免它以"高音质"身份挤掉正确缓存。
      if (name.toLowerCase().endsWith('.flac') && !await _isFlacFile(e)) {
        freed += await _deleteWithMeta(e);
        continue;
      }
      final rank = _qualityRank[m.group(1)!] ?? 0;
      if (rank > keepRank) keepRank = rank;
      found.add(MapEntry(e, rank));
    }
    for (final entry in found) {
      if (entry.value < keepRank) freed += await _deleteWithMeta(entry.key);
    }
    return freed;
  }

  /// 全量去重：对缓存目录中每首歌只保留最高音质那份，释放空间。
  Future<int> dedupeAudioCache() async {
    if (!await _audioDirectory.exists()) return 0;
    final keys = <String>{};
    final pattern = RegExp(r'^(.+)_(128k|320k|flac)\.(mp3|flac)$');
    for (final e in _audioDirectory.listSync()) {
      final m = pattern.firstMatch(p.basename(e.path));
      if (m != null) keys.add(m.group(1)!);
    }
    var freed = 0;
    for (final key in keys) {
      freed += await _dedupeAudioByKey(key);
    }
    return freed;
  }
}
