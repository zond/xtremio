import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_stats.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/torrent_stall_overlay.dart';

import '../../support/diagnostics_capture.dart';
import '../../support/player_harness.dart';

/// **Waiting is not the same question as mpv buffering.**
///
/// mpv's flag means its demuxer cache ran dry during playback. It does not
/// cover a read blocked in the server while mpv seeks, and on 2026-09-12
/// that is exactly what the viewer got: the flag cleared when the container
/// index arrived, the overlay came down, and nothing played for three and a
/// half minutes. There is no second stall anywhere in that log.
void main() {
  testWidgets('a position that stops moving brings the overlay back', (
    tester,
  ) async {
    final harness = PlayerHarness();
    await harness.pump(tester);
    // The file is open and known, so the start-up overlay's own polling
    // is over: what polls from here is the stall's.
    harness.engine.emitDuration(const Duration(seconds: 6669));
    await pumpEvents(tester);

    // Playing, with mpv perfectly happy: no buffering flag at all.
    harness.engine.emitPlaying(true);
    harness.engine.emitBuffering(false);
    harness.engine.emitPosition(const Duration(seconds: 939));
    await tester.pump();
    expect(
      find.textContaining(TorrentStallOverlay.waiting),
      findsNothing,
      reason: 'a player that is playing is not waiting',
    );

    // And then it stops, without mpv saying anything about it.
    await tester.pump(PlayerScreen.stuckAfter + PlayerScreen.stuckInterval);
    expect(find.textContaining(TorrentStallOverlay.waiting), findsOneWidget);

    // While it is stuck the stats are polled at the stall cadence.
    final beforeStuck = harness.calls.where((c) => c == 'stats').length;
    await tester.pump(const Duration(seconds: 10));
    final whileStuck =
        harness.calls.where((c) => c == 'stats').length - beforeStuck;
    expect(
      whileStuck,
      greaterThan(0),
      reason: 'a stuck player polls the torrent for what it is waiting on',
    );

    // Moving again takes it away. Twice, because the engine's event lands
    // in one frame and the rebuild it asks for happens in the next.
    harness.engine.emitPosition(const Duration(seconds: 940));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining(TorrentStallOverlay.waiting), findsNothing);

    // And the stall cadence with it: whatever polls while a film plays
    // untroubled polls less often than the stall's two seconds.
    final beforeRecovered = harness.calls.where((c) => c == 'stats').length;
    await tester.pump(const Duration(seconds: 10));
    final recovered =
        harness.calls.where((c) => c == 'stats').length - beforeRecovered;
    expect(
      recovered,
      lessThan(whileStuck),
      reason:
          'the stats poll kept the stall cadence after the position moved on: '
          '$recovered polls in ten seconds against $whileStuck while stuck',
    );
  });

  testWidgets('a position that stops moving writes down what mpv is doing', (
    tester,
  ) async {
    // A frozen picture is a decoder that cannot keep up or a read that
    // never arrived, and only these numbers tell them apart. They are
    // sampled twice a second and kept nowhere unless the stats panel is
    // open, which on a television it never is.
    final lines = captureDiagnostics();
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(seconds: 6669));
    harness.engine.emitPlaying(true);
    harness.engine.emitBuffering(false);
    harness.engine.emitPosition(const Duration(seconds: 5113));
    await pumpEvents(tester);

    await tester.pump(PlayerScreen.stuckAfter + PlayerScreen.stuckInterval);
    harness.engine.emitStats(
      const PlaybackStats(
        hwdec: 'no',
        videoCodec: 'hevc (Main 10)',
        audioCodec: 'truehd',
        width: 3840,
        height: 2160,
        outputFps: 0,
        containerFps: 23.976,
        droppedFrames: 0,
        decoderDroppedFrames: 0,
        cacheDuration: Duration(seconds: 12),
        pausedForCache: false,
      ),
    );
    await pumpEvents(tester);

    expect(
      lines,
      contains(
        'info player what mpv is doing with it: hwdec=no '
        'video=hevc (Main 10) 3840x2160 audio=truehd fps=0.0/23.976 '
        'dropped=0/0 cache=12000ms paused_for_cache=false',
      ),
    );
  });

  testWidgets('a frame or two is not playing again', (tester) async {
    // What froze a 4K remux on the television for seventy seconds: the
    // position moved a fraction of a second, the flag cleared, the log
    // said "playing again", and the detector -- counting from zero
    // again -- never spoke about the minute that followed.
    final lines = captureDiagnostics();
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(seconds: 6669));
    harness.engine.emitPlaying(true);
    harness.engine.emitBuffering(false);
    harness.engine.emitPosition(const Duration(seconds: 5113));
    await pumpEvents(tester);
    await tester.pump(PlayerScreen.stuckAfter + PlayerScreen.stuckInterval);
    expect(find.textContaining(TorrentStallOverlay.waiting), findsOneWidget);

    harness.engine.emitPosition(
      const Duration(seconds: 5113, milliseconds: 120),
    );
    await pumpEvents(tester);
    expect(find.textContaining(TorrentStallOverlay.waiting), findsOneWidget);
    expect(lines.where((line) => line.contains('playing again')), isEmpty);

    // A second of film is film.
    harness.engine.emitPosition(const Duration(seconds: 5114));
    await pumpEvents(tester);
    expect(find.textContaining(TorrentStallOverlay.waiting), findsNothing);
  });

  testWidgets('a paused player is not waiting', (tester) async {
    final harness = PlayerHarness();
    await harness.pump(tester);

    harness.engine.emitPlaying(true);
    harness.engine.emitPosition(const Duration(seconds: 939));
    await tester.pump();
    harness.engine.emitPlaying(false);
    await tester.pump();

    await tester.pump(PlayerScreen.stuckAfter + PlayerScreen.stuckInterval);
    expect(
      find.textContaining(TorrentStallOverlay.waiting),
      findsNothing,
      reason: 'the position stands still because the viewer stopped it',
    );
  });
}
