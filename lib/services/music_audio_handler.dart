import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart' as just_audio;

import '../models/song.dart';
import 'audio_player_manager.dart';

class MusicAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  MusicAudioHandler(this._manager) {
    _manager.addListener(_syncState);
    _syncState();
  }

  final AudioPlayerManager _manager;
  String? _queueSignature;
  String? _mediaItemSignature;

  void _syncState() {
    final queueSignature = _manager.playlist
        .map((song) => _songSignature(song, includeCurrentDuration: true))
        .join('\u0000');
    if (queueSignature != _queueSignature) {
      _queueSignature = queueSignature;
      queue.add(_manager.playlist.map(_toMediaItem).toList(growable: false));
    }

    final current = _manager.currentSong;
    final mediaItemSignature = current == null
        ? ''
        : _songSignature(current, includeCurrentDuration: true);
    if (mediaItemSignature != _mediaItemSignature) {
      _mediaItemSignature = mediaItemSignature;
      mediaItem.add(current == null ? null : _toMediaItem(current));
    }

    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          _manager.isPlaying ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: _toAudioProcessingState(_manager.processingState),
        playing: _manager.isPlaying,
        updatePosition: _manager.currentPosition,
        bufferedPosition: _manager.bufferedPosition,
        speed: 1,
        queueIndex: _manager.currentIndex >= 0 ? _manager.currentIndex : null,
      ),
    );
  }

  String _songSignature(
    Song song, {
    required bool includeCurrentDuration,
  }) {
    final isCurrent = song.hash == _manager.currentSong?.hash;
    final duration = includeCurrentDuration &&
            isCurrent &&
            _manager.totalDuration > Duration.zero
        ? _manager.totalDuration.inMilliseconds
        : song.timeLength * 1000;
    return '${song.hash}\u0001${song.songName}\u0001${song.authorName}'
        '\u0001${song.albumName}\u0001${song.coverUrl}\u0001$duration';
  }

  MediaItem _toMediaItem(Song song) {
    final coverUrl = song.coverUrl;
    final isCurrent = song.hash == _manager.currentSong?.hash;
    final duration = isCurrent && _manager.totalDuration > Duration.zero
        ? _manager.totalDuration
        : song.timeLength > 0
            ? Duration(seconds: song.timeLength)
            : null;
    return MediaItem(
      id: song.hash,
      title: song.songName,
      artist: song.authorName,
      album: song.albumName,
      duration: duration,
      artUri:
          coverUrl == null || coverUrl.isEmpty ? null : Uri.tryParse(coverUrl),
    );
  }

  AudioProcessingState _toAudioProcessingState(
    just_audio.ProcessingState state,
  ) {
    switch (state) {
      case just_audio.ProcessingState.idle:
        return AudioProcessingState.idle;
      case just_audio.ProcessingState.loading:
        return AudioProcessingState.loading;
      case just_audio.ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case just_audio.ProcessingState.ready:
        return AudioProcessingState.ready;
      case just_audio.ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  @override
  Future<void> play() => _manager.play();

  @override
  Future<void> pause() => _manager.pause();

  @override
  Future<void> seek(Duration position) => _manager.seek(position);

  @override
  Future<void> skipToNext() => _manager.playNext();

  @override
  Future<void> skipToPrevious() => _manager.playPrevious();

  @override
  Future<void> skipToQueueItem(int index) async {
    final songs = _manager.playlist;
    if (index < 0 || index >= songs.length) return;
    await _manager.playSong(songs[index]);
  }

  @override
  Future<void> stop() async {
    await _manager.stop();
    await super.stop();
  }
}
