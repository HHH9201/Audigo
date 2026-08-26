import 'dart:async';

import 'package:flutter/material.dart';

/// 轻量气泡提示（Toast），基于 Overlay 实现，无第三方依赖。
///
/// 用法：`AppToast.show(context, '提示内容', isError: true);`
/// 默认显示在屏幕右上角，2.5 秒后自动消失。
class AppToast {
  static OverlayEntry? _entry;
  static Timer? _timer;

  /// 显示气泡提示（自动隐藏上一条）。
  static void show(
    BuildContext context,
    String message, {
    bool isError = false,
  }) {
    hide();
    final overlay = Overlay.of(context, rootOverlay: true);
    _entry = OverlayEntry(
      builder: (_) => _ToastBubble(message: message, isError: isError),
    );
    overlay.insert(_entry!);
    _timer = Timer(const Duration(milliseconds: 2500), hide);
  }

  /// 隐藏当前气泡提示。
  static void hide() {
    _timer?.cancel();
    _timer = null;
    final entry = _entry;
    _entry = null;
    if (entry != null && entry.mounted) entry.remove();
  }
}

class _ToastBubble extends StatefulWidget {
  const _ToastBubble({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  State<_ToastBubble> createState() => _ToastBubbleState();
}

class _ToastBubbleState extends State<_ToastBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _offset;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    // 从右侧滑入
    _offset = Tween(begin: const Offset(0.5, 0), end: Offset.zero).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = widget.isError
        ? Icons.error_outline_rounded
        : Icons.check_circle_outline_rounded;
    final iconColor = widget.isError
        ? const Color(0xFFFF8A80)
        : const Color(0xFF69F0AE);
    return Positioned(
      // 右上角提示
      top: MediaQuery.of(context).padding.top + 16,
      right: 16,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _opacity,
          child: SlideTransition(
            position: _offset,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xE61B1B1B),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.25),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, color: iconColor, size: 18),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        widget.message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
