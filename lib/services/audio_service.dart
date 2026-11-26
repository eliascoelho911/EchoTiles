import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

import 'storage_service.dart';

abstract interface class GameAudio {
  Stream<Duration> get onDurationChanged;
  Stream<Duration> get onPositionChanged;
  Stream<void> get onPlayerComplete;
  Stream<String> get onPlaybackError;
  Future<Duration?> prepareSong(String audioPath);
  Future<void> startPrepared();
  Future<Duration?> getCurrentPosition();
  Future<void> pauseSong();
  Future<void> resumeSong();
  Future<void> stopSong();
}

class AudioService implements GameAudio {
  static final AudioService instance = AudioService._internal();
  AudioService._internal() : this.withPlayer(AudioPlayer());
  AudioService.withPlayer(this._musicPlayer);

  final AudioPlayer _musicPlayer;
  final StreamController<String> _errors = StreamController.broadcast();
  StreamSubscription<dynamic>? _eventSub;
  Duration? _currentDuration;
  bool _prepared = false;
  // A pending native resume must finish before a later stop or pause.
  Future<void> _controls = Future.value();

  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _controls.then((_) => operation());
    _controls = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Duration? get currentDuration => _currentDuration;
  @override
  Stream<Duration> get onDurationChanged =>
      _musicPlayer.onDurationChanged.handleError((Object _) {});
  @override
  Stream<Duration> get onPositionChanged =>
      _musicPlayer.onPositionChanged.handleError((Object _) {});
  @override
  Stream<void> get onPlayerComplete =>
      _musicPlayer.onPlayerComplete.handleError((Object _) {});
  @override
  Stream<String> get onPlaybackError => _errors.stream;

  Future<void> init() async {
    _musicPlayer.positionUpdater = TimerPositionUpdater(
      interval: const Duration(milliseconds: 20),
      getPosition: _musicPlayer.getCurrentPosition,
    );
    _eventSub = _musicPlayer.eventStream.listen(
      (_) {},
      onError: (Object _) {
        _errors.add('Não foi possível reproduzir a gravação neste aparelho.');
      },
    );
    await _musicPlayer.setReleaseMode(ReleaseMode.stop);
    await _musicPlayer.setPlaybackRate(1.0);
  }

  static Source _source(String path) {
    if (path.startsWith('assets/')) return AssetSource(path.substring(7));
    if (path.startsWith('content://') ||
        path.startsWith('http://') ||
        path.startsWith('https://')) {
      return UrlSource(path);
    }
    return DeviceFileSource(path);
  }

  Future<Duration?> getDuration() async {
    _currentDuration = await _musicPlayer.getDuration();
    return _currentDuration;
  }

  @override
  Future<Duration?> getCurrentPosition() => _musicPlayer.getCurrentPosition();

  static Future<Duration?> getAudioDuration(String audioPath) async {
    final player = AudioPlayer();
    try {
      await player.setSource(_source(audioPath));
      return await player.getDuration();
    } catch (_) {
      return null;
    } finally {
      await player.dispose();
    }
  }

  @override
  Future<Duration?> prepareSong(String audioPath) => _serial(() async {
    _prepared = false;
    _currentDuration = null;
    await _musicPlayer.stop();
    await _musicPlayer.setVolume(StorageService.getSoundEnabled() ? 1.0 : 0.0);
    await _musicPlayer.setPlaybackRate(1.0);
    await _musicPlayer.setSource(_source(audioPath));
    await _musicPlayer.seek(Duration.zero);
    _currentDuration = await _musicPlayer.getDuration();
    _prepared = true;
    return _currentDuration;
  });

  @override
  Future<void> startPrepared() => _serial(() async {
    if (!_prepared) throw StateError('O áudio ainda não foi preparado.');
    await _musicPlayer.resume();
  });

  Future<void> playSong(String audioPath) async {
    await prepareSong(audioPath);
    await startPrepared();
  }

  @override
  Future<void> pauseSong() => _serial(_musicPlayer.pause);
  @override
  Future<void> resumeSong() => startPrepared();
  @override
  Future<void> stopSong() => _serial(_musicPlayer.stop);

  Future<void> dispose() async {
    await _controls;
    await _eventSub?.cancel();
    await _musicPlayer.dispose();
    await _errors.close();
  }
}
