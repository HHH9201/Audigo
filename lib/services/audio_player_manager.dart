import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../services/media_cache_service.dart';
import '../services/music_api_service.dart';
import '../widgets/app_toast.dart';

enum PlayMode { sequence, loop, random }

enum RepeatMode { off, one, all }

class AudioPlayerManager extends ChangeNotifier {
  final AudioPlayer _player = AudioPlayer();

  // 高频进度通知器：仅用于进度条/歌词等高频刷新组件，
  // 与主 ChangeNotifier 分离，避免每 100ms 全量重建所有页面。
  final ChangeNotifier progressNotifier = ChangeNotifier();

  // 播放进度刷新间隔（毫秒）。进度条 500ms 足够流畅且明显降低
  // 高频重建对整体帧率的影响；歌词逐字高亮另有独立驱动。
  static const int _progressNotifyIntervalMs = 500;

  // 当前播放列表与当前索引
  List<Song> _playlist = [];
  int _currentIndex = -1;

  // 播放状态与进度
  bool _isPlaying = false;
  Duration _currentPosition = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  ProcessingState _processingState = ProcessingState.idle;
  bool _shuffleMode = false;
  RepeatMode _repeatMode = RepeatMode.off;
  List<int> _shuffleOrder = [];
  int _shufflePosition = -1;
  double _volume = 0.5;
  String _audioQuality = '128k';
  bool _autoPlayNext = true;
  bool _gaplessPlayback = true;
  bool _wifiOnlyHighQuality = false;
  bool _showLyrics = true;
  bool _cacheBeforePlay = true; // 是否先缓存整首再播放（关闭则直接流式播放）
  int _playRequestId = 0;
  int? _preparingSourceIndex;
  final List<int> _gaplessSongIndexes = [];
  ConcatenatingAudioSource? _gaplessSource;

  // 歌词
  List<LyricLine> _currentLyrics = [];
  int _currentLyricIndex = 0;
  int _currentLyricWordIndex = -1;
  double _currentLyricWordProgress = 0;
  List<LyricLine>? _indexedLyrics;
  Duration _lastLyricPosition = Duration.zero;

  Timer? _progressNotificationTimer;
  DateTime _lastProgressNotification = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _volumePersistTimer;

  // 收藏歌曲哈希列表
  final Set<String> _favoriteHashes = {};

  // Getters
  List<Song> get playlist => _playlist;
  int get currentIndex => _currentIndex;
  Song? get currentSong =>
      (_currentIndex >= 0 && _currentIndex < _playlist.length)
          ? _playlist[_currentIndex]
          : null;
  bool get isPlaying => _isPlaying;
  Duration get currentPosition => _currentPosition;
  Duration get bufferedPosition => _bufferedPosition;
  Duration get totalDuration => _totalDuration;
  ProcessingState get processingState => _processingState;
  PlayMode get playMode {
    if (_shuffleMode) return PlayMode.random;
    if (_repeatMode == RepeatMode.one) return PlayMode.loop;
    return PlayMode.sequence;
  }

  bool get shuffleMode => _shuffleMode;
  RepeatMode get repeatMode => _repeatMode;
  double get volume => _volume;
  String get audioQuality => _audioQuality;
  bool get autoPlayNext => _autoPlayNext;
  bool get gaplessPlayback => _gaplessPlayback;
  bool get showLyrics => _showLyrics;
  // 始终返回已加载的歌词（沉浸式页面需要；showLyrics 仅控制是否主动加载）。
  List<LyricLine> get currentLyrics => _currentLyrics;
  int get currentLyricIndex => _currentLyricIndex;
  int get currentLyricWordIndex => _currentLyricWordIndex;
  double get currentLyricWordProgress => _currentLyricWordProgress;
  Set<String> get favoriteHashes => _favoriteHashes;

  AudioPlayerManager() {
    _initAudioListeners();
    _restorePreferences();
  }

  Future<void> _restorePreferences() async {
    await reloadSettings();
    final prefs = await SharedPreferences.getInstance();
    final savedPlaylist = prefs.getStringList('player_playlist') ?? [];
    _playlist =
        savedPlaylist.map((item) => Song.fromJson(jsonDecode(item))).toList();
    _currentIndex = prefs.getInt('player_current_index') ?? -1;
    if (_currentIndex < -1 || _currentIndex >= _playlist.length) {
      _currentIndex = -1;
    }
    _shuffleMode = prefs.getBool('player_shuffle_mode') ?? false;
    final repeatIndex = prefs.getInt('player_repeat_mode') ?? 0;
    if (repeatIndex >= 0 && repeatIndex < RepeatMode.values.length) {
      _repeatMode = RepeatMode.values[repeatIndex];
    } else {
      _repeatMode = RepeatMode.off;
    }
    _shuffleOrder = (prefs.getStringList('player_shuffle_order') ?? [])
        .map(int.tryParse)
        .whereType<int>()
        .where((index) => index >= 0 && index < _playlist.length)
        .toList();
    _shufflePosition = prefs.getInt('player_shuffle_position') ?? -1;
    if (_shufflePosition < -1 || _shufflePosition >= _shuffleOrder.length) {
      _shufflePosition = -1;
    }
    final legacyMode = prefs.getInt('player_play_mode');
    if (legacyMode != null &&
        !prefs.containsKey('player_shuffle_mode') &&
        !prefs.containsKey('player_repeat_mode')) {
      _shuffleMode = legacyMode == PlayMode.random.index;
      _repeatMode =
          legacyMode == PlayMode.loop.index ? RepeatMode.one : RepeatMode.off;
    }
    if (_shuffleMode && !_isShuffleOrderValid()) {
      _generateShuffleOrder();
    }
    final favorites = await MusicApiService.getFavorites();
    _favoriteHashes.addAll(favorites.map((song) => song.hash));
    notifyListeners();
  }

  Future<void> _persistPlaylist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'player_playlist',
      _playlist.map((song) => jsonEncode(song.toJson())).toList(),
    );
    await prefs.setInt('player_current_index', _currentIndex);
    await prefs.setBool('player_shuffle_mode', _shuffleMode);
    await prefs.setInt('player_repeat_mode', _repeatMode.index);
    await prefs.setStringList(
      'player_shuffle_order',
      _shuffleOrder.map((index) => index.toString()).toList(),
    );
    await prefs.setInt('player_shuffle_position', _shufflePosition);
  }

  bool _isShuffleOrderValid() {
    if (_playlist.isEmpty) return _shuffleOrder.isEmpty;
    final expected = List<int>.generate(_playlist.length, (index) => index);
    final actual = List<int>.from(_shuffleOrder)..sort();
    return listEquals(expected, actual) &&
        _shufflePosition >= 0 &&
        _shufflePosition < _shuffleOrder.length &&
        _shuffleOrder[_shufflePosition] == _currentIndex;
  }

  void _generateShuffleOrder() {
    if (_playlist.isEmpty) {
      _shuffleOrder = [];
      _shufflePosition = -1;
      return;
    }
    final remaining = List<int>.generate(_playlist.length, (index) => index)
      ..remove(_currentIndex)
      ..shuffle(Random());
    _shuffleOrder = [_currentIndex, ...remaining];
    _shufflePosition = 0;
  }

  Future<void> reloadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _audioQuality = prefs.getString('audio_quality') ?? '128k';
    _autoPlayNext = prefs.getBool('auto_play_next') ?? true;
    _gaplessPlayback = prefs.getBool('gapless_playback') ?? true;
    _wifiOnlyHighQuality = prefs.getBool('wifi_only_high_quality') ?? false;
    _showLyrics = prefs.getBool('show_lyrics') ?? true;
    _cacheBeforePlay = prefs.getBool('cache_before_play') ?? true;
    _volume = (prefs.getDouble('playback_volume') ?? 0.5).clamp(0.0, 1.0);
    await _player.setVolume(_volume);
    if (!_showLyrics) {
      _currentLyrics = [];
      _currentLyricIndex = 0;
    }
    if (!_gaplessPlayback || !_autoPlayNext) {
      await _discardPreparedSources();
    } else {
      _prepareGaplessNext(_playRequestId);
    }
    notifyListeners();
  }

  Future<void> _discardPreparedSources() async {
    final source = _gaplessSource;
    final currentSourceIndex = _player.currentIndex ?? 0;
    if (source == null ||
        currentSourceIndex >= _gaplessSongIndexes.length - 1) {
      return;
    }
    await source.removeRange(
        currentSourceIndex + 1, _gaplessSongIndexes.length);
    _gaplessSongIndexes.removeRange(
      currentSourceIndex + 1,
      _gaplessSongIndexes.length,
    );
    _preparingSourceIndex = null;
  }

  Future<String> _effectiveStreamingQuality() async {
    if (!_wifiOnlyHighQuality || _audioQuality == '128k') return _audioQuality;
    final connections = await Connectivity().checkConnectivity();
    return connections.contains(ConnectivityResult.wifi) ||
            connections.contains(ConnectivityResult.ethernet)
        ? _audioQuality
        : '128k';
  }

  void _initAudioListeners() {
    _player.setVolume(_volume);

    // 监听播放状态
    _player.playerStateStream.listen((state) {
      _isPlaying = state.playing;
      _processingState = state.processingState;
      if (state.processingState == ProcessingState.completed) {
        _handleTrackEnded();
      }
      notifyListeners();
    });

    _player.currentIndexStream.listen((sourceIndex) {
      if (sourceIndex == null ||
          sourceIndex < 0 ||
          sourceIndex >= _gaplessSongIndexes.length) {
        return;
      }
      final songIndex = _gaplessSongIndexes[sourceIndex];
      if (songIndex == _currentIndex) return;
      _currentIndex = songIndex;
      _currentLyrics = [];
      _currentLyricIndex = 0;
      final song = currentSong;
      if (song != null) {
        // 始终加载歌词（沉浸式页面与右侧栏歌词面板都需要）。
        MusicApiService.getLyrics(song.hash,
                songName: song.songName, artist: song.authorName)
            .then((lyrics) {
          if (currentSong?.hash != song.hash) return;
          _currentLyrics = lyrics;
          notifyListeners();
        });
      }
      if (song != null) MusicApiService.addPlayHistory(song);
      _persistPlaylist();
      _prepareGaplessNext(_playRequestId);
      notifyListeners();
    });

    // 监听播放进度
    _player.positionStream.listen((position) {
      _currentPosition = position;
      final prevLyricIndex = _currentLyricIndex;
      _updateLyricIndex(position);
      // 仅在歌词行切换时触发主通知（低频），歌词页重绘；
      // 逐字高亮与进度条由 progressNotifier 独立驱动，避免高频重建。
      if (_currentLyricIndex != prevLyricIndex) {
        notifyListeners();
      }
      _scheduleProgressNotification();
    });

    _player.bufferedPositionStream.listen((position) {
      _bufferedPosition = position;
      _scheduleProgressNotification();
    });

    // 监听歌曲总时长
    _player.durationStream.listen((duration) {
      if (duration != null) {
        _totalDuration = duration;
        notifyListeners();
      }
    });
  }

  void _scheduleProgressNotification() {
    // 250ms 节流发送进度通知。不依赖 _isPlaying 判断：
    // just_audio 在缓冲/gapless 预加载等阶段 playing 状态可能短暂不一致，
    // 而进度条需要始终反映当前位置。
    const interval = Duration(milliseconds: _progressNotifyIntervalMs);
    final elapsed = DateTime.now().difference(_lastProgressNotification);
    if (elapsed >= interval) {
      _progressNotificationTimer?.cancel();
      _progressNotificationTimer = null;
      _lastProgressNotification = DateTime.now();
      progressNotifier.notifyListeners();
      return;
    }
    if (_progressNotificationTimer != null) return;
    _progressNotificationTimer = Timer(interval - elapsed, () {
      _progressNotificationTimer = null;
      _lastProgressNotification = DateTime.now();
      progressNotifier.notifyListeners();
    });
  }

  void _updateLyricIndex(Duration position) {
    if (_currentLyrics.isEmpty) {
      _currentLyricIndex = 0;
      _currentLyricWordIndex = -1;
      _currentLyricWordProgress = 0;
      _lastLyricPosition = position;
      return;
    }

    final lyricsChanged = !identical(_indexedLyrics, _currentLyrics);
    if (lyricsChanged) _indexedLyrics = _currentLyrics;
    var index = _currentLyricIndex.clamp(0, _currentLyrics.length - 1);
    final movedForward = !lyricsChanged && position >= _lastLyricPosition;
    if (movedForward && position >= _currentLyrics[index].time) {
      while (index + 1 < _currentLyrics.length &&
          position >= _currentLyrics[index + 1].time) {
        index++;
      }
    } else {
      var low = 0;
      var high = _currentLyrics.length;
      while (low < high) {
        final middle = low + ((high - low) >> 1);
        if (_currentLyrics[middle].time <= position) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }
      index = (low - 1).clamp(0, _currentLyrics.length - 1);
    }
    _currentLyricIndex = index;
    _lastLyricPosition = position;

    final words = _currentLyrics[index].words;
    var wordIndex = -1;
    var low = 0;
    var high = words.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      if (words[middle].time <= position) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    wordIndex = low - 1;
    _currentLyricWordIndex = wordIndex;
    _currentLyricWordProgress = 0;
    if (wordIndex >= 0) {
      final word = words[wordIndex];
      final elapsed = position.inMilliseconds - word.time.inMilliseconds;
      _currentLyricWordProgress = word.duration.inMilliseconds <= 0
          ? 1
          : (elapsed / word.duration.inMilliseconds).clamp(0.0, 1.0);
    }
  }

  void _handleTrackEnded() {
    if (_gaplessSource != null &&
        (_player.currentIndex ?? 0) < _gaplessSongIndexes.length - 1) {
      return;
    }
    if (_repeatMode == RepeatMode.one) {
      seek(Duration.zero);
      _player.play();
      return;
    }
    if (!_autoPlayNext) return;
    if (_shuffleMode ||
        _repeatMode == RepeatMode.all ||
        _currentIndex < _playlist.length - 1) {
      playNext();
    }
  }

  // 设置播放列表
  void setPlaylist(List<Song> songs) {
    _playlist = List.from(songs);
    _currentIndex =
        _playlist.isEmpty ? -1 : _currentIndex.clamp(0, _playlist.length - 1);
    if (_shuffleMode) _generateShuffleOrder();
    _persistPlaylist();
    notifyListeners();
  }

  // 播放指定歌曲
  Future<void> playSong(Song song, {List<Song>? newPlaylist}) async {
    final requestId = ++_playRequestId;
    // 确保平台播放器已初始化（解决首次 setAudioSource 卡死问题）
    await _player.setVolume(_volume);
    if (newPlaylist != null) {
      _playlist = List.from(newPlaylist);
      _currentIndex = _playlist.indexWhere((s) => s.hash == song.hash);
      if (_currentIndex == -1) {
        _playlist.insert(0, song);
        _currentIndex = 0;
      }
    } else {
      _currentIndex = _playlist.indexWhere((s) => s.hash == song.hash);
      if (_currentIndex == -1) {
        _playlist.add(song);
        _currentIndex = _playlist.length - 1;
      }
    }
    await _persistPlaylist();
    _currentLyrics = [];
    _currentLyricIndex = 0;
    notifyListeners();

    final localPath =
        song.localPath?.isNotEmpty == true ? song.localPath! : song.hash;
    final localFile = File(localPath);
    if (await localFile.exists()) {
      final dot = localPath.lastIndexOf('.');
      final basePath = dot > 0 ? localPath.substring(0, dot) : localPath;
      var lyrics = song.lyrics?.trim() ?? '';
      for (final extension in const ['.krc', '.lrc']) {
        final sidecar = File('$basePath$extension');
        if (!await sidecar.exists()) continue;
        try {
          final sidecarLyrics = (await sidecar.readAsString()).trim();
          if (sidecarLyrics.isNotEmpty) {
            lyrics = sidecarLyrics;
            break;
          }
        } on FileSystemException {
          // Fall back to the next sidecar or embedded lyrics.
        }
      }
      if (lyrics.isNotEmpty) {
        _currentLyrics = MusicApiService.parseLyrics(lyrics);
        if (_currentLyrics.isEmpty) {
          _currentLyrics = lyrics
              .split(RegExp(r'\r?\n'))
              .where((line) => line.trim().isNotEmpty)
              .map((line) => LyricLine(time: Duration.zero, text: line.trim()))
              .toList();
        }
        notifyListeners();
      }
      try {
        if (_gaplessPlayback) {
          _gaplessSource = ConcatenatingAudioSource(
            useLazyPreparation: true,
            children: [AudioSource.file(localPath)],
          );
          _gaplessSongIndexes
            ..clear()
            ..add(_currentIndex);
          _preparingSourceIndex = null;
          await _player.setAudioSource(_gaplessSource!);
        } else {
          _clearGaplessState();
          await _player.setFilePath(localPath);
        }
        if (requestId != _playRequestId) return;
        await _player.play();
        await MusicApiService.addPlayHistory(song);
        _prepareGaplessNext(requestId);
      } catch (e) {
        print('播放音频异常: $e');
      }
      return;
    }

    // 1. 获取在线音频地址 + 歌词（与原版 Go 的 GetSongUrl 一致：
    //    响应中直接携带歌词，避免单独调用 /search/lyric）。
    final quality = await _effectiveStreamingQuality();
    print('播放调试: 开始在线播放 ${song.songName} quality=$quality');
    final playResult = await MusicApiService.getPlayUrlsWithLyrics(
      song.hash,
      songName: song.songName,
      artist: song.authorName,
      quality: quality,
    );
    final urls = playResult.urls;
    print('播放调试: 获取到 ${urls.length} 个URL');
    for (var i = 0; i < urls.length; i++) {
      print('播放调试: url[$i]=${urls[i]}');
    }
    if (requestId != _playRequestId) return;
    if (urls.isEmpty) {
      print('播放调试: 无法获取播放URL，播放中止');
      // 未登录且本地也没有该音频时，前端提示未登录。
      if (!await MusicApiService.isLoggedIn()) {
        _showNotice('未登录：本地没有该歌曲，请登录后再播放在线歌曲');
      }
      _processingState = ProcessingState.idle;
      notifyListeners();
      return;
    }

    // 2. 加载歌词：优先使用播放地址响应中的歌词；为空时兜底独立接口。
    if (playResult.lyrics.trim().isNotEmpty) {
      _currentLyrics = MusicApiService.parseLyrics(playResult.lyrics);
      if (_currentLyrics.isEmpty) {
        _currentLyrics = playResult.lyrics
            .split(RegExp(r'\r?\n'))
            .where((line) => line.trim().isNotEmpty)
            .map((line) =>
                LyricLine(time: Duration.zero, text: line.trim()))
            .toList();
      }
      notifyListeners();
    } else {
      MusicApiService.getLyrics(song.hash,
              songName: song.songName, artist: song.authorName)
          .then((lyrics) {
        if (requestId != _playRequestId) return;
        _currentLyrics = lyrics;
        notifyListeners();
      });
    }

    // 3. 与 Go 原版一致：优先同步缓存整首歌曲，再播放本地文件。
    //    开启开关可在设置关闭整首缓存而直接流式播放。
    File? audioFile;
    if (_cacheBeforePlay) {
      try {
        final cache = await MediaCacheService.instance;
        for (var i = 0; i < urls.length; i++) {
          try {
            print('播放调试: 获取本地音频 (${i + 1}/${urls.length})');
            audioFile = await cache.getAudio(
              hash: song.hash,
              quality: quality,
              url: urls[i],
            );
            break;
          } catch (e) {
            print('播放调试: 缓存音频失败(${i + 1}/${urls.length}): $e');
          }
        }
      } catch (e) {
        print('播放调试: 初始化音频缓存失败: $e');
      }
    } else {
      print('播放调试: 设置已关闭整首缓存，直接流式播放');
    }

    if (audioFile != null && requestId == _playRequestId) {
      var localOk = false;
      try {
        print('播放调试: 本地音频已就绪 ${audioFile.path}');
        _clearGaplessState();
        await _player.pause();
        // Windows 上 just_audio 加载本地文件可能较慢或卡住（Media
        // Foundation 异步初始化），用 6 秒超时避免永久阻塞；
        // 超时/失败后重置播放器并回退远程播放。
        await _player.setFilePath(audioFile.path).timeout(
              const Duration(seconds: 6),
              onTimeout: () => throw TimeoutException('本地音频加载超时'),
            );
        if (requestId != _playRequestId) return;
        unawaited(_player.play());
        if (requestId != _playRequestId) return;
        print('播放调试: 本地音频播放已启动');
        await MusicApiService.addPlayHistory(song);
        _prepareGaplessNext(requestId);
        localOk = true;
      } catch (e) {
        print('播放调试: 本地播放器启动失败: $e');
      }
      if (!localOk) {
        // 超时/失败后重置播放器状态，避免后续 setAudioSource 卡死。
        try {
          await _player.stop();
          _clearGaplessState();
        } catch (_) {}
      } else {
        return;
      }
    }

    // 缓存下载或本地播放器启动失败时才回退远程流。
    final headers = {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36',
      'Referer': 'https://www.kugou.com/',
    };
    for (var i = 0; i < urls.length; i++) {
      try {
        print('播放调试: 回退远程音频 (${i + 1}/${urls.length})');
        _clearGaplessState();
        await _player.setAudioSource(
          AudioSource.uri(Uri.parse(urls[i]), headers: headers),
        ).timeout(
          const Duration(seconds: 8),
          onTimeout: () => throw TimeoutException('远程音频加载超时'),
        );
        if (requestId != _playRequestId) return;
        await _player.play();
        print('播放调试: 远程音频播放已启动');
        await MusicApiService.addPlayHistory(song);
        _prepareGaplessNext(requestId);
        return;
      } catch (e) {
        print('播放调试: 远程音频失败(${i + 1}/${urls.length}): $e');
        try {
          await _player.stop();
        } catch (_) {}
      }
    }

    _processingState = ProcessingState.idle;
    notifyListeners();
  }

  // 无 BuildContext 时通过全局 Navigator 弹出气泡提示。
  void _showNotice(String message, {bool isError = false}) {
    AppToast.show(null, message, isError: isError);
  }

  void _clearGaplessState() {
    _gaplessSource = null;
    _gaplessSongIndexes.clear();
    _preparingSourceIndex = null;
  }

  Future<void> _prepareGaplessNext(int requestId) async {
    if (!_gaplessPlayback ||
        !_autoPlayNext ||
        _shuffleMode ||
        _repeatMode == RepeatMode.one ||
        _gaplessSource == null) {
      return;
    }
    final currentSourceIndex = _player.currentIndex ?? 0;
    if (currentSourceIndex < _gaplessSongIndexes.length - 1 ||
        _preparingSourceIndex == currentSourceIndex) {
      return;
    }
    var nextIndex = _currentIndex + 1;
    if (nextIndex >= _playlist.length) {
      if (_repeatMode != RepeatMode.all || _playlist.isEmpty) return;
      nextIndex = 0;
    }
    _preparingSourceIndex = currentSourceIndex;
    final nextSong = _playlist[nextIndex];
    final localPath = nextSong.localPath?.isNotEmpty == true
        ? nextSong.localPath!
        : nextSong.hash;
    AudioSource? source;
    if (await File(localPath).exists()) {
      source = AudioSource.file(localPath);
    } else {
      final quality = await _effectiveStreamingQuality();
      if (requestId != _playRequestId ||
          !_gaplessPlayback ||
          !_autoPlayNext ||
          _shuffleMode ||
          _repeatMode == RepeatMode.one) {
        _preparingSourceIndex = null;
        return;
      }
      // 获取在线 URL 直接用于 gapless 预加载
      final urls = await MusicApiService.getPlayUrls(
        nextSong.hash,
        songName: nextSong.songName,
        artist: nextSong.authorName,
        quality: quality,
      );
      if (urls.isNotEmpty) {
        source = AudioSource.uri(
          Uri.parse(urls.first),
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36',
            'Referer': 'https://www.kugou.com/',
          },
        );
      }
    }
    if (requestId != _playRequestId ||
        !_gaplessPlayback ||
        !_autoPlayNext ||
        _shuffleMode ||
        _repeatMode == RepeatMode.one ||
        source == null ||
        _gaplessSource == null) {
      _preparingSourceIndex = null;
      return;
    }
    await _gaplessSource!.add(source);
    _gaplessSongIndexes.add(nextIndex);
    _preparingSourceIndex = null;
  }

  // 播放全部
  Future<void> playAll(List<Song> songs, {int initialIndex = 0}) async {
    if (songs.isEmpty) return;
    _playlist = List.from(songs);
    _currentIndex = initialIndex.clamp(0, _playlist.length - 1);
    if (_shuffleMode) _generateShuffleOrder();
    await _persistPlaylist();
    await playSong(_playlist[_currentIndex]);
  }

  Future<void> play() async {
    final song = currentSong;
    if (song == null) return;
    if (_player.processingState == ProcessingState.idle ||
        _player.audioSource == null) {
      await playSong(song);
      return;
    }
    await _player.play();
  }

  Future<void> pause() => _player.pause();

  Future<void> stop() => _player.stop();

  // 播放/暂停切换
  Future<void> togglePlay() async {
    final song = currentSong;
    if (song == null) return;
    if (_player.playing) {
      await pause();
      return;
    }
    if (_player.processingState == ProcessingState.idle ||
        _player.audioSource == null) {
      await playSong(song);
      return;
    }
    await play();
  }

  // 上一首
  Future<void> playPrevious() async {
    if (_playlist.isEmpty) return;
    if (_shuffleMode) {
      if (_shufflePosition <= 0) return;
      _shufflePosition--;
      _currentIndex = _shuffleOrder[_shufflePosition];
    } else if (_currentIndex > 0) {
      _currentIndex--;
    } else if (_repeatMode == RepeatMode.all) {
      _currentIndex = _playlist.length - 1;
    } else {
      return;
    }
    await _persistPlaylist();
    await playSong(_playlist[_currentIndex]);
  }

  // 下一首
  Future<void> playNext() async {
    if (_playlist.isEmpty) return;
    if (_shuffleMode) {
      if (!_isShuffleOrderValid()) _generateShuffleOrder();
      if (_shufflePosition + 1 >= _shuffleOrder.length) {
        final previousIndex = _currentIndex;
        final candidates = List<int>.generate(
          _playlist.length,
          (index) => index,
        )..remove(previousIndex);
        candidates.shuffle(Random());
        _shuffleOrder = [previousIndex, ...candidates];
        _shufflePosition = _shuffleOrder.length > 1 ? 1 : 0;
        _currentIndex = _shuffleOrder[_shufflePosition];
      } else {
        _shufflePosition++;
        _currentIndex = _shuffleOrder[_shufflePosition];
      }
    } else if (_currentIndex < _playlist.length - 1) {
      _currentIndex++;
    } else if (_repeatMode == RepeatMode.all) {
      _currentIndex = 0;
    } else {
      return;
    }
    await _persistPlaylist();
    await playSong(_playlist[_currentIndex]);
  }

  void setShuffleMode(bool enabled) {
    if (_shuffleMode == enabled) return;
    _shuffleMode = enabled;
    if (enabled) {
      _generateShuffleOrder();
      _discardPreparedSources();
    } else {
      _shuffleOrder = [];
      _shufflePosition = -1;
      _prepareGaplessNext(_playRequestId);
    }
    _persistPlaylist();
    notifyListeners();
  }

  void setRepeatMode(RepeatMode mode) {
    if (_repeatMode == mode) return;
    _repeatMode = mode;
    if (mode == RepeatMode.one) {
      _discardPreparedSources();
    } else {
      _prepareGaplessNext(_playRequestId);
    }
    _persistPlaylist();
    notifyListeners();
  }

  void cycleRepeatMode() {
    switch (_repeatMode) {
      case RepeatMode.off:
        setRepeatMode(RepeatMode.one);
        break;
      case RepeatMode.one:
        setRepeatMode(RepeatMode.all);
        break;
      case RepeatMode.all:
        setRepeatMode(RepeatMode.off);
        break;
    }
  }

  void setPlayMode(PlayMode mode) {
    switch (mode) {
      case PlayMode.sequence:
        setShuffleMode(false);
        setRepeatMode(RepeatMode.off);
        break;
      case PlayMode.loop:
        setShuffleMode(false);
        setRepeatMode(RepeatMode.one);
        break;
      case PlayMode.random:
        setShuffleMode(true);
        break;
    }
  }

  // 兼容旧入口：正常、单曲循环、随机播放。
  void cyclePlayMode() {
    switch (playMode) {
      case PlayMode.sequence:
        setPlayMode(PlayMode.loop);
        break;
      case PlayMode.loop:
        setPlayMode(PlayMode.random);
        break;
      case PlayMode.random:
        setPlayMode(PlayMode.sequence);
        break;
    }
  }

  Future<void> removeFromPlaylist(String hash) async {
    final removeIndex = _playlist.indexWhere((song) => song.hash == hash);
    if (removeIndex == -1) return;
    _playlist.removeAt(removeIndex);
    if (_playlist.isEmpty) {
      _currentIndex = -1;
      _shuffleOrder = [];
      _shufflePosition = -1;
      await _player.stop();
    } else {
      if (_currentIndex > removeIndex) {
        _currentIndex--;
      } else if (_currentIndex >= _playlist.length) {
        _currentIndex = _playlist.length - 1;
      }
      if (_shuffleMode) _generateShuffleOrder();
    }
    await _persistPlaylist();
    notifyListeners();
  }

  Future<void> clearPlaylist() async {
    await _player.stop();
    _playlist = [];
    _currentIndex = -1;
    _shuffleMode = false;
    _repeatMode = RepeatMode.off;
    _shuffleOrder = [];
    _shufflePosition = -1;
    _currentLyrics = [];
    _currentLyricIndex = 0;
    _currentPosition = Duration.zero;
    _bufferedPosition = Duration.zero;
    _totalDuration = Duration.zero;
    _processingState = ProcessingState.idle;
    await _persistPlaylist();
    notifyListeners();
  }

  // 设置音量 (0.0 - 1.0)
  void setVolume(double val) {
    _volume = val.clamp(0.0, 1.0);
    _player.setVolume(_volume);
    _volumePersistTimer?.cancel();
    _volumePersistTimer = Timer(const Duration(milliseconds: 300), () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('playback_volume', _volume);
    });
    notifyListeners();
  }

  // 收藏切换
  Future<void> toggleFavorite(String hash, {Song? song}) async {
    song ??= _playlist
        .cast<Song?>()
        .firstWhere((item) => item?.hash == hash, orElse: () => null);
    if (_favoriteHashes.contains(hash)) {
      _favoriteHashes.remove(hash);
      await MusicApiService.removeFavorite(hash);
    } else {
      _favoriteHashes.add(hash);
      if (song != null) await MusicApiService.addFavorite(song);
    }
    notifyListeners();
  }

  bool isFavorite(String hash) => _favoriteHashes.contains(hash);

  // 跳转进度
  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  @override
  void dispose() {
    _progressNotificationTimer?.cancel();
    final persistVolume = _volumePersistTimer?.isActive ?? false;
    _volumePersistTimer?.cancel();
    if (persistVolume) {
      SharedPreferences.getInstance()
          .then((prefs) => prefs.setDouble('playback_volume', _volume));
    }
    _player.dispose();
    progressNotifier.dispose();
    super.dispose();
  }
}
