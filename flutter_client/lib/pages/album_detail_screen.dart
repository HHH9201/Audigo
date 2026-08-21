import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/song.dart';
import '../services/audio_player_manager.dart';
import '../services/music_api_service.dart';
import '../theme/app_theme.dart';

class AlbumDetailDestination {
  final String id;
  final String title;
  final String? coverUrl;
  final String? artist;
  final String type;

  AlbumDetailDestination({
    required this.id,
    required this.title,
    this.coverUrl,
    this.artist,
    this.type = 'album',
  });
}

class AlbumDetailScreen extends StatefulWidget {
  final AlbumDetailDestination destination;
  final VoidCallback onBack;

  const AlbumDetailScreen({
    super.key,
    required this.destination,
    required this.onBack,
  });

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  List<Song> _songs = [];
  bool _isLoading = true;
  final Set<String> _downloadingHashes = {};

  Future<void> _downloadSong(Song song) async {
    if (_downloadingHashes.contains(song.hash)) return;
    setState(() => _downloadingHashes.add(song.hash));
    final path = await MusicApiService.downloadSong(song);
    if (!mounted) return;
    setState(() => _downloadingHashes.remove(song.hash));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(path == null ? '下载失败或已取消' : '已下载到 $path')),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadAlbumSongs();
  }

  Future<void> _loadAlbumSongs() async {
    setState(() => _isLoading = true);
    final songs = switch (widget.destination.type) {
      'album' => await MusicApiService.getAlbumSongs(widget.destination.id),
      'accountPlaylist' =>
        await MusicApiService.getAccountPlaylistSongs(widget.destination.id),
      _ => await MusicApiService.getPlaylistSongs(widget.destination.id),
    };
    setState(() {
      _songs = songs;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<AudioPlayerManager>();

    return Scaffold(
      backgroundColor: AppTheme.bgWarm,
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 返回按钮
            IconButton(
              icon: Icon(Icons.arrow_back_rounded, color: AppTheme.textPrimary),
              onPressed: widget.onBack,
            ),
            const SizedBox(height: 12),

            // 头部详情卡片
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppTheme.surfaceWhite,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.borderWarm),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: (widget.destination.coverUrl != null &&
                            widget.destination.coverUrl!.isNotEmpty)
                        ? CachedNetworkImage(
                            imageUrl: widget.destination.coverUrl!,
                            width: 140,
                            height: 140,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => Container(
                              width: 140,
                              height: 140,
                              color: AppTheme.surfaceWarm,
                              child: Icon(Icons.album,
                                  size: 64, color: AppTheme.textSecondary),
                            ),
                          )
                        : Container(
                            width: 140,
                            height: 140,
                            color: AppTheme.surfaceWarm,
                            child: Icon(Icons.album,
                                size: 64, color: AppTheme.textSecondary),
                          ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppTheme.accentOrange.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            widget.destination.type == 'album' ? '专辑' : '歌单',
                            style: TextStyle(
                                color: AppTheme.accentOrange,
                                fontSize: 11,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          widget.destination.title,
                          style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.textPrimary),
                        ),
                        const SizedBox(height: 6),
                        if (widget.destination.artist != null)
                          Text(
                            widget.destination.artist!,
                            style: TextStyle(
                                fontSize: 14, color: AppTheme.textSecondary),
                          ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.play_arrow_rounded,
                              color: Colors.white, size: 18),
                          label: const Text('播放全部',
                              style:
                                  TextStyle(color: Colors.white, fontSize: 13)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.accentOrange,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 10),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20)),
                            elevation: 0,
                          ),
                          onPressed: _songs.isNotEmpty
                              ? () => player.playAll(_songs)
                              : null,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // 歌曲列表
            Text(
              '歌曲列表',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary),
            ),
            const SizedBox(height: 12),

            _isLoading
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Center(
                        child: CircularProgressIndicator(
                            color: AppTheme.accentOrange)),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _songs.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, color: AppTheme.borderWarm),
                    itemBuilder: (context, idx) {
                      final song = _songs[idx];
                      final isFav = player.isFavorite(song.hash);

                      return ListTile(
                        leading: Text(
                          '${idx + 1}'.padLeft(2, '0'),
                          style: TextStyle(
                              fontSize: 13,
                              color: AppTheme.textSecondary,
                              fontWeight: FontWeight.w500),
                        ),
                        title: Text(
                          song.songName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary),
                        ),
                        subtitle: Text(
                          song.authorName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: AppTheme.textSecondary),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(
                                isFav ? Icons.favorite : Icons.favorite_border,
                                color: isFav
                                    ? AppTheme.accentOrange
                                    : AppTheme.textSecondary,
                                size: 20,
                              ),
                              onPressed: () =>
                                  player.toggleFavorite(song.hash, song: song),
                            ),
                            IconButton(
                              tooltip: '下载',
                              icon: _downloadingHashes.contains(song.hash)
                                  ? SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: AppTheme.accentOrange),
                                    )
                                  : Icon(Icons.download_rounded,
                                      color: AppTheme.accentOrange, size: 20),
                              onPressed: () => _downloadSong(song),
                            ),
                            IconButton(
                              tooltip: '播放',
                              icon: Icon(Icons.play_circle_outline_rounded,
                                  color: AppTheme.accentOrange, size: 24),
                              onPressed: () =>
                                  player.playSong(song, newPlaylist: _songs),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ],
        ),
      ),
    );
  }
}
