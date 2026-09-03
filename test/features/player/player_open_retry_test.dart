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
/// fails) while it is still resolving metadata or checking data, mpv gives
/// up on the first refusal, and the player used to show "Playback failed"
/// for a stream that would have played a second later.
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

  /// Long enough for every retry the player will make.
  Future<void> waitOutTheRetries(WidgetTester tester) async {
    for (var i = 0; i < PlayerScreen.torrentOpenRetries + 2; i++) {
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

  testWidgets('an open that keeps failing shows the failure in the end', (
    tester,
  ) async {
    final harness = await failFirstOpen(
      tester,
      stats: const TorrentStats(
        phase: TorrentPhase.buffering,
        initialWindowReadyBytes: 0,
        initialWindowBytes: 4194304,
      ),
    );
    await waitOutTheRetries(tester);

    expect(
      harness.engine.opened,
      hasLength(PlayerScreen.torrentOpenRetries + 1),
      reason: 'the first attempt and a bounded number of retries',
    );
    expect(find.text('Playback failed: $openFailure'), findsOneWidget);
    expect(overlay, findsNothing);
    // The polling ends with the failure, as it always did.
    final polled = harness.torrentStats.requests.length;
    await tester.pump(PlayerScreen.torrentStatsInterval * 4);
    expect(harness.torrentStats.requests, hasLength(polled));
  });

  testWidgets('a torrent the server has given up on is not retried', (
    tester,
  ) async {
    final harness = await failFirstOpen(
      tester,
      stats: const TorrentStats(
        phase: TorrentPhase.error,
        error: 'metadata not received in time',
      ),
    );
    // The first refusal came before the server had said anything, so it
    // bought one wait; the answer that arrives during it ends the matter.
    await tester.pump(PlayerScreen.torrentStatsInterval);
    await tester.pump();
    await tester.pump(PlayerScreen.torrentOpenRetryBackoff * 2);
    await tester.pump();
    expect(harness.engine.opened, hasLength(1));
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
