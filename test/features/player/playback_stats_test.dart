import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_stats.dart';
import 'package:xtremio/features/player/playback_stats_overlay.dart';

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
}
