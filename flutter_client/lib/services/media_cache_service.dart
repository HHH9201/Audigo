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
      return decoded is Map && decoded['length'] == length;
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

  static Future<void> _downloadAudio(String url, String path) async {
    await Dio().download(
      url,
      path,
      options: Options(headers: const {'Accept-Encoding': 'identity'}),
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
