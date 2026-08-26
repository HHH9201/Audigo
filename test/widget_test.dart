import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:audigo/main.dart';
import 'package:audigo/models/play_history.dart';
import 'package:audigo/models/song.dart';
import 'package:audigo/pages/local_music_screen.dart';
import 'package:audigo/services/audio_player_manager.dart';
import 'package:audigo/services/music_api_service.dart';
import 'package:audigo/theme/theme_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('song JSON keeps missing cover empty and normalizes present cover', () {
    expect(Song.fromJson({'hash': 'missing'}).coverUrl, isNull);
    expect(Song.fromJson({'hash': 'empty', 'cover': ''}).coverUrl, isNull);
    expect(
      Song.fromJson({
        'hash': 'present',
        'union_cover': 'http://example.com/{size}/cover.jpg',
      }).coverUrl,
      'https://example.com/400/cover.jpg',
    );
  });

  test('local music cache uses modified time and size', () {
    final cached = {'modified': 100, 'size': 200};

    expect(localCacheMatches(cached, 100, 200), isTrue);
    expect(localCacheMatches(cached, 101, 200), isFalse);
    expect(localCacheMatches(cached, 100, 201), isFalse);
  });

  test('local music formats include WMA', () {
    expect(localAudioExtensions, contains('.wma'));
  });

  test('same-name lyrics prefer KRC and fall back to LRC', () {
    final directory = Directory.systemTemp.createTempSync('musichub_lrc_test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final audio = File('${directory.path}${Platform.pathSeparator}track.mp3')
      ..writeAsBytesSync([]);
    final lrc = File('${directory.path}${Platform.pathSeparator}track.lrc')
      ..writeAsStringSync('[00:01.00]歌词');

    expect(sameNameLyricsPath(audio.path), lrc.path);
    final krc = File('${directory.path}${Platform.pathSeparator}track.krc')
      ..writeAsStringSync('[1000,500]<0,500,0>歌词');
    expect(sameNameLyricsPath(audio.path), krc.path);
  });

  test('unified lyrics parser reads KRC word timing and LRC fallback', () {
    final krc = MusicApiService.parseLyrics(
      '[1000,900]<0,400,0>你<400,500,0>好',
    );
    expect(krc.single.time, const Duration(seconds: 1));
    expect(krc.single.duration, const Duration(milliseconds: 900));
    expect(krc.single.text, '你好');
    expect(krc.single.words.map((word) => word.text), ['你', '好']);
    expect(krc.single.words.last.time, const Duration(milliseconds: 1400));

    final lrc = MusicApiService.parseLyrics('[00:01.25][00:02.500]歌词');
    expect(lrc.length, 2);
    expect(lrc.first.time, const Duration(milliseconds: 1250));
    expect(lrc.last.time, const Duration(milliseconds: 2500));
    expect(lrc.first.words, isEmpty);
  });

  test('play statistics respect analytics independently from history',
      () async {
    final song = Song(
      hash: 'test-hash',
      songName: 'Test Song',
      authorName: 'Test Artist',
    );
    SharedPreferences.setMockInitialValues({
      'analytics_enabled': true,
      'save_history': false,
    });

    await MusicApiService.addPlayHistory(song);
    var prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('play_statistics'), contains('test-hash'));
    expect(prefs.getStringList('play_history'), isNull);

    await prefs.setBool('analytics_enabled', false);
    await MusicApiService.addPlayHistory(song);
    prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('play_statistics'), contains('"test-hash":1'));
  });

  test('play history rejects empty hash without updating statistics', () async {
    SharedPreferences.setMockInitialValues({});
    final added = await MusicApiService.addPlayHistory(
      Song(hash: '', songName: 'Invalid', authorName: 'Artist'),
    );

    final prefs = await SharedPreferences.getInstance();
    expect(added, isFalse);
    expect(prefs.getString('play_statistics'), isNull);
    expect(prefs.getStringList('play_history'), isNull);
  });

  test('play history accumulates count and refreshes song information',
      () async {
    SharedPreferences.setMockInitialValues({});
    await MusicApiService.addPlayHistory(
      Song(
        hash: 'same-hash',
        songName: 'Old Name',
        authorName: 'Old Artist',
        timeLength: 100,
      ),
    );
    await MusicApiService.addPlayHistory(
      Song(
        hash: 'same-hash',
        songName: 'New Name',
        authorName: 'New Artist',
        timeLength: 200,
      ),
    );

    final history = await MusicApiService.getPlayHistory();
    expect(history.totalCount, 1);
    expect(history.records.single.playCount, 2);
    expect(history.records.single.songName, 'New Name');
    expect(history.records.single.artistName, 'New Artist');
    expect(history.records.single.duration, 200);
    expect(history.records.single.id, 'same-hash');
    expect(
        history.records.single.lastPlayTime, history.records.single.playTime);
  });

  test('play history sorts, filters, paginates, and reports filtered total',
      () async {
    final now = DateTime(2026, 8, 20, 12);
    PlayHistoryRecord record(String hash, DateTime time) => PlayHistoryRecord(
          id: hash,
          hash: hash,
          songName: hash,
          filename: '',
          artistName: 'Artist',
          albumName: '',
          albumId: '',
          duration: 60,
          unionCover: '',
          playTime: time,
          playCount: 1,
          lastPlayTime: time,
        );
    final records = [
      record('old', DateTime(2026, 8, 10, 12)),
      record('today-new', DateTime(2026, 8, 20, 11)),
      record('yesterday', DateTime(2026, 8, 19, 10)),
      record('today-old', DateTime(2026, 8, 20, 9)),
    ];
    SharedPreferences.setMockInitialValues({
      'play_history':
          records.map((record) => jsonEncode(record.toJson())).toList(),
    });

    final today = await MusicApiService.getPlayHistory(
      page: 2,
      pageSize: 1,
      filter: 'today',
      now: now,
    );
    expect(today.totalCount, 2);
    expect(today.records.single.hash, 'today-old');

    final yesterday = await MusicApiService.getPlayHistory(
      filter: 'yesterday',
      now: now,
    );
    expect(yesterday.totalCount, 1);
    expect(yesterday.records.single.hash, 'yesterday');

    final week = await MusicApiService.getPlayHistory(filter: 'week', now: now);
    expect(week.records.map((record) => record.hash), [
      'today-new',
      'today-old',
      'yesterday',
    ]);
  });

  test('play history keeps the latest 1000 records', () async {
    final records = List.generate(1000, (index) {
      final time = DateTime(2026, 1, 1).add(Duration(minutes: index));
      return jsonEncode(PlayHistoryRecord(
        id: 'hash-$index',
        hash: 'hash-$index',
        songName: 'Song $index',
        filename: '',
        artistName: 'Artist',
        albumName: '',
        albumId: '',
        duration: 60,
        unionCover: '',
        playTime: time,
        playCount: 1,
        lastPlayTime: time,
      ).toJson());
    });
    SharedPreferences.setMockInitialValues({'play_history': records});

    await MusicApiService.addPlayHistory(
      Song(hash: 'new-hash', songName: 'Newest', authorName: 'Artist'),
    );
    final history = await MusicApiService.getPlayHistory(pageSize: 2000);

    expect(history.totalCount, 1000);
    expect(history.records.first.hash, 'new-hash');
    expect(history.records.any((record) => record.hash == 'hash-0'), isFalse);
  });

  test('legacy play history defaults to one play and clear returns empty data',
      () async {
    SharedPreferences.setMockInitialValues({
      'play_history': [
        jsonEncode({
          'hash': 'legacy-hash',
          'songname': 'Legacy',
          'author_name': 'Artist',
          'play_time': '2026-08-20T10:00:00.000',
        }),
      ],
    });

    final history = await MusicApiService.getPlayHistory();
    expect(history.records.single.playCount, 1);
    expect(history.records.single.id, 'legacy-hash');

    final cleared = await MusicApiService.clearPlayHistory();
    final prefs = await SharedPreferences.getInstance();
    expect(cleared.records, isEmpty);
    expect(cleared.totalCount, 0);
    expect(prefs.getStringList('play_history'), isEmpty);
    expect(prefs.getString('play_history_update_time'), isNotEmpty);
  });

  test('clearing downloads removes audio and sidecar lyrics', () async {
    final directory =
        Directory.systemTemp.createTempSync('musichub_download_test');
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final audio = File('${directory.path}${Platform.pathSeparator}track.mp3')
      ..writeAsBytesSync([1]);
    final lyrics = File('${directory.path}${Platform.pathSeparator}track.lrc')
      ..writeAsStringSync('[00:01.00]歌词');
    SharedPreferences.setMockInitialValues({});
    final song = Song(
      hash: 'download-hash',
      songName: 'Downloaded Song',
      authorName: 'Test Artist',
    );
    await MusicApiService.addDownloadRecord(song, filePath: audio.path);

    await MusicApiService.clearDownloadRecords();

    expect(audio.existsSync(), isFalse);
    expect(lyrics.existsSync(), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('download_records'), isNull);
  });

  testWidgets('AudiGoApp smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final themeController = await ThemeController.load();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AudioPlayerManager()),
          ChangeNotifierProvider.value(value: themeController),
        ],
        child: const AudiGoApp(),
      ),
    );
    await tester.pump();

    expect(find.byType(AudiGoApp), findsOneWidget);
    expect(find.text('首页'), findsOneWidget);
  });
}
