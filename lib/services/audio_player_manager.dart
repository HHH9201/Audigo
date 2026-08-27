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
import '../services/webdav_service.dart';
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
  bool _isPreparingSong = false;
  Duration _currentPosition = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  ProcessingState _processingState = ProcessingState.idle;
  bool _shuffleMode = false;
  RepeatMode _repeatMode = RepeatMode.off;
  List<int> _shuffleOrder = [];
  int _shufflePosition = -1;
  double _volume = 1.0;
  String _audioQuality = 'flac';
  bool _autoPlayNext = true;
  bool _gaplessPlayback = true;
  bool _wifiOnlyHighQuality = false;
  bool _showLyrics = true;

  // 播放源替换操作串行队列：setFilePath / setAudioSource 必须排队执行，
  // 防止切歌竞态——旧请求的源加载完成事件覆盖新请求的播放源
  // （表现为 UI 显示新歌、实际播放旧歌）。
  Future<void> _sourceOpQueue = Future<void>.value();
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

  /// 串行执行播放源替换操作（与 [_sourceOpQueue] 配合）。
  /// 操作实际开始执行时才检查 [isCurrent]：过期的切歌请求直接跳过，
  /// 不再触碰播放器，避免旧请求晚到的加载完成事件覆盖新歌的播放源。
  Future<T?> _runExclusive<T>(bool Function() isCurrent,
      Future<T> Function() op) {
    final prev = _sourceOpQueue;
    final completer = Completer<void>();
    _sourceOpQueue = completer.future;
    return prev
        .then((_) => isCurrent() ? op() : Future<T?>.value(null))
        .whenComplete(() => completer.complete());
  }

  // Getters
  List<Song> get playlist => _playlist;
  int get currentIndex => _currentIndex;
  Song? get currentSong =>
      (_currentIndex >= 0 && _currentIndex < _playlist.length)
          ? _playlist[_currentIndex]
          : null;
  bool get isPlaying => _isPlaying;
  /// 切歌准备中（取 URL / 下载缓存阶段），UI 用于显示加载指示。
  bool get isPreparingSong => _isPreparingSong;
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
    _audioQuality = prefs.getString('audio_quality') ?? 'flac';
    _autoPlayNext = prefs.getBool('auto_play_next') ?? true;
    _gaplessPlayback = prefs.getBool('gapless_playback') ?? true;
    _wifiOnlyHighQuality = prefs.getBool('wifi_only_high_quality') ?? false;
    _showLyrics = prefs.getBool('show_lyrics') ?? true;
    _cacheBeforePlay = prefs.getBool('cache_before_play') ?? true;
    _volume = (prefs.getDouble('playback_volume') ?? 1.0).clamp(0.0, 1.0);
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
      if (state.playing && _localSourceActive) {
        // 本地源开始播放：启动停滞看门狗（Timer 驱动，独立于位置流）。
        _startStallWatchdog();
      }
      // 注意：playing 变 false 不能停看门狗——解码损坏时后端会把
      // playing 置回 false，这正是看门狗失效、不自动切歌的根因。
      // 用户主动暂停由 _userPaused 标记区分，看门狗据此跳过检查。
      if (state.processingState == ProcessingState.completed) {
        _stopStallWatchdog();
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
      // EOF 兜底：部分后端（media_kit 桥）在歌曲结束时
      // 不一定发出 ProcessingState.completed，导致不会自动播下一首；
      // 这里在位置到达总时长时主动触发结束处理（带防重入与二次确认）。
      _maybeTrackEnded(position);
      // 停滞看门狗：本地源解码损坏（文件截断等）时 MPV 卡死不推进也不发
      // completed 事件——位置长时间冻结则跳下一首并删除损坏缓存。
      _checkPlaybackStall(position);
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

  /// 将播放地址响应携带的歌词写入本地缓存，并同步到云盘。
  /// 缓存层已有该 hash 的歌词或内容为空时自动跳过。
  Future<void> _persistLyricsToCache(Song song, String content) async {
    if (content.trim().isEmpty) return;
    try {
      final cache = await MediaCacheService.instance;
      await cache.getLyrics(hash: song.hash, loader: () async => content);
    } catch (_) {
      // 歌词缓存失败不影响播放。
    }
    unawaited(WebDavService.instance.syncLyricsIfNeeded(song, content: content));
  }

  /// 独立接口获取歌词；上游不稳（如 502）导致为空时延时重试一次。
  /// 结果按 requestId 守卫，切歌后过期结果直接丢弃。
  Future<void> _fetchLyricsWithRetry(Song song, int requestId) async {
    var lyrics = await _tryGetLyrics(song);
    if (requestId != _playRequestId) return;
    if (lyrics.isEmpty) {
      print('播放调试: 歌词兜底第一次为空，3 秒后重试');
      await Future<void>.delayed(const Duration(seconds: 3));
      if (requestId != _playRequestId) return;
      lyrics = await _tryGetLyrics(song);
    }
    if (requestId != _playRequestId) return;
    if (lyrics.isEmpty) {
      print('播放调试: 歌词最终未获取到 ${song.songName}');
      return;
    }
    _currentLyrics = lyrics;
    notifyListeners();
    // 接口取到的歌词已由缓存层落盘，这里触发云盘备份。
    unawaited(WebDavService.instance.syncLyricsIfNeeded(song));
  }

  Future<List<LyricLine>> _tryGetLyrics(Song song) async {
    try {
      final lyrics = await MusicApiService.getLyrics(song.hash,
          songName: song.songName, artist: song.authorName);
      print('播放调试: 歌词兜底取到 ${lyrics.length} 行');
      if (lyrics.isNotEmpty) return lyrics;
    } catch (e) {
      print('播放调试: 歌词兜底异常: $e');
    }
    // 联网取不到（限流/无版权/未登录）时，从云盘兜底取歌词。
    try {
      final raw = await WebDavService.instance.fetchLyrics(
        songName: song.songName,
        artist: song.authorName,
      );
      if (raw.isNotEmpty) {
        print('播放调试: 云盘歌词兜底命中 ${raw.length} 字符');
        // 命中后写入本地缓存，之后离线也能直接用。
        if (song.hash.isNotEmpty) {
          try {
            final cache = await MediaCacheService.instance;
            final cached =
                await cache.getLyrics(hash: song.hash, loader: () async => raw);
            return MusicApiService.parseLyrics(cached.content);
          } catch (_) {
            // 缓存失败则直接解析原文。
          }
        }
        return MusicApiService.parseLyrics(raw);
      }
    } catch (_) {
      // 云盘不可用不影响播放。
    }
    return const [];
  }

  /// 结束"准备中"状态；过期请求不打扰更新一次的请求。
  void _finishPreparing(int requestId) {
    if (requestId != _playRequestId) return;
    if (!_isPreparingSong) return;
    _isPreparingSong = false;
    notifyListeners();
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
    if (_trackEndHandling) return;
    if (_gaplessSource != null &&
        (_player.currentIndex ?? 0) < _gaplessSongIndexes.length - 1) {
      return; // gapless 源内自动切歌，看门狗继续运行。
    }
    if (_repeatMode == RepeatMode.one) {
      seek(Duration.zero);
      _player.play();
      _startStallWatchdog();
      return;
    }
    // 自然结束：停看门狗，避免位置冻结被误判为解码损坏。
    _stopStallWatchdog();
    if (!_autoPlayNext) return;
    if (_shuffleMode ||
        _repeatMode == RepeatMode.all ||
        _currentIndex < _playlist.length - 1) {
      _trackEndHandling = true;
      try {
        playNext().whenComplete(() => _trackEndHandling = false);
      } catch (_) {
        _trackEndHandling = false;
      }
    }
  }

  /// EOF 兜底标志：防止 completed 事件与位置兜底重复触发下一首。
  bool _trackEndHandling = false;

  /// 停滞看门狗状态：位置推进时间戳与上次位置。
  DateTime _lastPositionAdvanceAt = DateTime.now();
  Duration _lastStallCheckPosition = Duration.zero;
  bool _localSourceActive = false;

  /// 用户主动暂停标记。解码损坏时后端会把 playing 置回 false，
  /// 看门狗不能用 playing 区分"用户暂停"与"解码卡死"，只能靠此标记。
  bool _userPaused = false;

  /// 位置到达总时长时视为歌曲结束（兜底 completed 事件丢失的后端）。
  void _maybeTrackEnded(Duration position) {
    if (_trackEndHandling) return;
    final total = _totalDuration;
    if (total <= Duration.zero) return;
    if (!_isPlaying) return;
    // 留 150ms 余量：部分后端末帧位置会略超总时长。
    if (position < total - const Duration(milliseconds: 150)) return;
    // 二次确认：completed 状态直接成立；否则短暂等待后核对位置。
    if (_player.processingState == ProcessingState.completed) {
      _handleTrackEnded();
      return;
    }
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (!_isPlaying || _trackEndHandling) return;
      final latest = _currentPosition;
      if (latest >= total - const Duration(milliseconds: 150)) {
        if (_player.processingState == ProcessingState.completed ||
            latest >= total) {
          _handleTrackEnded();
        }
      }
    });
  }

  /// 停滞看门狗：本地源播放中位置冻结超过 8 秒视为解码损坏（文件截断/
  /// 数据异常），跳到下一首并删除损坏的缓存文件，下次播放自动重新下载。
  /// 仅对本地源生效——远程流缓冲慢属正常，不误判。
  ///
  /// 注意：不能用 positionStream 驱动本检查——MPV 解码卡死时位置流
  /// 本身也会停止发事件（回调永远不被调用），必须用独立 Timer。
  Timer? _stallWatchdogTimer;

  void _startStallWatchdog() {
    _stallWatchdogTimer?.cancel();
    _userPaused = false;
    _lastPositionAdvanceAt = DateTime.now();
    _lastStallCheckPosition = Duration.zero;
    _stallWatchdogTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final now = DateTime.now();
      // 用 _userPaused 而非 _isPlaying 判断：解码损坏时后端可能把
      // playing 置回 false，若依赖 playing 检查看门狗将永远不触发。
      if (_userPaused || !_localSourceActive || _trackEndHandling) return;
      if (now.difference(_lastPositionAdvanceAt) <
          const Duration(seconds: 8)) {
        return;
      }
      final hasNext = _autoPlayNext &&
          (_shuffleMode ||
              _repeatMode == RepeatMode.all ||
              _currentIndex < _playlist.length - 1);
      final song = currentSong;
      print(
          '播放调试: 本地源播放停滞（疑似缓存损坏），${hasNext ? '跳到下一首' : '停止播放'}');
      // 删除损坏缓存，下次播放重新下载。MPV 占用中可能删除失败，
      // 换源后重试一次。
      if (song != null && song.hash.isNotEmpty) {
        unawaited(MediaCacheService.instance.then((cache) async {
          await cache.invalidateAudio(song.hash);
          await Future<void>.delayed(const Duration(seconds: 2));
          await cache.invalidateAudio(song.hash);
        }));
      }
      if (!hasNext) {
        pause();
        _showNotice('音频解码异常，已停止播放');
        _stallWatchdogTimer?.cancel();
        return;
      }
      _showNotice('音频解码异常，已切换下一首');
      _stallWatchdogTimer?.cancel();
      _trackEndHandling = true;
      try {
        playNext().whenComplete(() => _trackEndHandling = false);
      } catch (_) {
        _trackEndHandling = false;
      }
    });
  }

  void _stopStallWatchdog() {
    _stallWatchdogTimer?.cancel();
    _stallWatchdogTimer = null;
  }

  /// 位置推进时刷新时间戳（由 positionStream 调用）。
  void _checkPlaybackStall(Duration position) {
    final now = DateTime.now();
    if (position > _lastStallCheckPosition) {
      _lastPositionAdvanceAt = now;
    }
    _lastStallCheckPosition = position;
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
    _isPreparingSong = true;
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
      } else {
        // 内嵌歌词与伴生文件都为空时，回退到缓存层取歌词；
        // 缓存也没有则联网获取（含按歌名搜索兜底），成功后按 hash 落盘，
        // 下次播放直接命中缓存；仍取不到时尝试云盘歌词兜底，
        // 并把取到的歌词自动备份到云盘。
        unawaited(_fetchLyricsWithRetry(song, requestId));
      }
      try {
        // 源替换走串行队列并二次校验请求有效性（与在线路径一致，
        // 防止切歌竞态导致旧歌覆盖新歌播放源）。
        final loaded = await _runExclusive<bool>(
          () => requestId == _playRequestId,
          () async {
            _localSourceActive = true;
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
            return true;
          },
        );
        if (requestId != _playRequestId) return;
        if (loaded != true) return;
        await _player.play();
        // 显式启动看门狗：解码损坏时后端可能不发出 playing=true 状态，
        // 依赖状态事件启动会漏掉。
        _startStallWatchdog();
        await MusicApiService.addPlayHistory(song);
        _prepareGaplessNext(requestId);
      } catch (e) {
        print('播放音频异常: $e');
      }
      _finishPreparing(requestId);
      return;
    }

    // 缓存命中快路径：本地缓存层已有该 hash 且音质不低于当前设置的音频时，
    // 直接播放本地文件，跳过 VIP 领取与取播放 URL 的网络往返——
    // 这正是"本地有缓存每次播放仍要加载"的根源。
    // 歌词优先读本地缓存（磁盘读取，毫秒级），没有再异步联网补齐；
    // 播放历史、云盘备份同样全部异步，不阻塞播放。
    if (song.hash.isNotEmpty) {
      final cache = await MediaCacheService.instance;
      final quality = await _effectiveStreamingQuality();
      final cachedAudio = await cache.peekCachedAudio(song.hash, minQuality: quality);
      if (requestId != _playRequestId) return;
      if (cachedAudio != null) {
        final cachedLyrics = await cache.readCachedLyrics(song.hash);
        if (requestId != _playRequestId) return;
        if (cachedLyrics.trim().isNotEmpty) {
          _currentLyrics = MusicApiService.parseLyrics(cachedLyrics);
          if (_currentLyrics.isEmpty) {
            _currentLyrics = cachedLyrics
                .split(RegExp(r'\r?\n'))
                .where((line) => line.trim().isNotEmpty)
                .map((line) =>
                    LyricLine(time: Duration.zero, text: line.trim()))
                .toList();
          }
          notifyListeners();
        } else {
          unawaited(_fetchLyricsWithRetry(song, requestId));
        }
        try {
          print('播放调试: 缓存命中直接播放 ${cachedAudio.path}');
          final loaded = await _runExclusive<bool>(
            () => requestId == _playRequestId,
            () async {
            _localSourceActive = true;
            if (_gaplessPlayback) {
              // gapless 源：当前曲 + 后台预加载下一首，实现无缝切歌。
              _gaplessSource = ConcatenatingAudioSource(
                useLazyPreparation: true,
                children: [AudioSource.file(cachedAudio.path)],
              );
              _gaplessSongIndexes
                ..clear()
                ..add(_currentIndex);
              _preparingSourceIndex = null;
              await _player.setAudioSource(_gaplessSource!);
            } else {
              _clearGaplessState();
              await _player.pause();
              await _player.setFilePath(cachedAudio.path).timeout(
                    const Duration(seconds: 6),
                    onTimeout: () => throw TimeoutException('本地音频加载超时'),
                  );
            }
            return true;
          },
          );
          if (requestId != _playRequestId) return;
          if (loaded != true) return;
          unawaited(_player.play());
          // 显式启动看门狗：解码损坏时后端可能不发出 playing=true 状态，
          // 依赖状态事件启动会漏掉。
          _startStallWatchdog();
          print('播放调试: 缓存快路径播放已启动');
          unawaited(MusicApiService.addPlayHistory(song));
          _prepareGaplessNext(requestId);
          _finishPreparing(requestId);
          // 播放成功后异步备份到云盘（远端已存在则跳过）。
          unawaited(WebDavService.instance.syncSongIfNeeded(song, cachedAudio));
          return;
        } catch (e) {
          // 快路径失败（如加载超时）不中断播放，回退到在线路径重试。
          print('播放调试: 缓存快路径失败，回退在线路径: $e');
        }
      }
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

    // 2. 加载歌词：优先使用播放地址响应中的歌词；为空时兜底独立接口。
    //    （云盘兜底音频分支的歌词已在上面单独触发。）
    if (urls.isNotEmpty && playResult.lyrics.trim().isNotEmpty) {
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
      // 播放地址携带的歌词不经过缓存层，这里异步补写本地，
      // 保证下次播放（含离线）仍能显示歌词，并同步到云盘。
      unawaited(_persistLyricsToCache(song, playResult.lyrics));
    } else if (urls.isNotEmpty) {
      print('播放调试: 播放响应无歌词，走独立歌词接口兜底');
      unawaited(_fetchLyricsWithRetry(song, requestId));
    }

    // 3. 与 Go 原版一致：优先同步缓存整首歌曲，再播放本地文件。
    //    开启开关可在设置关闭整首缓存而直接流式播放。
    //    在线接口拿不到 URL（上游故障/无 VIP）时，从云盘兜底取音频。
    File? audioFile;
    if (urls.isEmpty) {
      print('播放调试: 无法获取播放URL，尝试从云盘获取音频');
      audioFile = await WebDavService.instance.fetchAudio(song: song);
      if (requestId != _playRequestId) return;
      if (audioFile == null) {
        // 云盘也没有：未登录且本地没有该音频时，前端提示未登录。
        if (!await MusicApiService.isLoggedIn()) {
          _showNotice('未登录：本地没有该歌曲，请登录后再播放在线歌曲');
        }
        _processingState = ProcessingState.idle;
        _finishPreparing(requestId);
        notifyListeners();
        return;
      }
      // 歌词同样走兜底链（接口 → 云盘）。
      unawaited(_fetchLyricsWithRetry(song, requestId));
    } else if (_cacheBeforePlay) {
      try {
        final cache = await MediaCacheService.instance;
        for (var i = 0; i < urls.length; i++) {
          try {
            print('播放调试: 获取本地音频 (${i + 1}/${urls.length})');
            audioFile = await cache.getAudio(
              hash: song.hash,
              quality: playResult.quality,
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
      final localAudio = audioFile;
      var localOk = false;
      try {
        print('播放调试: 本地音频已就绪 ${localAudio.path}');
        _clearGaplessState();
        // Windows 上 just_audio 加载本地文件可能较慢或卡住（Media
        // Foundation 异步初始化），用 6 秒超时避免永久阻塞；
        // 超时/失败后重置播放器并回退远程播放。
        // 源替换走串行队列并二次校验请求有效性，防止旧请求
        // 覆盖新歌播放源（UI 是新歌、实际播出旧歌的竞态）。
        final loaded = await _runExclusive<bool>(
          () => requestId == _playRequestId,
          () async {
            _localSourceActive = true;
            if (_gaplessPlayback) {
              // gapless 源：当前曲 + 后台预加载下一首，实现无缝切歌。
              _gaplessSource = ConcatenatingAudioSource(
                useLazyPreparation: true,
                children: [AudioSource.file(localAudio.path)],
              );
              _gaplessSongIndexes
                ..clear()
                ..add(_currentIndex);
              _preparingSourceIndex = null;
              await _player.setAudioSource(_gaplessSource!);
            } else {
              _clearGaplessState();
              await _player.pause();
              await _player.setFilePath(localAudio.path).timeout(
                    const Duration(seconds: 6),
                    onTimeout: () => throw TimeoutException('本地音频加载超时'),
                  );
            }
            return true;
          },
        );
        if (requestId != _playRequestId) return;
        if (loaded != true) return;
        unawaited(_player.play());
        // 显式启动看门狗：解码损坏时后端可能不发出 playing=true 状态，
        // 依赖状态事件启动会漏掉。
        _startStallWatchdog();
        print('播放调试: 本地音频播放已启动');
        await MusicApiService.addPlayHistory(song);
        _prepareGaplessNext(requestId);
        _finishPreparing(requestId);
        // 播放成功后自动把歌曲与歌词备份到云盘（已存在则跳过）。
        unawaited(WebDavService.instance.syncSongIfNeeded(song, audioFile));
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
        // 源替换走串行队列并二次校验请求有效性：旧请求排队到执行时
        // 已过期则跳过，不再替换源（否则旧歌的远程流会覆盖新歌播放）。
        final loaded = await _runExclusive<bool>(
          () => requestId == _playRequestId,
          () {
            _localSourceActive = false;
            return _player
                .setAudioSource(
                  AudioSource.uri(Uri.parse(urls[i]), headers: headers),
                )
                .timeout(
                  const Duration(seconds: 8),
                  onTimeout: () => throw TimeoutException('远程音频加载超时'),
                )
                .then((_) => true);
          },
        );
        if (requestId != _playRequestId) return;
        if (loaded != true) return;
        await _player.play();
        print('播放调试: 远程音频播放已启动');
        await MusicApiService.addPlayHistory(song);
        _prepareGaplessNext(requestId);
        _finishPreparing(requestId);
        return;
      } catch (e) {
        print('播放调试: 远程音频失败(${i + 1}/${urls.length}): $e');
        try {
          await _player.stop();
        } catch (_) {}
      }
    }

    _processingState = ProcessingState.idle;
    _finishPreparing(requestId);
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
    } else if (nextSong.hash.isNotEmpty) {
      // 本地曲库没有时，优先探测缓存层的已缓存文件（缓存快路径同款逻辑），
      // 命中即可零网络预加载下一首，实现真正的无缝切歌。
      try {
        final cache = await MediaCacheService.instance;
        final quality = await _effectiveStreamingQuality();
        final cached =
            await cache.peekCachedAudio(nextSong.hash, minQuality: quality);
        if (cached != null) {
          source = AudioSource.file(cached.path);
        }
      } catch (_) {
        // 缓存探测失败则走在线 URL 预加载。
      }
    }
    if (source == null) {
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
    _userPaused = false;
    final song = currentSong;
    if (song == null) return;
    if (_player.processingState == ProcessingState.idle ||
        _player.audioSource == null) {
      await playSong(song);
      return;
    }
    await _player.play();
  }

  Future<void> pause() {
    _userPaused = true;
    return _player.pause();
  }

  Future<void> stop() {
    _userPaused = true;
    _stopStallWatchdog();
    return _player.stop();
  }

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
    _stallWatchdogTimer?.cancel();
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
