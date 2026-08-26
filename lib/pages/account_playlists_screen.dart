import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../models/user_playlist.dart';
import '../services/music_api_service.dart';
import '../theme/app_theme.dart';
import 'album_detail_screen.dart';

class AccountPlaylistsScreen extends StatefulWidget {
  final ValueChanged<AlbumDetailDestination> onOpenDetail;

  const AccountPlaylistsScreen({super.key, required this.onOpenDetail});

  @override
  State<AccountPlaylistsScreen> createState() => _AccountPlaylistsScreenState();
}

class _AccountPlaylistsScreenState extends State<AccountPlaylistsScreen> {
  List<UserPlaylist> _playlists = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
  }

  Future<void> _loadPlaylists() async {
    setState(() => _isLoading = true);
    final playlists = await MusicApiService.getUserPlaylists();
    if (!mounted) return;
    setState(() {
      _playlists = playlists;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final created = _playlists.where((playlist) => playlist.type == 0).toList();
    final collected =
        _playlists.where((playlist) => playlist.type == 1).toList();

    return Scaffold(
      backgroundColor: AppTheme.bgWarm,
      body: RefreshIndicator(
        color: AppTheme.accentOrange,
        onRefresh: _loadPlaylists,
        child: _isLoading
            ? Center(
                child: CircularProgressIndicator(color: AppTheme.accentOrange),
              )
            : ListView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '收藏的歌单',
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '刷新',
                        onPressed: _loadPlaylists,
                        icon: Icon(
                          Icons.refresh_rounded,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '登录账号后同步创建和收藏的歌单',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 28),
                  if (_playlists.isEmpty) _buildEmptyState(),
                  if (created.isNotEmpty) ...[
                    _buildSectionTitle('我创建的歌单'),
                    const SizedBox(height: 12),
                    _buildPlaylistGrid(created),
                    const SizedBox(height: 28),
                  ],
                  if (collected.isNotEmpty) ...[
                    _buildSectionTitle('我收藏的歌单'),
                    const SizedBox(height: 12),
                    _buildPlaylistGrid(collected),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.only(top: 80),
      child: Column(
        children: [
          Icon(Icons.playlist_remove_rounded,
              size: 56, color: AppTheme.textSecondary),
          const SizedBox(height: 14),
          Text('暂无可同步的账号歌单', style: TextStyle(color: AppTheme.textSecondary)),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.bold,
        color: AppTheme.textPrimary,
      ),
    );
  }

  Widget _buildPlaylistGrid(List<UserPlaylist> playlists) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns =
            (constraints.maxWidth / 190).floor().clamp(2, 5).toInt();
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            childAspectRatio: 0.82,
          ),
          itemCount: playlists.length,
          itemBuilder: (context, index) => _buildPlaylistCard(playlists[index]),
        );
      },
    );
  }

  Widget _buildPlaylistCard(UserPlaylist playlist) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => widget.onOpenDetail(
        AlbumDetailDestination(
          id: playlist.globalCollectionId,
          title: playlist.name,
          coverUrl: playlist.coverUrl,
          artist: playlist.creatorName.isEmpty ? null : playlist.creatorName,
          type: 'accountPlaylist',
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: playlist.coverUrl.isEmpty
                  ? Container(
                      color: AppTheme.surfaceWarm,
                      child: Center(
                        child: Icon(Icons.queue_music_rounded,
                            size: 40, color: AppTheme.textSecondary),
                      ),
                    )
                  : CachedNetworkImage(
                      imageUrl: playlist.coverUrl,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      errorWidget: (_, __, ___) => Container(
                        color: AppTheme.surfaceWarm,
                        child: Center(
                          child: Icon(Icons.queue_music_rounded,
                              size: 40, color: AppTheme.textSecondary),
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${playlist.count} 首${playlist.creatorName.isEmpty ? '' : ' · ${playlist.creatorName}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
