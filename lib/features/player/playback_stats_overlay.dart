import 'package:flutter/material.dart';

import 'playback_stats.dart';

/// The stats OSD: a small translucent monospace panel listing what the
/// engine reports in [PlaybackStats].
///
/// Subscribes to [stats] for as long as it is mounted, so whoever shows it
/// controls when the engine samples: mount it to start, unmount to stop.
class PlaybackStatsOverlay extends StatelessWidget {
  const PlaybackStatsOverlay({super.key, required this.stats});

  final Stream<PlaybackStats> stats;

  static const TextStyle _style = TextStyle(
    color: Colors.white,
    fontFamily: 'monospace',
    fontFamilyFallback: ['Menlo', 'Consolas', 'DejaVu Sans Mono'],
    fontSize: 11,
    height: 1.35,
  );

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackStats>(
      stream: stats,
      builder: (context, snapshot) {
        final sample = snapshot.data;
        return IgnorePointer(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line
                    in sample == null
                        ? const ['stats: collecting…']
                        : describe(sample))
                  Text(line, style: _style),
              ],
            ),
          ),
        );
      },
    );
  }

  /// One text line per stat, in the order the panel shows them.
  static List<String> describe(PlaybackStats s) => [
    'fps      ${_fps(s.outputFps)} out / ${_fps(s.containerFps)} container',
    'dropped  ${s.droppedFrames ?? '-'} vo'
        '${s.decoderDroppedFrames == null ? '' : ' / ${s.decoderDroppedFrames} decoder'}',
    'hwdec    ${_hwdec(s)}',
    'video    ${s.videoCodec ?? '-'}'
        '${s.width != null && s.height != null ? ' ${s.width}x${s.height}' : ''}',
    'bitrate  ${formatBitrate(s.videoBitrate)}',
    'cache    ${_cache(s)}',
  ];

  static String _fps(double? fps) => fps == null ? '-' : fps.toStringAsFixed(2);

  static String _hwdec(PlaybackStats s) => switch (s.isSoftwareDecoding) {
    null => '-',
    true => 'software (hwdec-current: ${s.hwdec})',
    false => s.hwdec!,
  };

  static String _cache(PlaybackStats s) {
    final duration = s.cacheDuration;
    final seconds = duration == null
        ? '-'
        : '${(duration.inMilliseconds / 1000).toStringAsFixed(1)}s';
    if (s.pausedForCache == true) {
      final fill = s.cacheBufferingState;
      return '$seconds  buffering${fill == null ? '' : ' $fill%'}';
    }
    return seconds;
  }

  /// Bits per second in human units: `850 kbps`, `4.2 Mbps`.
  static String formatBitrate(int? bitsPerSecond) {
    if (bitsPerSecond == null) return '-';
    if (bitsPerSecond >= 1000000) {
      return '${(bitsPerSecond / 1000000).toStringAsFixed(1)} Mbps';
    }
    if (bitsPerSecond >= 1000) {
      return '${(bitsPerSecond / 1000).round()} kbps';
    }
    return '$bitsPerSecond bps';
  }
}
