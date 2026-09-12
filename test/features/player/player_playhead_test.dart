import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';

import '../../support/player_harness.dart';

/// **Telling the server where the player is.**
///
/// The server otherwise infers the playhead from the byte ranges the player
/// asks for, and those do not carry it: mpv reads the container index with
/// the same kind of request it seeks with, and keeps a second reader
/// crawling that index while it plays. Guessing wrong moves the retention
/// window off the film and takes the pieces the viewer is waiting on with
/// it, which is what the field log of 2026-09-12 is.
///
/// So these are about the two numbers leaving the app: the player's own
/// byte offset, and its own position in the picture. Nothing here is about
/// what the server does with them.
void main() {
  testWidgets('the player says where it is, in both units', (tester) async {
    final harness = PlayerHarness(
      configureEngine: (engine) => engine.playheadReport = const PlayheadReport(
        streamPos: 3304543293,
        film: Duration(seconds: 939),
      ),
    );
    await harness.pump(tester);

    harness.engine.emitPosition(const Duration(seconds: 939));
    await tester.pump();

    expect(harness.playhead.reports, isNotEmpty);
    final report = harness.playhead.reports.last;
    expect(
      report.offset,
      3304543293,
      reason: 'the demuxer own byte offset, not one derived from the time',
    );
    expect(report.filmSeconds, 939);
  });

  testWidgets('a backend that cannot say where it is reports nothing', (
    tester,
  ) async {
    // `playheadReport` defaults to null: no libmpv, or a demuxer that does
    // not exist yet. The server has an answer of its own for exactly this.
    final harness = PlayerHarness();
    await harness.pump(tester);

    harness.engine.emitPosition(const Duration(seconds: 939));
    await tester.pump();

    expect(harness.playhead.reports, isEmpty);
  });
}
