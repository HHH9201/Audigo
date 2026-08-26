import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/music_api_service.dart';
import '../services/audio_player_manager.dart';
import '../models/song.dart';
import '../theme/app_theme.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isLoading = true;

  // FM 状态
  List<Song> _fmList = [];
  int _fmIndex = 0;
  String _fmMode = 'normal'; // normal (红心), small (小众), peak (新歌)
  int _fmAiPool = 0; // 0: Alpha, 1: Beta, 2: Gamma

  // AI 推荐状态
  List<Song> _aiList = [];
  int _aiIndex = 0;

  // 每日推荐
  List<Song> _dailyRecommendList = [];

  // 私人专属好歌
  List<Song> _personalList = [];

  // VIP 专属推荐
  List<Song> _vipList = [];

  @override
  void initState() {
    super.initState();
    _loadAllHomeData();
  }

  Future<void> _loadAllHomeData() async {
    setState(() => _isLoading = true);

    final results = await Future.wait([
      MusicApiService.getPersonalFM(mode: _fmMode, songPoolId: _fmAiPool),
      MusicApiService.getAIRecommend(),
      MusicApiService.getDailyRecommend(),
      MusicApiService.getRecommendSongs("personal"),
      MusicApiService.getRecommendSongs("vip"),
    ]);

    if (mounted) {
      setState(() {
        _fmList = results[0];
        _fmIndex = 0;

        _aiList = results[1];
        _aiIndex = 0;

        _dailyRecommendList = results[2];
        _personalList = results[3];
        _vipList = results[4];

        _isLoading = false;
      });
    }
  }

  // 切换 FM 模式
  void _cycleFmMode() {
    final modes = ['normal', 'small', 'peak'];
    final nextIdx = (modes.indexOf(_fmMode) + 1) % modes.length;
    setState(() {
      _fmMode = modes[nextIdx];
    });
    _reloadFm();
  }

  // 切换 AI 模式
  void _cycleAiPool() {
    setState(() {
      _fmAiPool = (_fmAiPool + 1) % 3;
    });
    _reloadFm();
  }

  Future<void> _reloadFm() async {
    final fm = await MusicApiService.getPersonalFM(
        mode: _fmMode, songPoolId: _fmAiPool);
    if (mounted) {
      setState(() {
        _fmList = fm;
        _fmIndex = 0;
      });
    }
  }

  Future<void> _reportFmFeedback(Song song, String action) async {
    await MusicApiService.reportFMAction(hash: song.hash, action: action);
    if (!mounted) return;
    if (_fmIndex + 1 < _fmList.length) {
      setState(() => _fmIndex++);
    } else {
      await _reloadFm();
    }
  }

  Future<void> _reportAiFeedback(Song song, String action) async {
    await MusicApiService.reportFMAction(hash: song.hash, action: action);
    if (!mounted) return;
    if (_aiIndex + 1 < _aiList.length) {
      setState(() => _aiIndex++);
    } else {
      final songs = await MusicApiService.getAIRecommend();
      if (mounted) {
        setState(() {
          _aiList = songs;
          _aiIndex = 0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(color: AppTheme.accentOrange),
      );
    }

    final now = DateTime.now();
    final dayStr = now.day.toString().padLeft(2, '0');
    final monthStr = now.month.toString().padLeft(2, '0');

    return RefreshIndicator(
      onRefresh: _loadAllHomeData,
      color: AppTheme.accentOrange,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        children: [
          // 页面头部大标题与副标题
          Text(
            "首页",
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "发现你喜欢的音乐",
            style: TextStyle(
              fontSize: 14,
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 24),

          // 1. 私人 FM 与 AI 推荐水平并排布局
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth > 700) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _buildFmSection(context)),
                    const SizedBox(width: 20),
                    Expanded(child: _buildAiSection(context)),
                  ],
                );
              } else {
                return Column(
                  children: [
                    _buildFmSection(context),
                    const SizedBox(height: 20),
                    _buildAiSection(context),
                  ],
                );
              }
            },
          ),
          const SizedBox(height: 32),

          // 2. 每日推荐 Section (左侧日历大卡片 + 右侧双列歌曲预览)
          _buildDailySection(context, dayStr, monthStr),
          const SizedBox(height: 32),

          // 3. 私人专属好歌 Section (网格卡片)
          _buildHorizontalSongGridSection(
            context,
            icon: Icons.favorite_rounded,
            title: "私人专属好歌",
            subtitle: "根据你的喜好精选推荐",
            songs: _personalList,
            onRefresh: () async {
              final list = await MusicApiService.getRecommendSongs("personal");
              if (mounted) setState(() => _personalList = list);
            },
          ),
          const SizedBox(height: 32),

          // 4. VIP 专属推荐 Section
          _buildHorizontalSongGridSection(
            context,
            icon: Icons.workspace_premium_rounded,
            title: "VIP专属推荐",
            subtitle: "VIP会员专享精品歌曲",
            songs: _vipList,
            onRefresh: () async {
              final list = await MusicApiService.getRecommendSongs("vip");
              if (mounted) setState(() => _vipList = list);
            },
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  // 私人 FM 卡片 (1:1 原版)
  Widget _buildFmSection(BuildContext context) {
    final player = context.read<AudioPlayerManager>();
    final currentFm = _fmList.isNotEmpty && _fmIndex < _fmList.length
        ? _fmList[_fmIndex]
        : null;

    String modeName = "红心";
    IconData modeIcon = Icons.favorite;
    if (_fmMode == 'small') {
      modeName = "小众";
      modeIcon = Icons.diamond_outlined;
    } else if (_fmMode == 'peak') {
      modeName = "新歌";
      modeIcon = Icons.star_border;
    }

    String aiPoolName = "Alpha";
    if (_fmAiPool == 1) aiPoolName = "Beta";
    if (_fmAiPool == 2) aiPoolName = "Gamma";

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderWarm),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行与模式切换按钮
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.podcasts_rounded,
                      size: 20, color: AppTheme.accentOrange),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("私人FM",
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.textPrimary)),
                      Text("专属于你的音乐电台",
                          style: TextStyle(
                              fontSize: 11, color: AppTheme.textSecondary)),
                    ],
                  ),
                ],
              ),
              Row(
                children: [
                  // 模式按钮
                  InkWell(
                    onTap: _cycleFmMode,
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0x12E87A43),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          Icon(modeIcon,
                              size: 13, color: AppTheme.accentOrange),
                          const SizedBox(width: 4),
                          Text(modeName,
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.accentOrange)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // AI池按钮
                  InkWell(
                    onTap: _cycleAiPool,
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0x12E87A43),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.smart_toy_outlined,
                              size: 13, color: AppTheme.accentOrange),
                          const SizedBox(width: 4),
                          Text(aiPoolName,
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.accentOrange)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 歌曲大卡片内容
          Row(
            children: [
              // 封面图（带播放悬浮覆盖）
              Stack(
                alignment: Alignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: currentFm != null &&
                            currentFm.coverUrl != null &&
                            currentFm.coverUrl!.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: currentFm.coverUrl!,
                            width: 80,
                            height: 80,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) =>
                                _buildPlaceholderCover(size: 80),
                          )
                        : _buildPlaceholderCover(size: 80),
                  ),
                  InkWell(
                    onTap: () {
                      if (currentFm != null) player.playSong(currentFm);
                    },
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.4),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.play_arrow_rounded,
                          color: Colors.white, size: 22),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 14),

              // 歌曲名、歌手与切歌操作
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      currentFm?.songName ?? "正在为您推荐音乐...",
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      currentFm?.authorName ?? "点击开始播放私人FM",
                      style: TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _buildSmallActionBtn(
                            Icons.favorite_border_rounded, "喜欢", () {
                          if (currentFm != null) {
                            _reportFmFeedback(currentFm, 'play');
                          }
                        }),
                        const SizedBox(width: 8),
                        _buildSmallActionBtn(Icons.heart_broken_outlined, "不喜欢",
                            () {
                          if (currentFm != null) {
                            _reportFmFeedback(currentFm, 'garbage');
                          }
                        }),
                        const SizedBox(width: 8),
                        _buildSmallActionBtn(Icons.skip_next_rounded, "下一首",
                            () {
                          if (_fmIndex + 1 < _fmList.length) {
                            setState(() => _fmIndex++);
                            final nextSong = _fmList[_fmIndex];
                            player.playSong(nextSong);
                          } else {
                            _reloadFm();
                          }
                        }),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // AI 推荐卡片 (1:1 原版)
  Widget _buildAiSection(BuildContext context) {
    final player = context.read<AudioPlayerManager>();
    final currentAi = _aiList.isNotEmpty && _aiIndex < _aiList.length
        ? _aiList[_aiIndex]
        : null;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderWarm),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.psychology_outlined,
                      size: 20, color: AppTheme.accentOrange),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("AI推荐",
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.textPrimary)),
                      Text("智能算法为您精选",
                          style: TextStyle(
                              fontSize: 11, color: AppTheme.textSecondary)),
                    ],
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 歌曲大卡片内容
          Row(
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: currentAi != null &&
                            currentAi.coverUrl != null &&
                            currentAi.coverUrl!.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: currentAi.coverUrl!,
                            width: 80,
                            height: 80,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) =>
                                _buildPlaceholderCover(size: 80),
                          )
                        : _buildPlaceholderCover(size: 80),
                  ),
                  InkWell(
                    onTap: () {
                      if (currentAi != null) player.playSong(currentAi);
                    },
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.4),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.play_arrow_rounded,
                          color: Colors.white, size: 22),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      currentAi?.songName ?? "正在为您AI推荐音乐...",
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      currentAi?.authorName ?? "点击开始播放AI推荐",
                      style: TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _buildSmallActionBtn(
                            Icons.favorite_border_rounded, "喜欢", () {
                          if (currentAi != null) {
                            _reportAiFeedback(currentAi, 'play');
                          }
                        }),
                        const SizedBox(width: 8),
                        _buildSmallActionBtn(Icons.heart_broken_outlined, "不喜欢",
                            () {
                          if (currentAi != null) {
                            _reportAiFeedback(currentAi, 'garbage');
                          }
                        }),
                        const SizedBox(width: 8),
                        _buildSmallActionBtn(Icons.skip_next_rounded, "下一首",
                            () {
                          if (_aiIndex + 1 < _aiList.length) {
                            setState(() => _aiIndex++);
                            final nextSong = _aiList[_aiIndex];
                            player.playSong(nextSong);
                          }
                        }),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 每日推荐 Section (日历卡片 + 歌曲网格)
  Widget _buildDailySection(BuildContext context, String day, String month) {
    final player = context.read<AudioPlayerManager>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(Icons.calendar_today_rounded,
                    size: 20, color: AppTheme.accentOrange),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("每日推荐",
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary)),
                    Text("根据你的喜好每日更新",
                        style: TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary)),
                  ],
                ),
              ],
            ),
            TextButton(
              onPressed: () {
                if (_dailyRecommendList.isNotEmpty) {
                  player.playAll(_dailyRecommendList, initialIndex: 0);
                }
              },
              child: Text("播放全部",
                  style: TextStyle(color: AppTheme.accentOrange, fontSize: 13)),
            ),
          ],
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth > 650;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 左侧日历方块卡片
                InkWell(
                  onTap: () {
                    if (_dailyRecommendList.isNotEmpty) {
                      player.playAll(_dailyRecommendList, initialIndex: 0);
                    }
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    width: 140,
                    height: 160,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF22C55E), Color(0xFF16A34A)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF22C55E).withOpacity(0.3),
                          blurRadius: 12,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Stack(
                      children: [
                        Positioned(
                          top: 20,
                          left: 20,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(day,
                                  style: const TextStyle(
                                      fontSize: 36,
                                      fontWeight: FontWeight.w900,
                                      color: Colors.white,
                                      height: 1.0)),
                              Text(month,
                                  style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white.withOpacity(0.85))),
                            ],
                          ),
                        ),
                        Positioned(
                          bottom: 16,
                          left: 20,
                          right: 20,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.25),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.play_arrow_rounded,
                                    color: Colors.white, size: 28),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 16),

                // 右侧双列歌曲项预览
                Expanded(
                  child: SizedBox(
                    height: 160,
                    child: GridView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: isWide ? 2 : 1,
                        mainAxisExtent: 48,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 8,
                      ),
                      itemCount: _dailyRecommendList.length > 6
                          ? 6
                          : _dailyRecommendList.length,
                      itemBuilder: (context, idx) {
                        final song = _dailyRecommendList[idx];
                        return InkWell(
                          onTap: () => player.playSong(song),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: AppTheme.surfaceWhite,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppTheme.borderWarm),
                            ),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: song.coverUrl != null &&
                                          song.coverUrl!.isNotEmpty
                                      ? CachedNetworkImage(
                                          imageUrl: song.coverUrl!,
                                          width: 36,
                                          height: 36,
                                          fit: BoxFit.cover,
                                          errorWidget: (_, __, ___) =>
                                              _buildPlaceholderCover(),
                                        )
                                      : _buildPlaceholderCover(),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(song.songName,
                                          style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              color: AppTheme.textPrimary),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis),
                                      Text(song.authorName,
                                          style: TextStyle(
                                              fontSize: 11,
                                              color: AppTheme.textSecondary),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis),
                                    ],
                                  ),
                                ),
                                Icon(Icons.play_arrow_rounded,
                                    size: 18, color: AppTheme.accentOrange),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  // 专属好歌 / VIP 推荐 Section
  Widget _buildHorizontalSongGridSection(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Song> songs,
    required VoidCallback onRefresh,
  }) {
    final player = context.read<AudioPlayerManager>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: AppTheme.accentOrange),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary)),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary)),
                  ],
                ),
              ],
            ),
            Row(
              children: [
                TextButton(
                  onPressed: () {
                    if (songs.isNotEmpty) {
                      player.playAll(songs, initialIndex: 0);
                    }
                  },
                  child: Text("播放全部",
                      style: TextStyle(
                          color: AppTheme.accentOrange, fontSize: 13)),
                ),
                IconButton(
                  icon: Icon(Icons.refresh_rounded,
                      size: 18, color: AppTheme.textSecondary),
                  tooltip: "刷新",
                  onPressed: onRefresh,
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 16),

        // 卡片网格
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 220,
            mainAxisExtent: 64,
            crossAxisSpacing: 12,
            mainAxisSpacing: 10,
          ),
          itemCount: songs.length > 8 ? 8 : songs.length,
          itemBuilder: (context, index) {
            final song = songs[index];
            return InkWell(
              onTap: () => player.playSong(song),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceWhite,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.borderWarm),
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: song.coverUrl != null && song.coverUrl!.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: song.coverUrl!,
                              width: 48,
                              height: 48,
                              fit: BoxFit.cover,
                              errorWidget: (_, __, ___) =>
                                  _buildPlaceholderCover(),
                            )
                          : _buildPlaceholderCover(),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(song.songName,
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textPrimary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 2),
                          Text(song.authorName,
                              style: TextStyle(
                                  fontSize: 11, color: AppTheme.textSecondary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildSmallActionBtn(IconData icon, String tip, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: const Color(0x0A000000),
          borderRadius: BorderRadius.circular(14),
        ),
        child:
            Icon(icon, size: 14, color: AppTheme.textPrimary.withOpacity(0.7)),
      ),
    );
  }

  Widget _buildPlaceholderCover({double size = 48}) {
    return Container(
      width: size,
      height: size,
      color: const Color(0x10000000),
      child: Icon(Icons.music_note_rounded,
          color: AppTheme.textSecondary, size: size * 0.5),
    );
  }
}
