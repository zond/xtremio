import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/dev/dev_streams.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/torrent_startup_overlay.dart';

import '../../support/player_harness.dart';

/// The pre-playback overlay: what the server's `stats.json` says a torrent
/// is doing between `open` and the first frame, polled while it lasts.
void main() {
  final overlay = find.byType(TorrentStartupOverlay);

  Finder overlayText(String text) =>
      find.descendant(of: overlay, matching: find.text(text));

  LinearProgressIndicator progressBar(WidgetTester tester) =>
      tester.widget<LinearProgressIndicator>(
        find.descendant(
          of: overlay,
          matching: find.byType(LinearProgressIndicator),
        ),
      );

  /// One poll interval: the timer fires, the fake answers, the frame draws.
  Future<void> poll(WidgetTester tester) async {
    await tester.pump(PlayerScreen.torrentStatsInterval);
    await tester.pump();
  }

  group('TorrentStats', () {
    test('parses the phase fields stream-server adds to stats.json', () {
      final stats = TorrentStats.fromJson({
        'name': 'Night of the Living Dead',
        'infoHash': '11ea02584fa6351956f35671962ab46354d99060',
        'downloadSpeed': 1536000.0,
        'peers': 4,
        'phase': 'checking',
        'checkedBytes': 250,
        'checkTotalBytes': 1000,
        'initialWindowReadyBytes': null,
        'initialWindowBytes': null,
        'peerDiscovery': {'seen': 12, 'queued': 3, 'connecting': 2, 'live': 4},
      });
      expect(stats.phase, TorrentPhase.checking);
      expect(stats.checkProgress, 0.25);
      expect(stats.initialWindowProgress, isNull);
      expect(stats.downloadSpeed, 1536000);
      expect(stats.peers, 4);
      expect(stats.peerDiscovery.seen, 12);
      expect(stats.peerDiscovery.connecting, 2);
      expect(stats.peerDiscovery.live, 4);

      // Every phase name on the wire, and tolerance for a new one.
      for (final phase in TorrentPhase.values) {
        if (phase == TorrentPhase.unknown) continue;
        expect(TorrentPhase.parse(phase.wireName), phase);
      }
      expect(TorrentPhase.parse('seeding'), TorrentPhase.unknown);
      expect(TorrentPhase.parse(null), TorrentPhase.unknown);
      expect(
        TorrentStats.fromJson(const {'phase': 'buffering'}).peerDiscovery,
        const PeerDiscovery(),
      );
    });

    test('derives the stats URL from the stream URL', () {
      const hash = '11ea02584fa6351956f35671962ab46354d99060';
      // The query travels along: the server's per-file route takes the
      // stream route's `tr=`/`f=` and focuses the file it resolves.
      expect(
        TorrentStats.statsUrlFor(
          Uri.parse('http://127.0.0.1:11470/$hash/0?tr=udp%3A%2F%2Fa'),
        ),
        Uri.parse('http://127.0.0.1:11470/$hash/0/stats.json?tr=udp%3A%2F%2Fa'),
      );
      // The server's guessed index stays in the path; with `f=` filters the
      // per-file route picks the same file the stream route does.
      expect(
        TorrentStats.statsUrlFor(
          Uri.parse(
            'http://127.0.0.1:11470/$hash/-1?tr=udp%3A%2F%2Fa&f=Movie.mkv',
          ),
        ),
        Uri.parse(
          'http://127.0.0.1:11470/$hash/-1/stats.json?tr=udp%3A%2F%2Fa&f=Movie.mkv',
        ),
      );
      expect(
        TorrentStats.statsUrlFor(Uri.parse('http://127.0.0.1:11470/$hash/-1')),
        Uri.parse('http://127.0.0.1:11470/$hash/-1/stats.json'),
      );
      // Only the hash: the torrent-level stats.
      expect(
        TorrentStats.statsUrlFor(Uri.parse('http://127.0.0.1:11470/$hash')),
        Uri.parse('http://127.0.0.1:11470/$hash/stats.json'),
      );
      // The torrent-level stats for any of them, query included.
      expect(
        TorrentStats.torrentStatsUrlFor(
          Uri.parse('http://127.0.0.1:11470/$hash/-1?tr=udp%3A%2F%2Fa'),
        ),
        Uri.parse('http://127.0.0.1:11470/$hash/stats.json?tr=udp%3A%2F%2Fa'),
      );
      // Not the server's torrent path.
      expect(
        TorrentStats.statsUrlFor(
          Uri.parse('https://test-videos.co.uk/big_buck_bunny.mp4'),
        ),
        isNull,
      );
      expect(TorrentStats.statsUrlFor(Uri.parse('http://127.0.0.1/')), isNull);
      expect(
        TorrentStats.torrentStatsUrlFor(Uri.parse('http://127.0.0.1/x.mp4')),
        isNull,
      );
    });
  });

  group('TorrentStartupOverlay.describe', () {
    test('labels each phase, with a percentage where one exists', () {
      final connecting = TorrentStartupOverlay.describe(null);
      expect(connecting.label, 'Connecting to server…');
      expect(connecting.progress, isNull);
      expect(connecting.detail, isNull);

      final metadata = TorrentStartupOverlay.describe(
        const TorrentStats(phase: TorrentPhase.resolvingMetadata),
      );
      expect(metadata.label, 'Fetching torrent metadata…');
      expect(metadata.progress, isNull);

      final checking = TorrentStartupOverlay.describe(
        const TorrentStats(
          phase: TorrentPhase.checking,
          checkedBytes: 333,
          checkTotalBytes: 1000,
        ),
      );
      expect(checking.label, 'Checking existing data… 33%');
      expect(checking.progress, closeTo(0.333, 0.001));

      final finding = TorrentStartupOverlay.describe(
        const TorrentStats(
          phase: TorrentPhase.buffering,
          initialWindowReadyBytes: 0,
          initialWindowBytes: 4194304,
          peerDiscovery: PeerDiscovery(seen: 7, connecting: 2),
        ),
      );
      expect(finding.label, 'Finding peers…');
      expect(finding.detail, '7 found · 2 connecting');
      expect(finding.progress, 0);
      expect(
        TorrentStartupOverlay.describe(
          const TorrentStats(phase: TorrentPhase.buffering),
        ).detail,
        'No peers found yet',
      );

      final buffering = TorrentStartupOverlay.describe(
        const TorrentStats(
          phase: TorrentPhase.buffering,
          initialWindowReadyBytes: 2097152,
          initialWindowBytes: 4194304,
          peerDiscovery: PeerDiscovery(seen: 9, live: 3),
          downloadSpeed: 2500000,
          peers: 3,
        ),
      );
      expect(buffering.label, 'Buffering start… 50%');
      expect(buffering.progress, 0.5);
      expect(buffering.detail, '2.5 MB/s · 3 peers');

      final ready = TorrentStartupOverlay.describe(
        const TorrentStats(phase: TorrentPhase.ready, peers: 1),
      );
      expect(ready.label, 'Starting playback…');
      expect(ready.progress, 1);
      expect(ready.detail, '1 peer');

      final failed = TorrentStartupOverlay.describe(
        const TorrentStats(phase: TorrentPhase.error),
      );
      expect(failed.label, 'The torrent failed to start');
      expect(failed.failed, isTrue);

      // Speed only shows when there is some.
      expect(
        TorrentStartupOverlay.describe(
          const TorrentStats(phase: TorrentPhase.ready),
        ).detail,
        isNull,
      );
      expect(TorrentStartupOverlay.formatSpeed(850000), '850 kB/s');
      expect(TorrentStartupOverlay.formatSpeed(512), '512 B/s');
    });
  });

  testWidgets('follows the server phases until the media loads', (
    tester,
  ) async {
    final harness = PlayerHarness();
    // Nothing from the server yet. (Its indeterminate bar never settles, so
    // this test pumps by hand instead of `harness.pump`.)
    final stats = harness.torrentStats..response = null;
    await tester.pumpWidget(harness.build());
    await tester.pump();
    await tester.pump();

    // Opened, nothing loaded yet: the overlay is up, no bare spinner. The
    // server is not asked anything until the first tick (see below).
    expect(harness.engine.opened, hasLength(1));
    expect(overlay, findsOneWidget);
    expect(overlayText('Connecting to server…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(progressBar(tester).value, isNull);
    expect(stats.requests, isEmpty);

    // Polled every interval, for this torrent's file, and while that has no
    // answer the torrent-level stats too; the same answer does not redraw
    // anything.
    const base =
        'http://127.0.0.1:33759/11ea02584fa6351956f35671962ab46354d99060';
    await poll(tester);
    expect(stats.requests, [
      Uri.parse('$base/0/stats.json'),
      Uri.parse('$base/stats.json'),
    ]);
    await poll(tester);
    expect(stats.requests, hasLength(4));

    stats.response = const TorrentStats(
      phase: TorrentPhase.checking,
      checkedBytes: 250,
      checkTotalBytes: 1000,
    );
    await poll(tester);
    expect(overlayText('Checking existing data… 25%'), findsOneWidget);
    expect(progressBar(tester).value, 0.25);

    stats.response = const TorrentStats(
      phase: TorrentPhase.buffering,
      initialWindowReadyBytes: 0,
      initialWindowBytes: 4194304,
      peerDiscovery: PeerDiscovery(seen: 5, connecting: 1),
    );
    await poll(tester);
    expect(overlayText('Finding peers…'), findsOneWidget);
    expect(overlayText('5 found · 1 connecting'), findsOneWidget);

    stats.response = const TorrentStats(
      phase: TorrentPhase.buffering,
      initialWindowReadyBytes: 3145728,
      initialWindowBytes: 4194304,
      peerDiscovery: PeerDiscovery(seen: 9, live: 4),
      downloadSpeed: 1500000,
      peers: 4,
    );
    await poll(tester);
    expect(overlayText('Buffering start… 75%'), findsOneWidget);
    expect(overlayText('1.5 MB/s · 4 peers'), findsOneWidget);
    expect(progressBar(tester).value, 0.75);

    stats.response = const TorrentStats(phase: TorrentPhase.ready, peers: 4);
    await poll(tester);
    expect(overlayText('Starting playback…'), findsOneWidget);
    expect(progressBar(tester).value, 1);

    // The media loads: the overlay goes and the polling stops.
    harness.engine.emitDuration(const Duration(minutes: 96));
    await pumpEvents(tester);
    expect(overlay, findsNothing);
    final polled = stats.requests.length;
    await tester.pump(PlayerScreen.torrentStatsInterval * 4);
    expect(stats.requests, hasLength(polled));

    // Later buffering is the plain status again, not the start-up card.
    harness.engine.emitBuffering(true);
    await pumpEvents(tester);
    expect(find.text('Buffering from the torrent…'), findsOneWidget);
    expect(overlay, findsNothing);
  });

  testWidgets('reads the metadata phase off the torrent-level stats', (
    tester,
  ) async {
    // While a magnet's metadata is unresolved the per-file route has no
    // file to resolve and answers 404; the torrent-level route still says
    // what is going on.
    const base =
        'http://127.0.0.1:33759/11ea02584fa6351956f35671962ab46354d99060';
    final harness = PlayerHarness();
    final stats = harness.torrentStats
      ..response = null
      ..responses[Uri.parse('$base/stats.json')] = const TorrentStats(
        phase: TorrentPhase.resolvingMetadata,
      );
    await tester.pumpWidget(harness.build());
    await tester.pump();
    await poll(tester);
    expect(stats.requests, [
      Uri.parse('$base/0/stats.json'),
      Uri.parse('$base/stats.json'),
    ]);
    expect(overlayText('Fetching torrent metadata…'), findsOneWidget);

    // Once the per-file route answers, the torrent-level one is not asked.
    stats.response = const TorrentStats(
      phase: TorrentPhase.buffering,
      initialWindowReadyBytes: 0,
      initialWindowBytes: 4194304,
    );
    await poll(tester);
    expect(stats.requests, hasLength(3));
    expect(stats.requests.last, Uri.parse('$base/0/stats.json'));
    expect(overlayText('Finding peers…'), findsOneWidget);
  });

  testWidgets('asks the server nothing before the engine is told to open', (
    tester,
  ) async {
    // A stats request the server sees before the stream request makes it
    // create the torrent's engine from the bare info hash, without the
    // URL's trackers, and the stream then reuses that engine.
    final harness = PlayerHarness();
    await harness.pump(tester);
    expect(harness.calls.first, 'open');
    expect(harness.calls, contains('stats'));
  });

  testWidgets('a playing signal also ends it', (tester) async {
    final harness = PlayerHarness();
    await harness.pump(tester);
    expect(overlay, findsOneWidget);
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);
    expect(overlay, findsNothing);
  });

  testWidgets('keeps the controls up while it shows', (tester) async {
    useWideViewport(tester);
    final harness = PlayerHarness();
    await harness.pump(tester);
    // Even "playing" (as reported before the duration is known) would let
    // the controls fade; the overlay does not, until it is gone.
    expect(overlay, findsOneWidget);
    await tester.pump(PlayerScreen.controlsTimeout * 2);
    await tester.pump();
    expect(controlsOpacity(tester), 1);
  });

  testWidgets('stops polling when the screen goes away', (tester) async {
    final harness = PlayerHarness();
    await harness.pump(tester);
    final stats = harness.torrentStats;
    await poll(tester);
    expect(stats.requests.length, greaterThanOrEqualTo(2));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pump();
    final polled = stats.requests.length;
    await tester.pump(PlayerScreen.torrentStatsInterval * 4);
    expect(stats.requests, hasLength(polled));
  });

  testWidgets('shows nothing for a direct HTTP stream', (tester) async {
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
    expect(harness.engine.opened, hasLength(1));
    expect(overlay, findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(PlayerScreen.torrentStatsInterval * 2);
    expect(harness.torrentStats.requests, isEmpty);
  });

  testWidgets('an engine error replaces it', (tester) async {
    final harness = PlayerHarness();
    await harness.pump(tester);
    expect(overlay, findsOneWidget);
    harness.engine.emitError('no stream');
    await pumpEvents(tester);
    expect(overlay, findsNothing);
    expect(find.text('Playback failed: no stream'), findsOneWidget);
    final polled = harness.torrentStats.requests.length;
    await tester.pump(PlayerScreen.torrentStatsInterval * 4);
    expect(harness.torrentStats.requests, hasLength(polled));
  });

  testWidgets('a rejected open replaces it too', (tester) async {
    final harness = PlayerHarness(
      configureEngine: (engine) => engine.openError = 'unsupported URL',
    );
    await harness.pump(tester);
    expect(overlay, findsNothing);
    expect(find.text('Playback failed: unsupported URL'), findsOneWidget);
    final polled = harness.torrentStats.requests.length;
    await tester.pump(PlayerScreen.torrentStatsInterval * 4);
    expect(harness.torrentStats.requests, hasLength(polled));
  });

  testWidgets('is not fooled by a stale answer for the previous stream', (
    tester,
  ) async {
    // The core resolving a torrent while the player is on a direct stream:
    // the overlay belongs to whatever is opened now.
    final harness = PlayerHarness();
    await harness.pump(tester);
    expect(overlay, findsOneWidget);
    harness.core.setState(CoreField.player, {
      'selected': {'stream': DevStreams.bigBuckBunnyHttp},
      'stream': {
        'type': 'Ready',
        'content': [
          {'streaming_url': DevStreams.bigBuckBunnyHttp['url']},
          DevStreams.bigBuckBunnyHttp,
        ],
      },
    });
    await tester.pumpAndSettle();
    expect(harness.engine.opened, hasLength(2));
    expect(overlay, findsNothing);
  });
}
