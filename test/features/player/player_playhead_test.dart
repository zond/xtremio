import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../../support/fixtures.dart';
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
  testWidgets('the player says where it is and how long the film is', (
    tester,
  ) async {
    final harness = PlayerHarness(
      configureEngine: (engine) => engine.playheadReport = const PlayheadReport(
        streamPos: 3304543293,
        film: Duration(seconds: 939),
      ),
    );
    await harness.pump(tester);
    // No position has been reported and none needs to be: reporting runs on
    // a clock from the moment the media is open, because start-up is when
    // the server most needs to be told and when a player says least.
    harness.engine.emitDuration(const Duration(seconds: 6669));
    harness.engine.emitPlaying(true);
    await tester.pump();
    await tester.pump();

    expect(harness.playhead.reports, isNotEmpty);
    final report = harness.playhead.reports.last;
    expect(
      report.offset,
      3304543293,
      reason: 'the demuxer own byte offset, not one derived from the time',
    );
    expect(
      report.durationSeconds,
      6669,
      reason: "the film's length, which with the file's size is its bitrate",
    );
  });

  testWidgets('reports for a stream whose addon named no file index', (
    tester,
  ) async {
    // **The case every field log was.** An addon often does not say which
    // file of the torrent its stream is; the server then picks the largest
    // and answers with the index it chose, and the URL the core builds
    // carries that resolved index. Keyed off the addon's own `fileIdx`,
    // reporting simply never happened -- which is why the server placed the
    // window from reads in every log of this feature.
    final fixture = loadPlayerFixture();
    final stream =
        (fixture['selected'] as Map<String, dynamic>)['stream']
            as Map<String, dynamic>;
    stream.remove('fileIdx');
    expect(stream['fileIdx'], isNull, reason: 'the addon named no file');

    final harness = PlayerHarness(
      player: fixture,
      configureEngine: (engine) => engine.playheadReport = const PlayheadReport(
        streamPos: 3304543293,
        film: Duration(seconds: 939),
      ),
    );
    await harness.pump(tester);
    harness.engine.emitPlaying(true);
    await tester.pump();
    await tester.pump();

    expect(
      harness.playhead.reports,
      isNotEmpty,
      reason: 'the URL the player is reading says which file it is',
    );
    expect(harness.playhead.reports.last.fileIdx, 0);
  });

  testWidgets('it keeps reporting while the position is not moving', (
    tester,
  ) async {
    // A stall is when the server most needs to know where the player is,
    // and exactly when a player stops saying: positions come only while
    // playback runs, so a report hung off them would go stale after fifteen
    // seconds of the one thing that was still true.
    final harness = PlayerHarness(
      configureEngine: (engine) => engine.playheadReport = const PlayheadReport(
        streamPos: 3304543293,
        film: Duration(seconds: 939),
      ),
    );
    await harness.pump(tester);
    harness.engine.emitPlaying(true);
    await tester.pump();

    for (var tick = 0; tick < 4; tick++) {
      await tester.pump(PlayerScreen.timeReportInterval);
    }
    expect(harness.playhead.reports.length, greaterThan(2));
  });

  testWidgets('a backend that cannot say where it is reports nothing', (
    tester,
  ) async {
    // `playheadReport` defaults to null: no libmpv, or a demuxer that does
    // not exist yet. The server has an answer of its own for exactly this.
    final harness = PlayerHarness();
    await harness.pump(tester);

    harness.engine.emitPlaying(true);
    await tester.pump();
    await tester.pump();

    expect(harness.playhead.reports, isEmpty);
  });
}
