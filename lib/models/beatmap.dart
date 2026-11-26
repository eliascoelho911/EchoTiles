import 'youtube_models.dart';

enum NoteType { tap, hold }

class ChartNote {
  final int id;
  final int timeMs;
  final int lane;
  final NoteType type;
  final int durationMs;

  const ChartNote({
    required this.id,
    required this.timeMs,
    required this.lane,
    required this.type,
    this.durationMs = 0,
  });

  int get endMs => timeMs + durationMs;

  factory ChartNote.fromJson(Map<String, dynamic> json) {
    final type = switch (json['type']) {
      'tap' => NoteType.tap,
      'hold' => NoteType.hold,
      _ => throw const FormatException('Tipo de peça inválido.'),
    };
    return ChartNote(
      id: jsonInt(json, 'id'),
      timeMs: jsonInt(json, 'timeMs'),
      lane: jsonInt(json, 'lane'),
      type: type,
      durationMs: json.containsKey('durationMs')
          ? jsonInt(json, 'durationMs')
          : 0,
    );
  }
}

class Beatmap {
  final int durationMs;
  final List<ChartNote> notes;

  const Beatmap({required this.durationMs, required this.notes});

  factory Beatmap.fromJson(
    Map<String, dynamic> json, {
    required YoutubeTrack track,
  }) {
    if (jsonInt(json, 'schemaVersion') != 1 ||
        jsonInt(json, 'lanes') != 4 ||
        json['id'] != track.chartId ||
        json['trackId'] != track.id ||
        jsonInt(json, 'durationMs') != track.durationMs ||
        json['audioSha256'] is! String ||
        (json['audioSha256'] as String).toLowerCase() != track.audioSha256 ||
        json['generatorVersion'] is! String ||
        (json['generatorVersion'] as String).isEmpty) {
      throw const FormatException('Mapa incompatível com a gravação.');
    }
    final rawNotes = json['notes'];
    if (rawNotes is! List || rawNotes.isEmpty || rawNotes.length > 100000) {
      throw const FormatException('Mapa sem peças válidas.');
    }
    final notes = <ChartNote>[];
    final ids = <int>{};
    final laneEnds = List<int>.filled(4, -1);
    final laneStarts = List<int>.filled(4, -1);
    int previousTime = -1;
    int previousId = -1;
    int simultaneous = 0;
    for (final raw in rawNotes) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('Peça inválida.');
      }
      final note = ChartNote.fromJson(raw);
      if (note.id < 0 ||
          !ids.add(note.id) ||
          note.timeMs < 0 ||
          note.timeMs >= track.durationMs ||
          note.lane < 0 ||
          note.lane > 3 ||
          note.timeMs < previousTime ||
          (note.timeMs == previousTime && note.id <= previousId) ||
          (note.type == NoteType.hold
              ? note.durationMs <= 0
              : note.durationMs != 0) ||
          note.endMs > track.durationMs) {
        throw const FormatException(
          'Peças fora de ordem ou dos limites do áudio.',
        );
      }
      simultaneous = note.timeMs == previousTime ? simultaneous + 1 : 1;
      if (simultaneous > 2 ||
          laneStarts[note.lane] == note.timeMs ||
          laneEnds[note.lane] > note.timeMs) {
        throw const FormatException('Peças conflitantes na mesma coluna.');
      }
      laneStarts[note.lane] = note.timeMs;
      laneEnds[note.lane] = note.endMs;
      previousTime = note.timeMs;
      previousId = note.id;
      notes.add(note);
    }
    return Beatmap(
      durationMs: track.durationMs,
      notes: List.unmodifiable(notes),
    );
  }
}
