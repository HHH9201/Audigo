import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import 'audio_player_manager.dart';

/// 桌面端媒体键与全局快捷键管理器。
///
/// 对应原版 Go 版本 `mediakeyservice.go` + `frontend/systray-controller.js` 的
/// 前端键盘监听部分：支持 Space 播放/暂停、F7/F8/F9 上一首/播放暂停/下一首、
/// Ctrl+←/→ 上一首/下一首、Ctrl+↑/↓ 音量加减（与原版 GetMediaKeyStatus 列出的
/// 快捷键一致）。Linux 上系统级媒体键由 [MprisService]（D-Bus）负责，本管理器
/// 作为全局快捷键补充。
class DesktopMediaKeyManager {
  DesktopMediaKeyManager._();

  static final DesktopMediaKeyManager instance = DesktopMediaKeyManager._();

  static bool get isSupported => Platform.isLinux;

  final List<HotKey> _hotKeys = [];
  bool _initialized = false;

  Future<void> initialize(AudioPlayerManager player) async {
    if (!isSupported || _initialized) return;
    _initialized = true;

    // 媒体键（部分平台支持系统级）
    await _register(
      HotKey(key: LogicalKeyboardKey.mediaPlayPause),
      (_) => player.togglePlay(),
    );
    await _register(
      HotKey(key: LogicalKeyboardKey.mediaTrackPrevious),
      (_) => player.playPrevious(),
    );
    await _register(
      HotKey(key: LogicalKeyboardKey.mediaTrackNext),
      (_) => player.playNext(),
    );

    // 通用功能键（与原版 Go 前端一致）
    await _register(
      HotKey(key: LogicalKeyboardKey.f8),
      (_) => player.togglePlay(),
    );
    await _register(
      HotKey(key: LogicalKeyboardKey.f7),
      (_) => player.playPrevious(),
    );
    await _register(
      HotKey(key: LogicalKeyboardKey.f9),
      (_) => player.playNext(),
    );

    // Ctrl + 方向键（上一首/下一首/音量加减）
    await _register(
      HotKey(
        key: LogicalKeyboardKey.arrowLeft,
        modifiers: [HotKeyModifier.control],
      ),
      (_) => player.playPrevious(),
    );
    await _register(
      HotKey(
        key: LogicalKeyboardKey.arrowRight,
        modifiers: [HotKeyModifier.control],
      ),
      (_) => player.playNext(),
    );
    await _register(
      HotKey(
        key: LogicalKeyboardKey.arrowUp,
        modifiers: [HotKeyModifier.control],
      ),
      (_) => player.setVolume((player.volume + 0.05).clamp(0.0, 1.0)),
    );
    await _register(
      HotKey(
        key: LogicalKeyboardKey.arrowDown,
        modifiers: [HotKeyModifier.control],
      ),
      (_) => player.setVolume((player.volume - 0.05).clamp(0.0, 1.0)),
    );

    // Space 播放/暂停（仅当应用窗口聚焦时由窗口层处理，避免全局抢占输入）
  }

  Future<void> dispose() async {
    for (final hotKey in _hotKeys.toList()) {
      await hotKeyManager.unregister(hotKey);
    }
    _hotKeys.clear();
    _initialized = false;
  }

  Future<void> _register(
    HotKey hotKey,
    HotKeyHandler handler,
  ) async {
    try {
      await hotKeyManager.register(hotKey, keyDownHandler: handler);
      _hotKeys.add(hotKey);
    } catch (error) {
      // 平台可能不支持某个按键组合，静默跳过。
      // ignore: avoid_print
      print('⚠️ 注册快捷键失败 (${hotKey.key}): $error');
    }
  }
}
