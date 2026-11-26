import '../models/youtube_models.dart';

String trackSubtitle(YoutubeTrack track) {
  final duration = Duration(milliseconds: track.durationMs);
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  final time = '${duration.inMinutes}:$seconds';
  return track.artist.isEmpty ? time : '${track.artist} · $time';
}
