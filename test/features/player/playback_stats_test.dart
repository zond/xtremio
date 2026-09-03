import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
        ),
      ),
      [
        'torrent  buffering head 25%',
        'speed    1.5 MB/s',
        'seeds    2 connected',
        'peers    4 connected / 9 found',
        'swarm    137 seeds / 402 peers · 4 min ago',
      ],
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
