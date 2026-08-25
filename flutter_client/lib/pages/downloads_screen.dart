import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../services/audio_player_manager.dart';
import '../services/music_api_service.dart';
import '../theme/app_theme.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  List<Map<String, dynamic>> _downloads = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadDownloads();
  }

  Future<void> _loadDownloads() async {
    final records = await MusicApiService.getDownloadRecords(pageSize: 1000);
    if (!mounted) return;
    setState(() {
      _downloads = records;
      _loading = false;
    });
  }

  Future<void> _clearDownloads() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空下载'),
        content: const Text('将删除下载记录及对应音频文件，确定继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await MusicApiService.clearDownloadRecords();
    if (!mounted) return;
    setState(() => _downloads = []);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('下载记录与文件已清空')),
    );
  }

  Future<void> _play(Map<String, dynamic> item) async {
    final path = item['file_path']?.toString() ?? '';
    if (path.isEmpty || !await File(path).exists()) {
      _showMessage('下载文件不存在');
      return;
    }
    final song = Song.fromJson(item);
    if (mounted) await context.read<AudioPlayerManager>().playSong(song);
  }

  /// 打开下载文件所在的文件夹（对应原版 Go 的 DownloadService.OpenFileFolder）。
  Future<void> _openFolder(Map<String, dynamic> item) async {
    final path = item['file_path']?.toString() ?? '';
    if (path.isEmpty || !await File(path).exists()) {
      _showMessage('下载文件不存在');
      return;
    }
    final file = File(path);
    try {
      if (Platform.isWindows) {
        // 资源管理器中选中该文件。
        await Process.run('explorer.exe', ['/select,', path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else {
        await Process.run('xdg-open', [file.parent.path]);
      }
    } catch (e) {
      _showMessage('打开文件夹失败: $e');
    }
  }

  Future<void> _remove(Map<String, dynamic> item) async {
    await MusicApiService.removeDownloadRecord(item);
    if (!mounted) return;
    setState(() => _downloads.remove(item));
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _downloadTime(Map<String, dynamic> item) {
    final time = DateTime.tryParse(item['download_time']?.toString() ?? '');
    if (time == null) return '';
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${twoDigits(time.month)}-${twoDigits(time.day)} '
        '${twoDigits(time.hour)}:${twoDigits(time.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '下载管理',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const Spacer(),
                    OutlinedButton.icon(
                      icon: Icon(
                        Icons.delete_outline_rounded,
                        size: 16,
                        color: AppTheme.textSecondary,
                      ),
                      label: Text(
                        '清空记录',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: AppTheme.borderWarm),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                      ),
                      onPressed: _downloads.isEmpty ? null : _clearDownloads,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          sliver: SliverToBoxAdapter(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppTheme.surfaceWarm,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(12)),
                border: Border.all(color: AppTheme.borderWarm),
              ),
              child: const Row(
                children: [
                  Expanded(flex: 3, child: _Header('歌曲')),
                  Expanded(flex: 2, child: _Header('艺术家')),
                  Expanded(flex: 3, child: _Header('文件名')),
                  Expanded(flex: 2, child: _Header('下载时间')),
                  SizedBox(width: 116, child: _Header('操作')),
                ],
              ),
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
        else if (_downloads.isEmpty)
          SliverToBoxAdapter(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 60),
              alignment: Alignment.center,
              child: Column(
                children: [
                  Icon(
                    Icons.download_done_rounded,
                    size: 48,
                    color: AppTheme.textSecondary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '暂无下载记录',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
            sliver: SliverList.builder(
              itemCount: _downloads.length,
              itemBuilder: (context, idx) {
                final item = _downloads[idx];
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceWhite,
                    borderRadius: idx == _downloads.length - 1
                        ? const BorderRadius.vertical(
                            bottom: Radius.circular(12),
                          )
                        : null,
                    border: Border(
                      left: BorderSide(color: AppTheme.borderWarm),
                      right: BorderSide(color: AppTheme.borderWarm),
                      bottom: BorderSide(color: AppTheme.borderWarm),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: Text(
                          item['songname']?.toString() ?? '未知曲目',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          item['author_name']?.toString() ?? '未知歌手',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(
                          item['filename']?.toString() ?? '',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          _downloadTime(item),
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 116,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            IconButton(
                              tooltip: '播放',
                              icon: Icon(Icons.play_arrow_rounded,
                                  size: 18, color: AppTheme.accentOrange),
                              onPressed: () => _play(item),
                            ),
                            IconButton(
                              tooltip: '打开文件夹',
                              icon: Icon(Icons.folder_open_rounded,
                                  size: 17, color: AppTheme.accentOrange),
                              onPressed: () => _openFolder(item),
                            ),
                            IconButton(
                              tooltip: '删除',
                              icon: Icon(Icons.delete_outline,
                                  size: 18, color: AppTheme.textSecondary),
                              onPressed: () => _remove(item),
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
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: 12,
        color: AppTheme.textSecondary,
      ),
    );
  }
}
