import 'dart:convert';
import 'dart:io';

import 'package:echotiles/models/youtube_models.dart';
import 'package:echotiles/services/track_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('echotiles-cache-test');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'publishes verified local audio and chart and can reuse them offline',
    () async {
      final track = YoutubeTrack.fromJson(trackJson());
      final cache = TrackCache(root, client: mediaClient());
      final ready = await cache.prepare(track, 'http://server:8000');
      expect(await ready.audioFile.readAsString(), 'abc');
      expect(ready.chart.notes.first.timeMs, 4000);
      final offline = TrackCache(
        root,
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      final reused = await offline.prepare(track, 'http://server:8000');
      expect(await reused.audioFile.readAsString(), 'abc');
    },
  );

  test('a truncated download never becomes ready and can be retried', () async {
    final track = YoutubeTrack.fromJson(trackJson());
    await File('${root.path}/abandoned.part').writeAsString('partial');
    final cache = TrackCache(root, client: mediaClient(audio: 'ab'));
    await expectLater(
      cache.prepare(track, 'http://server:8000'),
      throwsA(isA<Exception>()),
    );
    expect(await File('${root.path}/$audioHash.m4a').exists(), isFalse);
    final ready = await TrackCache(
      root,
      client: mediaClient(),
    ).prepare(track, 'http://server:8000');
    expect(await ready.audioFile.readAsString(), 'abc');
    expect(
      await root.list().where((f) => f.path.endsWith('.part')).isEmpty,
      isTrue,
    );
  });

  test(
    'a same-size corrupted cache is rejected rather than used offline',
    () async {
      final track = YoutubeTrack.fromJson(trackJson());
      final ready = await TrackCache(
        root,
        client: mediaClient(),
      ).prepare(track, 'http://server:8000');
      await ready.audioFile.writeAsString('bad');
      final offline = TrackCache(
        root,
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      await expectLater(
        offline.prepare(track, 'http://server:8000'),
        throwsA(isA<Exception>()),
      );
      expect(await ready.audioFile.exists(), isFalse);
    },
  );

  test(
    'chart mismatch and wrong audio hash are fatal without a random fallback',
    () async {
      final track = YoutubeTrack.fromJson(trackJson());
      await expectLater(
        TrackCache(
          root,
          client: mediaClient(chart: {...chartJson(), 'durationMs': 2}),
        ).prepare(track, 'http://server:8000'),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        TrackCache(
          root,
          client: mediaClient(audio: 'bad'),
        ).prepare(track, 'http://server:8000'),
        throwsA(isA<Exception>()),
      );
    },
  );

  test(
    'evicts older tracks before reserving space and refuses an oversized track',
    () async {
      final track = YoutubeTrack.fromJson(trackJson());
      final budget = utf8.encode(jsonEncode(chartJson())).length + 16;
      final cache = TrackCache(root, client: mediaClient(), maxBytes: budget);
      final first = await cache.prepare(track, 'http://server:8000');
      final secondJson = {
        ...trackJson(id: 'second'),
        'audioSha256':
            'cb8379ac2098aa165029e3938a51da0bcecfc008fd6795f401178647f96c5b34',
      };
      final nextChart = {
        ...chartJson(trackId: 'second'),
        'audioSha256': secondJson['audioSha256'],
      };
      final second = await TrackCache(
        root,
        client: mediaClient(audio: 'def', chart: nextChart),
        maxBytes: budget,
      ).prepare(YoutubeTrack.fromJson(secondJson), 'http://server:8000');
      expect(await first.audioFile.exists(), isFalse);
      expect(await second.audioFile.readAsString(), 'def');
      final oversized = YoutubeTrack.fromJson({
        ...trackJson(),
        'audioBytes': budget + 1,
      });
      await expectLater(
        cache.prepare(oversized, 'http://server:8000'),
        throwsA(isA<Exception>()),
      );
      expect(await cache.sizeBytes(), lessThanOrEqualTo(budget));
    },
  );
}

MockClient mediaClient({String audio = 'abc', Map<String, dynamic>? chart}) =>
    MockClient(
      (request) async => request.url.path.contains('/charts/')
          ? http.Response(jsonEncode(chart ?? chartJson()), 200)
          : http.Response(audio, 200, headers: {'content-type': 'audio/mp4'}),
    );
