import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../l10n/app_localizations.dart';
import '../models/app_theme.dart';
import '../models/game_models.dart';
import '../models/beatmap.dart';
import '../services/audio_clock.dart';
import '../services/audio_service.dart';
import '../services/chart_timeline.dart';
import '../services/import_api.dart';
import '../services/track_cache.dart';
import '../services/haptics.dart';
import '../services/storage_service.dart';

class GameScreen extends StatefulWidget {
  final SongItem song;
  final AppThemeData appTheme;
  final GameAudio? audio;
  final Future<PreparedTrack> Function(SongItem)? prepareYoutube;
  final int Function()? nowMicros;

  const GameScreen({
    super.key,
    required this.song,
    required this.appTheme,
    this.audio,
    this.prepareYoutube,
    this.nowMicros,
  });

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const double _targetLineFactor = 0.80;
  static const double _tileHeightFactor = 0.20;
  static const double _beatGap = 0.06;

  late Ticker _ticker;
  Duration _lastElapsed = Duration.zero;

  GameStatus _status = GameStatus.ready;
  final List<GameTile> _tiles = [];
  final List<HitFeedback> _feedbacks = [];
  final Map<int, int> _activePointerTiles = {};
  final List<int> _lanePatternQueue = [];
  final List<double> _gapPatternQueue = [];

  int _score = 0;
  int _combo = 0;
  int _maxCombo = 0;
  int _nextTileIndex = 0;
  int _lastLane = -1;
  int _failedLane = -1;
  int _totalNotes = 160;
  bool _lastWasDouble = false;

  double _baseScrollSpeed = 0.50;
  double _songProgress = 0.0;
  final Random _rng = Random();

  Duration? _audioDuration;
  bool _songAudioFinished = false;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<void>? _completeSub;
  Size _screenSize = Size.zero;
  final Stopwatch _monotonic = Stopwatch()..start();
  late AudioClock _clock;
  ChartTimeline? _timeline;
  final Map<int, ChartNote> _chartNotes = {};
  final Set<int> _resolvedIds = {};
  final Map<int, int> _holdScores = {};
  StreamSubscription<String>? _errorSub;
  bool _preparing = true;
  bool _startingPlayback = false;
  bool _countingIn = false;
  bool _pauseWasReady = false;
  String? _playbackError;
  int _levelToken = 0;
  Future<void> _pausePending = Future.value();

  GameAudio get _audio => widget.audio ?? AudioService.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _clock = AudioClock(
      nowMicros: widget.nowMicros ?? () => _monotonic.elapsedMicroseconds,
    );
    _totalNotes = widget.song.notesCount;
    _ticker = createTicker(_onTick);
    _listenAudio();
    _initLevel();
  }

  void _listenAudio() {
    _durationSub = _audio.onDurationChanged.listen((dur) {
      if (dur.inMilliseconds > 0 && mounted) {
        setState(() {
          _audioDuration = dur;
          final calcNotes = widget.song.isYoutube
              ? _totalNotes
              : (dur.inMilliseconds /
                        1000.0 *
                        ((widget.song.bpm / 120.0) * 2.3))
                    .round();
          if (calcNotes > _totalNotes) {
            _totalNotes = calcNotes;
          }
        });
      }
    }, onError: _onAudioError);

    _positionSub = _audio.onPositionChanged.listen((pos) {
      if (_status != GameStatus.playing || _countingIn || _startingPlayback) {
        return;
      }
      if (widget.song.isYoutube) _clock.update(pos);
      if (_audioDuration != null &&
          _audioDuration!.inMilliseconds > 0 &&
          mounted) {
        final progress = (pos.inMilliseconds / _audioDuration!.inMilliseconds)
            .clamp(0.0, 1.0);
        setState(() {
          _songProgress = progress;
          if (!widget.song.isYoutube && progress >= 1.0) {
            _songAudioFinished = true;
          }
        });
      }
    }, onError: _onAudioError);

    _completeSub = _audio.onPlayerComplete.listen((_) {
      if (mounted && _status == GameStatus.playing && !_countingIn) {
        setState(() {
          _songAudioFinished = true;
          _songProgress = 1.0;
          if (_timeline != null) {
            _clock.update(Duration(milliseconds: _timeline!.chart.durationMs));
            _clock.pause();
            _advanceChart();
          }
        });
      }
    }, onError: _onAudioError);
    _errorSub = _audio.onPlaybackError.listen(
      _showPlaybackError,
      onError: _onAudioError,
    );
  }

  void _onAudioError(Object _) => _showPlaybackError(
    'Não foi possível reproduzir a gravação neste aparelho.',
  );

  void _stopAudioQuietly() {
    unawaited(_audio.stopSong().catchError((Object _) {}));
  }

  void _showPlaybackError(String message) {
    if (!mounted) return;
    _ticker.stop();
    _clock.pause();
    _stopAudioQuietly();
    setState(() {
      _preparing = false;
      _startingPlayback = false;
      _countingIn = false;
      _status = GameStatus.ready;
      _playbackError = message;
    });
  }

  Future<void> _prepareLevel(int token) async {
    try {
      await _audio.stopSong();
      var path = widget.song.assetAudio;
      // Explicit audio-free legacy demos keep their original practice mode.
      if (!widget.song.isYoutube && path.isEmpty) {
        if (mounted && token == _levelToken) {
          setState(() {
            _audioDuration = null;
            _preparing = false;
          });
        }
        return;
      }
      if (widget.song.isYoutube) {
        final prepare = widget.prepareYoutube;
        final ready = prepare != null
            ? await prepare(widget.song)
            : await (await TrackCache.forApp()).prepare(
                widget.song.youtubeTrack!,
                widget.song.serverBase!,
              );
        if (!mounted || token != _levelToken) return;
        path = ready.audioFile.path;
        _timeline = ChartTimeline(ready.chart, scrollSpeed: _baseScrollSpeed);
        _totalNotes = ready.chart.notes.length;
        _tiles.clear();
        for (final note in ready.chart.notes) {
          _chartNotes[note.id] = note;
          final projection = _timeline!.project(note, -3000);
          _tiles.add(
            GameTile(
              id: note.id,
              lane: note.lane,
              y: projection.y,
              length: projection.height / _tileHeightFactor,
              isLong: note.type == NoteType.hold,
              noteIndex: note.id,
            ),
          );
        }
      }
      final duration = await _audio.prepareSong(path);
      if (!mounted || token != _levelToken) return;
      if (duration == null || duration.inMilliseconds <= 0) {
        throw StateError('Duração de áudio indisponível.');
      }
      if (widget.song.isYoutube &&
          (duration.inMilliseconds - widget.song.youtubeTrack!.durationMs)
                  .abs() >
              500) {
        _showPlaybackError(
          'A duração reproduzida não corresponde ao mapa desta faixa.',
        );
        return;
      }
      setState(() {
        _audioDuration = duration;
        _preparing = false;
      });
    } on ImportApiException catch (error) {
      if (mounted && token == _levelToken) _showPlaybackError(error.message);
    } on FormatException {
      if (mounted && token == _levelToken) {
        _showPlaybackError(
          'O mapa desta faixa é inválido ou incompatível com o áudio.',
        );
      }
    } catch (_) {
      if (mounted && token == _levelToken) {
        _showPlaybackError(
          'Não foi possível preparar a gravação. Verifique se o arquivo está disponível e tente novamente.',
        );
      }
    }
  }

  void _initLevel() {
    if (_ticker.isActive) _ticker.stop();
    _clock.pause();
    _preparing = true;
    _startingPlayback = false;
    _countingIn = false;
    _pauseWasReady = false;
    _playbackError = null;
    _timeline = null;
    _chartNotes.clear();
    _resolvedIds.clear();
    _holdScores.clear();
    _status = GameStatus.ready;
    _score = 0;
    _combo = 0;
    _maxCombo = 0;
    _nextTileIndex = 0;
    _lastLane = -1;
    _failedLane = -1;
    _songAudioFinished = false;
    _lastWasDouble = false;
    _totalNotes = widget.song.notesCount;
    if (_audioDuration != null && _audioDuration!.inMilliseconds > 0) {
      final calcNotes =
          (_audioDuration!.inMilliseconds /
                  1000.0 *
                  ((widget.song.bpm / 120.0) * 2.3))
              .round();
      if (calcNotes > _totalNotes) {
        _totalNotes = calcNotes;
      }
    }
    _tiles.clear();
    _feedbacks.clear();
    _activePointerTiles.clear();
    _lanePatternQueue.clear();
    _gapPatternQueue.clear();
    _baseScrollSpeed = (widget.song.bpm / 120.0) * 0.50;
    _songProgress = 0.0;

    if (!widget.song.isYoutube) {
      _spawnTile(initialY: _targetLineFactor);
      for (int i = 0; i < 4; i++) {
        _spawnTile();
      }
    }
    unawaited(_prepareLevel(++_levelToken));
  }

  int _generateNextLane() {
    if (_lanePatternQueue.isEmpty) {
      _fillLanePatterns();
    }
    int lane = _lanePatternQueue.removeAt(0);
    if (lane == _lastLane) {
      lane = (_lastLane + 1 + _rng.nextInt(3)) % 4;
    }
    _lastLane = lane;
    return lane;
  }

  void _fillLanePatterns() {
    final patternType = _rng.nextInt(6);
    switch (patternType) {
      case 0:
        final s = _rng.nextInt(4);
        _lanePatternQueue.addAll([s, (s + 1) % 4, (s + 2) % 4, (s + 3) % 4]);
        _gapPatternQueue.addAll([0.05, 0.05, 0.05, 0.07]);
        break;
      case 1:
        final s = _rng.nextInt(4);
        _lanePatternQueue.addAll([s, (s + 3) % 4, (s + 2) % 4, (s + 1) % 4]);
        _gapPatternQueue.addAll([0.05, 0.05, 0.05, 0.07]);
        break;
      case 2:
        final a = _rng.nextInt(4);
        final b = (a + 1 + _rng.nextInt(3)) % 4;
        _lanePatternQueue.addAll([a, b, a, b]);
        _gapPatternQueue.addAll([0.06, 0.06, 0.06, 0.08]);
        break;
      case 3:
        final a = _rng.nextInt(4);
        final b = (a + 2) % 4;
        final c = (a + 1) % 4;
        final d = (a + 3) % 4;
        _lanePatternQueue.addAll([a, b, c, d]);
        _gapPatternQueue.addAll([0.05, 0.06, 0.05, 0.07]);
        break;
      case 4:
        final a = _rng.nextInt(4);
        final b = (a + 1 + _rng.nextInt(3)) % 4;
        final c = (b + 1 + _rng.nextInt(3)) % 4;
        _lanePatternQueue.addAll([a, b, c, b]);
        _gapPatternQueue.addAll([0.06, 0.06, 0.06, 0.07]);
        break;
      default:
        int current = _lastLane == -1 ? _rng.nextInt(4) : _lastLane;
        for (int i = 0; i < 4; i++) {
          current = (current + 1 + _rng.nextInt(3)) % 4;
          _lanePatternQueue.add(current);
          _gapPatternQueue.add(0.06);
        }
        break;
    }
  }

  void _spawnTile({double? initialY}) {
    final hasAudio = widget.song.assetAudio.isNotEmpty;
    if (hasAudio ? _songAudioFinished : _nextTileIndex >= _totalNotes) return;

    final lane = _generateNextLane();
    final double gap = _gapPatternQueue.isNotEmpty
        ? _gapPatternQueue.removeAt(0)
        : _beatGap;

    final allowLong = _nextTileIndex >= 10 && _songProgress < 0.85;
    final isLong = initialY == null && allowLong && (_rng.nextDouble() < 0.14);
    final length = isLong ? 3.0 : 1.0;

    double yPos;
    if (initialY != null) {
      yPos = initialY;
    } else {
      if (_tiles.isNotEmpty) {
        final highestTop = _tiles
            .map((t) => t.y - (_tileHeightFactor * t.length))
            .reduce(min);
        yPos = highestTop - gap;
      } else {
        yPos = _targetLineFactor;
      }
    }

    _tiles.add(
      GameTile(
        id: _nextTileIndex,
        lane: lane,
        y: yPos,
        length: length,
        isLong: isLong,
        noteIndex: _nextTileIndex,
      ),
    );
    _nextTileIndex++;

    final allowDouble =
        initialY == null &&
        _nextTileIndex >= 8 &&
        !_lastWasDouble &&
        _rng.nextDouble() < 0.50;

    if (allowDouble) {
      final candidates = [
        for (int i = 0; i < 4; i++)
          if ((i - lane).abs() >= 2) i,
      ];
      final secondLane = candidates[_rng.nextInt(candidates.length)];
      _tiles.add(
        GameTile(
          id: _nextTileIndex,
          lane: secondLane,
          y: yPos,
          length: length,
          isLong: isLong,
          noteIndex: _nextTileIndex,
        ),
      );
      _nextTileIndex++;
      _lastWasDouble = true;
      _lastLane = secondLane;
    } else {
      _lastWasDouble = false;
    }
  }

  void _onTick(Duration elapsed) {
    if (_status != GameStatus.playing) {
      _lastElapsed = elapsed;
      return;
    }
    if (widget.song.isYoutube) {
      if (_countingIn && _clock.position >= Duration.zero) {
        _clock.pause();
        if (!_startingPlayback) unawaited(_startPreparedPlayback());
        return;
      }
      setState(_advanceChart);
      return;
    }

    double dt = (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
    _lastElapsed = elapsed;
    if (dt <= 0) return;
    if (dt > 0.05) dt = 0.05;

    final currentSpeed =
        _baseScrollSpeed * (1.0 + pow(_songProgress, 2.5) * 1.50);

    setState(() {
      for (final tile in _tiles) {
        tile.y += currentSpeed * dt;
        if (tile.isHolding && tile.isLong) {
          final tileHeight = _tileHeightFactor * tile.length;
          final prevStep = (tile.holdProgress * 10).floor();
          tile.holdProgress =
              (tile.holdProgress + (currentSpeed * dt) / tileHeight).clamp(
                0.0,
                1.0,
              );
          _score += (dt * 220).toInt();

          final currStep = (tile.holdProgress * 10).floor();
          if (currStep > prevStep) {
            _combo++;
            if (_combo > _maxCombo) _maxCombo = _combo;
            Haptics.light();
          }

          if (tile.holdProgress >= 1.0) {
            tile.isHolding = false;
            tile.isHit = true;
            _score += 150;
            _combo += 2;
            if (_combo > _maxCombo) _maxCombo = _combo;
            Haptics.medium();
            final sw = _screenSize.width > 0 ? _screenSize.width : 400.0;
            final sh = _screenSize.height > 0 ? _screenSize.height : 800.0;
            _feedbacks.add(
              HitFeedback(
                quality: HitQuality.perfect,
                x: (tile.lane + 0.5) * (sw / 4),
                y: sh * _targetLineFactor,
                timestamp: DateTime.now().millisecondsSinceEpoch,
              ),
            );
          }
        }
      }

      final highestTop = _tiles.isEmpty
          ? 1.0
          : _tiles.map((t) => t.y - (_tileHeightFactor * t.length)).reduce(min);
      final hasAudio = widget.song.assetAudio.isNotEmpty;
      final canSpawn = hasAudio
          ? !_songAudioFinished
          : _nextTileIndex < _totalNotes;
      if (highestTop > -0.30 && canSpawn) {
        _spawnTile();
      }

      for (final tile in _tiles) {
        if (!tile.isHit && !tile.isHolding && !tile.isMissed && tile.y > 1.02) {
          tile.isMissed = true;
          _triggerGameOver(tile.lane);
          return;
        }
      }

      _tiles.removeWhere((t) => (t.isHit && !t.isHolding && t.y > 1.30));

      final now = DateTime.now().millisecondsSinceEpoch;
      _feedbacks.removeWhere((f) => now - f.timestamp > 700);

      if (_audioDuration == null || _audioDuration!.inMilliseconds == 0) {
        _songProgress = (_nextTileIndex / _totalNotes).clamp(0.0, 1.0);
      }

      final isComplete = hasAudio
          ? _songAudioFinished
          : _nextTileIndex >= _totalNotes;
      if (isComplete && _tiles.every((t) => t.isHit)) {
        _triggerVictory();
      }
    });
  }

  void _advanceChart() {
    final timeline = _timeline;
    if (timeline == null) return;
    final nowMs = _clock.position.inMicroseconds / 1000.0;
    _songProgress = (nowMs / timeline.chart.durationMs).clamp(0.0, 1.0);
    for (final tile in _tiles) {
      final note = _chartNotes[tile.id]!;
      tile.y = timeline.project(note, nowMs).y;
      if (tile.isHolding) {
        final previousStep = (tile.holdProgress * 10).floor();
        tile.holdProgress = max(
          tile.holdProgress,
          ((nowMs - note.timeMs) / note.durationMs).clamp(0.0, 1.0),
        );
        final earned = (tile.holdProgress * note.durationMs / 1000 * 220)
            .floor();
        _score += earned - (_holdScores[tile.id] ?? 0);
        _holdScores[tile.id] = earned;
        final step = (tile.holdProgress * 10).floor();
        if (step > previousStep) {
          _combo += step - previousStep;
          _maxCombo = max(_maxCombo, _combo);
          Haptics.light();
        }
        if (tile.holdProgress >= 1) {
          tile.isHolding = false;
          tile.isHit = true;
          _resolvedIds.add(tile.id);
          _activePointerTiles.removeWhere((_, id) => id == tile.id);
          _score += 150;
          _combo += 2;
          _maxCombo = max(_maxCombo, _combo);
          Haptics.medium();
        }
      }
      if (!_countingIn &&
          !tile.isHit &&
          !tile.isHolding &&
          (tile.y > 1.02 || _songAudioFinished)) {
        tile.isMissed = true;
        _triggerGameOver(tile.lane);
        return;
      }
    }
    _tiles.removeWhere(
      (tile) => tile.isHit && !tile.isHolding && tile.y > 1.30,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    _feedbacks.removeWhere((f) => now - f.timestamp > 700);
    if (timeline.isComplete(
      audioFinished: _songAudioFinished,
      resolvedIds: _resolvedIds,
    )) {
      _triggerVictory();
    }
  }

  void _beginCountIn() {
    if (_preparing || _startingPlayback || _status != GameStatus.ready) return;
    setState(() {
      _status = GameStatus.playing;
      _countingIn = true;
    });
    _clock.startCountIn(const Duration(seconds: 3));
    _lastElapsed = Duration.zero;
    _ticker.start();
  }

  void _startGame() {
    if (_preparing || _startingPlayback) return;
    setState(() => _status = GameStatus.playing);
    unawaited(_startPreparedPlayback());
  }

  Future<void> _startPreparedPlayback() async {
    final token = _levelToken;
    _startingPlayback = true;
    _countingIn = false;
    _ticker.stop();
    try {
      if (!widget.song.isYoutube && widget.song.assetAudio.isEmpty) {
        _lastElapsed = Duration.zero;
        _ticker.start();
        return;
      }
      await _audio.startPrepared();
      final position = await _audio.getCurrentPosition();
      if (!mounted || token != _levelToken) return;
      if (_status != GameStatus.playing) {
        await _audio.pauseSong();
        return;
      }
      _clock.start(position ?? Duration.zero);
      _lastElapsed = Duration.zero;
      _ticker.start();
    } catch (_) {
      if (mounted && token == _levelToken) _onAudioError(Object());
    } finally {
      if (mounted && token == _levelToken) {
        setState(() => _startingPlayback = false);
      }
    }
  }

  void _pauseGame() {
    if (_status != GameStatus.playing && _status != GameStatus.ready) return;
    _pauseWasReady = _status == GameStatus.ready;
    setState(() => _status = GameStatus.paused);
    _clock.pause();
    _ticker.stop();
    _pausePending = () async {
      try {
        await _audio.pauseSong();
        final position = await _audio.getCurrentPosition();
        if (!_countingIn &&
            position != null &&
            mounted &&
            _status == GameStatus.paused) {
          _clock.update(position);
        }
      } catch (_) {
        if (mounted) _onAudioError(Object());
      }
    }();
  }

  Future<void> _resumeGame() async {
    if (_status != GameStatus.paused || _startingPlayback || _preparing) return;
    await _pausePending;
    if (!mounted || _status != GameStatus.paused) return;
    if (_pauseWasReady) {
      setState(() => _status = GameStatus.ready);
      return;
    }
    setState(() => _status = GameStatus.playing);
    if (_countingIn) {
      _clock.resume();
      _ticker.start();
      return;
    }
    await _startPreparedPlayback();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _pauseGame();
  }

  void _triggerGameOver(int lane, [Offset? mistapOffset]) {
    _status = GameStatus.gameOver;
    _failedLane = lane;
    _ticker.stop();
    _clock.pause();
    _stopAudioQuietly();
    Haptics.heavy();
    if (mistapOffset != null) {
      _feedbacks.add(
        HitFeedback(
          quality: HitQuality.miss,
          x: mistapOffset.dx,
          y: mistapOffset.dy,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    StorageService.setHighScore(widget.song.id, _score);
    StorageService.setBestCombo(_maxCombo);
    setState(() {});
  }

  void _triggerVictory() {
    _status = GameStatus.victory;
    _ticker.stop();
    _clock.pause();
    _stopAudioQuietly();
    Haptics.medium();
    final stars = _calculateStars();
    StorageService.setHighScore(widget.song.id, _score);
    StorageService.setStars(widget.song.id, stars);
    StorageService.setBestCombo(_maxCombo);
  }

  int _calculateStars() {
    if (_songProgress >= 0.95) return 3;
    if (_songProgress >= 0.65) return 2;
    if (_songProgress >= 0.35) return 1;
    return 0;
  }

  void _onPointerDown(PointerDownEvent event, Size screenSize) {
    if (_preparing ||
        _startingPlayback ||
        _playbackError != null ||
        _countingIn ||
        (widget.song.isYoutube && _status == GameStatus.ready)) {
      return;
    }
    if (_status == GameStatus.gameOver ||
        _status == GameStatus.victory ||
        _status == GameStatus.paused) {
      return;
    }

    if (event.localPosition.dy < 75) {
      return;
    }

    final laneWidth = screenSize.width / 4;
    final tapX = event.localPosition.dx;
    final tapY = event.localPosition.dy;
    final tapLane = (tapX / laneWidth).floor().clamp(0, 3);
    final tapYFraction = tapY / screenSize.height;

    final unhitTiles = _tiles
        .where((t) => !t.isHit && !t.isHolding && !t.isMissed)
        .toList();
    final laneCandidates = unhitTiles.where((t) => t.lane == tapLane).toList();

    laneCandidates.sort((a, b) => b.y.compareTo(a.y));
    GameTile? hitTile;
    for (final t in laneCandidates) {
      final tileTop = t.y - (_tileHeightFactor * t.length);
      final isDirectTap =
          tapYFraction >= (tileTop - 0.04) && tapYFraction <= (t.y + 0.04);
      final isTargetLineHit =
          (t.y >= _targetLineFactor - 0.09 &&
              tileTop <= _targetLineFactor + 0.09) &&
          ((tapYFraction - _targetLineFactor).abs() <= 0.09);
      if (isDirectTap || isTargetLineHit) {
        hitTile = t;
        break;
      }
    }

    if (hitTile == null) {
      _triggerGameOver(tapLane, Offset(tapX, tapY));
      return;
    }

    final hasLowerMissed = unhitTiles.any(
      (t) => t.id < hitTile!.id && (t.y - (_tileHeightFactor * t.length)) > 1.0,
    );
    if (hasLowerMissed) {
      _triggerGameOver(tapLane, Offset(tapX, tapY));
      return;
    }

    if (_status == GameStatus.ready) {
      if (hitTile.id != 0) {
        _triggerGameOver(tapLane, Offset(tapX, tapY));
        return;
      }
      _startGame();
    }

    Haptics.light();

    final tileTop = hitTile.y - (_tileHeightFactor * hitTile.length);
    double dist;
    if (_targetLineFactor >= tileTop && _targetLineFactor <= hitTile.y) {
      dist = 0.0;
    } else {
      dist = min(
        (hitTile.y - _targetLineFactor).abs(),
        (tileTop - _targetLineFactor).abs(),
      );
    }

    HitQuality quality;
    int addScore;

    if (dist < 0.025) {
      quality = HitQuality.perfect;
      addScore = 100;
    } else if (dist < 0.06) {
      quality = HitQuality.great;
      addScore = 80;
    } else {
      quality = HitQuality.good;
      addScore = 50;
    }

    _combo++;
    if (_combo > _maxCombo) _maxCombo = _combo;
    _score += addScore + (_combo * 2);

    if (hitTile.isLong) {
      hitTile.isHolding = true;
      hitTile.holdProgress = 0.0;
      _activePointerTiles[event.pointer] = hitTile.id;
    } else {
      hitTile.isHit = true;
      _resolvedIds.add(hitTile.id);
    }

    _feedbacks.add(
      HitFeedback(
        quality: quality,
        x: tapX,
        y: tapY,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    setState(() {});
  }

  void _onPointerMove(PointerMoveEvent event, Size screenSize) {
    final tileId = _activePointerTiles[event.pointer];
    if (tileId != null) {
      final tile = _tiles.where((t) => t.id == tileId).firstOrNull;
      if (tile != null && tile.isHolding) {
        final laneWidth = screenSize.width / 4;
        final currentLane = (event.localPosition.dx / laneWidth).floor().clamp(
          0,
          3,
        );
        if (currentLane != tile.lane) {
          tile.isHolding = false;
          tile.isHit = true;
          _resolvedIds.add(tile.id);
          _activePointerTiles.remove(event.pointer);
        }
      }
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    final tileId = _activePointerTiles.remove(event.pointer);
    if (tileId != null) {
      for (final tile in _tiles) {
        if (tile.id == tileId && tile.isHolding) {
          tile.isHolding = false;
          tile.isHit = true;
          _resolvedIds.add(tile.id);
          if (tile.holdProgress >= 0.85) {
            _score += 100;
            Haptics.medium();
          }
        }
      }
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    final tileId = _activePointerTiles.remove(event.pointer);
    if (tileId != null) {
      for (final tile in _tiles) {
        if (tile.id == tileId && tile.isHolding) {
          tile.isHolding = false;
          tile.isHit = true;
          _resolvedIds.add(tile.id);
        }
      }
    }
  }

  @override
  void dispose() {
    _levelToken++;
    WidgetsBinding.instance.removeObserver(this);
    _monotonic.stop();
    _ticker.dispose();
    _durationSub?.cancel();
    _positionSub?.cancel();
    _completeSub?.cancel();
    _errorSub?.cancel();
    _stopAudioQuietly();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.appTheme;
    final l10n = AppLocalizations.of(context);
    final qualityLabels = {
      HitQuality.perfect: l10n.qualityPerfect,
      HitQuality.great: l10n.qualityGreat,
      HitQuality.good: l10n.qualityGood,
      HitQuality.miss: l10n.qualityMiss,
    };

    return Scaffold(
      backgroundColor: theme.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                _screenSize = size;
                return Listener(
                  onPointerDown: (e) => _onPointerDown(e, size),
                  onPointerMove: (e) => _onPointerMove(e, size),
                  onPointerUp: _onPointerUp,
                  onPointerCancel: _onPointerCancel,
                  child: CustomPaint(
                    size: size,
                    painter: _GameTilesPainter(
                      tiles: _tiles,
                      feedbacks: _feedbacks,
                      appTheme: theme,
                      failedLane: _failedLane,
                      isReady:
                          _status == GameStatus.ready && !widget.song.isYoutube,
                      targetLineFactor: _targetLineFactor,
                      tileHeightFactor: _tileHeightFactor,
                      startLabel: l10n.start,
                      qualityLabels: qualityLabels,
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned(top: 0, left: 0, right: 0, child: _buildHeader(theme)),
          if (_preparing || _startingPlayback) _buildPreparationOverlay(theme),
          if (_playbackError != null) _buildPlaybackError(theme),
          if (widget.song.isYoutube &&
              _status == GameStatus.ready &&
              !_preparing &&
              _playbackError == null)
            Center(
              child: FilledButton.icon(
                onPressed: _beginCountIn,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Começar · 3, 2, 1'),
              ),
            ),
          if (_countingIn && _status == GameStatus.playing)
            IgnorePointer(
              child: Center(
                child: Text(
                  '${(-_clock.position.inMilliseconds / 1000).ceil().clamp(1, 3)}',
                  style: TextStyle(
                    color: theme.playBg,
                    fontSize: 72,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
          if (_status == GameStatus.paused) _buildPauseOverlay(theme),
          if (_status == GameStatus.gameOver)
            _buildEndOverlay(theme, isWin: false),
          if (_status == GameStatus.victory)
            _buildEndOverlay(theme, isWin: true),
        ],
      ),
    );
  }

  Widget _buildPreparationOverlay(AppThemeData theme) {
    return ColoredBox(
      color: theme.background.withValues(alpha: 0.9),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(
              _startingPlayback
                  ? 'Iniciando áudio…'
                  : 'Preparando áudio e mapa…',
              style: TextStyle(
                color: theme.textPrimary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaybackError(AppThemeData theme) {
    return ColoredBox(
      color: theme.background.withValues(alpha: 0.96),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.music_off_rounded, size: 48, color: theme.textMuted),
              const SizedBox(height: 20),
              Text(
                _playbackError!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.textPrimary, fontSize: 17),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () {
                  _initLevel();
                  setState(() {});
                },
                child: const Text('Tentar preparar novamente'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Voltar à biblioteca'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(AppThemeData theme) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          decoration: BoxDecoration(
            color: theme.surface.withValues(alpha: 0.82),
            border: Border(
              bottom: BorderSide(
                color: theme.border.withValues(alpha: 0.4),
                width: 1.8,
              ),
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.arrow_back_ios_new_rounded,
                          color: theme.textPrimary,
                          size: 22,
                        ),
                        onPressed: () {
                          Haptics.select();
                          Navigator.of(context).pop();
                        },
                      ),
                      Column(
                        children: [
                          Text(
                            '$_score',
                            style: TextStyle(
                              fontFamily: 'Fredoka',
                              fontSize: 30,
                              fontWeight: FontWeight.w900,
                              color: theme.textPrimary,
                            ),
                          ),
                          if (_combo > 1)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: theme.playBg,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                AppLocalizations.of(context).comboLabel(_combo),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.0,
                                ),
                              ),
                            ),
                        ],
                      ),
                      IconButton(
                        icon: Icon(
                          _status == GameStatus.paused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                          color: theme.textPrimary,
                          size: 28,
                        ),
                        onPressed: () {
                          Haptics.select();
                          if (_status == GameStatus.playing ||
                              _status == GameStatus.ready) {
                            _pauseGame();
                          } else if (_status == GameStatus.paused) {
                            _resumeGame();
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: _songProgress,
                      minHeight: 6,
                      backgroundColor: theme.surfaceVariant.withValues(
                        alpha: 0.6,
                      ),
                      valueColor: AlwaysStoppedAnimation<Color>(theme.playBg),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPauseOverlay(AppThemeData theme) {
    return Container(
      color: Colors.black.withValues(alpha: 0.65),
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 32),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: theme.dialogBg,
            borderRadius: BorderRadius.circular(28),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 20,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                AppLocalizations.of(context).paused,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.5,
                  color: theme.textPrimary,
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  Haptics.select();
                  _resumeGame();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.playBg,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(54),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  AppLocalizations.of(context).resume,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  side: BorderSide(color: theme.border, width: 2),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  AppLocalizations.of(context).home,
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEndOverlay(AppThemeData theme, {required bool isWin}) {
    final stars = _calculateStars();
    final highScore = StorageService.getHighScore(widget.song.id);

    return Container(
      color: Colors.black.withValues(alpha: 0.72),
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 28),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: theme.dialogBg,
            borderRadius: BorderRadius.circular(28),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 24,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isWin
                    ? AppLocalizations.of(context).songCompleted
                    : AppLocalizations.of(context).outOfRhythm,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.0,
                  color: isWin ? theme.playBg : const Color(0xFFEF4444),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(3, (i) {
                  final active = i < stars;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      active ? Icons.star_rounded : Icons.star_outline_rounded,
                      color: active ? const Color(0xFFFFB800) : theme.border,
                      size: 38,
                    ),
                  );
                }),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: theme.surfaceVariant,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          AppLocalizations.of(context).score,
                          style: TextStyle(
                            color: theme.textMuted,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          '$_score',
                          style: TextStyle(
                            color: theme.textPrimary,
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          AppLocalizations.of(context).bestScore,
                          style: TextStyle(
                            color: theme.textMuted,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          '$highScore',
                          style: TextStyle(
                            color: theme.textPrimary,
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              ElevatedButton(
                onPressed: () {
                  Haptics.select();
                  _initLevel();
                  setState(() {});
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: isWin
                      ? theme.playBg
                      : const Color(0xFFEF4444),
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(54),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  isWin
                      ? AppLocalizations.of(context).playAgain
                      : AppLocalizations.of(context).tryAgain,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  side: BorderSide(color: theme.border, width: 2),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  AppLocalizations.of(context).home,
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GameTilesPainter extends CustomPainter {
  final List<GameTile> tiles;
  final List<HitFeedback> feedbacks;
  final AppThemeData appTheme;
  final int failedLane;
  final bool isReady;
  final double targetLineFactor;
  final double tileHeightFactor;
  final String startLabel;
  final Map<HitQuality, String> qualityLabels;

  _GameTilesPainter({
    required this.tiles,
    required this.feedbacks,
    required this.appTheme,
    required this.failedLane,
    required this.isReady,
    required this.targetLineFactor,
    required this.tileHeightFactor,
    required this.startLabel,
    required this.qualityLabels,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final laneWidth = size.width / 4;

    final laneDividerPaint = Paint()
      ..color = appTheme.border.withValues(alpha: 0.35)
      ..strokeWidth = 1.5;

    for (int i = 1; i < 4; i++) {
      final x = i * laneWidth;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), laneDividerPaint);
    }

    final targetLineY = size.height * targetLineFactor;
    final targetLinePaint = Paint()
      ..color = appTheme.playBg.withValues(alpha: 0.55)
      ..strokeWidth = 2.5;
    canvas.drawLine(
      Offset(0, targetLineY),
      Offset(size.width, targetLineY),
      targetLinePaint,
    );

    if (failedLane >= 0) {
      final failRect = Rect.fromLTWH(
        failedLane * laneWidth,
        0,
        laneWidth,
        size.height,
      );
      final failPaint = Paint()
        ..color = const Color(0xFFEF4444).withValues(alpha: 0.35);
      canvas.drawRect(failRect, failPaint);
    }

    for (final tile in tiles) {
      if (tile.isHit && !tile.isHolding) continue;

      final tileX = tile.lane * laneWidth;
      final tileHeight = size.height * tileHeightFactor * tile.length;
      final tileY = (tile.y * size.height) - tileHeight;
      if (tileY > size.height || tile.y < 0) continue;

      final rect = Rect.fromLTWH(
        tileX + 2.0,
        tileY,
        laneWidth - 4.0,
        tileHeight,
      );

      if (tile.isLong) {
        final tailPaint = Paint()
          ..color = appTheme.tileTailColor.withValues(alpha: 0.70);
        canvas.drawRect(rect, tailPaint);

        if (tile.isHolding) {
          final progressHeight = tileHeight * tile.holdProgress;
          final filledRect = Rect.fromLTWH(
            tileX + 2.0,
            tileY + tileHeight - progressHeight,
            laneWidth - 4.0,
            progressHeight,
          );
          final hitFillPaint = Paint()
            ..color = appTheme.tileHitColor.withValues(alpha: 0.85);
          canvas.drawRect(filledRect, hitFillPaint);

          final contactY = tileY + tileHeight - progressHeight;
          final sparkPaint = Paint()
            ..color = Colors.white
            ..strokeWidth = 3.0;
          canvas.drawLine(
            Offset(tileX + 3.0, contactY),
            Offset(tileX + laneWidth - 3.0, contactY),
            sparkPaint,
          );
        }

        final borderPaint = Paint()
          ..color = tile.isHolding ? appTheme.tileHitColor : appTheme.tileBorder
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0;
        canvas.drawRect(rect, borderPaint);

        final centerX = tileX + laneWidth / 2;
        final circleRadius = min(16.0, (laneWidth - 14) / 2);
        final circleCenter = Offset(
          centerX,
          tileY + tileHeight - circleRadius - 8,
        );
        final lineTop = tileY + 8;
        final lineBottom = circleCenter.dy - circleRadius;

        if (lineBottom > lineTop) {
          final linePaint = Paint()
            ..color = Colors.white.withValues(
              alpha: tile.isHolding ? 0.95 : 0.75,
            )
            ..strokeWidth = 3.5
            ..strokeCap = StrokeCap.round;
          canvas.drawLine(
            Offset(centerX, lineTop),
            Offset(centerX, lineBottom),
            linePaint,
          );
          canvas.drawCircle(Offset(centerX, lineTop), 3.5, linePaint);
        }

        final circlePaint = Paint()
          ..color = tile.isHolding
              ? appTheme.tileHitColor
              : Colors.white.withValues(alpha: 0.95)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(circleCenter, circleRadius, circlePaint);

        final circleBorder = Paint()
          ..color = tile.isHolding ? Colors.white : appTheme.tileBorder
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5;
        canvas.drawCircle(circleCenter, circleRadius, circleBorder);

        final innerDot = Paint()
          ..color = tile.isHolding ? Colors.white : appTheme.tileColor
          ..style = PaintingStyle.fill;
        canvas.drawCircle(circleCenter, circleRadius * 0.45, innerDot);
      } else {
        final tilePaint = Paint()..color = appTheme.tileColor;
        canvas.drawRect(rect, tilePaint);

        final borderPaint = Paint()
          ..color = appTheme.tileBorder
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0;
        canvas.drawRect(rect, borderPaint);
      }

      if (isReady && tile.id == 0) {
        final tp = TextPainter(
          text: TextSpan(
            text: startLabel,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w900,
              fontFamily: 'Fredoka',
              letterSpacing: 1.5,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
          canvas,
          Offset(
            tileX + (laneWidth - tp.width) / 2,
            tileY + (tileHeight - tp.height) / 2,
          ),
        );
      }
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    for (final fb in feedbacks) {
      final elapsed = now - fb.timestamp;
      final progress = (elapsed / 700.0).clamp(0.0, 1.0);
      final alpha = (1.0 - progress).clamp(0.0, 1.0);
      final floatOffset = progress * 36.0;

      Color color;
      switch (fb.quality) {
        case HitQuality.perfect:
          color = const Color(0xFFFFB800);
          break;
        case HitQuality.great:
          color = appTheme.playBg;
          break;
        case HitQuality.good:
          color = appTheme.songsBg;
          break;
        default:
          color = const Color(0xFFEF4444);
      }

      final tp = TextPainter(
        text: TextSpan(
          text: qualityLabels[fb.quality] ?? '',
          style: TextStyle(
            color: color.withValues(alpha: alpha),
            fontSize: 20,
            fontWeight: FontWeight.w900,
            fontFamily: 'Fredoka',
            letterSpacing: 1.2,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      tp.paint(
        canvas,
        Offset(fb.x - (tp.width / 2), fb.y - floatOffset - (tp.height / 2)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GameTilesPainter oldDelegate) => true;
}
