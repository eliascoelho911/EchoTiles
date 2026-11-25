import 'package:echotiles/models/beatmap.dart';
import 'package:echotiles/models/youtube_models.dart';
import 'package:echotiles/services/audio_clock.dart';
import 'package:echotiles/services/chart_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  late ChartTimeline timeline;
  setUp(
    () => timeline = ChartTimeline(
      Beatmap.fromJson(chartJson(), track: YoutubeTrack.fromJson(trackJson())),
      scrollSpeed: 0.5,
    ),
  );

  test(
    '30, 60 and 120 Hz and dropped frames project the same absolute position',
    () {
      final positions = <double>[];
      for (final fps in [30, 60, 120]) {
        for (var frame = 0; frame < fps * 4; frame++) {
          timeline.project(timeline.chart.notes.first, frame * 1000 / fps);
        }
        positions.add(timeline.project(timeline.chart.notes.first, 4000).y);
      }
      positions.add(timeline.project(timeline.chart.notes.first, 100).y);
      positions[3] = timeline.project(timeline.chart.notes.first, 4000).y;
      expect(positions, everyElement(closeTo(0.8, 0.000001)));
      expect(
        timeline.project(timeline.chart.notes.first, 4200).y,
        closeTo(0.9, 0.000001),
      );
    },
  );

  test(
    'a silent intro and negative count-in retain the first attack timestamp',
    () {
      final note = timeline.chart.notes.first;
      expect(timeline.project(note, -3000).y, lessThan(0));
      expect(timeline.project(note, 0).y, closeTo(-1.2, 0.000001));
      expect(timeline.project(note, 4000).y, closeTo(0.8, 0.000001));
      expect(
        timeline.project(timeline.chart.notes.last, 4500).height,
        closeTo(0.2, 0.000001),
      );
      expect(
        timeline.isComplete(audioFinished: false, resolvedIds: {0, 1, 2}),
        isFalse,
      );
      expect(
        timeline.isComplete(audioFinished: true, resolvedIds: {0, 1}),
        isFalse,
      );
      expect(
        timeline.isComplete(audioFinished: true, resolvedIds: {0, 1, 2}),
        isTrue,
      );
    },
  );

  test(
    'pause freezes the clock and resuming never includes time spent paused',
    () {
      var micros = 0;
      final clock = AudioClock(nowMicros: () => micros);
      clock.start(const Duration(seconds: 4));
      micros = 40000;
      clock.pause();
      expect(clock.position.inMilliseconds, 4040);
      micros = 5000000;
      expect(clock.position.inMilliseconds, 4040);
      clock.resume();
      micros += 20000;
      expect(clock.position.inMilliseconds, 4060);
      clock.update(const Duration(milliseconds: 4055));
      expect(clock.position.inMilliseconds, 4055);
    },
  );

  test('missing audio updates cannot keep the game scrolling silently', () {
    var micros = 0;
    final clock = AudioClock(nowMicros: () => micros);
    clock.start(const Duration(seconds: 1));
    micros = 2000000;
    expect(clock.position.inMilliseconds, 1080);
    clock.update(const Duration(seconds: 1));
    expect(clock.position.inMilliseconds, 1000);
  });

  test(
    'negative visual count-in can pause and cannot advance past audio zero',
    () {
      var micros = 0;
      final clock = AudioClock(nowMicros: () => micros);
      clock.startCountIn(const Duration(seconds: 3));
      micros = 1000000;
      expect(clock.position.inMilliseconds, -2000);
      clock.pause();
      micros = 5000000;
      expect(clock.position.inMilliseconds, -2000);
      clock.resume();
      micros = 8000000;
      expect(clock.position.inMilliseconds, 0);
    },
  );
}
