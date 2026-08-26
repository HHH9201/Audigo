import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'audio_player_manager.dart';
import 'desktop_lyrics_manager.dart';
import 'desktop_media_key_manager.dart';
import 'mpris_service.dart';

class DesktopLifecycleManager with WindowListener, TrayListener {
  DesktopLifecycleManager._();

  static final DesktopLifecycleManager instance = DesktopLifecycleManager._();

  static bool get isSupported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  final navigatorKey = GlobalKey<NavigatorState>();
  AudioPlayerManager? _player;
  bool _isExiting = false;
  bool _isCloseDialogOpen = false;
  String? _menuState;

  Future<void> initialize(AudioPlayerManager player) async {
    if (!isSupported) return;
    _player = player;
    _player!.addListener(_handlePlayerChanged);
    windowManager.addListener(this);
    trayManager.addListener(this);

    await windowManager.setPreventClose(true);
    final iconPath = Platform.isWindows
        ? 'windows/runner/resources/app_icon.ico'
        : 'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_32.png';
    await trayManager.setIcon(iconPath);
    await trayManager.setToolTip('拾音');
    await _updateTrayMenu(force: true);
  }

  Future<void> requestClose() async {
    if (!isSupported || _isExiting) return;
    final preferences = await SharedPreferences.getInstance();
    final action = preferences.getString('close_action') ?? 'ask';
    switch (action) {
      case 'minimize':
        await hideToTray();
        return;
      case 'exit':
        await exitApplication();
        return;
      default:
        await _askCloseAction();
    }
  }

  Future<void> hideToTray() async {
    if (!isSupported) return;
    await windowManager.hide();
  }

  Future<void> showWindow() async {
    if (!isSupported) return;
    await windowManager.show();
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.focus();
  }

  Future<void> refreshTrayMenu() async {
    if (!isSupported) return;
    await _updateTrayMenu(force: true);
  }

  Future<void> exitApplication() async {
    if (!isSupported || _isExiting) return;
    _isExiting = true;
    await _player?.stop();
    await DesktopMediaKeyManager.instance.dispose();
    await DesktopLyricsManager.instance.close();
    await MprisService.instance.dispose();
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  Future<void> _askCloseAction() async {
    if (_isCloseDialogOpen) return;
    final context = navigatorKey.currentContext;
    if (context == null) return;
    _isCloseDialogOpen = true;
    final result = await showDialog<_CloseChoice>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('关闭 拾音'),
        content: const Text('要最小化到系统托盘，还是退出播放器？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _CloseChoice.minimize),
            child: const Text('最小化到托盘'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, _CloseChoice.exit),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    _isCloseDialogOpen = false;
    if (result == _CloseChoice.minimize) {
      await hideToTray();
    } else if (result == _CloseChoice.exit) {
      await exitApplication();
    }
  }

  void _handlePlayerChanged() {
    _updateTrayMenu();
  }

  Future<void> _updateTrayMenu({bool force = false}) async {
    final player = _player;
    if (player == null) return;
    final song = player.currentSong;
    final state =
        '${song?.hash}|${player.isPlaying}|${DesktopLyricsManager.instance.enabled}';
    if (!force && state == _menuState) return;
    _menuState = state;

    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(
            label: song == null ? '拾音' : song.songName,
            disabled: true,
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'previous',
            label: '上一首',
            disabled: song == null,
          ),
          MenuItem(
            key: 'play_pause',
            label: player.isPlaying ? '暂停' : '播放',
            disabled: song == null,
          ),
          MenuItem(
            key: 'next',
            label: '下一首',
            disabled: song == null,
          ),
          MenuItem(
            key: 'favorite',
            label: song != null && player.isFavorite(song.hash)
                ? '♥ 取消喜欢'
                : '♥ 喜欢当前歌曲',
            disabled: song == null,
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'desktop_lyrics',
            label: DesktopLyricsManager.instance.enabled ? '隐藏桌面歌词' : '显示桌面歌词',
          ),
          MenuItem(key: 'show', label: '显示 拾音'),
          MenuItem(key: 'exit', label: '退出'),
        ],
      ),
    );
  }

  @override
  void onWindowClose() {
    requestClose();
  }

  @override
  void onWindowMinimize() {
    // 不隐藏到托盘：让最小化按钮正常最小化窗口，
    // 避免窗口隐藏后无法从任务栏/托盘找回（托盘图标异常时窗口会“消失”）。
  }

  @override
  void onTrayIconMouseDown() {
    showWindow();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'previous':
        _player?.playPrevious();
      case 'play_pause':
        _player?.togglePlay();
      case 'next':
        _player?.playNext();
      case 'favorite':
        final song = _player?.currentSong;
        if (song != null) {
          _player?.toggleFavorite(song.hash, song: song);
        }
        _updateTrayMenu(force: true);
      case 'desktop_lyrics':
        DesktopLyricsManager.instance
            .toggle()
            .then((_) => _updateTrayMenu(force: true));
      case 'show':
        showWindow();
      case 'exit':
        exitApplication();
    }
  }
}

enum _CloseChoice { minimize, exit }
