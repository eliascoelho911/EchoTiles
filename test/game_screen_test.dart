import 'dart:async';
import 'dart:io';

import 'package:echotiles/l10n/app_localizations.dart';
import 'package:echotiles/models/app_theme.dart';
import 'package:echotiles/models/beatmap.dart';
import 'package:echotiles/models/game_models.dart';
import 'package:echotiles/models/youtube_models.dart';
import 'package:echotiles/screens/game_screen.dart';
import 'package:echotiles/services/audio_service.dart';
import 'package:echotiles/services/storage_service.dart';
import 'package:echotiles/services/track_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({'haptic_enabled': false});
    await StorageService.init();
  });

  Future<void> openGame(
    WidgetTester tester,
    FakeAudio audio,
    int Function() now, {
    bool badChart = false,
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final track = YoutubeTrack.fromJson(trackJson());
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: GameScreen(
          song: SongItem.youtube(track, 'http://server:8000'),
          appTheme: AppThemes.fromName('amoled'),
          audio: audio,
          nowMicros: now,
          prepareYoutube: (_) async {
            if (badChart) throw const FormatException('Invalid chart');
            return PreparedTrack(
              File('/not-used-in-test.m4a'),
              Beatmap.fromJson(chartJson(), track: track),
            );
          },
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> begin(WidgetTester tester, void Function(int) now) async {
    await tester.tap(find.text('Começar · 3, 2, 1'));
    await tester.pump();
    now(3000000);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
  }

  testWidgets(
    'chart or player preparation failures never start a silent game',
    (tester) async {
      final audio = FakeAudio();
      await openGame(tester, audio, () => 0, badChart: true);
      expect(
        find.textContaining('O mapa desta faixa é inválido'),
        findsOneWidget,
      );
      expect(audio.playing, isFalse);
      expect(find.text('Começar · 3, 2, 1'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      final brokenPlayer = FakeAudio()..failPrepare = true;
      await openGame(tester, brokenPlayer, () => 0);
      expect(
        find.textContaining('Não foi possível preparar a gravação'),
        findsOneWidget,
      );
      expect(brokenPlayer.playing, isFalse);
    },
  );

  testWidgets(
    'playback failure after the count-in stops the game with an error',
    (tester) async {
      var now = 0;
      final audio = FakeAudio()..failStart = true;
      await openGame(tester, audio, () => now);
      await begin(tester, (value) => now = value);
      expect(
        find.textContaining('Não foi possível reproduzir'),
        findsOneWidget,
      );
      expect(audio.playing, isFalse);
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('OUT OF RHYTHM!'), findsNothing);
    },
  );

  testWidgets(
    'keeps the silence, plays doubles and a hold, and waits for audio completion',
    (tester) async {
      var now = 0;
      final audio = FakeAudio();
      await openGame(tester, audio, () => now);
      await begin(tester, (value) => now = value);
      expect(audio.playing, isTrue);
      expect(find.text('OUT OF RHYTHM!'), findsNothing);
      audio.sample(4000);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.tapAt(const Offset(150, 624));
      audio.sample(4500);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.tapAt(const Offset(50, 624));
      final hold = await tester.startGesture(const Offset(350, 624));
      audio.sample(4900);
      await tester.pump(const Duration(milliseconds: 16));
      await hold.up();
      audio.sample(10000);
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('SONG COMPLETED!'), findsNothing);
      expect(find.text('OUT OF RHYTHM!'), findsNothing);
      audio.complete.add(null);
      await tester.pump();
      expect(find.text('SONG COMPLETED!'), findsOneWidget);
      expect(StorageService.getStars('youtube_yt_demo'), 3);
    },
  );

  testWidgets('an empty tap and a missed tile end the game immediately', (
    tester,
  ) async {
    var now = 0;
    var audio = FakeAudio();
    await openGame(tester, audio, () => now);
    await begin(tester, (value) => now = value);
    audio.sample(4000);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tapAt(const Offset(250, 624));
    await tester.pump();
    expect(find.text('OUT OF RHYTHM!'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    audio = FakeAudio();
    now = 0;
    await openGame(tester, audio, () => now);
    await begin(tester, (value) => now = value);
    audio.sample(4600);
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('OUT OF RHYTHM!'), findsOneWidget);
  });

  testWidgets(
    'Android background freezes audio and notes until explicit resume',
    (tester) async {
      var now = 0;
      final audio = FakeAudio();
      await openGame(tester, audio, () => now);
      await begin(tester, (value) => now = value);
      audio.sample(4000);
      await tester.pump(const Duration(milliseconds: 16));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(audio.playing, isFalse);
      expect(find.text('PAUSED'), findsOneWidget);
      now += 5000000;
      await tester.pump(const Duration(seconds: 5));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.tap(find.text('RESUME'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(audio.playing, isTrue);
      expect(find.text('OUT OF RHYTHM!'), findsNothing);
      await tester.tapAt(const Offset(150, 624));
      await tester.pump();
      expect(find.text('OUT OF RHYTHM!'), findsNothing);
    },
  );
}

class FakeAudio implements GameAudio {
  final positions = StreamController<Duration>.broadcast(sync: true);
  final complete = StreamController<void>.broadcast(sync: true);
  bool failPrepare = false;
  bool failStart = false;
  bool playing = false;
  Duration position = Duration.zero;
  @override
  Stream<Duration> get onDurationChanged => const Stream.empty();
  @override
  Stream<Duration> get onPositionChanged => positions.stream;
  @override
  Stream<void> get onPlayerComplete => complete.stream;
  @override
  Stream<String> get onPlaybackError => const Stream.empty();
  @override
  Future<Duration?> prepareSong(String path) async {
    if (failPrepare) throw StateError('bad source');
    return const Duration(seconds: 12);
  }

  @override
  Future<void> startPrepared() async {
    if (failStart) throw StateError('decode failed');
    playing = true;
  }

  @override
  Future<Duration?> getCurrentPosition() async => position;
  @override
  Future<void> pauseSong() async {
    playing = false;
  }

  @override
  Future<void> resumeSong() => startPrepared();
  @override
  Future<void> stopSong() async {
    playing = false;
  }

  void sample(int ms) {
    position = Duration(milliseconds: ms);
    positions.add(position);
  }
}
