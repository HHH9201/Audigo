import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_client/services/media_cache_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('musichub_media_cache');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('同一音频缓存键的并发请求只下载一次', () async {
    var downloads = 0;
    final release = Completer<void>();
    final cache = MediaCacheService(
      rootDirectory: directory,
      audioDownloader: (url, path) async {
        downloads++;
        await release.future;
        await File(path).writeAsBytes([1, 2, 3], flush: true);
      },
    );

    final first = cache.getAudio(hash: 'song', quality: '320k', url: 'one');
    final second = cache.getAudio(hash: 'song', quality: '320', url: 'two');
    release.complete();

    final files = await Future.wait([first, second]);
    expect(downloads, 1);
    expect(files.first.path, files.last.path);
    expect(await files.first.readAsBytes(), [1, 2, 3]);
  });

  test('下载失败后同一缓存键可以重试', () async {
    var downloads = 0;
    final cache = MediaCacheService(
      rootDirectory: directory,
      audioDownloader: (url, path) async {
        downloads++;
        if (downloads == 1) throw const SocketException('offline');
        await File(path).writeAsBytes([1], flush: true);
      },
    );

    await expectLater(
      cache.getAudio(hash: 'retry', quality: '128k', url: 'audio'),
      throwsA(isA<SocketException>()),
    );
    final file = await cache.getAudio(
      hash: 'retry',
      quality: '128k',
      url: 'audio',
    );

    expect(downloads, 2);
    expect(await file.readAsBytes(), [1]);
  });

  test('不同音质使用独立音频缓存', () async {
    var downloads = 0;
    final cache = MediaCacheService(
      rootDirectory: directory,
      audioDownloader: (url, path) async {
        downloads++;
        await File(path).writeAsString(url, flush: true);
      },
    );

    final low = await cache.getAudio(
      hash: 'same-song',
      quality: '128k',
      url: 'low',
    );
    final lossless = await cache.getAudio(
      hash: 'same-song',
      quality: 'flac',
      url: 'lossless',
    );

    expect(downloads, 2);
    expect(low.path, isNot(lossless.path));
    expect(await low.readAsString(), 'low');
    expect(await lossless.readAsString(), 'lossless');
  });

  test('音频缓存截断后自动删除并重新下载', () async {
    var downloads = 0;
    final cache = MediaCacheService(
      rootDirectory: directory,
      audioDownloader: (url, path) async {
        downloads++;
        await File(path).writeAsBytes([downloads, 2, 3], flush: true);
      },
    );

    final first = await cache.getAudio(
      hash: 'damaged',
      quality: '128k',
      url: 'audio',
    );
    await first.writeAsBytes([9], flush: true);
    final recovered = await cache.getAudio(
      hash: 'damaged',
      quality: '128k',
      url: 'audio',
    );

    expect(downloads, 2);
    expect(await recovered.readAsBytes(), [2, 2, 3]);
  });

  test('歌词原文按 KRC 格式缓存且并发合并', () async {
    const lyrics = '[0,1000]<0,500,0>你<500,500,0>好';
    var loads = 0;
    final release = Completer<void>();
    final cache = MediaCacheService(rootDirectory: directory);

    Future<String> loader() async {
      loads++;
      await release.future;
      return lyrics;
    }

    final first = cache.getLyrics(hash: 'lyric-song', loader: loader);
    final second = cache.getLyrics(hash: 'lyric-song', loader: loader);
    release.complete();
    final results = await Future.wait([first, second]);

    expect(loads, 1);
    expect(results.first.content, lyrics);
    expect(results.first.format, 'krc');
    expect(results.last.content, lyrics);
  });

  test('歌词元数据损坏后重新获取 LRC 原文', () async {
    var loads = 0;
    final cache = MediaCacheService(rootDirectory: directory);
    final first = await cache.getLyrics(
      hash: 'lrc-song',
      loader: () async {
        loads++;
        return '[00:01.00]旧歌词';
      },
    );
    expect(first.format, 'lrc');

    final metadata = directory
        .listSync(recursive: true)
        .whereType<File>()
        .singleWhere((file) => file.path.endsWith('.lrc.meta'));
    await metadata.writeAsString(jsonEncode({'length': -1}), flush: true);

    final recovered = await cache.getLyrics(
      hash: 'lrc-song',
      loader: () async {
        loads++;
        return '[00:02.00]新歌词';
      },
    );

    expect(loads, 2);
    expect(recovered.content, '[00:02.00]新歌词');
    expect(recovered.format, 'lrc');
  });
}
