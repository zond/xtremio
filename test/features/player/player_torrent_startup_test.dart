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

    test('names the file the server opened, and empty is no name', () {
      // `streamName` is the one thing in stats.json about *this file* that
      // no addon supplied: for `/{infoHash}/{fileIdx}` it is the only name
      // there is. `EngineStats` starts it as `""` and fills it once the
      // torrent's metadata lists files, so empty is "not yet", not a name.
      expect(
        TorrentStats.fromJson(const {
          'phase': 'buffering',
          'streamName': 'Big Buck Bunny.mp4',
        }).streamName,
        'Big Buck Bunny.mp4',
      );
      expect(
        TorrentStats.fromJson(const {
          'phase': 'resolvingMetadata',
          'streamName': '',
        }).streamName,
        isNull,
      );
      expect(
        TorrentStats.fromJson(const {'phase': 'buffering'}).streamName,
        isNull,
      );
      // A different file is different stats: the player keeps the last
      // answer, so equality has to notice the name changing.
      expect(
        TorrentStats.fromJson(const {'phase': 'ready', 'streamName': 'a.mp4'}),
        isNot(
          TorrentStats.fromJson(const {
            'phase': 'ready',
            'streamName': 'b.mkv',
          }),
        ),
      );
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

  group('a wait one piece wide', () {
    /// A 16 MiB-piece torrent whose reader wants exactly one piece --
    /// which is every big torrent: librqbit credits verified pieces and
    /// nothing between them, so this percentage could only ever read 0 or
    /// 100, and it read 0 for tens of seconds while the download ran.
    const onePiece = TorrentStats(
      phase: TorrentPhase.buffering,
      initialWindowReadyBytes: 0,
      initialWindowBytes: 16777216,
      pieceLength: 16777216,
      peerDiscovery: PeerDiscovery(seen: 9, live: 4),
      downloadSpeed: 2000000,
      peers: 4,
      connectedSeeders: 2,
    );

    test('is counted in pieces, and has no percentage to show', () {
      expect(onePiece.windowPieces, 1);
      expect(onePiece.waitsForOnePiece, isTrue);
      expect(onePiece.initialWindowProgress, isNull);
      expect(onePiece.windowEta, const Duration(seconds: 9));
    });

    test('says which piece it is waiting for, not 0%', () {
      final status = TorrentStartupOverlay.describe(onePiece);
      expect(status.label, 'Waiting for the first piece (16 MiB)…');
      expect(status.progress, isNull, reason: 'nothing between 0 and done');
      expect(status.detail, contains('about 9 s left'));
      expect(status.detail, contains('2.0 MB/s'));

      // Mid-playback the same wait is for the next piece, not the first.
      final stalled = TorrentStallOverlay.describe(onePiece);
      expect(stalled.label, 'Waiting for the next piece (16 MiB)…');
      expect(stalled.progress, isNull);
    });

    test('a window of several pieces keeps a percentage that moves', () {
      const spanning = TorrentStats(
        phase: TorrentPhase.buffering,
        initialWindowReadyBytes: 2097152,
        initialWindowBytes: 8388608,
        pieceLength: 2097152,
        peerDiscovery: PeerDiscovery(seen: 9, live: 4),
        peers: 4,
      );
      expect(spanning.windowPieces, 4);
      expect(spanning.waitsForOnePiece, isFalse);
      expect(spanning.initialWindowProgress, 0.25);
      expect(
        TorrentStartupOverlay.describe(spanning).label,
        'Buffering start… 25%',
      );
    });

    test('an unknown piece length degrades to what it always said', () {
      // A server from before `pieceLength`: nothing is known about the
      // pieces, so the percentage is still the best that can be said and
      // nothing invents a piece size.
      const unknown = TorrentStats(
        phase: TorrentPhase.buffering,
        initialWindowReadyBytes: 1048576,
        initialWindowBytes: 4194304,
        peerDiscovery: PeerDiscovery(seen: 9, live: 4),
        peers: 4,
      );
      expect(unknown.windowPieces, isNull);
      expect(unknown.waitsForOnePiece, isFalse);
      expect(
        TorrentStartupOverlay.describe(unknown).label,
        'Buffering start… 25%',
      );
    });

    test('the piece length is parsed and shown in binary units', () {
      final stats = TorrentStats.fromJson(const {
        'phase': 'buffering',
        'initialWindowReadyBytes': 0,
        'initialWindowBytes': 16777216,
        'pieceLength': 16777216,
      });
      expect(stats.pieceLength, 16777216);
      expect(TorrentProgressCard.formatPieceSize(16777216), '16 MiB');
      expect(TorrentProgressCard.formatPieceSize(524288), '512 kiB');
      expect(TorrentProgressCard.formatPieceSize(1572864), '1.5 MiB');
      // A server that does not send it leaves it null rather than 0.
      expect(
        TorrentStats.fromJson(const {'phase': 'buffering'}).pieceLength,
        isNull,
      );
    });
  });

  group('the piece the reader is waiting on', () {
    /// The same 16 MiB-piece torrent as above, only with the server's
    /// sub-piece view of the one piece the wait is for. Everything the
    /// have-bitfield can say is still 0; this is what moves.
    TorrentStats waiting({
      int downloaded = 6553600,
      bool verified = false,
      int index = 137,
    }) => TorrentStats(
      phase: TorrentPhase.buffering,
      initialWindowReadyBytes: 0,
      initialWindowBytes: 16777216,
      pieceLength: 16777216,
      inFlightPiece: InFlightPiece(
        index: index,
        downloadedBytes: downloaded,
        totalBytes: 16777216,
        verified: verified,
      ),
      peerDiscovery: const PeerDiscovery(seen: 9, live: 4),
      downloadSpeed: 2000000,
      peers: 4,
      connectedSeeders: 2,
    );

    /// The card on its own, so the bar can be driven poll by poll without
    /// a whole player around it.
    Future<void> show(WidgetTester tester, TorrentStats stats) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: TorrentProgressCard(
                status: TorrentStartupOverlay.describe(stats),
              ),
            ),
          ),
        ),
      );
    }

    double? barValue(WidgetTester tester) => tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
        .value;

    test('is parsed, and null stays null rather than becoming a zero', () {
      final stats = TorrentStats.fromJson(const {
        'phase': 'buffering',
        'initialWindowReadyBytes': 0,
        'initialWindowBytes': 16777216,
        'pieceLength': 16777216,
        'inFlightPiece': {
          'index': 137,
          'downloadedBytes': 6553600,
          'totalBytes': 16777216,
          'verified': false,
        },
      });
      expect(
        stats.inFlightPiece,
        const InFlightPiece(
          index: 137,
          downloadedBytes: 6553600,
          totalBytes: 16777216,
        ),
      );
      expect(stats.inFlightPiece!.progress, closeTo(0.390625, 1e-9));

      // "We do not know" -- no reader open, no metadata, no chunk map --
      // is a null object, and must never be read as "nothing downloaded".
      expect(
        TorrentStats.fromJson(const {
          'phase': 'buffering',
          'inFlightPiece': null,
        }).inFlightPiece,
        isNull,
      );
      expect(
        TorrentStats.fromJson(const {'phase': 'checking'}).inFlightPiece,
        isNull,
      );
    });

    testWidgets('says the bytes of that piece, and the bar moves', (
      tester,
    ) async {
      final status = TorrentStartupOverlay.describe(waiting());
      expect(status.label, 'Waiting for piece 137, 6.3 of 16.0 MiB…');
      // The estimate is the piece's remainder, so it shrinks between
      // polls instead of quoting the whole piece for the whole wait.
      expect(status.detail, contains('about 6 s left'));

      await show(tester, waiting());
      expect(find.text('Waiting for piece 137, 6.3 of 16.0 MiB…'), findsOne);
      expect(barValue(tester), closeTo(0.390625, 1e-9));

      await show(tester, waiting(downloaded: 13107200));
      expect(find.text('Waiting for piece 137, 12.5 of 16.0 MiB…'), findsOne);
      expect(barValue(tester), closeTo(0.78125, 1e-9));
    });

    testWidgets('an unverified full piece does not read as done', (
      tester,
    ) async {
      // Every byte is on disk, but none of it can be served until the
      // hash checks out: a full bar here would be a promise the server
      // has not made.
      await show(tester, waiting(downloaded: 16777216));
      expect(barValue(tester), PieceProgressBar.unverifiedCap);
      expect(barValue(tester), lessThan(1));

      // `verified` is what fills it.
      await show(tester, waiting(downloaded: 16777216, verified: true));
      expect(barValue(tester), 1);
    });

    testWidgets('never runs backwards when a piece fails its hash', (
      tester,
    ) async {
      await show(tester, waiting(downloaded: 8388608));
      expect(barValue(tester), closeTo(0.5, 1e-9));

      // The piece failed its check and was discarded, so the count drops
      // back. The bar holds where it got to rather than animating down --
      // and nothing here animates at all, so there is no shrink to see
      // even for a frame.
      await show(tester, waiting(downloaded: 1048576));
      expect(barValue(tester), closeTo(0.5, 1e-9));
      await tester.pump(const Duration(seconds: 1));
      expect(barValue(tester), closeTo(0.5, 1e-9));

      // A different piece is a different wait: it starts where that piece
      // is, at once.
      await show(tester, waiting(index: 138, downloaded: 1048576));
      expect(barValue(tester), closeTo(0.0625, 1e-9));
      await tester.pump(const Duration(seconds: 1));
      expect(barValue(tester), closeTo(0.0625, 1e-9));
    });

    testWidgets('a piece the server does not know draws no bar of its own', (
      tester,
    ) async {
      const unknown = TorrentStats(
        phase: TorrentPhase.buffering,
        initialWindowReadyBytes: 0,
        initialWindowBytes: 16777216,
        pieceLength: 16777216,
        peerDiscovery: PeerDiscovery(seen: 9, live: 4),
        peers: 4,
      );
      final status = TorrentStartupOverlay.describe(unknown);
      expect(status.piece, isNull);
      expect(status.label, 'Waiting for the first piece (16 MiB)…');

      await show(tester, unknown);
      expect(find.byType(PieceProgressBar), findsNothing);
      // Not a bar sitting at zero, which would say "nothing downloaded":
      // the indeterminate sweep, which says only that something is
      // happening that cannot be measured.
      expect(barValue(tester), isNull);
    });

    testWidgets('a stall says the same thing in the present tense', (
      tester,
    ) async {
      final stalled = TorrentStallOverlay.describe(waiting());
      expect(stalled.label, 'Waiting for piece 137, 6.3 of 16.0 MiB…');
      expect(stalled.piece, isNotNull);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: TorrentProgressCard(status: stalled)),
          ),
        ),
      );
      expect(barValue(tester), closeTo(0.390625, 1e-9));

      // Without the sub-piece view it is the wording it always had.
      expect(
        TorrentStallOverlay.describe(
          const TorrentStats(
            phase: TorrentPhase.buffering,
            initialWindowReadyBytes: 0,
            initialWindowBytes: 16777216,
            pieceLength: 16777216,
            peers: 4,
            peerDiscovery: PeerDiscovery(live: 4),
          ),
        ).label,
        'Waiting for the next piece (16 MiB)…',
      );
    });

    test('a window of several pieces keeps its percentage', () {
      // The piece is known there too, but a window that really does span
      // several of them has a percentage that advances, and that is what
      // it shows -- the sub-piece view is for the wait that has none.
      const spanning = TorrentStats(
        phase: TorrentPhase.buffering,
        initialWindowReadyBytes: 2097152,
        initialWindowBytes: 8388608,
        pieceLength: 2097152,
        inFlightPiece: InFlightPiece(
          index: 4,
          downloadedBytes: 1048576,
          totalBytes: 2097152,
        ),
        peerDiscovery: PeerDiscovery(seen: 9, live: 4),
        peers: 4,
      );
      final status = TorrentStartupOverlay.describe(spanning);
      expect(status.label, 'Buffering start… 25%');
      expect(status.progress, 0.25);
      expect(status.piece, isNull);
    });

    test('the byte pair is said in the unit the piece takes', () {
      expect(
        TorrentProgressCard.formatPieceBytes(6553600, 16777216),
        '6.3 of 16.0 MiB',
      );
      // A short last piece reads as its own length, not a rounded one.
      expect(
        TorrentProgressCard.formatPieceBytes(6291456, 12058624),
        '6.0 of 11.5 MiB',
      );
      expect(TorrentProgressCard.formatPieceBytes(512, 1024), '0.5 of 1.0 kiB');
      expect(TorrentProgressCard.formatPieceBytes(3, 900), '3 of 900 B');
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

      // The one actionable DHT case: no trackers on this stream, and a DHT
      // that has never found a node this session -- said once, alongside
      // the peer count, as an explanation rather than an error.
      const findingNoPeers = TorrentStats(phase: TorrentPhase.buffering);
      const neverBootstrapped = DhtStatus(
        enabled: true,
        nodes: 0,
        nodesV6: 0,
        everBootstrapped: false,
      );
      expect(
        TorrentStartupOverlay.describe(
          findingNoPeers,
          hasTrackers: false,
          dht: neverBootstrapped,
        ).detail,
        'No peers found yet · no trackers on this stream, and the DHT has '
        'not found a peer on this network -- it may not find any',
      );
      // A tracked stream gets no explanation: trackers regularly work with
      // no DHT at all, so there is nothing here to explain.
      expect(
        TorrentStartupOverlay.describe(
          findingNoPeers,
          dht: neverBootstrapped,
        ).detail,
        'No peers found yet',
      );
      // Nor does a trackerless stream once the DHT has ever bootstrapped,
      // or when nothing was read about it at all.
      expect(
        TorrentStartupOverlay.describe(
          findingNoPeers,
          hasTrackers: false,
          dht: const DhtStatus(
            enabled: true,
            nodes: 12,
            nodesV6: 0,
            everBootstrapped: true,
          ),
        ).detail,
        'No peers found yet',
      );
      expect(
        TorrentStartupOverlay.describe(
          findingNoPeers,
          hasTrackers: false,
        ).detail,
        'No peers found yet',
      );
      // Once a peer turns up the moment has moved past "finding peers"
      // altogether, and with it the explanation: it only ever spoke to why
      // nothing had been found yet.
      expect(
        TorrentStartupOverlay.describe(
          const TorrentStats(
            phase: TorrentPhase.buffering,
            peerDiscovery: PeerDiscovery(seen: 3, live: 1),
            peers: 1,
          ),
          hasTrackers: false,
          dht: neverBootstrapped,
        ).detail,
        isNot(contains('DHT')),
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
          swarmLeechers: 402,
        ),
      );
      expect(buffering.label, 'Buffering start… 50%');
      expect(buffering.progress, 0.5);
      expect(
        buffering.detail,
        '2.5 MB/s · connected 3 · seeds 137 · swarm 539',
      );

      // Nobody could be asked about the swarm: our connection count stands
      // alone rather than being written against an unknown.
      final ready = TorrentStartupOverlay.describe(
        const TorrentStats(phase: TorrentPhase.ready, peers: 1),
      );
      expect(ready.label, 'Starting playback…');
      expect(ready.progress, 1);
      expect(ready.detail, 'connected 1');

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
      swarmLeechers: 402,
    );
    await poll(tester);
    expect(overlayText('Buffering start… 75%'), findsOneWidget);
    expect(
      overlayText('1.5 MB/s · connected 4 · seeds 137 · swarm 539'),
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

  group('TorrentProgressCard.formatSwarm', () {
    test('says the three numbers, and omits the ones nobody answered', () {
      // All three: our live connections, then what the trackers scraped --
      // the seeders, and the whole swarm they and the leechers make up.
      expect(
        TorrentProgressCard.formatSwarm(
          const TorrentStats(
            phase: TorrentPhase.ready,
            peers: 5,
            connectedSeeders: 2,
            swarmSeeders: 137,
            swarmLeechers: 402,
            peerDiscovery: PeerDiscovery(seen: 12, live: 5),
          ),
        ),
        'connected 5 · seeds 137 · swarm 539',
      );

      // No scrape at all -- no trackers, a private torrent, or an answer
      // still on its way. The two swarm figures are missing, not zero: a
      // 0 here would say the swarm is empty, which nobody claimed.
      expect(
        TorrentProgressCard.formatSwarm(
          const TorrentStats(
            phase: TorrentPhase.ready,
            peers: 5,
            peerDiscovery: PeerDiscovery(seen: 12, live: 5),
          ),
        ),
        'connected 5',
      );

      // Half a scrape: the seeder count stands, but the swarm total needs
      // the leechers to be a total at all, so it is left off.
      expect(
        TorrentProgressCard.formatSwarm(
          const TorrentStats(
            phase: TorrentPhase.ready,
            peers: 5,
            swarmSeeders: 137,
          ),
        ),
        'connected 5 · seeds 137',
      );

      // Our own end is always countable, so zero connections is an answer
      // and prints -- unlike the swarm figures, which are only ever
      // omitted or true.
      expect(
        TorrentProgressCard.formatSwarm(
          const TorrentStats(
            phase: TorrentPhase.ready,
            swarmSeeders: 0,
            swarmLeechers: 0,
          ),
        ),
        'connected 0 · seeds 0 · swarm 0',
      );
    });

    test('is the one formatter all three cards render', () {
      // The stall overlay and the start-up overlay have each grown their
      // own swarm wording before; the same stats must reach the screen as
      // the same string, or the three drift apart again.
      const stats = TorrentStats(
        phase: TorrentPhase.ready,
        downloadSpeed: 1500000,
        peers: 4,
        connectedSeeders: 2,
        swarmSeeders: 137,
        swarmLeechers: 402,
        peerDiscovery: PeerDiscovery(seen: 9, live: 4),
      );
      const swarm = 'connected 4 · seeds 137 · swarm 539';
      expect(TorrentProgressCard.formatSwarm(stats), swarm);
      expect(TorrentStallOverlay.describe(stats).detail, contains(swarm));
      expect(TorrentStartupOverlay.describe(stats).detail, contains(swarm));
    });
  });

  group('the DHT explanation for a trackerless magnet', () {
    const neverBootstrapped = DhtStatus(
      enabled: true,
      nodes: 0,
      nodesV6: 0,
      everBootstrapped: false,
    );
    const findingNoPeers = TorrentStats(phase: TorrentPhase.buffering);

    // The progress bar is indeterminate for "Finding peers…" (nothing
    // measurable yet), which never settles -- like the "Connecting to
    // server…" moment above, these pump by hand rather than through
    // `harness.pump`/`pumpAndSettle`.
    Future<void> pumpFinding(WidgetTester tester, PlayerHarness harness) async {
      await tester.pumpWidget(harness.build());
      await tester.pump();
      await tester.pump();
      await poll(tester);
    }

    testWidgets('shows on the fixture torrent, which has no trackers, on a '
        'DHT-less network', (tester) async {
      // The default fixture is exactly this case (see `perFile` above:
      // no trackers), so nothing about the stream needs building here.
      final harness = PlayerHarness(dhtStatus: neverBootstrapped)
        ..torrentStats.response = findingNoPeers;
      await pumpFinding(tester, harness);
      expect(overlayText('Finding peers…'), findsOneWidget);
      expect(
        overlayText(
          'No peers found yet · no trackers on this stream, and the '
          'DHT has not found a peer on this network -- it may not '
          'find any',
        ),
        findsOneWidget,
      );
    });

    testWidgets('does not show for a stream that has trackers', (tester) async {
      final harness = PlayerHarness(
        dhtStatus: neverBootstrapped,
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
      )..torrentStats.response = findingNoPeers;
      await pumpFinding(tester, harness);
      expect(overlayText('Finding peers…'), findsOneWidget);
      expect(overlayText('No peers found yet'), findsOneWidget);
      expect(find.textContaining('DHT'), findsNothing);
    });

    testWidgets('does not show once the DHT has ever bootstrapped', (
      tester,
    ) async {
      final harness = PlayerHarness(
        dhtStatus: const DhtStatus(
          enabled: true,
          nodes: 12,
          nodesV6: 0,
          everBootstrapped: true,
        ),
      )..torrentStats.response = findingNoPeers;
      await pumpFinding(tester, harness);
      expect(overlayText('No peers found yet'), findsOneWidget);
      expect(find.textContaining('DHT'), findsNothing);
    });

    testWidgets('is read once, never on a timer of its own', (tester) async {
      final harness = PlayerHarness(dhtStatus: neverBootstrapped)
        ..torrentStats.response = findingNoPeers;
      await pumpFinding(tester, harness);
      expect(harness.dhtStatusReads, 1);

      // Several more polls, a stall, and the OSD toggling on: none of it
      // asks about the DHT again.
      await poll(tester);
      await poll(tester);
      harness.engine.emitBuffering(true);
      await pumpEvents(tester);
      await tester.pump(PlayerScreen.torrentStallStatsInterval * 3);
      expect(harness.dhtStatusReads, 1);
    });
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
