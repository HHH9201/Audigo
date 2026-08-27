import 'dart:async';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:desktop_lyrics/desktop_lyrics.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_player_manager.dart';

/// 桌面歌词管理器：基于 pub 包 desktop_lyrics 的原生悬浮歌词窗口。
///
/// 插件内部自行创建并管理置顶透明窗口（Windows/Linux 原生实现），
/// 这里只负责：读取偏好 -> 应用样式配置 -> 随播放进度渲染逐字歌词帧。
class DesktopLyricsManager {
  DesktopLyricsManager._();

  static final DesktopLyricsManager instance = DesktopLyricsManager._();

  static const preferenceKey = 'desktop_lyrics';

  static bool get isSupported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  AudioPlayerManager? _player;
  DesktopLyrics? _lyrics;
  bool _enabled = true;
  double _fontSize = 22;
  Timer? _renderTimer;
  bool _rendering = false;
  String? _lastFrameKey;
  bool get enabled => _enabled;

  Future<void> initialize(AudioPlayerManager player) async {
    if (!isSupported) return;
    _player = player;
    final preferences = await SharedPreferences.getInstance();
    _enabled = preferences.getBool(preferenceKey) ?? true;
    _fontSize = (preferences.getInt('lyrics_font_size') ?? 22)
        .clamp(12, 48)
        .toDouble();
    _lyrics = DesktopLyrics();
    await _applyConfig();
    // 主通知（歌曲/歌词行切换等低频事件）+ 高频进度通知双路监听：
    // 逐字卡拉OK进度由 progressNotifier 驱动，
    // 仅靠主通知会导致整行期间桌面歌词静止、没有逐字高亮。
    player.addListener(_handlePlayerChanged);
    player.progressNotifier.addListener(_handlePlayerChanged);
  }

  Future<void> setEnabled(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(preferenceKey, value);
    await _applyEnabled(value);
  }

  Future<void> toggle() => setEnabled(!_enabled);

  /// 锁定歌词窗口（鼠标完全穿透，不可拖动）；解锁后恢复拖动。
  Future<void> setLocked(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('desktop_lyrics_locked', value);
    await _applyConfig();
    await _renderFrame();
  }

  bool get locked =>
      _locked; // 初始化后由偏好填充；同步字段便于托盘菜单读取。

  bool _locked = false;

  /// 逐字渐变填充开关（金色渐变卡拉OK效果）。
  Future<void> setGradient(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('desktop_lyrics_gradient', value);
    await _applyConfig();
  }

  bool _gradient = true;
  bool get gradient => _gradient;

  /// 托盘快捷调节字号：[delta] 为增量（如 +2 / -2），自动 clamp 到 12-48。
  Future<void> adjustFontSize(int delta) async {
    final next = (_fontSize + delta).clamp(12, 48).toDouble();
    if (next == _fontSize) return;
    _fontSize = next;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt('lyrics_font_size', next.toInt());
    await _applyConfig();
  }

  /// 设置变化后重新应用配置（字号等）。
  Future<void> reloadSettings() async {
    if (!isSupported) return;
    final preferences = await SharedPreferences.getInstance();
    _fontSize = (preferences.getInt('lyrics_font_size') ?? 22)
        .clamp(12, 48)
        .toDouble();
    await _applyEnabled(preferences.getBool(preferenceKey) ?? true);
  }

  /// 兼容旧调用点：字号变化后重新应用配置即可，无需重建窗口。
  Future<void> reloadLyricsWindow() => reloadSettings();

  Future<void> _applyEnabled(bool value) async {
    _enabled = value;
    await _applyConfig();
    if (!value) {
      _renderTimer?.cancel();
      _renderTimer = null;
      _stopSmoothTicker();
    } else {
      _renderFrame();
    }
  }

  Future<void> _applyConfig() async {
    final lyrics = _lyrics;
    if (lyrics == null) return;
    final preferences = await SharedPreferences.getInstance();
    final noBackground =
        preferences.getBool('desktop_lyrics_no_background') ?? false;
    _locked = preferences.getBool('desktop_lyrics_locked') ?? false;
    _gradient = preferences.getBool('desktop_lyrics_gradient') ?? true;
    try {
      await lyrics.apply(
        lyrics.state.copyWith(
          interaction: lyrics.state.interaction.copyWith(
            enabled: _enabled,
            // 锁定后鼠标穿透：不会被误拖动，通过托盘菜单解锁。
            clickThrough: _locked,
          ),
          text: lyrics.state.text.copyWith(
            fontSize: _fontSize,
            // 无背景模式：加深描边+阴影，保证浅色桌面上文字可读。
            strokeColor: noBackground ? const Color(0x99000000) : null,
            strokeWidth: noBackground ? 2.5 : null,
            shadowColor: noBackground ? const Color(0x66000000) : null,
          ),
          background: lyrics.state.background.copyWith(
            // 0 = 完全透明（隐藏背景面板）。
            opacity: noBackground ? 0.0 : 0.85,
            backgroundColor: noBackground
                ? const Color(0x00000000)
                : lyrics.state.background.backgroundColor,
          ),
          gradient: lyrics.state.gradient.copyWith(
            // 逐字渐变填充（金色渐变卡拉OK）。
            textGradientEnabled: _gradient,
          ),
          layout: lyrics.state.layout.copyWith(overlayWidth: 760),
        ),
      );
    } catch (error) {
      debugPrint('应用桌面歌词配置失败: $error');
    }
  }

  void _handlePlayerChanged() {
    if (!_enabled) return;
    // 通知驱动的渲染仅处理行切换/歌曲切换等事件；
    // 逐字平滑推进由 _smoothTicker 独立驱动（30fps + 位置插值）。
    _renderFrame();
  }

  /// 30fps 平滑渲染定时器：播放期间独立运行，不依赖通知频率。
  Timer? _smoothTimer;

  /// 上次从播放器读到的真实位置及读取时间，用于位置插值。
  Duration _lastReportedPosition = Duration.zero;
  DateTime _lastReportedAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _startSmoothTicker() {
    _smoothTimer ??= Timer.periodic(
      const Duration(milliseconds: 33),
      (_) => _renderFrame(),
    );
  }

  void _stopSmoothTicker() {
    _smoothTimer?.cancel();
    _smoothTimer = null;
  }

  /// 插值出当前播放位置：两次真实位置上报之间按播放耗时本地推进，
  /// 使逐字进度以 30fps 平滑流动而不是跟随上报频率（约 500ms 一跳）。
  Duration _interpolatedPosition(AudioPlayerManager player) {
    final reported = player.currentPosition;
    final now = DateTime.now();
    if (reported != _lastReportedPosition) {
      _lastReportedPosition = reported;
      _lastReportedAt = now;
      return reported;
    }
    if (!player.isPlaying) return reported;
    return reported + now.difference(_lastReportedAt);
  }

  Future<void> _renderFrame() async {
    final player = _player;
    final lyrics = _lyrics;
    if (player == null || lyrics == null || !_enabled || _rendering) return;
    // 播放中启动平滑定时器；暂停/停止时停掉，避免空转。
    if (player.isPlaying) {
      _startSmoothTicker();
    } else if (_smoothTimer != null) {
      _stopSmoothTicker();
    }
    _rendering = true;
    try {
      final frame = _buildFrame(player, _interpolatedPosition(player));
      // 内容未变化时跳过渲染，避免高频无效调用。
      final key =
          '${frame.currentLine}|${(frame.lineProgress ?? 0).toStringAsFixed(3)}';
      if (key == _lastFrameKey) return;
      _lastFrameKey = key;
      await lyrics.render(frame);
    } catch (error) {
      debugPrint('渲染桌面歌词失败: $error');
    } finally {
      _rendering = false;
    }
  }

  DesktopLyricsFrame _buildFrame(AudioPlayerManager player, Duration position) {
    final lyrics = player.currentLyrics;
    // 行索引按插值位置本地计算，保证与逐字进度同步推进
    // （播放器的行索引由 positionStream 驱动，最高滞后数百毫秒）。
    var index = -1;
    for (var i = lyrics.length - 1; i >= 0; i--) {
      if (lyrics[i].time <= position) {
        index = i;
        break;
      }
    }
    if (index < 0) {
      final song = player.currentSong;
      final text = song != null
          ? '${song.songName}  ${song.authorName}'
          : '拾音';
      return DesktopLyricsFrame.line(currentLine: text, lineProgress: 0);
    }

    final line = lyrics[index];
    final words = line.words;
    if (words.isEmpty) {
      return DesktopLyricsFrame.line(
        currentLine: line.text,
        lineProgress: 0,
      );
    }

    // 逐字卡拉OK：token 时间轴相对行起点，position 为当前行内进度。
    final linePosition = position - line.time;
    final tokens = <DesktopLyricsTimelineToken>[
      for (final word in words)
        DesktopLyricsTimelineToken(
          text: word.text,
          start: word.time - line.time,
          end: word.time - line.time + word.duration,
        ),
    ];
    return DesktopLyricsFrame.fromKaraokeTimeline(
      position: linePosition,
      tokens: tokens,
    );
  }

  Future<void> close() async {
    _renderTimer?.cancel();
    _renderTimer = null;
    _stopSmoothTicker();
    _player?.removeListener(_handlePlayerChanged);
    _player?.progressNotifier.removeListener(_handlePlayerChanged);
    final lyrics = _lyrics;
    _lyrics = null;
    lyrics?.dispose();
  }
}
