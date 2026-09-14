import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/torrent_stall_overlay.dart';

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
