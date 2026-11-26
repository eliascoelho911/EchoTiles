import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:echotiles/services/audio_service.dart';
import 'package:echotiles/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'stop requested during native startup still wins when startup completes',
    () async {
      SharedPreferences.setMockInitialValues({});
      await StorageService.init();
      final native = DelayedNativePlayer();
      final audio = AudioService.withPlayer(native);
      await audio.prepareSong('/cache/verified.m4a');
      final starting = audio.startPrepared();
      await native.starting.future;
      final stopping = audio.stopSong();
      native.allowStart.complete();
      await Future.wait([starting, stopping]);
      expect(native.playing, isFalse);
    },
  );
}

class DelayedNativePlayer extends Fake implements AudioPlayer {
  final starting = Completer<void>();
  final allowStart = Completer<void>();
  bool playing = false;
  @override
  Future<void> stop() async {
    playing = false;
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setPlaybackRate(double rate) async {}
  @override
  Future<void> setSource(Source source) async {}
  @override
  Future<void> seek(Duration duration) async {}
  @override
  Future<Duration?> getDuration() async => const Duration(seconds: 12);
  @override
  Future<void> resume() async {
    starting.complete();
    await allowStart.future;
    playing = true;
  }
}
