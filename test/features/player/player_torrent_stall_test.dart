import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/dev/dev_streams.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/torrent_stall_overlay.dart';
import 'package:xtremio/features/player/torrent_startup_overlay.dart';

import '../../support/player_harness.dart';

/// The mid-playback stall: what the server's `stats.json` says while
/// playback waits for the torrent, polled only for as long as it waits.
void main() {
  final card = find.byType(TorrentStallOverlay);

  Finder cardText(String text) =>
      find.descendant(of: card, matching: find.text(text));

  LinearProgressIndicator progressBar(WidgetTester tester) =>
      tester.widget<LinearProgressIndicator>(
        find.descendant(
          of: card,
          matching: find.byType(LinearProgressIndicator),
        ),
      );

  /// A player whose torrent has started playing: the start-up overlay is
  /// done and its polling with it.
  Future<PlayerHarness> pumpPlaying(WidgetTester tester) async {
    final harness = PlayerHarness();
    harness.torrentStats.response = const TorrentStats(
      phase: TorrentPhase.ready,
      peers: 2,
    );
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(minutes: 96));
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);
    expect(find.byType(TorrentStartupOverlay), findsNothing);
    return harness;
  }

  testWidgets('a stall measures the torrent instead of spinning', (
    tester,
  ) async {
    final harness = await pumpPlaying(tester);
    final stats = harness.torrentStats;

    // Playing: nothing is asked of the server at all.
    final whilePlaying = stats.requests.length;
    await tester.pump(PlayerScreen.torrentStallStatsInterval * 4);
    expect(stats.requests, hasLength(whilePlaying));

    // Stalled: the numbers are there in the first frames, not two seconds
    // later, and it is the measurable card rather than a bare spinner.
    stats.response = const TorrentStats(
      phase: TorrentPhase.ready,
      downloadSpeed: 1500000,
      peers: 4,
      peerDiscovery: PeerDiscovery(seen: 9, live: 4),
    );
    harness.engine.emitBuffering(true);
    await pumpEvents(tester);
    expect(card, findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(cardText('Buffering from the torrent…'), findsOneWidget);
    expect(cardText('1.5 MB/s · 4 peers · 9 found'), findsOneWidget);
    // Past the head of the file the server measures no target: an honest
    // indeterminate bar rather than a full one.
    expect(progressBar(tester).value, isNull);
    expect(stats.requests, hasLength(whilePlaying + 1));

    // It keeps up, at the slower stall cadence: nothing on a start-up
    // interval, a fresh answer on a stall one.
    stats.response = const TorrentStats(
      phase: TorrentPhase.buffering,
      initialWindowReadyBytes: 1048576,
      initialWindowBytes: 4194304,
      downloadSpeed: 250000,
      peers: 1,
    );
    await tester.pump(PlayerScreen.torrentStatsInterval);
    expect(stats.requests, hasLength(whilePlaying + 1));
    await tester.pump(PlayerScreen.torrentStallStatsInterval);
    await tester.pump();
    expect(stats.requests, hasLength(whilePlaying + 2));
    expect(cardText('Buffering from the torrent… 25%'), findsOneWidget);
    expect(cardText('250 kB/s · 1 peer'), findsOneWidget);
    expect(progressBar(tester).value, 0.25);

    // Playing again: the card goes and so does the polling.
    harness.engine.emitBuffering(false);
    await pumpEvents(tester);
    expect(card, findsNothing);
    expect(find.text('Buffering from the torrent…'), findsNothing);
    final whileStalled = stats.requests.length;
    await tester.pump(PlayerScreen.torrentStallStatsInterval * 4);
    expect(stats.requests, hasLength(whileStalled));
  });

  testWidgets('says so when the torrent stops for good', (tester) async {
    final harness = await pumpPlaying(tester);
    harness.torrentStats.response = const TorrentStats(
      phase: TorrentPhase.error,
      error: 'download folder is not writable',
    );
    harness.engine.emitBuffering(true);
    await pumpEvents(tester);
    expect(cardText('The torrent stopped'), findsOneWidget);
    expect(cardText('download folder is not writable'), findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.byType(LinearProgressIndicator)),
      findsNothing,
    );
    harness.engine.emitBuffering(false);
    await pumpEvents(tester);
  });

  testWidgets('a direct stream stalls with the plain status', (tester) async {
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
    );
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(minutes: 10));
    harness.engine.emitBuffering(true);
    await pumpEvents(tester);
    expect(card, findsNothing);
    expect(find.text('Buffering…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pump(PlayerScreen.torrentStallStatsInterval * 2);
    expect(harness.torrentStats.requests, isEmpty);
  });

  testWidgets('leaves no polling behind when the screen goes mid-stall', (
    tester,
  ) async {
    final harness = await pumpPlaying(tester);
    harness.engine.emitBuffering(true);
    await pumpEvents(tester);
    expect(card, findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await pumpEvents(tester);
    final polled = harness.torrentStats.requests.length;
    await tester.pump(PlayerScreen.torrentStallStatsInterval * 4);
    expect(harness.torrentStats.requests, hasLength(polled));
  });

  group('TorrentStallOverlay.describe', () {
    test('says what a stall is waiting for, in peers and never in seeds', () {
      // Nothing back yet: the sentence the player has always shown.
      final waiting = TorrentStallOverlay.describe(null);
      expect(waiting.label, 'Buffering from the torrent…');
      expect(waiting.progress, isNull);
      expect(waiting.detail, isNull);

      // Live but starved: zeros are the answer, and the swarm's found
      // peers only add a number when they exceed the connected ones.
      final starved = TorrentStallOverlay.describe(
        const TorrentStats(
          phase: TorrentPhase.ready,
          peerDiscovery: PeerDiscovery(seen: 12),
        ),
      );
      expect(starved.label, 'Buffering from the torrent…');
      expect(starved.progress, isNull);
      expect(starved.detail, '0 B/s · 0 peers · 12 found');
      expect(
        TorrentStallOverlay.describe(
          const TorrentStats(
            phase: TorrentPhase.ready,
            downloadSpeed: 2500000,
            peers: 3,
            peerDiscovery: PeerDiscovery(seen: 3, live: 3),
          ),
        ).detail,
        '2.5 MB/s · 3 peers',
      );

      // The head window is the one target a stall can have a bar for.
      final head = TorrentStallOverlay.describe(
        const TorrentStats(
          phase: TorrentPhase.buffering,
          initialWindowReadyBytes: 3145728,
          initialWindowBytes: 4194304,
          peers: 1,
        ),
      );
      expect(head.label, 'Buffering from the torrent… 75%');
      expect(head.progress, 0.75);
      expect(head.detail, '0 B/s · 1 peer');

      final checking = TorrentStallOverlay.describe(
        const TorrentStats(
          phase: TorrentPhase.checking,
          checkedBytes: 500,
          checkTotalBytes: 1000,
        ),
      );
      expect(checking.label, 'Checking existing data… 50%');
      expect(checking.progress, 0.5);

      expect(
        TorrentStallOverlay.describe(
          const TorrentStats(phase: TorrentPhase.resolvingMetadata),
        ).label,
        'Waiting for the torrent…',
      );

      // A torrent the server gave up on: the reason, and no bar.
      final failed = TorrentStallOverlay.describe(
        const TorrentStats(phase: TorrentPhase.error, error: 'disk full'),
      );
      expect(failed.label, 'The torrent stopped');
      expect(failed.detail, 'disk full');
      expect(failed.failed, isTrue);
      expect(failed.progress, isNull);

      // A phase this build does not know still says what it can.
      expect(
        TorrentStallOverlay.describe(
          const TorrentStats(phase: TorrentPhase.unknown, peers: 2),
        ).detail,
        '0 B/s · 2 peers',
      );
    });
  });
}
