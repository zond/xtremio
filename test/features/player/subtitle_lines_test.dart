import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/subtitle_lines.dart';

/// The subtitle text over a film on the surface, drawn the way media_kit's
/// own subtitle view draws it over the texture.
void main() {
  testWidgets('shows mpv\'s current lines, trimmed, one per row, and follows '
      'them', (tester) async {
    final lines = StreamController<List<String>>();
    addTearDown(lines.close);
    await tester.pumpWidget(
      MaterialApp(
        home: SubtitleLines(
          lines: lines.stream,
          initial: const ['  Hello  ', '   ', 'there'],
          style: const TextStyle(fontSize: 32),
          padding: EdgeInsets.zero,
        ),
      ),
    );
    expect(find.text('Hello\nthere'), findsOneWidget);

    lines.add(const ['Goodbye']);
    await tester.pumpAndSettle();
    expect(find.text('Goodbye'), findsOneWidget);
    expect(find.text('Hello\nthere'), findsNothing);
  });

  test('scales as media_kit does: full size from 1920x1080 up, by the '
      'square root of the area below it', () {
    expect(SubtitleLines.scaleFor(const Size(1920, 1080)), 1.0);
    expect(SubtitleLines.scaleFor(const Size(3840, 2160)), 1.0);
    expect(SubtitleLines.scaleFor(const Size(960, 540)), closeTo(0.5, 1e-9));
  });
}
