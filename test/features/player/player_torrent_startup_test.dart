import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/dev/dev_streams.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/torrent_progress_card.dart';
import 'package:xtremio/features/player/torrent_stall_overlay.dart';
import 'package:xtremio/features/player/torrent_startup_overlay.dart';

import '../../support/player_harness.dart';

/// The pre-playback overlay: what the server's `stats.json` says a torrent
/// is doing between `open` and the first frame, polled while it lasts.
void main() {
  final overlay = find.byType(TorrentStartupOverlay);

  /// The recorded fixture's torrent: file 0, no trackers.
  const perFile = TorrentStatsRequest(
    infoHash: '11ea02584fa6351956f35671962ab46354d99060',
    fileIdx: 0,
  );
  const torrentLevel = TorrentStatsRequest(
    infoHash: '11ea02584fa6351956f35671962ab46354d99060',
  );

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

  /// Long enough for every retry a torrent's open gets while the server
  /// says it is still starting up (see player_open_retry_test): what is
  /// still failing after this is a failure.
  Future<void> exhaustOpenRetries(WidgetTester tester) async {
    for (var i = 0; i < PlayerScreen.torrentOpenRetries + 2; i++) {
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
    }
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
      // The server's reason for a failure travels along; absent otherwise.
      final failed = TorrentStats.fromJson(const {
        'phase': 'error',
        'error': 'metadata not received in time',
      });
      expect(failed.phase, TorrentPhase.error);
      expect(failed.error, 'metadata not received in time');
      expect(stats.error, isNull);
      expect(failed, isNot(TorrentStats.fromJson(const {'phase': 'error'})));
    });

    test('keeps an unknown swarm null rather than calling it zero', () {
      final scraped = TorrentStats.fromJson(const {
        'phase': 'ready',
        'peers': 5,
        'connectedSeeders': 2,
        'swarmSeeders': 137,
        'swarmLeechers': 402,
        'swarmScrapeAgeSecs': 240,
      });
      expect(scraped.connectedSeeders, 2);
      expect(scraped.swarmSeeders, 137);
      expect(scraped.swarmLeechers, 402);
      expect(scraped.swarmScrapeAge, const Duration(minutes: 4));

      // No tracker answered: the three swarm fields are null (or absent),
      // which is "we could not ask" and must not become a 0. The connected
      // counts are still counts.
      final unscraped = TorrentStats.fromJson(const {
        'phase': 'ready',
        'peers': 5,
        'connectedSeeders': 0,
        'swarmSeeders': null,
        'swarmLeechers': null,
        'swarmScrapeAgeSecs': null,
      });
      expect(unscraped.connectedSeeders, 0);
      expect(unscraped.swarmSeeders, isNull);
      expect(unscraped.swarmLeechers, isNull);
      expect(unscraped.swarmScrapeAge, isNull);
      expect(
        TorrentStats.fromJson(const {'phase': 'ready'}).swarmSeeders,
        isNull,
      );

      // A swarm nobody seeds is a real answer, and not the same value.
      final empty = TorrentStats.fromJson(const {
        'phase': 'ready',
        'peers': 5,
        'swarmSeeders': 0,
        'swarmLeechers': 0,
        'swarmScrapeAgeSecs': 12,
      });
      expect(empty.swarmSeeders, 0);
      expect(empty, isNot(unscraped));
    });

    test(
      'derives the request from the stream the way the core builds its URL',
      () {
        const hash = '11ea02584fa6351956f35671962ab46354d99060';
        // Hash, file index and the trackers the URL's `tr=` carries.
        final request = TorrentStatsRequest.forStream(
          StreamInfo({
            'infoHash': hash,
            'fileIdx': 2,
            'announce': ['udp://a', 'udp://b'],
          }),
        );
        expect(
          request,
          const TorrentStatsRequest(
            infoHash: hash,
            fileIdx: 2,
            trackers: ['udp://a', 'udp://b'],
          ),
        );
        // The torrent-level request keeps everything but the file.
        expect(
          request!.torrentLevel,
          const TorrentStatsRequest(
            infoHash: hash,
            trackers: ['udp://a', 'udp://b'],
          ),
        );
        // No index, or the server's "largest file" guess: torrent-level
        // already, no trackers.
        expect(
          TorrentStatsRequest.forStream(StreamInfo({'infoHash': hash})),
          const TorrentStatsRequest(infoHash: hash),
        );
        final guessed = TorrentStatsRequest.forStream(
          StreamInfo({'infoHash': hash, 'fileIdx': -1}),
        );
        expect(guessed, const TorrentStatsRequest(infoHash: hash));
        expect(guessed!.torrentLevel, same(guessed));
        // Not a torrent.
        expect(
          TorrentStatsRequest.forStream(
            StreamInfo(DevStreams.bigBuckBunnyHttp),
          ),
          isNull,
        );
        expect(TorrentStatsRequest.forStream(null), isNull);
        // Equality is by value, trackers included.
        expect(
          const TorrentStatsRequest(infoHash: hash, trackers: ['udp://a']),
          isNot(
            const TorrentStatsRequest(infoHash: hash, trackers: ['udp://b']),
          ),
        );
      },
    );
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
      // Nothing is connected here, so there is no seed of ours to count --
      // but a tracker that answered can still say the swarm is worth the
      // wait, and that is the one number this moment gains.
      expect(
        TorrentStartupOverlay.describe(
          const TorrentStats(
            phase: TorrentPhase.buffering,
            swarmSeeders: 137,
            peerDiscovery: PeerDiscovery(seen: 7, connecting: 2),
          ),
        ).detail,
        '7 found · 2 connecting · 137 seeds in the swarm',
      );
      expect(
        TorrentStartupOverlay.describe(
          const TorrentStats(phase: TorrentPhase.buffering, swarmSeeders: 1),
        ).detail,
        'No peers found yet · 1 seed in the swarm',
      );

      final buffering = TorrentStartupOverlay.describe(
        const TorrentStats(
          phase: TorrentPhase.buffering,
          initialWindowReadyBytes: 2097152,
          initialWindowBytes: 4194304,
          peerDiscovery: PeerDiscovery(seen: 9, live: 3),
          downloadSpeed: 2500000,
          peers: 3,
          connectedSeeders: 1,
          swarmSeeders: 137,
        ),
      );
      expect(buffering.label, 'Buffering start… 50%');
      expect(buffering.progress, 0.5);
      expect(buffering.detail, '2.5 MB/s · seeds 1 of 137 · peers 3 · 9 found');

      // Nobody could be asked about the swarm: the count of ours stands
      // alone rather than being written as a share of an unknown.
      final ready = TorrentStartupOverlay.describe(
        const TorrentStats(phase: TorrentPhase.ready, peers: 1),
      );
      expect(ready.label, 'Starting playback…');
      expect(ready.progress, 1);
      expect(ready.detail, 'seeds 0 · peers 1');

      final failed = TorrentStartupOverlay.describe(
        const TorrentStats(phase: TorrentPhase.error),
      );
      expect(failed.label, 'The torrent failed to start');
      expect(failed.failed, isTrue);
      expect(failed.detail, isNull);
      // The server's reason, when it gives one, is the detail line.
      expect(
        TorrentStartupOverlay.describe(
          const TorrentStats(
            phase: TorrentPhase.error,
            error: 'metadata not received in time',
          ),
        ).detail,
        'metadata not received in time',
      );

      // Speed only shows when there is some.
      expect(
        TorrentStartupOverlay.describe(
          const TorrentStats(phase: TorrentPhase.ready),
        ).detail,
        isNull,
      );
      expect(TorrentProgressCard.formatSpeed(850000), '850 kB/s');
      expect(TorrentProgressCard.formatSpeed(512), '512 B/s');
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
    await poll(tester);
    expect(stats.requests, [perFile, torrentLevel]);
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
      connectedSeeders: 2,
      swarmSeeders: 137,
    );
    await poll(tester);
    expect(overlayText('Buffering start… 75%'), findsOneWidget);
    expect(
      overlayText('1.5 MB/s · seeds 2 of 137 · peers 4 · 9 found'),
      findsOneWidget,
    );
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

    // Later buffering is the stall card, not this one; see
    // player_torrent_stall_test.
    harness.engine.emitBuffering(true);
    await pumpEvents(tester);
    expect(find.textContaining('Buffering from the torrent…'), findsOneWidget);
    expect(overlay, findsNothing);
    expect(find.byType(TorrentStallOverlay), findsOneWidget);
  });

  testWidgets('falls back to the torrent-level stats for the phase', (
    tester,
  ) async {
    // When the server has no answer for the file (an index the torrent
    // does not have), the torrent-level stats still say what is going on.
    final harness = PlayerHarness();
    final stats = harness.torrentStats
      ..response = null
      ..responses[torrentLevel] = const TorrentStats(
        phase: TorrentPhase.resolvingMetadata,
      );
    await tester.pumpWidget(harness.build());
    await tester.pump();
    await poll(tester);
    expect(stats.requests, [perFile, torrentLevel]);
    expect(overlayText('Fetching torrent metadata…'), findsOneWidget);

    // Once the file has an answer, the torrent-level one is not asked.
    stats.response = const TorrentStats(
      phase: TorrentPhase.buffering,
      initialWindowReadyBytes: 0,
      initialWindowBytes: 4194304,
    );
    await poll(tester);
    expect(stats.requests, hasLength(3));
    expect(stats.requests.last, perFile);
    expect(overlayText('Finding peers…'), findsOneWidget);
  });

  testWidgets('a failed torrent shows the server\'s reason', (tester) async {
    final harness = PlayerHarness();
    harness.torrentStats.response = const TorrentStats(
      phase: TorrentPhase.error,
      error: 'metadata not received in time',
    );
    await harness.pump(tester);
    expect(overlayText('The torrent failed to start'), findsOneWidget);
    expect(overlayText('metadata not received in time'), findsOneWidget);
    expect(
      find.descendant(
        of: overlay,
        matching: find.byType(LinearProgressIndicator),
      ),
      findsNothing,
    );
  });

  testWidgets('asks for the stream\'s trackers and file', (tester) async {
    // The stream's `announce` list is what the core puts in the URL's
    // `tr=`; the server needs it if the stats request creates the engine.
    final harness = PlayerHarness(
      player: {
        'selected': {'stream': DevStreams.bigBuckBunnyTorrent},
        'stream': {
          'type': 'Ready',
          'content': [
            {
              'streaming_url':
                  'http://127.0.0.1:33759/${DevStreams.bigBuckBunnyTorrent['infoHash']}/-1',
            },
            DevStreams.bigBuckBunnyTorrent,
          ],
        },
      },
      stream: DevStreams.bigBuckBunnyTorrent,
    );
    await harness.pump(tester);
    await poll(tester);
    // No file index: torrent-level from the start, and no fallback.
    expect(harness.torrentStats.requests.toSet(), {
      TorrentStatsRequest(
        infoHash: DevStreams.bigBuckBunnyTorrent['infoHash'] as String,
        trackers: List<String>.from(
          DevStreams.bigBuckBunnyTorrent['announce'] as List<dynamic>,
        ),
      ),
    });
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
    // A torrent the server is still starting up buys a few more attempts
    // first, so what ends the overlay is a failure that survives them.
    harness.engine.openError = 'no stream';
    harness.engine.emitError('no stream');
    await pumpEvents(tester);
    await exhaustOpenRetries(tester);
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
    await exhaustOpenRetries(tester);
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
