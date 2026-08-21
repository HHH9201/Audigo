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

  static const preferenceKey = 'taskbar_lyrics';
  static const windowArgument = 'desktop_lyrics';

  static bool get isSupported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  AudioPlayerManager? _player;
  WindowController? _window;
  bool _enabled = true;
  bool _creating = false;
  String? _lastSnapshot;
  DateTime _lastSentAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get enabled => _enabled;

  Future<void> initialize(AudioPlayerManager player) async {
    if (!isSupported) return;
    _player = player;
    final preferences = await SharedPreferences.getInstance();
    _enabled = preferences.getBool(preferenceKey) ?? true;
    player.addListener(_handlePlayerChanged);
    if (_enabled) await show();
  }

  Future<void> setEnabled(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(preferenceKey, value);
    await _applyEnabled(value);
  }

  Future<void> reloadSettings() async {
    if (!isSupported) return;
    final preferences = await SharedPreferences.getInstance();
    await _applyEnabled(preferences.getBool(preferenceKey) ?? true);
  }

  Future<void> toggle() => setEnabled(!_enabled);

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
      await _sendSnapshotWhenReady();
      return;
    }

    _creating = true;
    try {
      final windows = await WindowController.getAll();
      for (final window in windows) {
        if (window.arguments == windowArgument) {
          _window = window;
          await window.show();
          await _sendSnapshotWhenReady();
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
      await _sendSnapshotWhenReady();
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
    unawaited(_sendSnapshot());
  }

  Future<void> _sendSnapshot({bool force = false}) async {
    final player = _player;
    final window = _window;
    if (player == null || window == null) return;

    final now = DateTime.now();
    if (!force && now.difference(_lastSentAt).inMilliseconds < 32) return;
    _lastSentAt = now;

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

    try {
      await window.invokeMethod<void>('lyrics_update', snapshot);
    } catch (_) {
      // The secondary engine may still be registering its method handler.
    }
  }
}
