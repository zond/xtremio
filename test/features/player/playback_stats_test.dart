import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_stats.dart';
import 'package:xtremio/features/player/playback_stats_overlay.dart';
import 'package:xtremio/features/player/torrent_stats.dart';

void main() {
  test('parses mpv property strings', () {
    final stats = PlaybackStats.fromMpv({
      'estimated-vf-fps': '23.976024',
      'container-fps': '23.976025',
      'frame-drop-count': '3',
      'decoder-frame-drop-count': '0',
      'hwdec-current': 'vaapi',
      'video-codec': 'hevc (Main 10)',
      'video-params/w': '3840',
      'video-params/h': '2160',
      'video-bitrate': '15234567',
      'demuxer-cache-duration': '12.345678',
      'paused-for-cache': 'no',
      'cache-buffering-state': '100',
    });
    expect(stats.outputFps, closeTo(23.976, 0.001));
    expect(stats.containerFps, closeTo(23.976, 0.001));
    expect(stats.droppedFrames, 3);
    expect(stats.decoderDroppedFrames, 0);
    expect(stats.hwdec, 'vaapi');
    expect(stats.isSoftwareDecoding, isFalse);
    expect(stats.videoCodec, 'hevc (Main 10)');
    expect((stats.width, stats.height), (3840, 2160));
    expect(stats.videoBitrate, 15234567);
    expect(stats.cacheDuration, const Duration(milliseconds: 12346));
    expect(stats.pausedForCache, isFalse);
    expect(stats.cacheBufferingState, 100);
  });

  test('treats empty, missing and unparsable properties as unknown', () {
    // Before the first frame mpv returns "" for most of these.
    final stats = PlaybackStats.fromMpv({
      for (final name in PlaybackStats.mpvProperties) name: '',
      'estimated-vf-fps': 'nan?',
      'paused-for-cache': 'maybe',
    });
    expect(stats, const PlaybackStats());
    expect(stats.isSoftwareDecoding, isNull);
    expect(PlaybackStats.fromMpv(const {}), const PlaybackStats());
  });

  test('hwdec-current "no" means software decoding', () {
    expect(
      PlaybackStats.fromMpv({'hwdec-current': 'no'}).isSoftwareDecoding,
      isTrue,
    );
    expect(
      PlaybackStatsOverlay.describe(const PlaybackStats(hwdec: 'no')),
      contains('hwdec    software (hwdec-current: no)'),
    );
    expect(
      PlaybackStatsOverlay.describe(const PlaybackStats(hwdec: 'nvdec')),
      contains('hwdec    nvdec'),
    );
  });

  test('renders each stat on its own line in human units', () {
    final lines = PlaybackStatsOverlay.describe(
      const PlaybackStats(
        outputFps: 59.94,
        containerFps: 60,
        droppedFrames: 2,
        decoderDroppedFrames: 1,
        hwdec: 'vaapi',
        videoCodec: 'h264 (High)',
        width: 1920,
        height: 1080,
        videoBitrate: 4200000,
        cacheDuration: Duration(milliseconds: 8400),
        pausedForCache: true,
        cacheBufferingState: 37,
      ),
    );
    expect(lines, [
      'fps      59.94 out / 60.00 container',
      'dropped  2 vo / 1 decoder',
      'hwdec    vaapi',
      'video    h264 (High) 1920x1080',
      'bitrate  4.2 Mbps',
      'cache    8.4s  buffering 37%',
    ]);
    expect(PlaybackStatsOverlay.formatBitrate(850000), '850 kbps');
    expect(PlaybackStatsOverlay.formatBitrate(512), '512 bps');
    expect(PlaybackStatsOverlay.formatBitrate(null), '-');
    expect(
      PlaybackStatsOverlay.describe(const PlaybackStats()),
      everyElement(contains('-')),
    );
  });

  test('reads what the demuxer says it can seek in', () {
    // The reading the "seeking past the buffer jumps back" report is
    // taken from: mpv restores the position instead of seeking when the
    // demuxer says it cannot, and these are the properties that say so.
    // `demuxer-cache-state` is a node property, which mpv converts to
    // JSON on its way out through `mpv_get_property_string`.
    final stats = PlaybackStats.fromMpv({
      'seekable': 'yes',
      'partially-seekable': 'yes',
      'demuxer-cache-state':
          '{"seekable-ranges":[{"start":300.5,"end":420.0},'
          '{"start":0.0,"end":12.25}],"eof-cached":false,"fw-bytes":1234}',
    });
    expect(stats.seekable, isTrue);
    expect(stats.partiallySeekable, isTrue);
    expect(stats.seekableRanges, [
      const SeekableRange(
        Duration(milliseconds: 300500),
        Duration(seconds: 420),
      ),
      const SeekableRange(Duration.zero, Duration(milliseconds: 12250)),
    ]);
    expect(
      PlaybackStatsOverlay.describe(stats),
      containsAllInOrder([
        'seekable yes · partially yes',
        'ranges   300-420s, 0-12s',
      ]),
    );
  });

  test('a seekable we asked for is not reported as one mpv concluded', () {
    // The player sets `force-seekable` on the embedded server's own
    // streams, and mpv then answers `seekable yes` whatever the demuxer
    // thought -- so a panel printing `yes` there would be quoting our own
    // claim back as a reading, and the fault it was raised to diagnose
    // could never show. `partially-seekable`, which mpv sets alongside a
    // forced `seekable`, is what carries the demuxer's answer instead.
    final forced = PlaybackStats.fromMpv({
      'seekable': 'yes',
      'partially-seekable': 'yes',
      'force-seekable': 'yes',
    });
    expect(forced.seekableForced, isTrue);
    expect(
      PlaybackStatsOverlay.describe(forced),
      contains('seekable forced · partially yes'),
    );

    // The demuxer was content: our claim changed nothing and the fault is
    // somewhere else.
    final content = PlaybackStats.fromMpv({
      'seekable': 'yes',
      'partially-seekable': 'no',
      'force-seekable': 'yes',
    });
    expect(
      PlaybackStatsOverlay.describe(content),
      contains('seekable forced · partially no'),
    );

    // An addon's own URL is not forced, and both rows read straight.
    final addon = PlaybackStats.fromMpv({
      'seekable': 'no',
      'partially-seekable': 'no',
      'force-seekable': 'no',
    });
    expect(addon.seekableForced, isFalse);
    expect(
      PlaybackStatsOverlay.describe(addon),
      contains('seekable no · partially no'),
    );
  });

  test('no range is an answer; no answer is not', () {
    // Two different readings the panel must not confuse. `none` is mpv
    // saying the cache can serve a seek from nowhere yet -- which is what
    // every file reads for its first seconds, and not on its own a fault;
    // a backend that does not answer has told us nothing, and a row
    // claiming `none` there would be a measurement nobody made.
    final none = PlaybackStats.fromMpv({
      'seekable': 'no',
      'demuxer-cache-state': '{"seekable-ranges":[]}',
    });
    expect(none.seekableRanges, isEmpty);
    expect(
      PlaybackStatsOverlay.describe(none),
      containsAllInOrder(['seekable no · partially -', 'ranges   none']),
    );

    for (final state in const [
      'nothing mpv would ever say',
      '[1,2]',
      '{"fw-bytes":12}',
    ]) {
      final stats = PlaybackStats.fromMpv({'demuxer-cache-state': state});
      expect(stats.seekableRanges, isNull, reason: state);
      expect(
        PlaybackStatsOverlay.describe(stats),
        isNot(contains(startsWith('ranges'))),
        reason: state,
      );
    }

    // Nothing about seeking answered at all: neither row is drawn.
    expect(
      PlaybackStatsOverlay.describe(const PlaybackStats(hwdec: 'no')),
      isNot(anyElement(startsWith('seekable'))),
    );
  });

  test('the swarm rows say peers, and the phase only until it is ready', () {
    // Nothing back from the server yet: the panel says so rather than
    // showing zeros it has not measured.
    expect(PlaybackStatsOverlay.describeTorrent(null), [
      'torrent  waiting for the server',
    ]);

    // Ready: no phase row. Our connections are two rows (how many hold the
    // whole file, and how many are connected out of the addresses found),
    // and the swarm is a third -- here one no tracker answered for, which
    // says so instead of reporting a zero swarm.
    expect(
      PlaybackStatsOverlay.describeTorrent(
        const TorrentStats(
          phase: TorrentPhase.ready,
          peerDiscovery: PeerDiscovery(seen: 12),
        ),
      ),
      [
        'speed    0 B/s',
        'seeds    0 connected',
        'peers    0 connected / 12 found',
        'swarm    not reported',
      ],
    );

    // Not ready: the phase leads, with the percentage of whatever it is
    // the server is measuring. With a scrape behind it the swarm row
    // carries both sides of the swarm and how old the snapshot is.
    expect(
      PlaybackStatsOverlay.describeTorrent(
        const TorrentStats(
          phase: TorrentPhase.buffering,
          initialWindowReadyBytes: 1048576,
          initialWindowBytes: 4194304,
          downloadSpeed: 1500000,
          peers: 4,
          connectedSeeders: 2,
          swarmSeeders: 137,
          swarmLeechers: 402,
          swarmScrapeAge: Duration(minutes: 4),
          peerDiscovery: PeerDiscovery(seen: 9, live: 4),
          pieceLength: 2097152,
        ),
      ),
      [
        'torrent  buffering head 25%',
        'speed    1.5 MB/s',
        'seeds    2 connected',
        'peers    4 connected / 9 found',
        'swarm    137 seeds / 402 peers · 4 min ago',
        // The single number that explains why a wait is long: nothing is
        // readable until a whole piece is verified.
        'piece    2 MiB',
      ],
    );

    // With the server's sub-piece view the panel also says *which* piece
    // the reader is sitting on and how far into it -- and whether that
    // piece has passed its hash check, since a full byte count on its own
    // only means it is complete enough to be hashed.
    expect(
      PlaybackStatsOverlay.describeTorrent(
        const TorrentStats(
          phase: TorrentPhase.buffering,
          initialWindowReadyBytes: 0,
          initialWindowBytes: 16777216,
          pieceLength: 16777216,
          inFlightPiece: InFlightPiece(
            index: 137,
            downloadedBytes: 6553600,
            totalBytes: 16777216,
          ),
        ),
      ).skip(5),
      ['piece    16 MiB', 'inflight #137 · 6.3 of 16.0 MiB · unverified'],
    );
    expect(
      PlaybackStatsOverlay.describeTorrent(
        const TorrentStats(
          phase: TorrentPhase.ready,
          pieceLength: 16777216,
          inFlightPiece: InFlightPiece(
            index: 137,
            downloadedBytes: 16777216,
            totalBytes: 16777216,
            verified: true,
          ),
        ),
      ).last,
      'inflight #137 · 16.0 of 16.0 MiB · verified',
    );

    // A swarm the trackers say is empty is an answer, and reads as one --
    // the row a client must not confuse with "not reported" above.
    expect(
      PlaybackStatsOverlay.describeTorrent(
        const TorrentStats(
          phase: TorrentPhase.ready,
          swarmSeeders: 0,
          swarmLeechers: 0,
          swarmScrapeAge: Duration(seconds: 12),
        ),
      ),
      contains('swarm    0 seeds / 0 peers · 12 s ago'),
    );
    expect(PlaybackStatsOverlay.formatAge(const Duration(seconds: 59)), '59 s');
    expect(
      PlaybackStatsOverlay.formatAge(const Duration(minutes: 59)),
      '59 min',
    );
    expect(PlaybackStatsOverlay.formatAge(const Duration(minutes: 90)), '1 h');
    expect(
      PlaybackStatsOverlay.describeTorrent(
        const TorrentStats(
          phase: TorrentPhase.checking,
          checkedBytes: 3,
          checkTotalBytes: 4,
        ),
      ),
      contains('torrent  checking 75%'),
    );

    // The server's own reason for stopping gets a row of its own, under
    // the swarm rows rather than among them: it is the one row whose
    // length the app does not decide.
    const stopped = TorrentStats(phase: TorrentPhase.error, error: 'disk full');
    expect(
      PlaybackStatsOverlay.describeTorrent(stopped),
      contains('torrent  stopped'),
    );
    expect(
      PlaybackStatsOverlay.describeTorrent(stopped),
      isNot(contains('error    disk full')),
    );
    expect(
      PlaybackStatsOverlay.describeTorrentError(stopped),
      'error    disk full',
    );
    expect(
      PlaybackStatsOverlay.describeTorrentError(
        const TorrentStats(phase: TorrentPhase.ready),
      ),
      isNull,
    );
  });

  group('the DHT row', () {
    const bootstrapped = DhtStatus(
      enabled: true,
      nodes: 40,
      nodesV6: 3,
      everBootstrapped: true,
    );
    const neverBootstrapped = DhtStatus(
      enabled: true,
      nodes: 0,
      nodesV6: 0,
      everBootstrapped: false,
    );
    const disabled = DhtStatus(
      enabled: false,
      nodes: 0,
      nodesV6: 0,
      everBootstrapped: false,
    );

    test('says so, with the node counts, only while never bootstrapped', () {
      expect(
        PlaybackStatsOverlay.describeDht(neverBootstrapped),
        'dht      DHT unavailable — using trackers only · 0 nodes (0 v6)',
      );
    });

    testWidgets('is absent once bootstrapped, disabled, or unread', (
      tester,
    ) async {
      Future<void> pumpWith(DhtStatus? dht) => tester.pumpWidget(
        MaterialApp(
          home: PlaybackStatsOverlay(
            stats: const Stream<PlaybackStats>.empty(),
            isTorrent: true,
            torrent: const TorrentStats(phase: TorrentPhase.ready, peers: 4),
            dht: dht,
          ),
        ),
      );

      await pumpWith(bootstrapped);
      await tester.pump();
      expect(find.textContaining('dht'), findsNothing);

      await pumpWith(disabled);
      await tester.pump();
      expect(find.textContaining('dht'), findsNothing);

      await pumpWith(null);
      await tester.pump();
      expect(find.textContaining('dht'), findsNothing);

      // The one state that is news.
      await pumpWith(neverBootstrapped);
      await tester.pump();
      expect(
        find.textContaining('DHT unavailable — using trackers only'),
        findsOneWidget,
      );
    });
  });

  testWidgets('a long error from the server does not take over the frame', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: PlaybackStatsOverlay(
            stats: const Stream<PlaybackStats>.empty(),
            isTorrent: true,
            torrent: TorrentStats(
              phase: TorrentPhase.error,
              // The server passes its reason through verbatim, and some of
              // them are a paragraph.
              error: 'the torrent could not be added: ${'why ' * 60}',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // The panel stays a panel in the corner: as wide as the row it holds
    // to, and no taller than its rows plus the two lines the error is cut
    // off at -- a bound the paragraph would blow through if it wrapped.
    final size = tester.getSize(find.byType(PlaybackStatsOverlay));
    expect(size.width, lessThan(PlaybackStatsOverlay.wideRowWidth + 40));
    expect(size.height, lessThan(140));
  });
}
