import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;

import '../models/song.dart';
import 'audio_player_manager.dart';

/// MPRIS (Media Player Remote Interfacing Specification) D-Bus 服务。
///
/// 在 Linux 上向桌面环境（GNOME/KDE 等）暴露媒体控制接口，使系统媒体控制、
/// 锁屏卡片、快捷键可以播放/暂停/切歌/跳转/调音量。
/// 基于 `dbus` 包在会话总线上导出 `org.mpris.MediaPlayer2.audigo` 服务。
///
/// 仅在 Linux 平台启用。
class MprisService {
  MprisService._();

  static final MprisService instance = MprisService._();

  /// 总线名称与对象路径。
  static const String busName = 'org.mpris.MediaPlayer2.audigo';
  static const String objectPath = '/org/mpris/MediaPlayer2';
  static const String rootInterface = 'org.mpris.MediaPlayer2';
  static const String playerInterface = 'org.mpris.MediaPlayer2.Player';

  static bool get isSupported => Platform.isLinux;

  DBusClient? _client;
  _MprisObject? _object;
  AudioPlayerManager? _player;
  Timer? _positionTimer;

  bool _active = false;
  bool get active => _active;

  /// 播放器状态（Playing/Paused/Stopped）。
  String _playbackStatus = 'Stopped';
  Map<String, DBusValue> _metadata = {};
  double _volume = 0.5;
  int _positionUs = 0;
  String? _currentTrackId;

  /// 初始化并启动 MPRIS 服务，监听 [player] 的状态变化。
  Future<void> initialize(AudioPlayerManager player) async {
    if (!isSupported || _active) return;
    _player = player;
    player.addListener(_handlePlayerChanged);

    try {
      final client = DBusClient.session();
      final reply = await client.requestName(
        busName,
        flags: const {DBusRequestNameFlag.doNotQueue},
      );
      if (reply != DBusRequestNameReply.primaryOwner) {
        await client.close();
        return;
      }
      final object = _MprisObject(this);
      await client.registerObject(object);
      _client = client;
      _object = object;
      _active = true;

      // 周期同步播放位置（MPRIS Position 属性）。
      _positionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        _syncPosition();
      });

      _pushAll();
      // ignore: avoid_print
      print('✅ MPRIS D-Bus 服务启动成功: $busName');
    } catch (error) {
      // ignore: avoid_print
      print('⚠️ MPRIS 启动失败（可能无 D-Bus 会话总线）: $error');
    }
  }

  /// 停止 MPRIS 服务并释放总线名称。
  Future<void> dispose() async {
    _positionTimer?.cancel();
    _positionTimer = null;
    _player?.removeListener(_handlePlayerChanged);
    _player = null;
    final object = _object;
    final client = _client;
    _object = null;
    _client = null;
    _active = false;
    if (object != null && client != null) {
      try {
        await client.unregisterObject(object);
      } catch (_) {}
    }
    if (client != null) {
      try {
        await client.releaseName(busName);
      } catch (_) {}
      await client.close();
    }
  }

  void _handlePlayerChanged() {
    if (!_active) return;
    final player = _player;
    if (player == null) return;

    final song = player.currentSong;
    final status = player.isPlaying
        ? 'Playing'
        : (player.processingState == ProcessingState.idle ||
                player.processingState == ProcessingState.completed)
            ? 'Stopped'
            : 'Paused';
    if (status != _playbackStatus) {
      _playbackStatus = status;
      _emitPlayerProperty('PlaybackStatus', DBusString(status));
    }

    final volume = player.volume;
    if ((volume - _volume).abs() > 0.001) {
      _volume = volume;
      _emitPlayerProperty('Volume', DBusDouble(volume));
    }

    if (song != null) {
      final metadata = _buildMetadata(song);
      final changed = _metadataChanged(metadata);
      _metadata = metadata;
      if (changed) {
        _emitPlayerProperty('Metadata', _metadataVariant());
      }
    } else if (_metadata.isNotEmpty) {
      _metadata = {};
      _emitPlayerProperty('Metadata', _metadataVariant());
    }
  }

  void _syncPosition() {
    final player = _player;
    if (player == null || !_active) return;
    final positionUs =
        player.currentPosition.inMicroseconds.clamp(0, 1 << 62);
    if ((positionUs - _positionUs).abs() >= 500000) {
      _positionUs = positionUs;
      _emitPlayerProperty('Position', DBusInt64(positionUs));
    }
  }

  Map<String, DBusValue> _buildMetadata(Song song) {
    final trackId = '/org/mpris/MediaPlayer2/Track/${song.hash}';
    _currentTrackId = trackId;
    return <String, DBusValue>{
      'mpris:trackid': DBusObjectPath(trackId),
      'xesam:title': DBusString(song.songName),
      'xesam:artist': DBusArray.string([song.authorName]),
      if (song.albumName != null && song.albumName!.isNotEmpty)
        'xesam:album': DBusString(song.albumName!),
      if (song.coverUrl != null && song.coverUrl!.isNotEmpty)
        'mpris:artUrl': DBusString(song.coverUrl!),
      if (song.timeLength > 0)
        'mpris:length':
            DBusInt64(song.timeLength * 1000000), // 秒 -> 微秒
    };
  }

  bool _metadataChanged(Map<String, DBusValue> next) {
    if (_metadata.length != next.length) return true;
    for (final entry in _metadata.entries) {
      final other = next[entry.key];
      if (other == null) return true;
      final left = entry.value.toString();
      final right = other.toString();
      if (left != right) return true;
    }
    return false;
  }

  DBusValue _metadataVariant() =>
      DBusVariant(DBusDict.stringVariant(_metadata));

  void _emitPlayerProperty(String name, DBusValue value) {
    final object = _object;
    if (object == null) return;
    unawaited(object.emitPropertiesChanged(
      playerInterface,
      changedProperties: {name: value},
    ));
  }

  void _pushAll() {
    final object = _object;
    if (object == null) return;
    unawaited(object.emitPropertiesChanged(
      rootInterface,
      changedProperties: {
        'CanQuit': DBusBoolean(false),
        'CanRaise': DBusBoolean(false),
        'HasTrackList': DBusBoolean(false),
        'Identity': DBusString('拾音'),
        'DesktopEntry': DBusString('audigo'),
        'SupportedUriSchemes': DBusArray.string(['file', 'http', 'https']),
        'SupportedMimeTypes': DBusArray.string([
          'audio/mpeg',
          'audio/flac',
          'audio/ogg',
          'audio/wav',
          'audio/aac',
          'audio/mp4',
        ]),
      },
    ));
    unawaited(object.emitPropertiesChanged(
      playerInterface,
      changedProperties: {
        'PlaybackStatus': DBusString(_playbackStatus),
        'Rate': DBusDouble(1.0),
        'Metadata': _metadataVariant(),
        'Volume': DBusDouble(_volume),
        'Position': DBusInt64(_positionUs),
        'MinimumRate': DBusDouble(1.0),
        'MaximumRate': DBusDouble(1.0),
        'CanGoNext': DBusBoolean(true),
        'CanGoPrevious': DBusBoolean(true),
        'CanPlay': DBusBoolean(true),
        'CanPause': DBusBoolean(true),
        'CanSeek': DBusBoolean(true),
        'CanControl': DBusBoolean(true),
      },
    ));
  }

  // ==================== 播放器控制（供 D-Bus 方法调用） ====================

  Future<void> play() async {
    final player = _player;
    if (player == null) return;
    final current = player.currentSong;
    if (player.processingState == ProcessingState.completed ||
        player.processingState == ProcessingState.idle) {
      if (current == null) return;
      await player.playSong(current);
      return;
    }
    await player.play();
  }

  Future<void> pause() async {
    await _player?.pause();
  }

  Future<void> playPause() async {
    await _player?.togglePlay();
  }

  Future<void> stop() async {
    await _player?.stop();
  }

  Future<void> next() async {
    await _player?.playNext();
  }

  Future<void> previous() async {
    await _player?.playPrevious();
  }

  Future<void> seek(int offsetUs) async {
    final player = _player;
    if (player == null) return;
    await player.seek(player.currentPosition +
        Duration(microseconds: offsetUs));
  }

  Future<void> setPosition(String trackId, int positionUs) async {
    if (_currentTrackId != null && trackId != _currentTrackId) return;
    await _player?.seek(Duration(microseconds: positionUs));
  }

  Future<void> openUri(String uri) async {
    // 本地文件 URI（file://）可作为本地歌曲播放。
    final player = _player;
    if (player == null || !uri.startsWith('file://')) return;
    final path = uri.replaceFirst('file://', '');
    if (path.isEmpty || !File(path).existsSync()) return;
    await player.playSong(Song(
      hash: path,
      songName: path.split(Platform.pathSeparator).last,
      authorName: '本地音乐',
      localPath: path,
    ));
  }

  Future<void> setVolume(double volume) async {
    _player?.setVolume(volume.clamp(0.0, 1.0));
  }

  void emitSeeked(int positionUs) {
    final object = _object;
    if (object == null) return;
    unawaited(object.emitSignal(
      playerInterface,
      'Seeked',
      [DBusInt64(positionUs)],
    ));
  }
}

/// MPRIS D-Bus 导出对象：处理方法调用与属性读写。
class _MprisObject extends DBusObject {
  _MprisObject(this._service) : super(DBusObjectPath(MprisService.objectPath));

  final MprisService _service;

  @override
  List<DBusIntrospectInterface> introspect() => [
        DBusIntrospectInterface(MprisService.rootInterface, methods: [
          DBusIntrospectMethod('Raise'),
          DBusIntrospectMethod('Quit'),
        ], properties: [
          DBusIntrospectProperty('CanQuit', DBusSignature('b'),
              access: DBusPropertyAccess.read),
          DBusIntrospectProperty('CanRaise', DBusSignature('b'),
              access: DBusPropertyAccess.read),
          DBusIntrospectProperty('HasTrackList', DBusSignature('b'),
              access: DBusPropertyAccess.read),
          DBusIntrospectProperty('Identity', DBusSignature('s'),
              access: DBusPropertyAccess.read),
          DBusIntrospectProperty('DesktopEntry', DBusSignature('s'),
              access: DBusPropertyAccess.read),
          DBusIntrospectProperty('SupportedUriSchemes', DBusSignature.array(DBusSignature('s')),
              access: DBusPropertyAccess.read),
          DBusIntrospectProperty('SupportedMimeTypes', DBusSignature.array(DBusSignature('s')),
              access: DBusPropertyAccess.read),
        ]),
        DBusIntrospectInterface(MprisService.playerInterface, methods: [
          DBusIntrospectMethod('Next'),
          DBusIntrospectMethod('Previous'),
          DBusIntrospectMethod('Pause'),
          DBusIntrospectMethod('PlayPause'),
          DBusIntrospectMethod('Stop'),
          DBusIntrospectMethod('Play'),
          DBusIntrospectMethod('Seek', args: [
            DBusIntrospectArgument(DBusSignature('x'), DBusArgumentDirection.in_),
          ]),
          DBusIntrospectMethod('SetPosition', args: [
            DBusIntrospectArgument(DBusSignature('o'), DBusArgumentDirection.in_),
            DBusIntrospectArgument(DBusSignature('x'), DBusArgumentDirection.in_),
          ]),
          DBusIntrospectMethod('OpenUri', args: [
            DBusIntrospectArgument(DBusSignature('s'), DBusArgumentDirection.in_),
          ]),
        ], signals: [
          DBusIntrospectSignal('Seeked', args: [
            DBusIntrospectArgument(DBusSignature('x'), DBusArgumentDirection.out),
          ]),
        ], properties: [
          DBusIntrospectProperty('PlaybackStatus', DBusSignature('s'),
              access: DBusPropertyAccess.read),
          DBusIntrospectProperty('Rate', DBusSignature('d'),
              access: DBusPropertyAccess.readwrite),
          DBusIntrospectProperty('Metadata',
              DBusSignature.dict(DBusSignature('s'), DBusSignature('v')),
              access: DBusPropertyAccess.read),
          DBusIntrospectProperty('Volume', DBusSignature('d'),
              access: DBusPropertyAccess.readwrite),
          DBusIntrospectProperty('Position', DBusSignature('x'),
              access: DBusPropertyAccess.read),
          DBusIntrospectProperty('MinimumRate', DBusSignature('d'),
              access: DBusPropertyAccess.read),
          DBusIntrospectProperty('MaximumRate', DBusSignature('d'),
              access: DBusPropertyAccess.read),
          DBusIntrospectProperty('CanGoNext', DBusSignature('b'),
              access: DBusPropertyAccess.read),
          DBusIntrospectProperty('CanGoPrevious', DBusSignature('b'),
              access: DBusPropertyAccess.read),
          DBusIntrospectProperty('CanPlay', DBusSignature('b'),
              access: DBusPropertyAccess.read),
          DBusIntrospectProperty('CanPause', DBusSignature('b'),
              access: DBusPropertyAccess.read),
          DBusIntrospectProperty('CanSeek', DBusSignature('b'),
              access: DBusPropertyAccess.read),
          DBusIntrospectProperty('CanControl', DBusSignature('b'),
              access: DBusPropertyAccess.read),
        ]),
      ];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    final interface = methodCall.interface;
    final name = methodCall.name;
    if (interface == MprisService.playerInterface) {
      switch (name) {
        case 'Play':
          await _service.play();
          return DBusMethodSuccessResponse();
        case 'Pause':
          await _service.pause();
          return DBusMethodSuccessResponse();
        case 'PlayPause':
          await _service.playPause();
          return DBusMethodSuccessResponse();
        case 'Stop':
          await _service.stop();
          return DBusMethodSuccessResponse();
        case 'Next':
          await _service.next();
          return DBusMethodSuccessResponse();
        case 'Previous':
          await _service.previous();
          return DBusMethodSuccessResponse();
        case 'Seek':
          if (methodCall.values.isNotEmpty) {
            final offsetUs = methodCall.values.first.asInt64();
            await _service.seek(offsetUs);
          }
          return DBusMethodSuccessResponse();
        case 'SetPosition':
          if (methodCall.values.length >= 2) {
            final trackId = methodCall.values[0].asObjectPath().value;
            final positionUs = methodCall.values[1].asInt64();
            await _service.setPosition(trackId, positionUs);
          }
          return DBusMethodSuccessResponse();
        case 'OpenUri':
          if (methodCall.values.isNotEmpty) {
            final uri = methodCall.values.first.asString();
            await _service.openUri(uri);
          }
          return DBusMethodSuccessResponse();
      }
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface == MprisService.rootInterface) {
      final value = _rootProperty(name);
      if (value != null) return DBusGetPropertyResponse(value);
    } else if (interface == MprisService.playerInterface) {
      final value = _playerProperty(name);
      if (value != null) return DBusGetPropertyResponse(value);
    }
    return DBusMethodErrorResponse.unknownProperty();
  }

  @override
  Future<DBusMethodResponse> setProperty(
      String interface, String name, DBusValue value) async {
    if (interface == MprisService.playerInterface) {
      switch (name) {
        case 'Volume':
          if (value is DBusVariant) {
            final inner = value.value;
            if (inner is DBusDouble) {
              await _service.setVolume(inner.value);
              return DBusMethodSuccessResponse();
            }
          } else if (value is DBusDouble) {
            await _service.setVolume(value.value);
            return DBusMethodSuccessResponse();
          }
        case 'Rate':
          // 当前不支持变速播放，忽略写入。
          return DBusMethodSuccessResponse();
      }
    }
    return DBusMethodErrorResponse.unknownProperty();
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    if (interface == MprisService.rootInterface) {
      return DBusGetAllPropertiesResponse(_rootAll());
    }
    if (interface == MprisService.playerInterface) {
      return DBusGetAllPropertiesResponse(_playerAll());
    }
    return DBusGetAllPropertiesResponse({});
  }

  // ==================== 属性构建 ====================

  Map<String, DBusValue> _rootAll() => {
        'CanQuit': DBusBoolean(false),
        'CanRaise': DBusBoolean(false),
        'HasTrackList': DBusBoolean(false),
        'Identity': DBusString('拾音'),
        'DesktopEntry': DBusString('audigo'),
        'SupportedUriSchemes': DBusArray.string(['file', 'http', 'https']),
        'SupportedMimeTypes': DBusArray.string([
          'audio/mpeg',
          'audio/flac',
          'audio/ogg',
          'audio/wav',
          'audio/aac',
          'audio/mp4',
        ]),
      };

  Map<String, DBusValue> _playerAll() => {
        'PlaybackStatus': DBusString(_service._playbackStatus),
        'Rate': DBusDouble(1.0),
        'Metadata': DBusDict.stringVariant(_service._metadata),
        'Volume': DBusDouble(_service._volume),
        'Position': DBusInt64(_service._positionUs),
        'MinimumRate': DBusDouble(1.0),
        'MaximumRate': DBusDouble(1.0),
        'CanGoNext': DBusBoolean(true),
        'CanGoPrevious': DBusBoolean(true),
        'CanPlay': DBusBoolean(true),
        'CanPause': DBusBoolean(true),
        'CanSeek': DBusBoolean(true),
        'CanControl': DBusBoolean(true),
      };

  DBusValue? _rootProperty(String name) => _rootAll()[name];

  DBusValue? _playerProperty(String name) => _playerAll()[name];
}
