import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const localMusicIdPrefix = 'local-';

class LocalMusicFile {
  final String path;
  final int modified;
  final int size;

  const LocalMusicFile({
    required this.path,
    required this.modified,
    required this.size,
  });
}

class LocalMusicIndexResult {
  final Map<String, Map<String, dynamic>> metadataByPath;
  final Map<String, String> hashToPath;

  const LocalMusicIndexResult({
    required this.metadataByPath,
    required this.hashToPath,
  });

  List<Map<String, dynamic>> get uniqueMetadata {
    final seen = <String>{};
    return metadataByPath.values.where((metadata) {
      final contentId = metadata['contentId'] as String;
      return seen.add(contentId);
    }).toList();
  }

  String? resolvePath(String hash) {
    final mapped = hashToPath[hash];
    if (mapped != null) return mapped;
    return File(hash).existsSync() ? hash : null;
  }
}

typedef LocalMetadataReader = Future<List<Map<String, dynamic>>> Function(
  List<Map<String, dynamic>> inputs,
);

class LocalMusicIndex {
  final File cacheFile;

  const LocalMusicIndex(this.cacheFile);

  Future<LocalMusicIndexResult> update(
    Iterable<LocalMusicFile> files, {
    required String coverDirectory,
    required LocalMetadataReader readMetadata,
  }) async {
    final cached = await _load();
    final current = <String, Map<String, dynamic>>{};
    final pending = <Map<String, dynamic>>[];
    final sortedFiles = files.toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in sortedFiles) {
      final old = cached[file.path];
      if (old != null &&
          old['modified'] == file.modified &&
          old['size'] == file.size &&
          old['contentId'] is String) {
        current[file.path] = old;
        continue;
      }
      final contentId = await contentIdForFile(File(file.path));
      pending.add({
        'path': file.path,
        'modified': file.modified,
        'size': file.size,
        'contentId': contentId,
        'coverDirectory': coverDirectory,
      });
    }

    if (pending.isNotEmpty) {
      for (final metadata in await readMetadata(pending)) {
        current[metadata['path'] as String] = metadata;
      }
    }

    final hashToPath = <String, String>{};
    for (final entry in current.entries) {
      hashToPath.putIfAbsent(
        entry.value['contentId'] as String,
        () => entry.key,
      );
    }
    await _save(current, hashToPath);
    await _removeUnusedCovers(current, coverDirectory);
    return LocalMusicIndexResult(
      metadataByPath: current,
      hashToPath: hashToPath,
    );
  }

  Future<Map<String, Map<String, dynamic>>> _load() async {
    if (!await cacheFile.exists()) return {};
    try {
      final decoded = jsonDecode(await cacheFile.readAsString());
      if (decoded is! Map<String, dynamic>) return {};
      final rawFiles = decoded['files'];
      final source = rawFiles is Map ? rawFiles : decoded;
      return source.map<String, Map<String, dynamic>>(
        (path, metadata) => MapEntry(
          path.toString(),
          Map<String, dynamic>.from(metadata as Map),
        ),
      );
    } on FormatException {
      return {};
    } on FileSystemException {
      return {};
    } on TypeError {
      return {};
    }
  }

  Future<void> _save(
    Map<String, Map<String, dynamic>> metadata,
    Map<String, String> hashToPath,
  ) async {
    await cacheFile.parent.create(recursive: true);
    final temporary = File('${cacheFile.path}.tmp');
    try {
      await temporary.writeAsString(
        jsonEncode({
          'version': 2,
          'files': metadata,
          'hashToPath': hashToPath,
        }),
        flush: true,
      );
      await temporary.rename(cacheFile.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _removeUnusedCovers(
    Map<String, Map<String, dynamic>> metadata,
    String coverDirectory,
  ) async {
    final directory = Directory(coverDirectory);
    if (!await directory.exists()) return;
    final used = metadata.values
        .map((item) => item['coverPath'])
        .whereType<String>()
        .toSet();
    await for (final entity in directory.list()) {
      if (entity is File && !used.contains(entity.path)) {
        await entity.delete();
      }
    }
  }
}

Future<String> contentIdForFile(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return '$localMusicIdPrefix$digest';
}
