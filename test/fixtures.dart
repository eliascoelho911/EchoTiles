const audioHash =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

Map<String, dynamic> trackJson({String id = 'yt_demo'}) => {
  'id': id,
  'title': 'Faixa de teste',
  'artist': 'Canal',
  'durationMs': 12000,
  'videoId': 'BaW_jenozKc',
  'sourceUrl': 'https://www.youtube.com/watch?v=BaW_jenozKc',
  'audioUrl': '/api/tracks/$id/audio',
  'audioSha256': audioHash,
  'audioBytes': 3,
  'chartId': 'chart_a',
  'chartUrl': '/api/charts/chart_a',
  'bpm': 120.0,
};

Map<String, dynamic> chartJson({String trackId = 'yt_demo'}) => {
  'schemaVersion': 1,
  'id': 'chart_a',
  'trackId': trackId,
  'audioSha256': audioHash,
  'generatorVersion': 'rhythm-v1',
  'lanes': 4,
  'durationMs': 12000,
  'bpmEstimate': 120.0,
  'notes': [
    {'id': 0, 'timeMs': 4000, 'lane': 1, 'type': 'tap'},
    {'id': 1, 'timeMs': 4500, 'lane': 0, 'type': 'tap'},
    {'id': 2, 'timeMs': 4500, 'lane': 3, 'type': 'hold', 'durationMs': 400},
  ],
};
