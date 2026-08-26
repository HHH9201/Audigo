import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

class DesktopLyricsWindow extends StatefulWidget {
  const DesktopLyricsWindow({super.key, required this.controller});

  final WindowController controller;

  @override
  State<DesktopLyricsWindow> createState() => _DesktopLyricsWindowState();
}

class _DesktopLyricsWindowState extends State<DesktopLyricsWindow> {
  _LyricsSnapshot _snapshot = const _LyricsSnapshot();
  double _fontSize = 23;

  @override
  void initState() {
    super.initState();
    widget.controller.setWindowMethodHandler((call) async {
      switch (call.method) {
        case 'lyrics_update':
          final value = call.arguments;
          if (value is String && mounted) {
            setState(() => _snapshot = _LyricsSnapshot.fromJson(value));
          }
        case 'lyrics_attach':
          return await _runTaskbarOperation(attach: true);
        case 'lyrics_detach':
          return await _runTaskbarOperation(attach: false);
        case 'close':
          await windowManager.destroy();
      }
      return null;
    });
    _loadFontSize();
  }

  Future<Map<String, dynamic>> _runTaskbarOperation(
      {required bool attach}) async {
    if (!Platform.isWindows) {
      return {'attached': false, 'error': 'unsupported'};
    }
    const channel = MethodChannel('musichub/taskbar_lyrics');
    try {
      final result = await channel.invokeMethod<dynamic>(
          attach ? 'attach' : 'detach');
      final map = result is Map ? Map<String, dynamic>.from(result) : {};
      return {
        'attached': attach && map['attached'] == true,
        'error': map['error'],
      };
    } catch (error) {
      return {'attached': false, 'error': '$error'};
    }
  }

  Future<void> _loadFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    final fontSize = (prefs.getInt('lyrics_font_size') ?? 22).toDouble();
    if (mounted && fontSize != _fontSize) {
      setState(() => _fontSize = fontSize.clamp(12, 48));
    }
  }

  @override
  void dispose() {
    widget.controller.setWindowMethodHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final line = _snapshot.line.isNotEmpty
        ? _snapshot.line
        : _snapshot.song.isNotEmpty
            ? '${_snapshot.song}  ${_snapshot.artist}'
            : '拾音';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => windowManager.startDragging(),
          child: Container(
            alignment: Alignment.center,
            padding: EdgeInsets.symmetric(
              horizontal: 22,
              vertical: Platform.isWindows ? 2 : 10,
            ),
            decoration: BoxDecoration(
              color: const Color(0xD91B1B1B),
              border: Border.all(color: Colors.white24),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // FittedBox 缩放歌词行，避免嵌入任务栏后高度不足导致溢出
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.center,
                    child: _KaraokeLine(
                      snapshot: _snapshot,
                      fallback: line,
                      fontSize: _fontSize,
                    ),
                  ),
                ),
                if (!Platform.isWindows && _snapshot.nextLine.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    _snapshot.nextLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: (_fontSize * 0.55).clamp(10, 14),
                      height: 1.15,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _KaraokeLine extends StatelessWidget {
  const _KaraokeLine({
    required this.snapshot,
    required this.fallback,
    required this.fontSize,
  });

  final _LyricsSnapshot snapshot;
  final String fallback;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    if (snapshot.words.isEmpty) {
      return Text(
        fallback,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: _style(Colors.white),
      );
    }

    return Text.rich(
      TextSpan(
        children: List.generate(snapshot.words.length, (index) {
          final isPast = index < snapshot.wordIndex;
          final isCurrent = index == snapshot.wordIndex;
          final color = isPast
              ? const Color(0xFFFFA94D)
              : isCurrent
                  ? Color.lerp(
                      Colors.white,
                      const Color(0xFFFFA94D),
                      snapshot.wordProgress,
                    )!
                  : Colors.white;
          return TextSpan(text: snapshot.words[index], style: _style(color));
        }),
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
    );
  }

  TextStyle _style(Color color) => TextStyle(
        color: color,
        fontSize: fontSize,
        fontWeight: FontWeight.w700,
        height: 1.15,
        shadows: const [
          Shadow(color: Colors.black, blurRadius: 4, offset: Offset(0, 1)),
        ],
      );
}

class _LyricsSnapshot {
  const _LyricsSnapshot({
    this.song = '',
    this.artist = '',
    this.line = '',
    this.nextLine = '',
    this.words = const [],
    this.wordIndex = -1,
    this.wordProgress = 0,
  });

  final String song;
  final String artist;
  final String line;
  final String nextLine;
  final List<String> words;
  final int wordIndex;
  final double wordProgress;

  factory _LyricsSnapshot.fromJson(String source) {
    final value = jsonDecode(source) as Map<String, dynamic>;
    return _LyricsSnapshot(
      song: value['song'] as String? ?? '',
      artist: value['artist'] as String? ?? '',
      line: value['line'] as String? ?? '',
      nextLine: value['nextLine'] as String? ?? '',
      words: (value['words'] as List? ?? const []).cast<String>(),
      wordIndex: value['wordIndex'] as int? ?? -1,
      wordProgress: (value['wordProgress'] as num?)?.toDouble() ?? 0,
    );
  }
}

Future<void> configureDesktopLyricsWindow() async {
  await windowManager.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final fontSize = (prefs.getInt('lyrics_font_size') ?? 22).clamp(12, 48);
  final offsetX = prefs.getInt('lyrics_offset_x') ?? 0;
  final offsetY = prefs.getInt('lyrics_offset_y') ?? 0;
  final size = Size(720, (fontSize + (Platform.isWindows ? 14 : 34)).toDouble());
  final display = await screenRetriever.getPrimaryDisplay();
  final visibleOrigin = display.visiblePosition ?? Offset.zero;
  final visibleSize = display.visibleSize ?? display.size;
  // 默认水平居中；lyricsOffsetX 仅在任务栏内部横向移动（与原版一致）。
  final x = visibleOrigin.dx +
      (visibleSize.width - size.width) / 2 +
      offsetX.toDouble();
  final margin = Platform.isWindows ? 6.0 : 12.0;
  final y = visibleOrigin.dy +
      visibleSize.height -
      size.height -
      margin +
      offsetY.toDouble();

  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: size,
      backgroundColor: Colors.transparent,
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
      alwaysOnTop: true,
    ),
    () async {
      await windowManager.setResizable(false);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSkipTaskbar(true);
      await windowManager.setPosition(Offset(x, y));
      await windowManager.show();
      // 任务栏歌词开关开启时，在窗口自身引擎内嵌入任务栏（该引擎内原生通道
      // 已注册，比主窗口跨窗口调用更可靠）；关闭时保持桌面浮窗。
      final embedTaskbar =
          Platform.isWindows && (await prefs.getBool('taskbar_lyrics')) == true;
      if (embedTaskbar) {
        // 与 Go 版一致：先等本窗口完成首帧渲染（约 500ms），再挂载进任务栏。
        // 若立即 SetParent，Flutter 从未在窗口中绘制，挂进去后也不会重绘导致空白。
        Future<void>.delayed(const Duration(milliseconds: 600), () {
          unawaited(attachToWindowsTaskbar());
        });
      }
    },
  );
}

Future<void> attachToWindowsTaskbar() async {
  const channel = MethodChannel('musichub/taskbar_lyrics');
  for (final delay in const [
    Duration(milliseconds: 80),
    Duration(milliseconds: 180),
    Duration(milliseconds: 350),
    Duration(milliseconds: 700),
  ]) {
    await Future<void>.delayed(delay);
    try {
      final result = await channel.invokeMethod<dynamic>('attach');
      if (result is Map && result['attached'] == true) {
        debugPrint('任务栏歌词已嵌入 Windows 任务栏');
        return;
      }
    } on MissingPluginException {
      debugPrint('任务栏歌词原生插件不可用');
      return;
    } catch (error) {
      debugPrint('任务栏歌词嵌入重试失败: $error');
    }
  }
  debugPrint('任务栏歌词嵌入失败，保留浮窗');
}
