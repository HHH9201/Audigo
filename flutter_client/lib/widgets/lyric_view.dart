import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/audio_player_manager.dart';
import '../theme/app_theme.dart';

class LyricView extends StatefulWidget {
  const LyricView({Key? key}) : super(key: key);

  @override
  State<LyricView> createState() => _LyricViewState();
}

class _LyricViewState extends State<LyricView>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  late final AnimationController _recordController;
  Timer? _timeTimer;
  Timer? _controlsTimer;
  String _currentTimeStr = '';
  bool _showControls = true;
  int _lastActiveIndex = -1;

  @override
  void initState() {
    super.initState();
    _recordController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    );
    _updateTime();
    _timeTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _updateTime());
    _scheduleControlsHide();
  }

  void _updateTime() {
    if (!mounted) return;
    final now = DateTime.now();
    setState(() {
      _currentTimeStr = '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}:'
          '${now.second.toString().padLeft(2, '0')}';
    });
  }

  void _showControlLayer() {
    _controlsTimer?.cancel();
    if (!_showControls) setState(() => _showControls = true);
    _scheduleControlsHide();
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _scrollToActive(int activeIndex) {
    if (!_scrollController.hasClients || activeIndex < 0) return;
    final viewportCenter = _scrollController.position.viewportDimension / 2;
    final target = activeIndex * 64.0 - viewportCenter + 32;
    _scrollController.animateTo(
      target.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString();
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _timeTimer?.cancel();
    _controlsTimer?.cancel();
    _recordController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<AudioPlayerManager>();
    final song = player.currentSong;
    final lyrics = player.currentLyrics;
    final activeIndex = player.currentLyricIndex;
    final isFav = song != null && player.isFavorite(song.hash);
    final isRandom = player.shuffleMode;
    final repeatMode = player.repeatMode;

    if (player.isPlaying && !_recordController.isAnimating) {
      _recordController.repeat();
    } else if (!player.isPlaying && _recordController.isAnimating) {
      _recordController.stop();
    }

    if (activeIndex != _lastActiveIndex) {
      _lastActiveIndex = activeIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToActive(activeIndex);
      });
    }

    final currentSeconds = player.currentPosition.inMilliseconds / 1000.0;
    final totalSeconds = player.totalDuration.inMilliseconds > 0
        ? player.totalDuration.inMilliseconds / 1000.0
        : 1.0;
    final sliderValue = currentSeconds.clamp(0.0, totalSeconds);

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: MouseRegion(
        onEnter: (_) => _showControlLayer(),
        onHover: (_) => _showControlLayer(),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _showControlLayer,
          child: Stack(
            children: [
              Positioned.fill(
                child: song?.coverBytes != null
                    ? Image.memory(song!.coverBytes!, fit: BoxFit.cover)
                    : song?.coverUrl != null && song!.coverUrl!.isNotEmpty
                        ? (song.localPath?.isNotEmpty == true
                            ? Image.file(
                                File(song.coverUrl!),
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                  color: const Color(0xFF0F172A),
                                ),
                              )
                            : CachedNetworkImage(
                                imageUrl: song.coverUrl!,
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) => Container(
                                  color: const Color(0xFF0F172A),
                                ),
                              ))
                        : Container(color: const Color(0xFF0F172A)),
              ),
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
                  child: Container(color: Colors.black.withOpacity(0.68)),
                ),
              ),
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 850;
                    final content = compact
                        ? Column(
                            children: [
                              Expanded(
                                flex: 4,
                                child: _buildRecordSection(
                                  song?.coverUrl,
                                  song?.coverBytes,
                                  song?.songName,
                                  song?.authorName,
                                  song?.albumName,
                                  compact: true,
                                ),
                              ),
                              Expanded(
                                flex: 5,
                                child: _buildLyrics(
                                  player,
                                  lyrics.length,
                                  activeIndex,
                                  compact: true,
                                ),
                              ),
                            ],
                          )
                        : Row(
                            children: [
                              Expanded(
                                flex: 4,
                                child: _buildRecordSection(
                                  song?.coverUrl,
                                  song?.coverBytes,
                                  song?.songName,
                                  song?.authorName,
                                  song?.albumName,
                                ),
                              ),
                              const SizedBox(width: 36),
                              Expanded(
                                flex: 6,
                                child: _buildLyrics(
                                  player,
                                  lyrics.length,
                                  activeIndex,
                                ),
                              ),
                            ],
                          );
                    return Padding(
                      padding: EdgeInsets.fromLTRB(
                        compact ? 28 : 88,
                        compact ? 54 : 64,
                        compact ? 28 : 72,
                        118,
                      ),
                      child: content,
                    );
                  },
                ),
              ),
              Positioned(
                left: 32,
                bottom: 24,
                child: Text(
                  _currentTimeStr,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w300,
                    color: Colors.white.withOpacity(0.55),
                  ),
                ),
              ),
              _buildControlLayer(
                player,
                isFav,
                isRandom,
                repeatMode,
                sliderValue,
                totalSeconds,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecordSection(
    String? coverUrl,
    Uint8List? coverBytes,
    String? songName,
    String? authorName,
    String? albumName, {
    bool compact = false,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = math.min(constraints.maxWidth, constraints.maxHeight);
        final recordSize = (available * (compact ? 0.58 : 0.66))
            .clamp(compact ? 130.0 : 210.0, compact ? 210.0 : 400.0);
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedBuilder(
              animation: _recordController,
              builder: (context, child) => Transform.rotate(
                angle: _recordController.value * math.pi * 2,
                child: child,
              ),
              child: Container(
                width: recordSize,
                height: recordSize,
                padding: EdgeInsets.all(recordSize * 0.055),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF111111),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.55),
                      blurRadius: 36,
                      offset: const Offset(0, 16),
                    ),
                    BoxShadow(
                      color: Colors.white.withOpacity(0.1),
                      spreadRadius: 8,
                    ),
                  ],
                ),
                child: ClipOval(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (coverBytes != null)
                        Image.memory(coverBytes, fit: BoxFit.cover)
                      else if (coverUrl != null &&
                          coverUrl.isNotEmpty &&
                          File(coverUrl).existsSync())
                        Image.file(
                          File(coverUrl),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _recordPlaceholder(),
                        )
                      else if (coverUrl != null && coverUrl.isNotEmpty)
                        CachedNetworkImage(
                          imageUrl: coverUrl,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => _recordPlaceholder(),
                        )
                      else
                        _recordPlaceholder(),
                      Center(
                        child: Container(
                          width: recordSize * 0.14,
                          height: recordSize * 0.14,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.black.withOpacity(0.78),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.75),
                              width: recordSize * 0.025,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(height: compact ? 14 : 28),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                songName ?? '未播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: compact ? 18 : 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 7),
            Text(
              authorName ?? '选择音乐开始播放',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: compact ? 13 : 16,
                color: Colors.white.withOpacity(0.72),
              ),
            ),
            if (albumName != null && albumName.isNotEmpty && !compact) ...[
              const SizedBox(height: 5),
              Text(
                albumName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withOpacity(0.45),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _recordPlaceholder() {
    return Container(
      color: const Color(0xFF292929),
      child:
          const Icon(Icons.music_note_rounded, size: 84, color: Colors.white30),
    );
  }

  Widget _buildLyrics(
    AudioPlayerManager player,
    int lyricCount,
    int activeIndex, {
    bool compact = false,
  }) {
    if (lyricCount == 0) {
      return Center(
        child: Text(
          '暂无歌词或纯音乐',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: compact ? 20 : 28,
            color: Colors.white.withOpacity(0.55),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) => ListView.builder(
        controller: _scrollController,
        padding: EdgeInsets.symmetric(
          vertical: math.max(0, constraints.maxHeight / 2 - 36),
          horizontal: 12,
        ),
        itemCount: lyricCount,
        itemBuilder: (context, index) {
          final line = player.currentLyrics[index];
          final active = index == activeIndex;
          return InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => player.seek(line.time),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 180),
                style: TextStyle(
                  fontSize: compact ? 23 : 31,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                  color: active ? Colors.white : Colors.white.withOpacity(0.48),
                  height: 1.35,
                  shadows: active
                      ? [
                          Shadow(
                            color: Colors.white.withOpacity(0.45),
                            blurRadius: 20,
                          ),
                        ]
                      : null,
                ),
                child: active && line.words.isNotEmpty
                    ? Text.rich(
                        TextSpan(
                          children:
                              List.generate(line.words.length, (wordIndex) {
                            final sung =
                                wordIndex < player.currentLyricWordIndex;
                            final current =
                                wordIndex == player.currentLyricWordIndex;
                            return TextSpan(
                              text: line.words[wordIndex].text,
                              style: TextStyle(
                                color: sung
                                    ? AppTheme.accentOrange
                                    : current
                                        ? Color.lerp(
                                            Colors.white,
                                            AppTheme.accentOrange,
                                            player.currentLyricWordProgress,
                                          )
                                        : Colors.white.withOpacity(0.62),
                              ),
                            );
                          }),
                        ),
                        textAlign: TextAlign.center,
                      )
                    : Text(line.text, textAlign: TextAlign.center),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildControlLayer(
    AudioPlayerManager player,
    bool isFav,
    bool isRandom,
    RepeatMode repeatMode,
    double sliderValue,
    double totalSeconds,
  ) {
    final song = player.currentSong;
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !_showControls,
        child: AnimatedOpacity(
          opacity: _showControls ? 1 : 0,
          duration: const Duration(milliseconds: 350),
          child: Stack(
            children: [
              Positioned(
                top: 22,
                right: 24,
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.close_fullscreen_rounded,
                        color: Colors.white70,
                      ),
                      tooltip: '退出沉浸式播放',
                      onPressed: () => Navigator.pop(context),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded,
                          color: Colors.white70),
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 20,
                top: 100,
                bottom: 130,
                child: SizedBox(
                  width: 32,
                  child: Column(
                    children: [
                      Icon(
                        player.volume == 0
                            ? Icons.volume_off_rounded
                            : Icons.volume_up_rounded,
                        color: Colors.white70,
                        size: 20,
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: SliderTheme(
                            data: SliderThemeData(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 5,
                              ),
                              activeTrackColor: AppTheme.accentOrange,
                              inactiveTrackColor: Colors.white24,
                              thumbColor: Colors.white,
                            ),
                            child: Slider(
                              value: player.volume,
                              onChanged: player.setVolume,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(72, 28, 72, 18),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withOpacity(0.78)
                      ],
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          SizedBox(
                            width: 42,
                            child: Text(
                              _formatDuration(player.currentPosition),
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white70,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: SliderTheme(
                              data: SliderThemeData(
                                trackHeight: 4,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 12,
                                ),
                                activeTrackColor: AppTheme.accentOrange,
                                inactiveTrackColor: Colors.white24,
                                thumbColor: Colors.white,
                              ),
                              child: Slider(
                                value: sliderValue,
                                min: 0,
                                max: totalSeconds,
                                onChanged: (value) => player.seek(
                                  Duration(
                                    milliseconds: (value * 1000).round(),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 42,
                            child: Text(
                              _formatDuration(player.totalDuration),
                              textAlign: TextAlign.end,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white70,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _controlButton(
                            icon: isFav
                                ? Icons.favorite
                                : Icons.favorite_border_rounded,
                            color:
                                isFav ? AppTheme.accentOrange : Colors.white70,
                            tooltip: '收藏',
                            onPressed: song == null
                                ? null
                                : () => player.toggleFavorite(song.hash),
                          ),
                          _controlButton(
                            icon: Icons.shuffle_rounded,
                            color: isRandom
                                ? AppTheme.accentOrange
                                : Colors.white70,
                            tooltip: isRandom ? '关闭随机播放' : '随机播放',
                            onPressed: () => player.setShuffleMode(!isRandom),
                          ),
                          _controlButton(
                            icon: Icons.skip_previous_rounded,
                            tooltip: '上一首',
                            onPressed: player.playPrevious,
                            iconSize: 28,
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 50,
                            height: 50,
                            child: Material(
                              color: AppTheme.accentOrange,
                              shape: const CircleBorder(),
                              child: IconButton(
                                icon: Icon(
                                  player.isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  color: Colors.white,
                                  size: 30,
                                ),
                                tooltip: player.isPlaying ? '暂停' : '播放',
                                onPressed: player.togglePlay,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _controlButton(
                            icon: Icons.skip_next_rounded,
                            tooltip: '下一首',
                            onPressed: player.playNext,
                            iconSize: 28,
                          ),
                          _controlButton(
                            icon: repeatMode == RepeatMode.one
                                ? Icons.repeat_one_rounded
                                : Icons.repeat_rounded,
                            color: repeatMode != RepeatMode.off
                                ? AppTheme.accentOrange
                                : Colors.white70,
                            tooltip: switch (repeatMode) {
                              RepeatMode.off => '开启单曲循环',
                              RepeatMode.one => '开启列表循环',
                              RepeatMode.all => '关闭循环播放',
                            },
                            onPressed: player.cycleRepeatMode,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _controlButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Color color = Colors.white,
    double iconSize = 22,
  }) {
    return IconButton(
      icon: Icon(icon, color: color, size: iconSize),
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}
