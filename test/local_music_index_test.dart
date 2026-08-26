import 'dart:convert';
import 'dart:io';

import 'package:audigo/services/local_music_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late Directory covers;
  late File cacheFile;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('musichub_local_index');
    covers = Directory('${directory.path}${Platform.pathSeparator}covers')
      ..createSync();
    cacheFile = File('${directory.path}${Platform.pathSeparator}metadata.json');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  LocalMusicFile snapshot(File file) {
    final stat = file.statSync();
    return LocalMusicFile(
      path: file.path,
      modified: stat.modified.millisecondsSinceEpoch,
      size: stat.size,
    );
  }

  Future<List<Map<String, dynamic>>> metadata(
    List<Map<String, dynamic>> inputs,
  ) async {
    return inputs
        .map((input) => <String, dynamic>{
              ...input,
              'title': File(input['path'] as String).uri.pathSegments.last,
              'artist': 'Artist',
            })
        .toList();
  }

  test('内容 ID 在文件移动后保持稳定并持久化 hash 到路径映射', () async {
    final first = File('${directory.path}${Platform.pathSeparator}first.mp3')
      ..writeAsBytesSync([1, 2, 3]);
    final index = LocalMusicIndex(cacheFile);
    final initial = await index.update(
      [snapshot(first)],
      coverDirectory: covers.path,
      readMetadata: metadata,
    );
    final contentId = initial.uniqueMetadata.single['contentId'] as String;

    final moved = await first.rename(
      '${directory.path}${Platform.pathSeparator}moved.mp3',
    );
    final updated = await index.update(
      [snapshot(moved)],
      coverDirectory: covers.path,
      readMetadata: metadata,
    );
    final persisted = jsonDecode(cacheFile.readAsStringSync()) as Map;

    expect(contentId, startsWith(localMusicIdPrefix));
    expect(updated.uniqueMetadata.single['contentId'], contentId);
    expect(updated.resolvePath(contentId), moved.path);
    expect((persisted['hashToPath'] as Map)[contentId], moved.path);
  });

  test('mtime 和 size 未变化时复用缓存且相同内容只返回一首', () async {
    final first = File('${directory.path}${Platform.pathSeparator}a.mp3')
      ..writeAsBytesSync([4, 5, 6]);
    final second = File('${directory.path}${Platform.pathSeparator}b.mp3')
      ..writeAsBytesSync([4, 5, 6]);
    var reads = 0;
    final index = LocalMusicIndex(cacheFile);
    Future<List<Map<String, dynamic>>> countingReader(
      List<Map<String, dynamic>> inputs,
    ) {
      reads += inputs.length;
      return metadata(inputs);
    }

    final initial = await index.update(
      [snapshot(first), snapshot(second)],
      coverDirectory: covers.path,
      readMetadata: countingReader,
    );
    final repeated = await index.update(
      [snapshot(first), snapshot(second)],
      coverDirectory: covers.path,
      readMetadata: countingReader,
    );

    expect(reads, 2);
    expect(initial.uniqueMetadata, hasLength(1));
    expect(repeated.uniqueMetadata, hasLength(1));
    expect(repeated.hashToPath, hasLength(1));
  });

  test('清理失效映射和未使用封面并原子写入有效缓存', () async {
    final audio = File('${directory.path}${Platform.pathSeparator}gone.mp3')
      ..writeAsBytesSync([7, 8, 9]);
    final cover = File('${covers.path}${Platform.pathSeparator}cover.jpg')
      ..writeAsBytesSync([1]);
    final index = LocalMusicIndex(cacheFile);
    await index.update(
      [snapshot(audio)],
      coverDirectory: covers.path,
      readMetadata: (inputs) async => [
        {
          ...(await metadata(inputs)).single,
          'coverPath': cover.path,
        }
      ],
    );

    audio.deleteSync();
    final empty = await index.update(
      const [],
      coverDirectory: covers.path,
      readMetadata: metadata,
    );
    final persisted = jsonDecode(cacheFile.readAsStringSync()) as Map;

    expect(empty.metadataByPath, isEmpty);
    expect(empty.hashToPath, isEmpty);
    expect(cover.existsSync(), isFalse);
    expect(persisted['files'], isEmpty);
    expect(File('${cacheFile.path}.tmp').existsSync(), isFalse);
  });

  test('兼容旧版路径 hash 和无 contentId 的旧缓存', () async {
    final audio = File('${directory.path}${Platform.pathSeparator}legacy.mp3')
      ..writeAsBytesSync([10, 11]);
    final stat = snapshot(audio);
    cacheFile.writeAsStringSync(jsonEncode({
      audio.path: {
        'path': audio.path,
        'modified': stat.modified,
        'size': stat.size,
        'title': 'Legacy',
      },
    }));
    var reads = 0;

    final result = await LocalMusicIndex(cacheFile).update(
      [stat],
      coverDirectory: covers.path,
      readMetadata: (inputs) {
        reads += inputs.length;
        return metadata(inputs);
      },
    );

    expect(reads, 1);
    expect(result.resolvePath(audio.path), audio.path);
    expect(result.uniqueMetadata.single['contentId'], startsWith('local-'));
  });
}
