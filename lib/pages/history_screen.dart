import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/play_history.dart';
import '../services/audio_player_manager.dart';
import '../services/music_api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_toast.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  String _filter = 'all'; // all, today, yesterday, week
  PlayHistoryData _history = PlayHistoryData(
    records: [],
    totalCount: 0,
    updateTime: DateTime.fromMillisecondsSinceEpoch(0),
  );
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final history = await MusicApiService.getPlayHistory(
      pageSize: 1000,
      filter: _filter,
    );
    if (!mounted) return;
    setState(() {
      _history = history;
      _loading = false;
    });
  }

  Future<void> _clearHistory() async {
    final history = await MusicApiService.clearPlayHistory();
    if (!mounted) return;
    setState(() => _history = history);
    AppToast.show(context, '历史记录已清空');
  }

  @override
  Widget build(BuildContext context) {
    final historyRecords = _history.records;

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 头部与统计
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(Icons.history_rounded,
                        size: 28, color: AppTheme.accentOrange),
                    const SizedBox(width: 10),
                    Text(
                      '播放历史',
                      style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textPrimary),
                    ),
                    const Spacer(),
                    // 统计项
                    _buildStatBadge(
                        Icons.music_note_rounded, '${_history.totalCount} 首歌曲'),
                    const SizedBox(width: 12),
                    _buildStatBadge(Icons.schedule_rounded,
                        '${(_history.totalDuration / 60).round()} 分钟'),
                    const SizedBox(width: 12),
                    _buildStatBadge(Icons.play_circle_outline_rounded,
                        '${_history.totalPlays} 次播放'),
                  ],
                ),
                const SizedBox(height: 24),

                // 过滤按钮与清空
                Row(
                  children: [
                    _buildFilterChip('全部', 'all'),
                    const SizedBox(width: 8),
                    _buildFilterChip('今天', 'today'),
                    const SizedBox(width: 8),
                    _buildFilterChip('昨天', 'yesterday'),
                    const SizedBox(width: 8),
                    _buildFilterChip('本周', 'week'),
                    const Spacer(),
                    OutlinedButton.icon(
                      icon: Icon(Icons.delete_outline_rounded,
                          size: 16, color: AppTheme.textSecondary),
                      label: Text('清空历史',
                          style: TextStyle(
                              color: AppTheme.textSecondary, fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: AppTheme.borderWarm),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                      ),
                      onPressed: historyRecords.isEmpty ? null : _clearHistory,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
        if (_loading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 60),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (historyRecords.isEmpty)
          SliverToBoxAdapter(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 60),
              alignment: Alignment.center,
              child: Column(
                children: [
                  Icon(Icons.history, size: 48, color: AppTheme.textSecondary),
                  const SizedBox(height: 12),
                  Text('暂无播放历史记录',
                      style: TextStyle(
                          color: AppTheme.textSecondary, fontSize: 14)),
                ],
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
            sliver: SliverList.separated(
              itemCount: historyRecords.length,
              separatorBuilder: (_, __) =>
                  Divider(height: 1, color: AppTheme.borderWarm),
              itemBuilder: (context, idx) {
                final record = historyRecords[idx];
                final song = record.toSong();

                return ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: (song.coverUrl != null && song.coverUrl!.isNotEmpty)
                        ? CachedNetworkImage(
                            imageUrl: song.coverUrl!,
                            width: 44, memCacheWidth: 88,
                            height: 44,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => Container(
                              width: 44,
                              height: 44,
                              color: AppTheme.surfaceWarm,
                              child: Icon(Icons.music_note,
                                  color: AppTheme.textSecondary),
                            ),
                          )
                        : Container(
                            width: 44,
                            height: 44,
                            color: AppTheme.surfaceWarm,
                            child: Icon(Icons.music_note,
                                color: AppTheme.textSecondary),
                          ),
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
                    '${song.authorName} · ${record.playCount} 次 · ${_formatPlayTime(record.playTime)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Selector<AudioPlayerManager, bool>(
                        selector: (_, player) => player.isFavorite(record.hash),
                        builder: (context, isFav, _) => IconButton(
                          icon: Icon(
                            isFav ? Icons.favorite : Icons.favorite_border,
                            color: isFav
                                ? AppTheme.accentOrange
                                : AppTheme.textSecondary,
                            size: 20,
                          ),
                          onPressed: () => context
                              .read<AudioPlayerManager>()
                              .toggleFavorite(song.hash, song: song),
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.play_circle_outline_rounded,
                            color: AppTheme.accentOrange, size: 24),
                        onPressed: () =>
                            context.read<AudioPlayerManager>().playSong(song),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  String _formatPlayTime(DateTime time) {
    final now = DateTime.now();
    final day = DateTime(time.year, time.month, time.day);
    final today = DateTime(now.year, now.month, now.day);
    final prefix = day == today
        ? '今天'
        : day == today.subtract(const Duration(days: 1))
            ? '昨天'
            : '${time.month}月${time.day}日';
    return '$prefix ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildStatBadge(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderWarm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppTheme.accentOrange),
          const SizedBox(width: 6),
          Text(text,
              style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, String value) {
    final isSelected = _filter == value;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      selectedColor: AppTheme.accentOrange,
      backgroundColor: AppTheme.surfaceWhite,
      labelStyle: TextStyle(
        color: isSelected ? Colors.white : AppTheme.textPrimary,
        fontSize: 12,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
            color: isSelected ? AppTheme.accentOrange : AppTheme.borderWarm),
      ),
      onSelected: (selected) {
        if (selected) {
          setState(() {
            _filter = value;
            _loading = true;
          });
          _loadHistory();
        }
      },
    );
  }
}
