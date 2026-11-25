import 'dart:math';

/// Native position is authoritative; interpolation is bounded when samples stop.
class AudioClock {
  final int Function() _now;
  final int maxExtrapolationMicros;
  Duration _anchor = Duration.zero;
  int _anchorMicros = 0;
  bool _running = false;
  bool _countIn = false;

  AudioClock({
    required int Function() nowMicros,
    this.maxExtrapolationMicros = 80000,
  }) : _now = nowMicros;

  Duration get position {
    if (!_running) return _anchor;
    final elapsed = max(0, _now() - _anchorMicros);
    if (_countIn) {
      return Duration(microseconds: min(0, _anchor.inMicroseconds + elapsed));
    }
    return _anchor +
        Duration(microseconds: min(elapsed, maxExtrapolationMicros));
  }

  void update(Duration position) {
    _anchor = position;
    _anchorMicros = _now();
  }

  void start(Duration position) {
    _countIn = false;
    update(position);
    _running = true;
  }

  void startCountIn(Duration duration) {
    _countIn = true;
    update(-duration);
    _running = true;
  }

  void pause() {
    update(position);
    _running = false;
  }

  void resume() {
    _anchorMicros = _now();
    _running = true;
  }
}
