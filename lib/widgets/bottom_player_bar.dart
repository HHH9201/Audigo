import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/audio_player_manager.dart';
import '../theme/app_theme.dart';
import 'lyric_view.dart';

class BottomPlayerBar extends StatefulWidget {
  final VoidCallback? onTogglePlaylist;
  final VoidCallback? onToggleLyrics;

  const BottomPlayerBar({
    Key? key,
    this.onTogglePlaylist,
    this.onToggleLyrics,
  }) : super(key: key);

  @override
  State<BottomPlayerBar> createState() => _BottomPlayerBarState();
}

class _BottomPlayerBarState extends State<BottomPlayerBar> {
  final LayerLink _volumeLayerLink = LayerLink();
  OverlayEntry? _volumeOverlayEntry;

  @override
  void dispose() {
    _volumeOverlayEntry?.remove();
    _volumeOverlayEntry = null;
    super.dispose();
  }

  /// 音量弹层必须挂载到 Overlay 上：底栏高度固定为 80，
  /// 若用 Stack + Positioned 把弹层画到底栏边界之外，超出部分无法命中手势，
  /// 导致滑块既点不中也拖不动。
  void _toggleVolumePopover() {
    if (_volumeOverlayEntry != null) {
      _closeVolumePopover();
      return;
    }
    final player = context.read<AudioPlayerManager>();
    _volumeOverlayEntry = OverlayEntry(
      builder: (_) => _buildVolumePopover(player),
    );
    Overlay.of(context).insert(_volumeOverlayEntry!);
    setState(() {});
  }

  void _closeVolumePopover() {
    _volumeOverlayEntry?.remove();
    _volumeOverlayEntry = null;
    if (mounted) setState(() {});
  }

  /// 滚轮调节音量（悬停在音量图标或弹层上时）
  void _onVolumeScroll(PointerScrollEvent event) {
    final player = context.read<AudioPlayerManager>();
    final step = event.scrollDelta.dy > 0 ? -0.05 : 0.05;
    player.setVolume((player.volume + step).clamp(0.0, 1.0));
  }

  Widget _wrapVolumeScroll(Widget child) {
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) _onVolumeScroll(event);
      },
      child: child,
    );
  }

  Widget _buildVolumePopover(AudioPlayerManager player) {
    return Stack(
      children: [
        // 全屏透明屏障：点击弹层外部关闭
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _closeVolumePopover,
            child: const SizedBox.expand(),
          ),
        ),
        CompositedTransformFollower(
          link: _volumeLayerLink,
          targetAnchor: Alignment.topCenter,
          followerAnchor: Alignment.bottomCenter,
          offset: const Offset(0, 4),
          showWhenUnlinked: false,
          child: _wrapVolumeScroll(
            Material(
              type: MaterialType.transparency,
              child: ListenableBuilder(
                listenable: player,
                builder: (context, _) => Container(
                  width: 44,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceWhite,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.borderWarm),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.12),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 逆时针旋转 90°：滑块 min 朝下、max 朝上；
                      // 旋转会交换宽高，因此给滑块显式的双向尺寸。
                      RotatedBox(
                        quarterTurns: -1,
                        child: SizedBox(
                          width: 132,
                          height: 28,
                          child: SliderTheme(
                            data: SliderThemeData(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 5),
                              activeTrackColor: AppTheme.accentOrange,
                              inactiveTrackColor: AppTheme.borderWarm,
                              thumbColor: AppTheme.accentOrange,
                            ),
                            child: Slider(
                              value: player.volume,
                              min: 0.0,
                              max: 1.0,
                              onChanged: (v) => player.setVolume(v),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${(player.volume * 100).toInt()}%',
                        maxLines: 1,
                        style: TextStyle(
                            fontSize: 10,
                            height: 1.0,
                            color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(1, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  /// 进度行（当前时间 + 滑块 + 总时长）：独立监听 progressNotifier（500ms），
  /// 不随主 build 重建，保证进度条与时间文本流畅更新且不影响整体帧率。
  Widget _buildProgressRow(AudioPlayerManager player) {
    return SizedBox(
      height: 24,
      child: AnimatedBuilder(
        animation: player.progressNotifier,
        builder: (context, _) {
          final currentSeconds = player.currentPosition.inSeconds.toDouble();
          final totalSeconds = player.totalDuration.inSeconds > 0
              ? player.totalDuration.inSeconds.toDouble()
              : 1.0;
          final sliderVal = currentSeconds.clamp(0.0, totalSeconds);
          return Row(
            children: [
              SizedBox(
                width: 36,
                child: Text(
                  _formatDuration(player.currentPosition),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 16,
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 10,
                      ),
                      activeTrackColor: AppTheme.accentOrange,
                      inactiveTrackColor: AppTheme.borderWarm,
                      thumbColor: AppTheme.accentOrange,
                      overlayColor: AppTheme.accentOrange.withOpacity(0.2),
                    ),
                    child: Slider(
                      value: sliderVal,
                      min: 0.0,
                      max: totalSeconds,
                      onChanged: (value) => player.seek(
                        Duration(milliseconds: (value * 1000).round()),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 36,
                child: Text(
                  _formatDuration(player.totalDuration),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<AudioPlayerManager>();
    final song = player.currentSong;
    final isFav = song != null && player.isFavorite(song.hash);

    final isRandom = player.shuffleMode;
    final repeatMode = player.repeatMode;

    return Container(
      height: 80,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: AppTheme.surfaceWhite,
        border: Border(top: BorderSide(color: AppTheme.borderWarm, width: 1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 1. 左侧：歌曲信息 (56px 封面 + 标题/艺术家)
          SizedBox(
            width: 240,
            child: Row(
              children: [
                // 封面（点击进入沉浸式歌词页，始终可用）
                GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LyricView(
                          onExit: () => Navigator.pop(context),
                        ),
                      ),
                    );
                  },
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceWarm,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: song?.coverBytes != null
                          ? Image.memory(song!.coverBytes!, fit: BoxFit.cover)
                          : (song?.coverUrl != null &&
                                  song!.coverUrl!.isNotEmpty)
                              ? (song.localPath?.isNotEmpty == true
                                  ? Image.file(
                                      File(song.coverUrl!),
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => Icon(
                                        Icons.music_note,
                                        color: AppTheme.textSecondary,
                                        size: 24,
                                      ),
                                    )
                                  : CachedNetworkImage(
                                      imageUrl: song.coverUrl!,
                                      fit: BoxFit.cover,
                                      errorWidget: (_, __, ___) => Icon(
                                        Icons.music_note,
                                        color: AppTheme.textSecondary,
                                        size: 24,
                                      ),
                                    ))
                              : Icon(
                                  Icons.music_note,
                                  color: AppTheme.textSecondary,
                                  size: 24,
                                ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // 歌名和歌手
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song?.songName ?? "未播放",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        song?.authorName ?? "选择音乐开始播放",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 2. 中间：播放控制与响应式进度条
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: Icon(
                        isFav ? Icons.favorite : Icons.favorite_border,
                        color: isFav
                            ? AppTheme.accentOrange
                            : AppTheme.textSecondary,
                        size: 20,
                      ),
                      tooltip: "收藏",
                      onPressed: song != null
                          ? () => player.toggleFavorite(song.hash)
                          : null,
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: Icon(
                        Icons.shuffle_rounded,
                        size: 20,
                        color: isRandom
                            ? AppTheme.accentOrange
                            : AppTheme.textSecondary,
                      ),
                      tooltip: isRandom ? "关闭随机播放" : "随机播放",
                      onPressed: () => player.setShuffleMode(!isRandom),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: Icon(
                        Icons.skip_previous,
                        size: 22,
                        color: AppTheme.textPrimary,
                      ),
                      tooltip: "上一首",
                      onPressed: player.playPrevious,
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 48,
                      height: 48,
                      child: Material(
                        color: AppTheme.accentOrange,
                        shape: const CircleBorder(),
                        child: player.isPreparingSong
                            ? const Padding(
                                padding: EdgeInsets.all(14),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white),
                                ),
                              )
                            : IconButton(
                                padding: EdgeInsets.zero,
                                icon: Icon(
                                  player.isPlaying
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                  color: Colors.white,
                                  size: 28,
                                ),
                                tooltip: player.isPlaying ? "暂停" : "播放",
                                onPressed: player.togglePlay,
                              ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: Icon(
                        Icons.skip_next,
                        size: 22,
                        color: AppTheme.textPrimary,
                      ),
                      tooltip: "下一首",
                      onPressed: player.playNext,
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: Icon(
                        repeatMode == RepeatMode.one
                            ? Icons.repeat_one_rounded
                            : Icons.repeat_rounded,
                        size: 20,
                        color: repeatMode != RepeatMode.off
                            ? AppTheme.accentOrange
                            : AppTheme.textSecondary,
                      ),
                      tooltip: switch (repeatMode) {
                        RepeatMode.off => "开启单曲循环",
                        RepeatMode.one => "开启列表循环",
                        RepeatMode.all => "关闭循环播放",
                      },
                      onPressed: player.cycleRepeatMode,
                    ),
                  ],
                ),
                _buildProgressRow(player),
              ],
            ),
          ),

          // 3. 右侧：音量控制与功能面板按扭
          SizedBox(
            width: 240,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // 音量控制：弹层挂载到 Overlay，图标本身支持滚轮调音量
                CompositedTransformTarget(
                  link: _volumeLayerLink,
                  child: _wrapVolumeScroll(
                    IconButton(
                      icon: Icon(
                        player.volume == 0
                            ? Icons.volume_off
                            : (player.volume < 0.5
                                ? Icons.volume_down
                                : Icons.volume_up),
                        size: 20,
                        color: AppTheme.textSecondary,
                      ),
                      tooltip: "音量 (${(player.volume * 100).toInt()}%)",
                      onPressed: _toggleVolumePopover,
                    ),
                  ),
                ),

                // 歌词按钮（图标改为"词"字）
                IconButton(
                  icon: Text('词',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textSecondary)),
                  tooltip: "歌词",
                  onPressed: player.showLyrics ? widget.onToggleLyrics : null,
                ),

                // 播放列表按钮
                IconButton(
                  icon: Icon(Icons.format_list_bulleted,
                      size: 20, color: AppTheme.textSecondary),
                  tooltip: "播放列表",
                  onPressed: widget.onTogglePlaylist,
                ),

                // 沉浸式全屏播放（始终可用，不依赖"显示歌词"开关）
                IconButton(
                  icon: Icon(Icons.fullscreen,
                      size: 22, color: AppTheme.textSecondary),
                  tooltip: "沉浸式播放",
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LyricView(
                          onExit: () => Navigator.pop(context),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
