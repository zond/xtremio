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
      'display-fps': '23.976025',
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
    expect(stats.displayFps, closeTo(23.976, 0.001));
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
      'cache    8.4s mpv  buffering 37%',
    ]);
    expect(PlaybackStatsOverlay.formatBitrate(850000), '850 kbps');
    expect(PlaybackStatsOverlay.formatBitrate(512), '512 bps');
    expect(PlaybackStatsOverlay.formatBitrate(null), '-');
    expect(
      PlaybackStatsOverlay.describe(const PlaybackStats()),
      everyElement(contains('-')),
    );
  });

  test('says what rate mpv thinks the display is on, right under the drop '
      'counts', () {
    // The row the drop counts are read against. On Android mpv cannot
    // measure the display and is told the rate instead
    // (`MediaKitEngine.displayRateProperties`); this is its own belief
    // read back, so a rate here that is not the one the display settled on
    // is a set that went nowhere and the drops belong to something else.
    expect(
      PlaybackStatsOverlay.describe(
        const PlaybackStats(
          droppedFrames: 2779,
          decoderDroppedFrames: 0,
          displayFps: 23.976025,
        ),
      ),
      containsAllInOrder(const [
        'dropped  2779 vo / 0 decoder',
        'display  23.976 Hz',
      ]),
    );

    // The rate the panel was never asked to be on is as much a reading as
    // the right one, and it is the one that says the ask did not land.
    expect(
      PlaybackStatsOverlay.describe(const PlaybackStats(displayFps: 59.94)),
      contains('display  59.940 Hz'),
    );

    // But an engine with no such property draws no row: a dash there would
    // read as a measured rate of none on a backend nobody asked.
    expect(
      PlaybackStatsOverlay.describe(const PlaybackStats(hwdec: 'no')),
      isNot(contains(startsWith('display '))),
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

  group('the cache row carries mpv\'s buffer and the retention window', () {
    const bitrate = 8000000; // 1 MB of video a second, so bytes read as time.

    List<String> rows({
      CacheWindow? window,
      int? videoBitrate = bitrate,
      SharingNumbers? sharing,
    }) => PlaybackStatsOverlay.describe(
      PlaybackStats(
        videoBitrate: videoBitrate,
        cacheDuration: const Duration(milliseconds: 294600),
      ),
      held: window == null && sharing == null
          ? null
          : StreamNumbers(window: window, sharing: sharing),
    );

    String cacheRow(List<String> lines) =>
        lines.firstWhere((line) => line.startsWith('cache'));

    test('the mpv half is labelled, so it cannot read as ours', () {
      // It always was mpv's few seconds of memory; unlabelled it read as
      // the disk, which is the row's other half now.
      expect(cacheRow(rows()), 'cache    294.6s mpv');
    });

    test('the window is two halves, in bytes and in watching', () {
      expect(
        cacheRow(
          rows(
            window: const CacheWindow(
              behindBytes: 1288490188,
              aheadBytes: 356515840,
            ),
          ),
        ),
        'cache    294.6s mpv · behind 1.3 GB (21 min) · ahead 356.5 MB (5 min)',
      );
    });

    test('a half that holds nothing reads as the zero it was measured at', () {
      // Zero here is not an absence: the window exists, and this side of
      // the playhead is empty -- which is what a stream that has just
      // started looks like behind, and what a seek that outran the
      // read-ahead looks like ahead.
      expect(
        cacheRow(
          rows(window: const CacheWindow(behindBytes: 0, aheadBytes: 0)),
        ),
        'cache    294.6s mpv · behind 0 B (0 s) · ahead 0 B (0 s)',
      );
    });

    test('no bitrate, no time -- and never a dash beside the bytes', () {
      // mpv answers no `video-bitrate` for the first seconds of every
      // file, which is exactly when someone is watching this row.
      expect(
        cacheRow(
          rows(
            videoBitrate: null,
            window: const CacheWindow(behindBytes: 0, aheadBytes: 356515840),
          ),
        ),
        'cache    294.6s mpv · behind 0 B · ahead 356.5 MB',
      );
    });

    test('a bitrate of zero is no rate either, and not a division by one', () {
      // mpv answers `video-bitrate` as 0 rather than leaving it out on
      // plenty of files -- the panel's own bitrate row has a place for
      // that reading. Bytes over nothing is not a length of watching: the
      // seconds come out infinite, and asking for a `Duration` of that
      // throws out of the panel's build rather than drawing anything at
      // all. So zero is treated as the absence it is, and the halves go on
      // in bytes alone.
      final lines = rows(
        videoBitrate: 0,
        window: const CacheWindow(behindBytes: 1288490188, aheadBytes: 0),
      );
      expect(lines, contains('bitrate  0 bps'));
      expect(
        cacheRow(lines),
        'cache    294.6s mpv · behind 1.3 GB · ahead 0 B',
      );
    });

    test('nothing bounding the stream leaves the row mpv\'s alone', () {
      // A torrent the budget covers has no policy and so no window, and a
      // stream this server does not hold has neither. Dashes there would
      // say a cache of nothing was measured.
      expect(rows(), isNot(contains(contains('behind'))));
      expect(rows(window: null, sharing: null), isNot(contains(contains('·'))));
    });
  });

  group('the waste row is what the cache fetched and threw away', () {
    List<String> rows(SharingNumbers? sharing) =>
        PlaybackStatsOverlay.describeWaste(
          sharing == null ? null : StreamNumbers(sharing: sharing),
        );

    test('bytes dropped and reclaims refused, both of them', () {
      // The two numbers that made the 1.6 GB open legible: pieces the
      // cache fetched and its own next pass deleted, and pieces it asked
      // the backend to forget and could not, because an open stream was
      // still reading ahead over them.
      expect(
        rows(
          const SharingNumbers(
            transfer: LiveTransfer(
              downloadedBytes: 1600000000,
              wastedBytes: 1500000000,
              uploadedBytes: 0,
            ),
            refusedReclaims: 33,
          ),
        ),
        ['waste  1.5 GB fetched and dropped · 33 reclaims refused'],
      );
    });

    test('a healthy stream still draws the row, at zero', () {
      // Zero is the reading, not an absence: a viewer looking for this is
      // looking for whether it is climbing.
      expect(
        rows(
          const SharingNumbers(
            transfer: LiveTransfer(
              downloadedBytes: 100,
              wastedBytes: 0,
              uploadedBytes: 0,
            ),
            refusedReclaims: 0,
          ),
        ),
        ['waste  0 B fetched and dropped · 0 reclaims refused'],
      );
    });

    test(
      'one refusal is singular, and a stream with no numbers has no row',
      () {
        expect(rows(const SharingNumbers(refusedReclaims: 1)), [
          'waste  1 reclaim refused',
        ]);
        expect(rows(null), isEmpty);
        expect(PlaybackStatsOverlay.describeWaste(null), isEmpty);
      },
    );
  });

  group(
    'the sharing row is a torrent\'s promises and its live period\'s bytes',
    () {
      List<String> rows(SharingNumbers? sharing) =>
          PlaybackStatsOverlay.describeSharing(
            sharing == null ? null : StreamNumbers(sharing: sharing),
          );

      test('committed, both directions, and the ratio said to be a live '
          'period\'s', () {
        // "since it last went live" and not "this session": the counters are
        // the live state's own, so a pause and resume or an idle drop
        // and re-add starts them at zero again. A viewer whose torrent
        // shared gigabytes half an hour ago is looking at ↑ 0 B, and the
        // words beside it must be true of that.
        expect(
          rows(
            const SharingNumbers(
              committedBytes: 859832320,
              transfer: LiveTransfer(
                downloadedBytes: 4800000000,
                wastedBytes: 0,
                uploadedBytes: 2100000000,
                ratio: 0.4375,
              ),
            ),
          ),
          [
            'sharing  859.8 MB committed · ↑ 2.1 GB ↓ 4.8 GB'
                ' · 0.44 since it last went live',
          ],
        );
      });

      test('a stream with no swarm has no row at all', () {
        // A proxied response is not seeded: no committed set, no ratio. A
        // line of zeroes would say it had shared nothing, when the truth is
        // that there was nothing to share.
        expect(rows(null), isEmpty);
        expect(PlaybackStatsOverlay.describeSharing(null), isEmpty);
        expect(
          PlaybackStatsOverlay.describeSharing(
            const StreamNumbers(
              window: CacheWindow(behindBytes: 1, aheadBytes: 2),
            ),
          ),
          isEmpty,
        );
      });

      test('a torrent with no policy has promised nothing, not zero bytes', () {
        expect(
          rows(
            const SharingNumbers(
              transfer: LiveTransfer(
                downloadedBytes: 4800000000,
                wastedBytes: 0,
                uploadedBytes: 2100000000,
                ratio: 0.4375,
              ),
            ),
          ),
          ['sharing  ↑ 2.1 GB ↓ 4.8 GB · 0.44 since it last went live'],
        );
      });

      test(
        'counters that cannot be read take the whole transfer with them',
        () {
          // Paused, checking, stopped for space, in error: a torrent that has
          // moved gigabytes and then paused has not moved nothing.
          expect(rows(const SharingNumbers(committedBytes: 859832320)), [
            'sharing  859.8 MB committed',
          ]);
        },
      );

      test(
        'a ratio against nothing downloaded is left out, never drawn 0.00',
        () {
          // A torrent resumed onto a complete file and seeded from it: the
          // ratio is undefined, and 0.00 would tell a viewer they have shared
          // nothing while they are sharing.
          expect(
            rows(
              const SharingNumbers(
                transfer: LiveTransfer(
                  downloadedBytes: 0,
                  wastedBytes: 0,
                  uploadedBytes: 2100000000,
                ),
              ),
            ),
            ['sharing  ↑ 2.1 GB ↓ 0 B since it last went live'],
          );
        },
      );

      test('the bytes carry the period even with no ratio beside them', () {
        // The same seeding torrent, said as the rule rather than as the
        // shape: the period belongs to the counters, so it cannot leave
        // with the ratio. Uploaded gigabytes under no period at all read
        // as everything this torrent has ever given back, when they are
        // one live period's -- and the idle sweep dropping the engine and
        // a later stream re-adding it starts that period again.
        final seeding = rows(
          const SharingNumbers(
            committedBytes: 859832320,
            transfer: LiveTransfer(
              downloadedBytes: 0,
              wastedBytes: 0,
              uploadedBytes: 2100000000,
            ),
          ),
        );
        expect(seeding, [
          'sharing  859.8 MB committed · ↑ 2.1 GB ↓ 0 B'
              ' since it last went live',
        ]);
      });
    },
  );

  test('bytes are decimal, on the panel\'s own ladder', () {
    expect(PlaybackStatsOverlay.formatBytes(0), '0 B');
    expect(PlaybackStatsOverlay.formatBytes(999), '999 B');
    expect(PlaybackStatsOverlay.formatBytes(340000), '340 kB');
    expect(PlaybackStatsOverlay.formatBytes(356515840), '356.5 MB');
    expect(PlaybackStatsOverlay.formatBytes(1288490188), '1.3 GB');
  });

  testWidgets('a proxied stream draws the window and no sharing row', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: PlaybackStatsOverlay(
            stats: Stream<PlaybackStats>.value(
              const PlaybackStats(
                videoBitrate: 8000000,
                cacheDuration: Duration(seconds: 12),
              ),
            ),
            // What a proxied stream answers: a window off the proxy cache,
            // and no sharing at all -- it is not seeded.
            held: const StreamNumbers(
              window: CacheWindow(behindBytes: 60000000, aheadBytes: 30000000),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text(
        'cache    12.0s mpv · behind 60.0 MB (1 min) · ahead 30.0 MB (30 s)',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('sharing'), findsNothing);
  });

  testWidgets('the sharing row is the server\'s answer, not the app\'s claim', (
    tester,
  ) async {
    // The row is drawn from what the server said about the stream, above
    // this player's own idea of what kind of stream it is: the two are
    // different questions, and only one of them was measured. So it sits
    // with the cache row it is read against rather than inside the swarm
    // block, and a panel that was told there is no torrent still shows
    // what the server says it has committed and moved.
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: PlaybackStatsOverlay(
            stats: Stream<PlaybackStats>.value(
              const PlaybackStats(cacheDuration: Duration(seconds: 12)),
            ),
            isTorrent: false,
            held: const StreamNumbers(
              sharing: SharingNumbers(committedBytes: 820000000),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('sharing  820.0 MB committed'), findsOneWidget);
    // And nothing about a swarm, which is what `isTorrent` decides.
    expect(find.textContaining('speed    '), findsNothing);
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
