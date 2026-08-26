import 'dart:async';
import 'dart:io';

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
    player.addListener(_handlePlayerChanged);
  }

  Future<void> setEnabled(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(preferenceKey, value);
    await _applyEnabled(value);
  }

  Future<void> toggle() => setEnabled(!_enabled);

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
    } else {
      _renderFrame();
    }
  }

  Future<void> _applyConfig() async {
    final lyrics = _lyrics;
    if (lyrics == null) return;
    try {
      await lyrics.apply(
        lyrics.state.copyWith(
          interaction: lyrics.state.interaction.copyWith(
            enabled: _enabled,
            clickThrough: false,
          ),
          text: lyrics.state.text.copyWith(fontSize: _fontSize),
          background: lyrics.state.background.copyWith(opacity: 0.85),
          layout: lyrics.state.layout.copyWith(overlayWidth: 760),
        ),
      );
    } catch (error) {
      debugPrint('应用桌面歌词配置失败: $error');
    }
  }

  void _handlePlayerChanged() {
    if (!_enabled) return;
    // 播放器每 500ms 高频通知；歌词帧渲染节流至 ~100ms。
    final elapsed = DateTime.now().difference(_lastRenderAt);
    const interval = Duration(milliseconds: 100);
    if (elapsed >= interval) {
      _renderTimer?.cancel();
      _renderTimer = null;
      _renderFrame();
      return;
    }
    _renderTimer ??= Timer(interval - elapsed, () {
      _renderTimer = null;
      _renderFrame();
    });
  }

  DateTime _lastRenderAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _renderFrame() async {
    final player = _player;
    final lyrics = _lyrics;
    if (player == null || lyrics == null || !_enabled || _rendering) return;
    _rendering = true;
    _lastRenderAt = DateTime.now();
    try {
      final frame = _buildFrame(player);
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

  DesktopLyricsFrame _buildFrame(AudioPlayerManager player) {
    final lyrics = player.currentLyrics;
    final index = lyrics.isEmpty
        ? -1
        : player.currentLyricIndex.clamp(0, lyrics.length - 1);
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
    final position = player.currentPosition - line.time;
    final tokens = <DesktopLyricsTimelineToken>[
      for (final word in words)
        DesktopLyricsTimelineToken(
          text: word.text,
          start: word.time - line.time,
          end: word.time - line.time + word.duration,
        ),
    ];
    return DesktopLyricsFrame.fromKaraokeTimeline(
      position: position,
      tokens: tokens,
    );
  }

  Future<void> close() async {
    _renderTimer?.cancel();
    _renderTimer = null;
    _player?.removeListener(_handlePlayerChanged);
    final lyrics = _lyrics;
    _lyrics = null;
    lyrics?.dispose();
  }
}
