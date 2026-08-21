import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

class DesktopLyricsWindow extends StatefulWidget {
  const DesktopLyricsWindow({super.key, required this.controller});

  final WindowController controller;

  @override
  State<DesktopLyricsWindow> createState() => _DesktopLyricsWindowState();
}

class _DesktopLyricsWindowState extends State<DesktopLyricsWindow> {
  _LyricsSnapshot _snapshot = const _LyricsSnapshot();

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
        case 'close':
          await windowManager.destroy();
      }
    });
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
            : 'MusicHub';
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
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _KaraokeLine(snapshot: _snapshot, fallback: line),
                if (!Platform.isWindows && _snapshot.nextLine.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    _snapshot.nextLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 13,
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
  const _KaraokeLine({required this.snapshot, required this.fallback});

  final _LyricsSnapshot snapshot;
  final String fallback;

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
        fontSize: 23,
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
  const size = Size(720, 92);
  await windowManager.ensureInitialized();
  final display = await screenRetriever.getPrimaryDisplay();
  final visibleOrigin = display.visiblePosition ?? Offset.zero;
  final visibleSize = display.visibleSize ?? display.size;
  final x = visibleOrigin.dx + (visibleSize.width - size.width) / 2;
  final margin = Platform.isWindows ? 6.0 : 12.0;
  final y = visibleOrigin.dy + visibleSize.height - size.height - margin;

  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
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
      if (Platform.isWindows) await attachToWindowsTaskbar();
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
