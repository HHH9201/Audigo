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

    // 酷狗 /album/songs、/playlist/songs 等返回的是嵌套结构：
    //   歌名 -> base.audio_name / audio_info.audio_name
    //   歌手 -> base.author_name / authors[].author_name
    //   专辑 -> album_info.album_name
    //   hash -> audio_info.hash
    //   时长 -> audio_info.duration（毫秒）
    //   封面 -> album_info.cover / trans_param.union_cover
    final base = json['base'];
    final audioInfo = json['audio_info'];
    final albumInfo2 = json['album_info'];
    dynamic val(Object? parent, String key) =>
        parent is Map ? parent[key] : null;

    String? firstAuthors;
    final authorsRaw = json['authors'];
    if (authorsRaw is List && authorsRaw.isNotEmpty) {
      final first = authorsRaw.first;
      if (first is Map) {
        firstAuthors = (first['author_name'] ?? first['name'])?.toString();
        if (firstAuthors?.isEmpty ?? true) firstAuthors = null;
      }
    }

    final rawDuration = json['time_length'] ??
        json['timelength_320'] ??
        json['duration'] ??
        json['Duration'] ??
        json['timelen'] ??
        val(audioInfo, 'duration') ??
        val(audioInfo, 'duration_320');
    final duration = rawDuration is num
        ? (rawDuration > 10000 ? rawDuration ~/ 1000 : rawDuration.toInt())
        : 0;

    String cover = '';
    final coverCandidates = [
      json['union_cover'],
      json['img_url'],
      json['Image'],
      json['cover'],
      json['pic'],
      json['sizable_cover'],
      val(albumInfo2, 'cover'),
      val(albumInfo2, 'img'),
      val(transParam, 'union_cover'),
    ];
    for (final c in coverCandidates) {
      if (c != null && c.toString().isNotEmpty) {
        cover = c.toString().replaceAll('{size}', '400');
        break;
      }
    }
    if (cover.startsWith('http://')) {
      cover = cover.replaceFirst('http://', 'https://');
    }

    return Song(
      hash: json['hash'] ??
          json['audio_id']?.toString() ??
          json['FileHash']?.toString() ??
          json['file_hash']?.toString() ??
          val(audioInfo, 'hash')?.toString() ??
          val(base, 'audio_id')?.toString() ??
          '',
      // 兼容三种返回：扁平小写、酷狗 v3 大写、kuge/专辑详情嵌套(base.audio_name)。
      songName: json['songname'] ??
          json['song_name'] ??
          json['OriSongName'] ??
          json['song_name_raw'] ??
          json['filename'] ??
          json['name'] ??
          val(base, 'audio_name')?.toString() ??
          val(base, 'song_name')?.toString() ??
          _fileNameTitle(json['FileName']) ??
          '未知曲目',
      authorName: json['author_name'] ??
          json['singer_name'] ??
          json['singer'] ??
          json['artist'] ??
          json['SingerName'] ??
          json['Singername'] ??
          json['singer_name_raw'] ??
          val(base, 'author_name')?.toString() ??
          (firstSinger is Map ? firstSinger['name'] : null) ??
          firstAuthors ??
          '未知歌手',
      albumName: json['album_name'] ??
          json['AlbumName'] ??
          json['album'] ??
          (albumInfo is Map ? albumInfo['name'] : null) ??
          val(albumInfo2, 'album_name')?.toString() ??
          _fileNameAlbum(json['FileName']) ??
          '',
      albumId: json['album_id']?.toString() ??
          json['AlbumID']?.toString() ??
          (albumInfo is Map ? albumInfo['album_id']?.toString() : null) ??
          val(albumInfo2, 'album_id')?.toString() ??
          val(base, 'album_id')?.toString() ??
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

  /// 从酷狗 v3 的 `FileName`（形如"歌手 - 歌名"）中截取"歌名"部分。
  static String? _fileNameTitle(dynamic value) {
    final raw = value?.toString() ?? '';
    final sep = raw.lastIndexOf(' - ');
    return sep > 0 ? raw.substring(sep + 3).trim() : (raw.isEmpty ? null : raw);
  }

  /// 从酷狗 v3 的 `FileName`（形如"歌手 - 歌名"）中截取"歌手"部分。
  static String _fileNameAlbum(dynamic value) {
    final raw = value?.toString() ?? '';
    final sep = raw.lastIndexOf(' - ');
    return sep > 0 ? raw.substring(0, sep).trim() : '';
  }
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
