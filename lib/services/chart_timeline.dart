import 'dart:math';

import '../models/beatmap.dart';

class NoteProjection {
  final double y;
  final double height;
  const NoteProjection(this.y, this.height);
}

/// A frame only projects a timestamp. It never adds or moves musical events.
class ChartTimeline {
  final Beatmap chart;
  final double scrollSpeed;
  final double targetLine;
  final double tapHeight;
  const ChartTimeline(
    this.chart, {
    this.scrollSpeed = 0.5,
    this.targetLine = 0.8,
    this.tapHeight = 0.2,
  });

  NoteProjection project(ChartNote note, double audioMs) => NoteProjection(
    targetLine + scrollSpeed * (audioMs - note.timeMs) / 1000,
    note.type == NoteType.hold
        ? max(tapHeight, scrollSpeed * note.durationMs / 1000)
        : tapHeight,
  );

  bool isComplete({
    required bool audioFinished,
    required Set<int> resolvedIds,
  }) =>
      audioFinished &&
      chart.notes.every((note) => resolvedIds.contains(note.id));
}
