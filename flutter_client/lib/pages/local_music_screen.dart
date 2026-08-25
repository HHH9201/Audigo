import 'dart:convert';
import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../services/audio_player_manager.dart';
import '../services/local_music_index.dart';
import '../theme/app_theme.dart';

const localAudioExtensions = {
  '.mp3',
  '.flac',
  '.wav',
  '.m4a',
  '.aac',
  '.ogg',
  '.opus',
  '.ape',
  '.aif',
  '.aiff',
  '.aifc',
  '.wma',
};

String? sameNameLyricsPath(String audioPath) {
  for (final extension in ['.krc', '.lrc']) {
    final lyricsPath = p.setExtension(audioPath, extension);
    if (File(lyricsPath).existsSync()) return lyricsPath;
  }
  return null;
}

String? sameNameLrcPath(String audioPath) => sameNameLyricsPath(audioPath);

String? _readSameNameLyrics(String audioPath) {
  final lyricsPath = sameNameLyricsPath(audioPath);
  if (lyricsPath == null) return null;
  try {
    final lyrics = File(lyricsPath).readAsStringSync().trim();
    return lyrics.isEmpty ? null : lyrics;
  } on FileSystemException {
    return null;
  }
}

String _coverExtension(List<int> bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return '.png';
  }
  if (bytes.length >= 6 &&
      String.fromCharCodes(bytes.take(6)).startsWith('GIF8')) {
    return '.gif';
  }
  if (bytes.length >= 12 &&
      String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
    return '.webp';
  }
  return '.jpg';
}

String _stablePathHash(String value) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return hash.toRadixString(16);
}

List<Map<String, dynamic>> _readMetadataBatch(
  List<Map<String, dynamic>> inputs,
) {
  return inputs.map(_readMetadata).toList();
}

Map<String, dynamic> _readMetadata(Map<String, dynamic> input) {
  final path = input['path'] as String;
  final coverDirectory = input['coverDirectory'] as String;
  final file = File(path);
  final fallbackTitle = p.basenameWithoutExtension(path);
  String? coverPath;
  String? lyrics = _readSameNameLyrics(path);
  var title = fallbackTitle;
  var artist = '未知艺术家';
  String? album;
  var duration = 0;

  try {
    final metadata = readMetadata(file, getImage: true);
    final metadataTitle = metadata.title?.trim();
    final metadataArtist = metadata.artist?.trim();
    final metadataAlbum = metadata.album?.trim();
    title = metadataTitle?.isNotEmpty == true ? metadataTitle! : fallbackTitle;
    artist = metadataArtist?.isNotEmpty == true ? metadataArtist! : '未知艺术家';
    album = metadataAlbum?.isNotEmpty == true ? metadataAlbum : null;
    duration = metadata.duration?.inSeconds ?? 0;
    lyrics ??= metadata.lyrics?.trim();

    if (metadata.pictures.isNotEmpty) {
      final frontCovers = metadata.pictures
          .where((picture) => picture.pictureType == PictureType.coverFront);
      final cover = frontCovers.isNotEmpty
          ? frontCovers.first.bytes
          : metadata.pictures.first.bytes;
      final destination = File(p.join(
        coverDirectory,
        '${_stablePathHash(path)}${_coverExtension(cover)}',
      ));
      destination.parent.createSync(recursive: true);
      destination.writeAsBytesSync(cover, flush: true);
      coverPath = destination.path;
    }
  } catch (_) {}

  return {
    'path': path,
    'modified': input['modified'],
    'size': input['size'],
    'title': title,
    'artist': artist,
    'album': album,
    'duration': duration,
    'coverPath': coverPath,
    'lyrics': lyrics,
  };
}

Song songFromLocalCache(Map<String, dynamic> data) {
  final path = data['path'] as String;
  final coverPath = data['coverPath'] as String?;
  return Song(
    hash: data['contentId'] as String? ?? path,
    songName: data['title'] as String? ?? p.basenameWithoutExtension(path),
    authorName: data['artist'] as String? ?? '未知艺术家',
    albumName: data['album'] as String?,
    coverUrl:
        coverPath != null && File(coverPath).existsSync() ? coverPath : null,
    timeLength: data['duration'] as int? ?? 0,
    localPath: path,
    lyrics: data['lyrics'] as String?,
  );
}

bool localCacheMatches(
  Map<String, dynamic> cached,
  int modified,
  int size,
) {
  return cached['modified'] == modified && cached['size'] == size;
}

class LocalMusicScreen extends StatefulWidget {
  const LocalMusicScreen({super.key});

  @override
  State<LocalMusicScreen> createState() => _LocalMusicScreenState();
}

class _LocalMusicScreenState extends State<LocalMusicScreen> {
  static const _pathsKey = 'local_music_paths';

  final List<String> _folderPaths = [];
  final List<Song> _localSongs = [];
  bool _isPathExpanded = true;
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _loadFolders();
  }

  Future<void> _loadFolders() async {
    final prefs = await SharedPreferences.getInstance();
    _folderPaths.addAll(prefs.getStringList(_pathsKey) ?? []);
    if (!mounted) return;
    setState(() {});
    await _scanMusic(showResult: false);
  }

  Future<void> _saveFolders() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_pathsKey, _folderPaths);
  }

  Future<void> _addFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择音乐文件夹',
    );
    if (path == null || path.isEmpty) return;
    final directoryExists = await Directory(path).exists();
    if (!mounted) return;
    if (!directoryExists) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('文件夹不存在，请重新选择')),
      );
      return;
    }
    if (_folderPaths.contains(path)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该文件夹已添加')),
      );
      return;
    }
    setState(() => _folderPaths.add(path));
    await _saveFolders();
    await _scanMusic();
  }

  Future<void> _removeFolder(String path) async {
    setState(() => _folderPaths.remove(path));
    await _saveFolders();
    await _scanMusic(showResult: false);
  }

  Future<void> _scanMusic({bool showResult = true}) async {
    if (_isScanning) return;
    setState(() => _isScanning = true);

    final supportDirectory = await getApplicationSupportDirectory();
    final localCacheDirectory = Directory(
      p.join(supportDirectory.path, 'local_music'),
    );
    final coverDirectory = p.join(localCacheDirectory.path, 'covers');
    final metadataCacheFile = File(
      p.join(localCacheDirectory.path, 'metadata.json'),
    );
    final files = <LocalMusicFile>[];

    for (final path in _folderPaths) {
      final directory = Directory(path);
      if (!await directory.exists()) continue;
      try {
        await for (final entity
            in directory.list(recursive: true, followLinks: false)) {
          if (entity is! File ||
              !localAudioExtensions
                  .contains(p.extension(entity.path).toLowerCase())) {
            continue;
          }
          final stat = await entity.stat();
          files.add(LocalMusicFile(
            path: entity.path,
            modified: stat.modified.millisecondsSinceEpoch,
            size: stat.size,
          ));
        }
      } on FileSystemException {
        continue;
      }
    }

    final index = await LocalMusicIndex(metadataCacheFile).update(
      files,
      coverDirectory: coverDirectory,
      readMetadata: (inputs) => compute(_readMetadataBatch, inputs),
    );
    final songs = index.uniqueMetadata.map(songFromLocalCache).toList()
      ..sort((a, b) =>
          a.songName.toLowerCase().compareTo(b.songName.toLowerCase()));
    if (!mounted) return;
    setState(() {
      _localSongs
        ..clear()
        ..addAll(songs);
      _isScanning = false;
    });
    if (showResult) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('扫描完成，共发现 ${songs.length} 首歌曲')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final artistCount =
        _localSongs.map((song) => song.authorName).toSet().length;
    final albumCount = _localSongs
        .map((song) => song.albumName)
        .where((album) => album != null && album.isNotEmpty)
        .toSet()
        .length;

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
                      '本地音乐',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const Spacer(),
                    ElevatedButton.icon(
                      icon: const Icon(
                        Icons.create_new_folder_rounded,
                        size: 16,
                        color: Colors.white,
                      ),
                      label: const Text(
                        '添加文件夹',
                        style: TextStyle(color: Colors.white, fontSize: 12),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accentOrange,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        elevation: 0,
                      ),
                      onPressed: _addFolder,
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      icon: Icon(
                        Icons.play_arrow_rounded,
                        size: 16,
                        color: AppTheme.textPrimary,
                      ),
                      label: Text(
                        '播放全部',
                        style: TextStyle(
                            color: AppTheme.textPrimary, fontSize: 12),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: AppTheme.borderWarm),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                      ),
                      onPressed: _localSongs.isNotEmpty
                          ? () => context
                              .read<AudioPlayerManager>()
                              .playAll(_localSongs)
                          : null,
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: _isScanning
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              Icons.sync_rounded,
                              color: AppTheme.textSecondary,
                            ),
                      tooltip: '扫描音乐',
                      onPressed: _isScanning ? null : _scanMusic,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    _buildStatCard('${_localSongs.length}', '首歌曲'),
                    const SizedBox(width: 16),
                    _buildStatCard('$artistCount', '位艺术家'),
                    const SizedBox(width: 16),
                    _buildStatCard('$albumCount', '张专辑'),
                  ],
                ),
                const SizedBox(height: 24),
                Container(
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceWhite,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.borderWarm),
                  ),
                  child: Column(
                    children: [
                      ListTile(
                        leading: Icon(
                          Icons.folder_open_rounded,
                          color: AppTheme.accentOrange,
                        ),
                        title: const Text(
                          '音乐文件夹路径',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        subtitle: Text(
                          '${_folderPaths.length} 个路径',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                        trailing: IconButton(
                          icon: Icon(
                            _isPathExpanded
                                ? Icons.expand_less
                                : Icons.expand_more,
                          ),
                          onPressed: () => setState(
                              () => _isPathExpanded = !_isPathExpanded),
                        ),
                      ),
                      if (_isPathExpanded)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          child: _folderPaths.isEmpty
                              ? Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  child: Text(
                                    '还没有添加任何音乐文件夹路径，点击右上角“添加文件夹”开始添加',
                                    style: TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                )
                              : Column(
                                  children: _folderPaths.map((path) {
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 4),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.folder,
                                            size: 16,
                                            color: AppTheme.textSecondary,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              path,
                                              style:
                                                  const TextStyle(fontSize: 12),
                                            ),
                                          ),
                                          IconButton(
                                            icon: Icon(
                                              Icons.close,
                                              size: 16,
                                              color: AppTheme.textSecondary,
                                            ),
                                            onPressed: () =>
                                                _removeFolder(path),
                                          ),
                                        ],
                                      ),
                                    );
                                  }).toList(),
                                ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
        if (_localSongs.isEmpty)
          SliverToBoxAdapter(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 40),
              alignment: Alignment.center,
              child: Text(
                '暂无本地音乐，请先添加文件夹',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
            sliver: SliverList.separated(
              itemCount: _localSongs.length,
              separatorBuilder: (_, __) =>
                  Divider(height: 1, color: AppTheme.borderWarm),
              itemBuilder: (context, idx) {
                final song = _localSongs[idx];
                return ListTile(
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceWarm,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: song.coverUrl?.isNotEmpty == true
                        ? Image.file(File(song.coverUrl!), fit: BoxFit.cover)
                        : Icon(
                            Icons.music_note,
                            color: AppTheme.textSecondary,
                          ),
                  ),
                  title: Text(
                    song.songName,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    [
                      song.authorName,
                      if (song.albumName?.isNotEmpty == true) song.albumName!,
                      if (song.timeLength > 0) _formatDuration(song.timeLength),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  trailing: IconButton(
                    icon: Icon(
                      Icons.play_circle_outline_rounded,
                      color: AppTheme.accentOrange,
                    ),
                    onPressed: () =>
                        context.read<AudioPlayerManager>().playSong(song),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final remainingSeconds = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$remainingSeconds';
  }

  Widget _buildStatCard(String count, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: AppTheme.surfaceWhite,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderWarm),
        ),
        child: Column(
          children: [
            Text(
              count,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: AppTheme.accentOrange,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
