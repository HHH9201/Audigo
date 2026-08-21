import 'dart:typed_data';

// 通用歌曲模型
class Song {
  final String hash;
  final String songName;
  final String authorName;
  final String? albumName;
  final String? albumId;
  final String? coverUrl;
  final Uint8List? coverBytes;
  final int timeLength; // 秒
  final String? localPath;
  final String? lyrics;

  Song({
    required this.hash,
    required this.songName,
    required this.authorName,
    this.albumName,
    this.albumId,
    this.coverUrl,
    this.coverBytes,
    this.timeLength = 0,
    this.localPath,
    this.lyrics,
  });

  factory Song.fromJson(Map<String, dynamic> json) {
    final singerInfo = json['singerinfo'];
    final firstSinger =
        singerInfo is List && singerInfo.isNotEmpty ? singerInfo.first : null;
    final albumInfo = json['albuminfo'];
    final transParam = json['trans_param'];
    final rawDuration = json['time_length'] ??
        json['timelength_320'] ??
        json['duration'] ??
        json['timelen'];
    final duration = rawDuration is num
        ? (rawDuration > 10000 ? rawDuration ~/ 1000 : rawDuration.toInt())
        : 0;
    String cover = '';
    if (json['union_cover'] != null &&
        json['union_cover'].toString().isNotEmpty) {
      cover = json['union_cover'].toString().replaceAll('{size}', '400');
    } else if (json['img_url'] != null &&
        json['img_url'].toString().isNotEmpty) {
      cover = json['img_url'].toString().replaceAll('{size}', '400');
    } else if (json['cover'] != null && json['cover'].toString().isNotEmpty) {
      cover = json['cover'].toString().replaceAll('{size}', '400');
    } else if (json['pic'] != null && json['pic'].toString().isNotEmpty) {
      cover = json['pic'].toString().replaceAll('{size}', '400');
    } else if (json['sizable_cover'] != null &&
        json['sizable_cover'].toString().isNotEmpty) {
      cover = json['sizable_cover'].toString().replaceAll('{size}', '400');
    } else if (transParam is Map &&
        transParam['union_cover']?.toString().isNotEmpty == true) {
      cover = transParam['union_cover'].toString().replaceAll('{size}', '400');
    }

    if (cover.startsWith('http://')) {
      cover = cover.replaceFirst('http://', 'https://');
    }

    return Song(
      hash: json['hash'] ?? json['audio_id']?.toString() ?? '',
      songName: json['songname'] ??
          json['song_name'] ??
          json['filename'] ??
          json['name'] ??
          '未知曲目',
      authorName: json['author_name'] ??
          json['singer_name'] ??
          json['singer'] ??
          json['artist'] ??
          (firstSinger is Map ? firstSinger['name'] : null) ??
          '未知歌手',
      albumName: json['album_name'] ??
          json['album'] ??
          (albumInfo is Map ? albumInfo['name'] : null) ??
          '',
      albumId: json['album_id']?.toString() ??
          (albumInfo is Map ? albumInfo['album_id']?.toString() : null) ??
          '',
      coverUrl: cover.isEmpty ? null : cover,
      timeLength: duration,
      localPath:
          json['local_path']?.toString() ?? json['file_path']?.toString(),
      lyrics: json['lyrics']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'hash': hash,
        'songname': songName,
        'author_name': authorName,
        'album_name': albumName,
        'album_id': albumId,
        'union_cover': coverUrl,
        'time_length': timeLength,
        'local_path': localPath,
        'lyrics': lyrics,
      };
}

class LyricWord {
  final Duration time;
  final Duration duration;
  final String text;

  const LyricWord({
    required this.time,
    required this.duration,
    required this.text,
  });
}

// 歌词行模型
class LyricLine {
  final Duration time;
  final Duration duration;
  final String text;
  final List<LyricWord> words;

  const LyricLine({
    required this.time,
    required this.text,
    this.duration = Duration.zero,
    this.words = const [],
  });
}
