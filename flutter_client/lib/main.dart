import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'services/audio_player_manager.dart';
import 'services/desktop_lifecycle_manager.dart';
import 'services/desktop_lyrics_manager.dart';
import 'services/desktop_media_key_manager.dart';
import 'services/mpris_service.dart';
import 'services/music_audio_handler.dart';
import 'pages/main_scaffold.dart';
import 'theme/theme_controller.dart';
import 'widgets/desktop_lyrics_window.dart';

/// 是否桌面端。窗口管理、托盘、多窗口歌词等仅桌面功能在此为 true。
final bool kIsDesktop =
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // 初始化 libmpv 播放引擎（just_audio 的 Windows/Linux 平台实现）。
  JustAudioMediaKit.ensureInitialized();
  if (DesktopLifecycleManager.isSupported) {
    final controller = await WindowController.fromCurrentEngine();
    if (controller.arguments == DesktopLyricsManager.windowArgument) {
      await configureDesktopLyricsWindow();
      runApp(DesktopLyricsWindow(controller: controller));
      return;
    }
  }
  WindowOptions windowOptions = const WindowOptions(
    size: Size(1280, 800),
    minimumSize: Size(960, 640),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden, // 隐藏 Windows 原生标题栏
  );

  final preferences = await SharedPreferences.getInstance();
  final startMinimized = preferences.getBool('start_minimized') ?? false;
  if (kIsDesktop) {
    await windowManager.ensureInitialized();
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      if (startMinimized) {
        await DesktopLifecycleManager.instance.hideToTray();
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
    });
  }

  final themeController = await ThemeController.load();
  final audioPlayerManager = AudioPlayerManager();

  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_initializeDeferredServices(audioPlayerManager));
  });
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: audioPlayerManager),
        ChangeNotifierProvider.value(value: themeController),
      ],
      child: const MusicHubApp(),
    ),
  );
}

Future<void> _initializeDeferredServices(
  AudioPlayerManager audioPlayerManager,
) async {
  final initializations = <Future<void>>[];
  if (kIsDesktop) {
    final desktopInit = <Future<void>>[
      DesktopLifecycleManager.instance.initialize(audioPlayerManager),
      DesktopLyricsManager.instance.initialize(audioPlayerManager),
      DesktopMediaKeyManager.instance.initialize(audioPlayerManager),
      MprisService.instance.initialize(audioPlayerManager),
    ];
    initializations.addAll(desktopInit);
  } else if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
    initializations.add(
      AudioService.init(
        builder: () => MusicAudioHandler(audioPlayerManager),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.hjh.musichub.playback',
          androidNotificationChannelName: '音乐播放',
          androidNotificationOngoing: true,
        ),
      ).then<void>((_) {}),
    );
  }

  try {
    await Future.wait(initializations);
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        context: ErrorDescription('初始化非首帧服务时'),
      ),
    );
  }
}

class MusicHubApp extends StatelessWidget {
  const MusicHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();
    return MaterialApp(
      navigatorKey: DesktopLifecycleManager.instance.navigatorKey,
      title: 'MusicHub',
      debugShowCheckedModeBanner: false,
      theme: theme.theme,
      home: const MainScaffold(),
    );
  }
}
