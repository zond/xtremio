import 'package:flutter/material.dart';

import '../../shell/device_profile.dart';
import 'playback_stats.dart';
import 'torrent_progress_card.dart';
import 'torrent_stats.dart';

/// The stats OSD: a small translucent monospace panel listing what the
/// engine reports in [PlaybackStats], and for a torrent what the embedded
/// server reports about the swarm feeding it ([torrent]).
///
/// Subscribes to [stats] for as long as it is mounted, so whoever shows it
/// controls when the engine samples: mount it to start, unmount to stop.
/// The torrent rows are polled by the player, which keeps them coming for
/// as long as this panel is up.
class PlaybackStatsOverlay extends StatelessWidget {
  const PlaybackStatsOverlay({
    super.key,
    required this.stats,
    this.source,
    this.isTorrent = false,
    this.torrent,
  });

  final Stream<PlaybackStats> stats;

  /// The URL libmpv is playing, shown as the last line (a torrent reads
  /// `http://127.0.0.1:11470/<infoHash>/<fileIdx>?tr=…`).
  final Uri? source;

  /// The stream is a torrent the embedded server is serving: the swarm
  /// rows belong in the panel, even before [torrent] has arrived. False for
  /// a direct HTTP stream, which has no swarm to describe.
  final bool isTorrent;

  /// The latest `stats.json` for that torrent, or null while the player's
  /// poll has not answered yet.
  final TorrentStats? torrent;

  static const TextStyle _style = TextStyle(
    color: Colors.white,
    fontFamily: 'monospace',
    fontFamilyFallback: ['Menlo', 'Consolas', 'DejaVu Sans Mono'],
    fontSize: 11,
    height: 1.35,
  );

  /// The font size the panel uses on a television. The set's global text
  /// scale alone leaves the 11pt monospace of a desktop unreadable from a
  /// sofa, and this panel is the one place where the numbers are the whole
  /// point of looking.
  static const double tvFontSize = 16;

  @override
  Widget build(BuildContext context) {
    final style = DeviceScope.isTv(context)
        ? _style.copyWith(fontSize: tvFontSize)
        : _style;
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
                  Text(line, style: style),
                if (isTorrent)
                  for (final line in describeTorrent(torrent))
                    Text(line, style: style),
                if (source != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Text(
                      'url      $source',
                      style: style,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
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

  /// The torrent rows, in the same label column as the mpv ones: what the
  /// swarm is doing right now. Null stats means the poll has not answered
  /// for this torrent yet.
  ///
  /// The counts are connections -- peers, never "seeds": the server counts
  /// who has handshaked (`live`) and how many addresses the search has
  /// turned up (`seen`), not who has the whole file. The phase is worth a
  /// row only while the torrent is not ready; once it is, the speed and the
  /// peers are the news.
  static List<String> describeTorrent(TorrentStats? s) {
    if (s == null) return const ['torrent  waiting for the server'];
    final error = s.error;
    return [
      if (s.phase != TorrentPhase.ready) 'torrent  ${_phase(s)}',
      'speed    ${TorrentProgressCard.formatSpeed(s.downloadSpeed)}',
      'peers    ${s.peerDiscovery.live} connected'
          ' / ${s.peerDiscovery.seen} found',
      if (error != null) 'error    $error',
    ];
  }

  /// The phase, with the percentage of whatever it is measuring when the
  /// server measures one.
  static String _phase(TorrentStats s) => switch (s.phase) {
    TorrentPhase.resolvingMetadata => 'resolving metadata',
    TorrentPhase.checking => TorrentProgressCard.withPercent(
      'checking',
      s.checkProgress,
    ),
    TorrentPhase.buffering => TorrentProgressCard.withPercent(
      'buffering head',
      s.initialWindowProgress,
    ),
    TorrentPhase.ready => 'ready',
    TorrentPhase.error => 'stopped',
    TorrentPhase.unknown => 'unknown',
  };

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
