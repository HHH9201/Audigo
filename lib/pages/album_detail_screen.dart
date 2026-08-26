import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/song.dart';
import '../services/audio_player_manager.dart';
import '../services/music_api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_toast.dart';

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

/// 专辑/歌单详情页 —— 与“我喜欢的”页面同款操作布局：
/// 大封面 + 类型徽标 + 标题 + 创建者 + 歌曲数 + 操作按钮（播放全部/批量下载/刷新），
/// 下方为表格型歌曲列表（# / 标题 / 专辑 / 时长 / 操作）。
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
  bool _isRefreshing = false;
  final Set<String> _downloadingHashes = {};
  bool _isBatchDownloading = false;
  int _totalCount = 0;

  Future<void> _downloadSong(Song song) async {
    if (_downloadingHashes.contains(song.hash)) return;
    setState(() => _downloadingHashes.add(song.hash));
    final path = await MusicApiService.downloadSong(song);
    if (!mounted) return;
    setState(() => _downloadingHashes.remove(song.hash));
    AppToast.show(
      context,
      path == null ? '下载失败或已取消' : '已下载到 $path',
      isError: path == null,
    );
  }

  Future<void> _downloadAll() async {
    if (_songs.isEmpty || _isBatchDownloading) return;
    setState(() => _isBatchDownloading = true);
    var success = 0;
    var failed = 0;
    for (final song in _songs) {
      final path = await MusicApiService.downloadSong(song);
      if (path != null) {
        success++;
      } else {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() => _isBatchDownloading = false);
    AppToast.show(
      context,
      failed == 0
          ? '批量下载完成：共 $success 首'
          : '批量下载完成：成功 $success 首，失败 $failed 首',
      isError: failed > 0,
    );
  }

  @override
  void initState() {
    super.initState();
    _loadAlbumSongs();
  }

  Future<void> _loadAlbumSongs() async {
    setState(() {
      _isLoading = true;
      _isRefreshing = true;
    });
    final songs = switch (widget.destination.type) {
      'album' => await MusicApiService.getAlbumSongs(widget.destination.id),
      'accountPlaylist' =>
        await MusicApiService.getAccountPlaylistSongs(widget.destination.id),
      _ => await MusicApiService.getPlaylistSongs(widget.destination.id),
    };
    if (!mounted) return;
    setState(() {
      _songs = songs;
      _totalCount = songs.length;
      _isLoading = false;
      _isRefreshing = false;
    });
  }

  Future<void> _refresh() async {
    if (_isRefreshing) return;
    await _loadAlbumSongs();
  }

  String _formatDuration(int seconds) {
    if (seconds <= 0) return '--:--';
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgWarm,
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 返回按钮
                  IconButton(
                    icon: Icon(Icons.arrow_back_rounded,
                        color: AppTheme.textPrimary),
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
                                        size: 64,
                                        color: AppTheme.textSecondary),
                                  ),
                                )
                              : Container(
                                  width: 140,
                                  height: 140,
                                  color: AppTheme.surfaceWarm,
                                  child: Icon(Icons.album,
                                      size: 64,
                                      color: AppTheme.textSecondary),
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
                                  color:
                                      AppTheme.accentOrange.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  widget.destination.type == 'album'
                                      ? '专辑'
                                      : '歌单',
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
                              Row(
                                children: [
                                  if (widget.destination.artist != null) ...[
                                    Flexible(
                                      child: Text(
                                        widget.destination.artist!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontSize: 14,
                                            color: AppTheme.textSecondary),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text('·',
                                        style: TextStyle(
                                            color: AppTheme.textSecondary)),
                                    const SizedBox(width: 6),
                                  ],
                                  Text(
                                    '$_totalCount首歌曲',
                                    style: TextStyle(
                                        fontSize: 14,
                                        color: AppTheme.textSecondary),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              Row(
                                children: [
                                  ElevatedButton.icon(
                                    icon: const Icon(Icons.play_arrow_rounded,
                                        color: Colors.white, size: 18),
                                    label: const Text('播放全部',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 13)),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppTheme.accentOrange,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 20, vertical: 10),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(20)),
                                      elevation: 0,
                                    ),
                                    onPressed: _songs.isNotEmpty
                                        ? () => context
                                            .read<AudioPlayerManager>()
                                            .playAll(_songs)
                                        : null,
                                  ),
                                  const SizedBox(width: 8),
                                  OutlinedButton.icon(
                                    icon: _isBatchDownloading
                                        ? SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color:
                                                    AppTheme.accentOrange),
                                          )
                                        : Icon(Icons.download_rounded,
                                            size: 16,
                                            color: AppTheme.accentOrange),
                                    label: Text(
                                      _isBatchDownloading
                                          ? '下载中...'
                                          : '批量下载',
                                      style: TextStyle(
                                          fontSize: 13,
                                          color: AppTheme.accentOrange),
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16, vertical: 10),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(20)),
                                      side: BorderSide(
                                          color: AppTheme.accentOrange
                                              .withOpacity(0.6)),
                                    ),
                                    onPressed: _songs.isNotEmpty
                                        ? _downloadAll
                                        : null,
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    tooltip: '刷新',
                                    icon: _isRefreshing
                                        ? SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: AppTheme.accentOrange),
                                          )
                                        : Icon(Icons.sync_rounded,
                                            color: AppTheme.textSecondary),
                                    onPressed: _isRefreshing ? null : _refresh,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // 歌曲列表表头（与“我喜欢的”页面一致）
                  if (_songs.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppTheme.surfaceWarm,
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(12)),
                        border: Border.all(color: AppTheme.borderWarm),
                      ),
                      child: Row(
                        children: [
                          SizedBox(width: 24, child: Text('#',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                  color: AppTheme.textSecondary))),
                          Expanded(
                              flex: 5,
                              child: Text('标题',
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                      color: AppTheme.textSecondary))),
                          Expanded(
                              flex: 3,
                              child: Text('专辑',
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                      color: AppTheme.textSecondary))),
                          Expanded(
                              flex: 2,
                              child: Text('时长',
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                      color: AppTheme.textSecondary))),
                          SizedBox(width: 150, child: Text('操作',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                                color: AppTheme.textSecondary))),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),

          // 歌曲列表
          if (_isLoading)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 60),
                child: Center(
                    child: CircularProgressIndicator(
                        color: AppTheme.accentOrange)),
              ),
            )
          else if (_songs.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 60),
                child: Center(
                  child: Column(
                    children: [
                      Icon(Icons.music_off_rounded,
                          size: 48, color: AppTheme.textSecondary),
                      const SizedBox(height: 12),
                      Text('暂无歌曲',
                          style: TextStyle(color: AppTheme.textSecondary)),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
              sliver: SliverList.separated(
                itemCount: _songs.length,
                separatorBuilder: (_, __) =>
                    Divider(height: 1, color: AppTheme.borderWarm),
                itemBuilder: (context, idx) {
                  final song = _songs[idx];
                  final albumName = song.albumName?.isNotEmpty == true
                      ? song.albumName!
                      : '未知专辑';
                  return Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceWhite,
                      border: Border(
                        left: BorderSide(color: AppTheme.borderWarm),
                        right: BorderSide(color: AppTheme.borderWarm),
                        bottom: idx == _songs.length - 1
                            ? BorderSide(color: AppTheme.borderWarm)
                            : BorderSide.none,
                      ),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 24,
                          child: Text(
                            '${idx + 1}'.padLeft(2, '0'),
                            style: TextStyle(
                                fontSize: 13,
                                color: AppTheme.textSecondary,
                                fontWeight: FontWeight.w500),
                          ),
                        ),
                        Expanded(
                          flex: 5,
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: song.coverUrl?.isNotEmpty == true
                                    ? CachedNetworkImage(
                                        imageUrl: song.coverUrl!,
                                        width: 40,
                                        height: 40,
                                        fit: BoxFit.cover,
                                        errorWidget: (_, __, ___) => Container(
                                          width: 40,
                                          height: 40,
                                          color: AppTheme.surfaceWarm,
                                          child: Icon(Icons.music_note,
                                              size: 18,
                                              color: AppTheme.textSecondary),
                                        ),
                                      )
                                    : Container(
                                        width: 40,
                                        height: 40,
                                        color: AppTheme.surfaceWarm,
                                        child: Icon(Icons.music_note,
                                            size: 18,
                                            color: AppTheme.textSecondary),
                                      ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: InkWell(
                                  onTap: () => context
                                      .read<AudioPlayerManager>()
                                      .playSong(song, newPlaylist: _songs),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
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
                                            fontSize: 11,
                                            color: AppTheme.textSecondary),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(
                            albumName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12, color: AppTheme.textSecondary),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            _formatDuration(song.timeLength),
                            style: TextStyle(
                                fontSize: 12, color: AppTheme.textSecondary),
                          ),
                        ),
                        SizedBox(
                          width: 150,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                tooltip: '播放',
                                visualDensity: VisualDensity.compact,
                                icon: Icon(Icons.play_circle_outline_rounded,
                                    color: AppTheme.accentOrange, size: 22),
                                onPressed: () => context
                                    .read<AudioPlayerManager>()
                                    .playSong(song, newPlaylist: _songs),
                              ),
                              Selector<AudioPlayerManager, bool>(
                                selector: (_, player) =>
                                    player.isFavorite(song.hash),
                                builder: (context, isFav, _) => IconButton(
                                  tooltip: isFav ? '取消收藏' : '收藏',
                                  visualDensity: VisualDensity.compact,
                                  icon: Icon(
                                    isFav
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    color: isFav
                                        ? AppTheme.accentOrange
                                        : AppTheme.textSecondary,
                                    size: 18,
                                  ),
                                  onPressed: () => context
                                      .read<AudioPlayerManager>()
                                      .toggleFavorite(song.hash, song: song),
                                ),
                              ),
                              IconButton(
                                tooltip: '下载',
                                visualDensity: VisualDensity.compact,
                                icon: _downloadingHashes.contains(song.hash)
                                    ? SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: AppTheme.accentOrange),
                                      )
                                    : Icon(Icons.download_rounded,
                                        color: AppTheme.textSecondary,
                                        size: 20),
                                onPressed: () => _downloadSong(song),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}