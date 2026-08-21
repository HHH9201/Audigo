import 'song.dart';

class PlayHistoryRecord {
  final String id;
  final String hash;
  final String songName;
  final String filename;
  final String artistName;
  final String albumName;
  final String albumId;
  final int duration;
  final String unionCover;
  final DateTime playTime;
  final int playCount;
  final DateTime lastPlayTime;

  const PlayHistoryRecord({
    required this.id,
    required this.hash,
    required this.songName,
    required this.filename,
    required this.artistName,
    required this.albumName,
    required this.albumId,
    required this.duration,
    required this.unionCover,
    required this.playTime,
    required this.playCount,
    required this.lastPlayTime,
  });

  factory PlayHistoryRecord.fromSong(Song song, DateTime now) {
    return PlayHistoryRecord(
      id: song.hash,
      hash: song.hash,
      songName: song.songName,
      filename: song.localPath ?? '',
      artistName: song.authorName,
      albumName: song.albumName ?? '',
      albumId: song.albumId ?? '',
      duration: song.timeLength,
      unionCover: song.coverUrl ?? '',
      playTime: now,
      playCount: 1,
      lastPlayTime: now,
    );
  }

  factory PlayHistoryRecord.fromJson(Map<String, dynamic> json) {
    final playTime = DateTime.tryParse(json['play_time']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    return PlayHistoryRecord(
      id: json['id']?.toString() ?? json['hash']?.toString() ?? '',
      hash: json['hash']?.toString() ?? '',
      songName: json['songname']?.toString() ?? '未知曲目',
      filename: json['filename']?.toString() ?? '',
      artistName: json['author_name']?.toString() ?? '未知歌手',
      albumName: json['album_name']?.toString() ?? '',
      albumId: json['album_id']?.toString() ?? '',
      duration: _asInt(json['time_length']),
      unionCover: json['union_cover']?.toString() ?? '',
      playTime: playTime,
      playCount:
          json.containsKey('play_count') ? _asInt(json['play_count']) : 1,
      lastPlayTime:
          DateTime.tryParse(json['last_play_time']?.toString() ?? '') ??
              playTime,
    );
  }

  PlayHistoryRecord replayed(Song song, DateTime now) {
    return PlayHistoryRecord(
      id: id,
      hash: hash,
      songName: song.songName,
      filename: song.localPath ?? '',
      artistName: song.authorName,
      albumName: song.albumName ?? '',
      albumId: song.albumId ?? '',
      duration: song.timeLength,
      unionCover: song.coverUrl ?? '',
      playTime: now,
      playCount: playCount + 1,
      lastPlayTime: now,
    );
  }

  Song toSong() => Song(
        hash: hash,
        songName: songName,
        authorName: artistName,
        albumName: albumName,
        albumId: albumId,
        coverUrl: unionCover,
        timeLength: duration,
        localPath: filename.isEmpty ? null : filename,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'hash': hash,
        'songname': songName,
        'filename': filename,
        'author_name': artistName,
        'album_name': albumName,
        'album_id': albumId,
        'time_length': duration,
        'union_cover': unionCover,
        'play_time': playTime.toIso8601String(),
        'play_count': playCount,
        'last_play_time': lastPlayTime.toIso8601String(),
      };

  static int _asInt(dynamic value) =>
      value is num ? value.toInt() : int.tryParse(value?.toString() ?? '') ?? 0;
}

class PlayHistoryData {
  final List<PlayHistoryRecord> records;
  final int totalCount;
  final DateTime updateTime;

  const PlayHistoryData({
    required this.records,
    required this.totalCount,
    required this.updateTime,
  });

  int get totalDuration =>
      records.fold(0, (total, record) => total + record.duration);

  int get totalPlays =>
      records.fold(0, (total, record) => total + record.playCount);
}
