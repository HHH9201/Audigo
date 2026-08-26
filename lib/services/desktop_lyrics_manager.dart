import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_player_manager.dart';

class DesktopLyricsManager {
  DesktopLyricsManager._();

  static final DesktopLyricsManager instance = DesktopLyricsManager._();

  static const preferenceKey = 'desktop_lyrics';
  static const taskbarPreferenceKey = 'taskbar_lyrics';
  static const windowArgument = 'desktop_lyrics';

  static bool get isSupported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  AudioPlayerManager? _player;
  WindowController? _window;
  bool _enabled = true;
  bool _taskbarEnabled = false;
  bool _creating = false;
  String? _lastSnapshot;
  DateTime _lastSentAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _sendTimer;

  bool get enabled => _enabled;
  bool get taskbarEnabled => _taskbarEnabled;

  Future<void> initialize(AudioPlayerManager player) async {
    if (!isSupported) return;
    _player = player;
    final preferences = await SharedPreferences.getInstance();
    _enabled = preferences.getBool(preferenceKey) ?? true;
    _taskbarEnabled =
        preferences.getBool(taskbarPreferenceKey) ?? false;
    player.addListener(_handlePlayerChanged);
    if (_enabled) await show();
  }

  Future<void> setEnabled(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(preferenceKey, value);
    await _applyEnabled(value);
  }

  /// 切换任务栏内嵌与否（桌面浮窗 <-> 内嵌任务栏）。仅 Windows 生效。
  Future<void> setTaskbarEnabled(bool value) async {
    _taskbarEnabled = value;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(taskbarPreferenceKey, value);
    await _applyTaskbar();
  }

  Future<void> reloadSettings() async {
    if (!isSupported) return;
    final preferences = await SharedPreferences.getInstance();
    _taskbarEnabled =
        preferences.getBool(taskbarPreferenceKey) ?? false;
    await _applyEnabled(preferences.getBool(preferenceKey) ?? true);
  }

  /// 字号/位置设置变化后重建歌词窗口以应用新配置。
  Future<void> reloadLyricsWindow() async {
    if (!isSupported || !_enabled) return;
    await close();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await show();
  }

  Future<void> toggle() => setEnabled(!_enabled);

  /// 根据 _taskbarEnabled 决定把歌词窗口内嵌到任务栏还是恢复成桌面浮窗。
  Future<void> _applyTaskbar() async {
    if (!isSupported || !_enabled || _window == null) return;
    final method = _taskbarEnabled ? 'lyrics_attach' : 'lyrics_detach';
    // 窗口引擎就绪需要一点时间，失败重试几次。
    for (final delay in const [
      Duration(milliseconds: 120),
      Duration(milliseconds: 300),
      Duration(milliseconds: 700),
    ]) {
      await Future<void>.delayed(delay);
      try {
        final window = _window;
        if (window == null) return;
        final result =
            await window.invokeMethod<Map>('$method', null);
        if (result is Map && result['attached'] == true) {
          if (_taskbarEnabled) {
            debugPrint('任务栏歌词已嵌入 Windows 任务栏');
          } else {
            debugPrint('任务栏歌词已恢复为桌面浮窗');
          }
          return;
        }
      } catch (error) {
        debugPrint('歌词窗口切换任务栏状态失败: $error');
      }
    }
  }

  Future<void> _applyEnabled(bool value) async {
    _enabled = value;
    if (value) {
      await show();
    } else {
      await hide();
    }
  }

  Future<void> show() async {
    if (!isSupported || _creating) return;
    final existing = _window;
    if (existing != null) {
      await existing.show();
      unawaited(_sendSnapshotWhenReady());
      return;
    }

    _creating = true;
    try {
      final windows = await WindowController.getAll();
      for (final window in windows) {
        if (window.arguments == windowArgument) {
          _window = window;
          await window.show();
          unawaited(_sendSnapshotWhenReady());
          return;
        }
      }
      _window = await WindowController.create(
        const WindowConfiguration(
          arguments: windowArgument,
          hiddenAtLaunch: true,
        ),
      );
      await _window!.show();
      unawaited(_sendSnapshotWhenReady());
    } catch (error) {
      debugPrint('创建桌面歌词窗口失败: $error');
      _window = null;
    } finally {
      _creating = false;
    }
  }

  Future<void> _sendSnapshotWhenReady() async {
    for (final delay in const [
      Duration(milliseconds: 120),
      Duration(milliseconds: 300),
      Duration(milliseconds: 700),
      Duration(seconds: 1),
    ]) {
      await Future<void>.delayed(delay);
      await _sendSnapshot(force: true);
    }
  }

  Future<void> hide() async {
    try {
      await _window?.hide();
    } catch (error) {
      debugPrint('隐藏桌面歌词窗口失败: $error');
      _window = null;
    }
  }

  Future<void> close() async {
    _sendTimer?.cancel();
    _sendTimer = null;
    final window = _window;
    _window = null;
    if (window == null) return;
    try {
      await window.invokeMethod<void>('close');
    } catch (_) {}
  }

  void _handlePlayerChanged() {
    if (!_enabled) return;
    if (_window == null) {
      unawaited(show());
      return;
    }
    final elapsed = DateTime.now().difference(_lastSentAt);
    const interval = Duration(milliseconds: 100);
    if (elapsed >= interval) {
      _sendTimer?.cancel();
      _sendTimer = null;
      unawaited(_sendSnapshot());
      return;
    }
    _sendTimer ??= Timer(interval - elapsed, () {
      _sendTimer = null;
      unawaited(_sendSnapshot());
    });
  }

  Future<void> _sendSnapshot({bool force = false}) async {
    final player = _player;
    final window = _window;
    if (player == null || window == null) return;

    final now = DateTime.now();
    if (!force && now.difference(_lastSentAt).inMilliseconds < 100) return;

    final lyrics = player.currentLyrics;
    final index = lyrics.isEmpty
        ? -1
        : player.currentLyricIndex.clamp(0, lyrics.length - 1);
    final line = index >= 0 ? lyrics[index] : null;
    final snapshot = jsonEncode({
      'song': player.currentSong?.songName ?? '',
      'artist': player.currentSong?.authorName ?? '',
      'playing': player.isPlaying,
      'line': line?.text ?? '',
      'nextLine':
          index >= 0 && index + 1 < lyrics.length ? lyrics[index + 1].text : '',
      'words': line?.words.map((word) => word.text).toList() ?? const [],
      'wordIndex': player.currentLyricWordIndex,
      'wordProgress': player.currentLyricWordProgress,
    });
    if (!force && snapshot == _lastSnapshot) return;
    _lastSnapshot = snapshot;
    _lastSentAt = now;

    try {
      await window.invokeMethod<void>('lyrics_update', snapshot);
    } catch (_) {
      // The secondary engine may still be registering its method handler.
    }
  }
}
