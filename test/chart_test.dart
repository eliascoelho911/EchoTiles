import 'package:echotiles/models/beatmap.dart';
import 'package:echotiles/models/youtube_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  test(
    'requires integer duration and schema even if a decimal has the same value',
    () {
      final track = YoutubeTrack.fromJson(trackJson());
      for (final change in [
        {'schemaVersion': 1.0},
        {'lanes': 4.0},
        {'durationMs': 12000.0},
      ]) {
        expect(
          () => Beatmap.fromJson({...chartJson(), ...change}, track: track),
          throwsFormatException,
        );
      }
    },
  );

  test('rejects invalid track sizes, hashes and nonrelative media URLs', () {
    for (final change in <Map<String, dynamic>>[
      {'durationMs': 0},
      {'audioBytes': 0},
      {'audioSha256': 'short'},
      {'audioUrl': 'https://other.test/audio'},
      {'chartUrl': '//other.test/chart'},
    ]) {
      expect(
        () => YoutubeTrack.fromJson({...trackJson(), ...change}),
        throwsFormatException,
      );
    }
  });
  test(
    'preserves silence, simultaneous attacks and a hold from the contract',
    () {
      final track = YoutubeTrack.fromJson(trackJson());
      final chart = Beatmap.fromJson(chartJson(), track: track);
      expect(chart.notes.map((n) => n.timeMs), [4000, 4500, 4500]);
      expect(chart.notes.last.durationMs, 400);
      expect(chart.notes.last.lane, 3);
    },
  );

  test('rejects charts that cannot match the prepared four-lane audio', () {
    final track = YoutubeTrack.fromJson(trackJson());
    for (final changes in <Map<String, dynamic>>[
      {'schemaVersion': 2},
      {'lanes': 5},
      {'durationMs': 11000},
      {'audioSha256': '0' * 64},
      {'trackId': 'other'},
      {'id': 'other'},
      {'notes': []},
      {
        'notes': [
          {'id': 0, 'timeMs': 12000, 'lane': 0, 'type': 'tap'},
        ],
      },
      {
        'notes': [
          {'id': 0, 'timeMs': -1, 'lane': 0, 'type': 'tap'},
        ],
      },
      {
        'notes': [
          {'id': 0, 'timeMs': 0, 'lane': 4, 'type': 'tap'},
        ],
      },
      {
        'notes': [
          {'id': 0, 'timeMs': 1.5, 'lane': 0, 'type': 'tap'},
        ],
      },
      {
        'notes': [
          {'id': 0, 'timeMs': 0, 'lane': 0, 'type': 'piano'},
        ],
      },
      {
        'notes': [
          {'id': 0, 'timeMs': 0, 'lane': 0, 'type': 'hold'},
        ],
      },
      {
        'notes': [
          {
            'id': 0,
            'timeMs': 11999,
            'lane': 0,
            'type': 'hold',
            'durationMs': 2,
          },
        ],
      },
      {
        'notes': [
          {'id': 0, 'timeMs': 0, 'lane': 0, 'type': 'tap', 'durationMs': 2},
        ],
      },
    ]) {
      expect(
        () => Beatmap.fromJson({...chartJson(), ...changes}, track: track),
        throwsFormatException,
        reason: changes.toString(),
      );
    }
  });

  test(
    'rejects unsorted, duplicate, overlapping or three simultaneous notes',
    () {
      final track = YoutubeTrack.fromJson(trackJson());
      final cases = [
        [note(0, 400), note(1, 300)],
        [note(0, 300), note(0, 400)],
        [note(2, 300), note(1, 300, lane: 1)],
        [note(0, 300), note(1, 300)],
        [note(0, 300), note(1, 300, lane: 1), note(2, 300, lane: 2)],
        [note(0, 300, hold: 500), note(1, 700)],
      ];
      for (final notes in cases) {
        expect(
          () =>
              Beatmap.fromJson({...chartJson(), 'notes': notes}, track: track),
          throwsFormatException,
          reason: notes.toString(),
        );
      }
    },
  );
}

Map<String, dynamic> note(int id, int time, {int lane = 0, int hold = 0}) => {
  'id': id,
  'timeMs': time,
  'lane': lane,
  'type': hold > 0 ? 'hold' : 'tap',
  'durationMs': hold,
};
