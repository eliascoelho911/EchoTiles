import 'package:echotiles/models/game_models.dart';
import 'package:echotiles/models/youtube_models.dart';
import 'package:echotiles/services/song_catalog.dart';
import 'package:echotiles/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.init();
  });

  test(
    'repeated ready polls add a track once and preserve the local library',
    () async {
      final local = SongItem.fromJson({
        'id': 'custom_1',
        'title': 'Local',
        'artist': 'Eu',
        'assetAudio': '/music/local.mp3',
      });
      await StorageService.addCustomSong(local);
      final track = YoutubeTrack.fromJson(trackJson());
      await StorageService.mergeYoutubeTracks([track], 'http://server:8000');
      await StorageService.mergeYoutubeTracks([track], 'http://server:8000');
      await StorageService.setHighScore('youtube_yt_demo', 456);
      final songs = SongCatalog.getSongs();
      expect(songs.map((s) => s.id).toSet().length, 3);
      expect(songs.where((s) => s.isYoutube).single.highScore, 456);
      expect(
        songs.where((s) => s.isYoutube).single.youtubeTrack?.audioSha256,
        audioHash,
      );
      expect(
        songs.firstWhere((s) => s.id == 'custom_1').assetAudio,
        '/music/local.mp3',
      );
      expect(
        songs.firstWhere((s) => s.id == 'default_brain_dance').assetAudio,
        startsWith('assets/'),
      );
    },
  );
}
