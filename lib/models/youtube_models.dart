enum ImportKind { auto, video, playlist }

int jsonInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int) throw FormatException('Campo $key inválido.');
  return value;
}

String jsonString(
  Map<String, dynamic> json,
  String key, {
  bool allowEmpty = false,
}) {
  final value = json[key];
  if (value is! String || (!allowEmpty && value.isEmpty)) {
    throw FormatException('Campo $key inválido.');
  }
  return value;
}

class YoutubeLink {
  final bool hasVideo;
  final bool hasPlaylist;
  const YoutubeLink._(this.hasVideo, this.hasPlaylist);

  bool get needsChoice => hasVideo && hasPlaylist;
  ImportKind get suggestedKind =>
      hasVideo ? ImportKind.video : ImportKind.playlist;

  factory YoutubeLink.parse(String value) {
    final uri = Uri.tryParse(value.trim());
    const hosts = {
      'youtube.com',
      'www.youtube.com',
      'm.youtube.com',
      'music.youtube.com',
      'youtu.be',
      'www.youtu.be',
    };
    if (uri == null ||
        !{'https', 'http'}.contains(uri.scheme) ||
        !hosts.contains(uri.host.toLowerCase()) ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException(
        'Cole um link de vídeo ou playlist do YouTube.',
      );
    }
    final video =
        (uri.host.endsWith('youtu.be') &&
            uri.pathSegments.isNotEmpty &&
            uri.pathSegments.first.isNotEmpty) ||
        (uri.path == '/watch' &&
            (uri.queryParameters['v']?.isNotEmpty ?? false)) ||
        (uri.pathSegments.length == 2 &&
            {'shorts', 'live', 'embed'}.contains(uri.pathSegments.first));
    final playlist = uri.queryParameters['list']?.isNotEmpty ?? false;
    if (!video && !playlist) {
      throw const FormatException(
        'O link precisa identificar um vídeo ou uma playlist.',
      );
    }
    return YoutubeLink._(video, playlist);
  }
}

class ImportFailure {
  final String code;
  final String message;
  final bool retryable;
  const ImportFailure(this.code, this.message, this.retryable);

  factory ImportFailure.fromJson(Map<String, dynamic> json) => ImportFailure(
    jsonString(json, 'code'),
    jsonString(json, 'message'),
    json['retryable'] == true,
  );
}

class ImportEntry {
  final String id;
  final int index;
  final String? title;
  final String status;
  final double? progress;
  final String? trackId;
  final ImportFailure? error;

  const ImportEntry({
    required this.id,
    required this.index,
    this.title,
    required this.status,
    this.progress,
    this.trackId,
    this.error,
  });

  factory ImportEntry.fromJson(Map<String, dynamic> json) {
    final progress = (json['progress'] as num?)?.toDouble();
    if (progress != null &&
        (!progress.isFinite || progress < 0 || progress > 1)) {
      throw const FormatException('Progresso inválido.');
    }
    final status = jsonString(json, 'status');
    if (!{
      'queued',
      'downloading',
      'preparing_audio',
      'analyzing',
      'ready',
      'failed',
    }.contains(status)) {
      throw const FormatException('Etapa de importação desconhecida.');
    }
    return ImportEntry(
      id: jsonString(json, 'id'),
      index: jsonInt(json, 'index'),
      title: json['title'] as String?,
      status: status,
      progress: progress,
      trackId: json['trackId'] as String?,
      error: json['error'] == null
          ? null
          : ImportFailure.fromJson(json['error'] as Map<String, dynamic>),
    );
  }
}

class ImportJob {
  final String id;
  final String status;
  final int? totalItems;
  final int readyItems;
  final int failedItems;
  final List<ImportEntry> items;
  final ImportFailure? error;

  const ImportJob({
    required this.id,
    required this.status,
    this.totalItems,
    required this.readyItems,
    required this.failedItems,
    required this.items,
    this.error,
  });

  bool get isFinished => {'completed', 'partial', 'failed'}.contains(status);

  factory ImportJob.fromJson(Map<String, dynamic> json) {
    final status = jsonString(json, 'status');
    if (!{
      'queued',
      'resolving',
      'running',
      'completed',
      'partial',
      'failed',
    }.contains(status)) {
      throw const FormatException('Estado de importação desconhecido.');
    }
    return ImportJob(
      id: jsonString(json, 'id'),
      status: status,
      totalItems: json['totalItems'] as int?,
      readyItems: jsonInt(json, 'readyItems'),
      failedItems: jsonInt(json, 'failedItems'),
      error: json['error'] == null
          ? null
          : ImportFailure.fromJson(json['error'] as Map<String, dynamic>),
      items: List.unmodifiable(
        (json['items'] as List).map(
          (item) => ImportEntry.fromJson(item as Map<String, dynamic>),
        ),
      ),
    );
  }
}

class YoutubeTrack {
  final String id;
  final String title;
  final String artist;
  final int durationMs;
  final String videoId;
  final String sourceUrl;
  final String audioUrl;
  final String audioSha256;
  final int audioBytes;
  final String chartId;
  final String chartUrl;
  final double? bpm;

  const YoutubeTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.durationMs,
    required this.videoId,
    required this.sourceUrl,
    required this.audioUrl,
    required this.audioSha256,
    required this.audioBytes,
    required this.chartId,
    required this.chartUrl,
    this.bpm,
  });

  factory YoutubeTrack.fromJson(Map<String, dynamic> json) {
    final hash = jsonString(json, 'audioSha256').toLowerCase();
    final duration = jsonInt(json, 'durationMs');
    final bytes = jsonInt(json, 'audioBytes');
    final bpm = (json['bpm'] as num?)?.toDouble();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
        duration <= 0 ||
        bytes <= 0 ||
        (bpm != null && (!bpm.isFinite || bpm <= 0))) {
      throw const FormatException('Metadados de áudio inválidos.');
    }
    final audioUrl = jsonString(json, 'audioUrl');
    final chartUrl = jsonString(json, 'chartUrl');
    for (final path in [audioUrl, chartUrl]) {
      final uri = Uri.tryParse(path);
      if (uri == null ||
          uri.hasScheme ||
          uri.hasAuthority ||
          !path.startsWith('/') ||
          path.startsWith('//')) {
        throw const FormatException('Endereço de mídia inválido.');
      }
    }
    return YoutubeTrack(
      id: jsonString(json, 'id'),
      title: jsonString(json, 'title'),
      artist: jsonString(json, 'artist', allowEmpty: true),
      durationMs: duration,
      videoId: jsonString(json, 'videoId'),
      sourceUrl: jsonString(json, 'sourceUrl'),
      audioUrl: audioUrl,
      audioSha256: hash,
      audioBytes: bytes,
      chartId: jsonString(json, 'chartId'),
      chartUrl: chartUrl,
      bpm: bpm,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'durationMs': durationMs,
    'videoId': videoId,
    'sourceUrl': sourceUrl,
    'audioUrl': audioUrl,
    'audioSha256': audioSha256,
    'audioBytes': audioBytes,
    'chartId': chartId,
    'chartUrl': chartUrl,
    'bpm': bpm,
  };
}
