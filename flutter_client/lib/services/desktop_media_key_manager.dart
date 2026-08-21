import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import 'audio_player_manager.dart';

class DesktopMediaKeyManager {
  DesktopMediaKeyManager._();

  static final DesktopMediaKeyManager instance = DesktopMediaKeyManager._();

  static bool get isSupported => Platform.isLinux;

  final List<HotKey> _hotKeys = [];

  Future<void> initialize(AudioPlayerManager player) async {
    if (!isSupported || _hotKeys.isNotEmpty) return;

    await _register(
      LogicalKeyboardKey.mediaPlayPause,
      (_) => player.togglePlay(),
    );
    await _register(
      LogicalKeyboardKey.mediaTrackPrevious,
      (_) => player.playPrevious(),
    );
    await _register(
      LogicalKeyboardKey.mediaTrackNext,
      (_) => player.playNext(),
    );
  }

  Future<void> dispose() async {
    for (final hotKey in _hotKeys.toList()) {
      await hotKeyManager.unregister(hotKey);
    }
    _hotKeys.clear();
  }

  Future<void> _register(
    LogicalKeyboardKey key,
    HotKeyHandler handler,
  ) async {
    final hotKey = HotKey(key: key, scope: HotKeyScope.system);
    await hotKeyManager.register(hotKey, keyDownHandler: handler);
    _hotKeys.add(hotKey);
  }
}
