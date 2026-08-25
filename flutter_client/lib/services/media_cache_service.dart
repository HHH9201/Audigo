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
    final extension = quality == 'flac' ? '.flac' : '.mp3';
    final path =
        p.join(_audioDirectory.path, '${_fileKey(hash)}_$quality$extension');
    final target = File(path);
    final metadata = File('$path.meta');
    if (await _isValid(target, metadata)) return target;

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
      await temporary.rename(target.path);
      await _writeMetadata(metadata, length);
      return target;
    } catch (_) {
      await _deleteIfExists(temporary);
      await _deleteIfExists(target);
      await _deleteIfExists(metadata);
      rethrow;
    }
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

  Future<bool> _isValid(File file, File metadata) async {
    try {
      if (!await file.exists() || !await metadata.exists()) return false;
      final length = await file.length();
      if (length <= 0) return false;
      final decoded = jsonDecode(await metadata.readAsString());
      if (decoded is! Map || decoded['length'] != length) return false;
      // 校验文件头，防止之前缓存的 HTML 错误页被当作音频
      if (!_isValidAudioHeader(file)) {
        await _deleteIfExists(file);
        await _deleteIfExists(metadata);
        return false;
      }
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
}
