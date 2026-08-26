import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/song.dart';
import '../services/music_api_service.dart';
import '../services/audio_player_manager.dart';
import '../theme/app_theme.dart';
import 'album_detail_screen.dart';

class DiscoverScreen extends StatefulWidget {
  final ValueChanged<AlbumDetailDestination> onOpenDetail;

  const DiscoverScreen({super.key, required this.onOpenDetail});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  String _selectedTab = 'personal';
  bool _isLoadingRecommendations = false;
  bool _isLoadingNewSongs = false;
  bool _isLoadingNewAlbums = false;

  List<Song> _recommendSongs = [];
  List<Song> _newSongs = [];
  List<Map<String, dynamic>> _newAlbums = [];

  final List<Map<String, String>> _tabs = [
    {'id': 'personal', 'label': '私人专属好歌'},
    {'id': 'classic', 'label': '经典怀旧金曲'},
    {'id': 'popular', 'label': '热门好歌精选'},
    {'id': 'vip', 'label': 'VIP专属推荐'},
    {'id': 'treasure', 'label': '小众宝藏佳作'},
    {'id': 'trendy', 'label': '潮流尝鲜'},
  ];

  @override
  void initState() {
    super.initState();
    _loadAllData();
  }

  Future<void> _loadAllData() async {
    _loadRecommendations();
    _loadNewSongs();
    _loadNewAlbums();
  }

  Future<void> _loadRecommendations() async {
    setState(() => _isLoadingRecommendations = true);
    final songs = await MusicApiService.getRecommendSongs(_selectedTab);
    setState(() {
      _recommendSongs = songs;
      _isLoadingRecommendations = false;
    });
  }

  Future<void> _loadNewSongs() async {
    setState(() => _isLoadingNewSongs = true);
    final songs = await MusicApiService.getNewSongs();
    if (!mounted) return;
    setState(() {
      _newSongs = songs;
      _isLoadingNewSongs = false;
    });
  }

  Future<void> _loadNewAlbums() async {
    setState(() => _isLoadingNewAlbums = true);
    final albums = await MusicApiService.getNewAlbums();
    if (!mounted) return;
    setState(() {
      _newAlbums = albums;
      _isLoadingNewAlbums = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<AudioPlayerManager>();

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头部
          Text(
            '发现音乐',
            style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
                color: AppTheme.textPrimary),
          ),
          const SizedBox(height: 4),
          Text(
            '探索新的音乐世界',
            style: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 28),

          // 1. 歌曲推荐 Section
          _buildSectionHeader(
            icon: Icons.favorite_rounded,
            title: '歌曲推荐',
            onPlayAll: _recommendSongs.isNotEmpty
                ? () => player.playAll(_recommendSongs)
                : null,
            onRefresh: _loadRecommendations,
          ),
          const SizedBox(height: 12),

          // 分类 Tabs
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _tabs.map((tab) {
              final isSelected = _selectedTab == tab['id'];
              return ChoiceChip(
                label: Text(tab['label']!),
                selected: isSelected,
                selectedColor: AppTheme.accentOrange,
                backgroundColor: AppTheme.surfaceWhite,
                labelStyle: TextStyle(
                  color: isSelected ? Colors.white : AppTheme.textPrimary,
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: isSelected
                        ? AppTheme.accentOrange
                        : AppTheme.borderWarm,
                  ),
                ),
                onSelected: (selected) {
                  if (selected) {
                    setState(() => _selectedTab = tab['id']!);
                    _loadRecommendations();
                  }
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 16),

          // 推荐歌曲列表
          _isLoadingRecommendations
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Center(
                      child: CircularProgressIndicator(
                          color: AppTheme.accentOrange)),
                )
              : _buildSongGrid(_recommendSongs),

          const SizedBox(height: 36),

          // 2. 新歌速递 Section
          _buildSectionHeader(
            icon: Icons.local_fire_department_rounded,
            title: '新歌速递',
            onPlayAll:
                _newSongs.isNotEmpty ? () => player.playAll(_newSongs) : null,
            onRefresh: _loadNewSongs,
          ),
          const SizedBox(height: 16),
          _isLoadingNewSongs
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Center(
                      child: CircularProgressIndicator(
                          color: AppTheme.accentOrange)),
                )
              : _buildSongGrid(_newSongs),

          const SizedBox(height: 36),

          // 3. 新碟上架 Section
          _buildSectionHeader(
            icon: Icons.album_rounded,
            title: '新碟上架',
            onRefresh: _loadNewAlbums,
          ),
          const SizedBox(height: 16),
          _isLoadingNewAlbums
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Center(
                      child: CircularProgressIndicator(
                          color: AppTheme.accentOrange)),
                )
              : _buildAlbumGrid(_newAlbums),

          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildSectionHeader({
    required IconData icon,
    required String title,
    VoidCallback? onPlayAll,
    VoidCallback? onRefresh,
  }) {
    return Row(
      children: [
        Icon(icon, size: 22, color: AppTheme.accentOrange),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary),
        ),
        const Spacer(),
        if (onPlayAll != null) ...[
          ElevatedButton.icon(
            icon: const Icon(Icons.play_arrow_rounded,
                size: 18, color: Colors.white),
            label: const Text('播放全部',
                style: TextStyle(color: Colors.white, fontSize: 12)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentOrange,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              elevation: 0,
            ),
            onPressed: onPlayAll,
          ),
          const SizedBox(width: 8),
        ],
        if (onRefresh != null)
          IconButton(
            icon: Icon(Icons.refresh_rounded,
                size: 20, color: AppTheme.textSecondary),
            tooltip: '刷新',
            onPressed: onRefresh,
          ),
      ],
    );
  }

  Widget _buildSongGrid(List<Song> songs) {
    if (songs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Text('暂无歌曲数据', style: TextStyle(color: AppTheme.textSecondary)),
      );
    }
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisExtent: 64,
        crossAxisSpacing: 16,
        mainAxisSpacing: 10,
      ),
      itemCount: songs.length,
      itemBuilder: (context, idx) {
        final song = songs[idx];
        return InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => context
              .read<AudioPlayerManager>()
              .playSong(song, newPlaylist: songs),
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
                  borderRadius: BorderRadius.circular(6),
                  child: (song.coverUrl != null && song.coverUrl!.isNotEmpty)
                      ? CachedNetworkImage(
                          imageUrl: song.coverUrl!,
                          width: 48, memCacheWidth: 96,
                          height: 48,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(
                            width: 48,
                            height: 48,
                            color: AppTheme.surfaceWarm,
                            child: Icon(Icons.music_note,
                                color: AppTheme.textSecondary),
                          ),
                        )
                      : Container(
                          width: 48,
                          height: 48,
                          color: AppTheme.surfaceWarm,
                          child: Icon(Icons.music_note,
                              color: AppTheme.textSecondary),
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.songName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        song.authorName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11, color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.play_circle_outline_rounded,
                      color: AppTheme.accentOrange, size: 22),
                  onPressed: () => context
                      .read<AudioPlayerManager>()
                      .playSong(song, newPlaylist: songs),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAlbumGrid(List<Map<String, dynamic>> albums) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisExtent: 220,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: albums.length,
      itemBuilder: (context, idx) {
        final album = albums[idx];
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => widget.onOpenDetail(
            AlbumDetailDestination(
              id: album['id']?.toString() ?? '',
              title: album['title']?.toString() ?? '',
              coverUrl: album['cover']?.toString(),
              artist: album['author_name']?.toString(),
              type: 'album',
            ),
          ),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.surfaceWhite,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.borderWarm),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      imageUrl: album['cover'],
                      fit: BoxFit.cover,
                      width: double.infinity,
                      memCacheWidth: 400,
                      errorWidget: (_, __, ___) => Container(
                        color: AppTheme.surfaceWarm,
                        child: Icon(Icons.album,
                            size: 48, color: AppTheme.textSecondary),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  album['title'],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: AppTheme.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  album['author_name'],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
