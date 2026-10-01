import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/dev/dev_streams.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/torrent_startup_overlay.dart';

import '../../support/player_harness.dart';

/// An `open` that fails while the torrent is still starting up.
///
/// The server answers the media route with an error (or the connection
/// fails) while it is still resolving metadata or checking data, and mpv
/// gives up on the first refusal. Without a retry, the player would show
/// "Playback failed" for a stream that plays a second later.
void main() {
  final overlay = find.byType(TorrentStartupOverlay);
  final failure = find.textContaining('Playback failed');

  const openFailure =
      'Failed to open http://127.0.0.1:11470/'
      '11ea02584fa6351956f35671962ab46354d99060/0';

  /// Mounts the screen and lets the first `open` fail.
  Future<PlayerHarness> failFirstOpen(
    WidgetTester tester, {
    TorrentStats? stats,
  }) async {
    final harness = PlayerHarness(
      configureEngine: (engine) => engine.openError = openFailure,
    );
    if (stats != null) harness.torrentStats.response = stats;
    await tester.pumpWidget(harness.build());
    await tester.pump();
    await tester.pump();
    return harness;
  }

  /// Half a minute of retries: long enough that a retry with a count on
  /// it would have run out.
  Future<void> waitOutTheRetries(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
    }
  }

  testWidgets('an open that failed while checking is tried again and plays', (
    tester,
  ) async {
    final harness = await failFirstOpen(
      tester,
      stats: const TorrentStats(
        phase: TorrentPhase.checking,
        checkedBytes: 250,
        checkTotalBytes: 1000,
      ),
    );

    // The refusal is not shown: the start-up card stays up, with the
    // progress it already had, and the poller behind it never stopped.
    expect(harness.engine.opened, hasLength(1));
    expect(failure, findsNothing);
    expect(overlay, findsOneWidget);
    await tester.pump(PlayerScreen.torrentStatsInterval);
    await tester.pump();
    expect(
      find.descendant(
        of: overlay,
        matching: find.text('Checking existing data… 25%'),
      ),
      findsOneWidget,
    );

    // The second attempt lands.
    harness.engine.openError = null;
    await tester.pump(PlayerScreen.torrentOpenRetryBackoff);
    await tester.pump();
    expect(harness.engine.opened, hasLength(2));
    expect(harness.engine.opened.last.$1, harness.engine.opened.first.$1);

    harness.engine.emitDuration(const Duration(minutes: 96));
    await pumpEvents(tester);
    expect(overlay, findsNothing);
    expect(failure, findsNothing);
    expect(find.text('video surface'), findsOneWidget);

    // Nothing is left waiting once the media is in.
    final opens = harness.engine.opened.length;
    await waitOutTheRetries(tester);
    expect(harness.engine.opened, hasLength(opens));
  });

  testWidgets('an error from the engine is retried the same way', (
    tester,
  ) async {
    // mpv's own "Failed to open" arrives on the error stream, not as a
    // rejected `open`; it is the same failure and gets the same patience.
    final harness = PlayerHarness();
    // A determinate card, so pumping settles: an indeterminate bar never
    // does (see player_torrent_startup_test).
    harness.torrentStats.response = const TorrentStats(
      phase: TorrentPhase.checking,
      checkedBytes: 1,
      checkTotalBytes: 10,
    );
    await harness.pump(tester);
    expect(harness.engine.opened, hasLength(1));

    harness.engine.emitError(openFailure);
    await pumpEvents(tester);
    expect(failure, findsNothing);
    expect(overlay, findsOneWidget);

    await tester.pump(PlayerScreen.torrentOpenRetryBackoff);
    await tester.pump();
    expect(harness.engine.opened, hasLength(2));
  });

  testWidgets('an open that keeps failing while the torrent starts is tried '
      'for as long as it takes', (tester) async {
    // A dead swarm: the viewer is the one who gives up, never a count.
    final harness = await failFirstOpen(
      tester,
      stats: const TorrentStats(
        phase: TorrentPhase.buffering,
        initialWindowReadyBytes: 0,
        initialWindowBytes: 4194304,
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(PlayerScreen.openRetryBackoffCap);
      await tester.pump();
    }

    expect(harness.engine.opened.length, greaterThan(20));
    expect(failure, findsNothing);
    expect(overlay, findsOneWidget);
    // Still polling: the card is still showing what is happening.
    final polled = harness.torrentStats.requests.length;
    await tester.pump(PlayerScreen.torrentStatsInterval * 4);
    expect(harness.torrentStats.requests.length, greaterThan(polled));
  });

  testWidgets('the wait between attempts grows, and stops growing', (
    tester,
  ) async {
    final harness = await failFirstOpen(
      tester,
      stats: const TorrentStats(phase: TorrentPhase.resolvingMetadata),
    );
    // Each wait is one more multiple of the backoff, to the cap.
    for (var n = 1; n <= 30; n++) {
      final wait = PlayerScreen.torrentOpenRetryBackoff * n;
      final expected = wait < PlayerScreen.openRetryBackoffCap
          ? wait
          : PlayerScreen.openRetryBackoffCap;
      final before = harness.engine.opened.length;
      await tester.pump(expected - const Duration(milliseconds: 1));
      await tester.pump();
      expect(harness.engine.opened, hasLength(before), reason: 'wait $n');
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(harness.engine.opened, hasLength(before + 1), reason: 'wait $n');
    }
  });

  testWidgets('a torrent whose metadata did not come is still waited for', (
    tester,
  ) async {
    final harness = await failFirstOpen(
      tester,
      stats: const TorrentStats(
        phase: TorrentPhase.error,
        error: 'metadata not received in time',
      ),
    );
    await waitOutTheRetries(tester);
    expect(harness.engine.opened.length, greaterThan(5));
    expect(failure, findsNothing);
  });

  testWidgets('a torrent that is ready and still will not open fails', (
    tester,
  ) async {
    // The bytes are there and mpv cannot read them: an answer, not a wait.
    final harness = await failFirstOpen(
      tester,
      stats: const TorrentStats(phase: TorrentPhase.ready),
    );
    await tester.pump(PlayerScreen.torrentStatsInterval);
    await tester.pump();
    await waitOutTheRetries(tester);
    expect(harness.engine.opened, hasLength(lessThanOrEqualTo(2)));
    expect(find.text('Playback failed: $openFailure'), findsOneWidget);
  });

  testWidgets('a direct URL stream fails at once, as before', (tester) async {
    final harness = PlayerHarness(
      player: {
        'selected': {'stream': DevStreams.bigBuckBunnyHttp},
        'stream': {
          'type': 'Ready',
          'content': [
            {'streaming_url': DevStreams.bigBuckBunnyHttp['url']},
            DevStreams.bigBuckBunnyHttp,
          ],
        },
      },
      stream: DevStreams.bigBuckBunnyHttp,
      configureEngine: (engine) => engine.openError = 'unsupported URL',
    );
    await harness.pump(tester);

    expect(find.text('Playback failed: unsupported URL'), findsOneWidget);
    expect(harness.engine.opened, hasLength(1));
    await waitOutTheRetries(tester);
    expect(harness.engine.opened, hasLength(1));
  });

  testWidgets('nothing retries after the screen is gone', (tester) async {
    final harness = await failFirstOpen(
      tester,
      stats: const TorrentStats(phase: TorrentPhase.checking),
    );
    expect(harness.engine.opened, hasLength(1));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await waitOutTheRetries(tester);
    expect(harness.engine.opened, hasLength(1));
    // A timer still pending here would fail the test on its own; this says
    // what would be wrong if it did.
    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: 'no retry and no poll outlives dispose',
    );
  });
}
