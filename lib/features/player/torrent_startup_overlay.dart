import 'package:flutter/material.dart';

import 'torrent_stats.dart';

/// One line of what the start-up overlay says, derived from the server's
/// stats: a phase label (with the percentage when there is one), the
/// progress for a determinate bar (null for an indeterminate one), and an
/// optional detail line (download speed, peers).
final class TorrentStartupStatus {
  const TorrentStartupStatus({
    required this.label,
    this.progress,
    this.detail,
    this.failed = false,
  });

  final String label;

  /// `0..1`, or null when nothing measurable is going on yet.
  final double? progress;
  final String? detail;

  /// The server reported the torrent as failed: no progress to expect.
  final bool failed;
}

/// Shown over the video from the moment a torrent's URL is opened until
/// the engine reports the media loaded, instead of a bare spinner: what
/// the server is doing to get the first bytes ready (hash-checking data it
/// already has, finding peers, filling the initial window) and how far
/// along it is.
class TorrentStartupOverlay extends StatelessWidget {
  const TorrentStartupOverlay({super.key, required this.stats});

  /// The latest `stats.json`, or null while the server has not answered
  /// for this torrent yet.
  final TorrentStats? stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = describe(stats);
    final detail = status.detail;
    return Card(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 280, maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    status.failed
                        ? Icons.error_outline
                        : Icons.downloading_outlined,
                    size: 20,
                    color: status.failed
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      status.label,
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (!status.failed) ...[
                const SizedBox(height: 12),
                // Determinate when there is a percentage; the indeterminate
                // sweep is the only thing here that animates on its own.
                LinearProgressIndicator(value: status.progress),
              ],
              if (detail != null) ...[
                const SizedBox(height: 8),
                Text(detail, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// What to say for [stats]. Null stats means the server has not answered
  /// for this torrent yet (unreachable, or a 404 before the engine exists).
  static TorrentStartupStatus describe(TorrentStats? stats) {
    if (stats == null) {
      return const TorrentStartupStatus(label: 'Connecting to server…');
    }
    final detail = _detail(stats);
    switch (stats.phase) {
      case TorrentPhase.resolvingMetadata:
        return TorrentStartupStatus(
          label: 'Fetching torrent metadata…',
          detail: detail,
        );
      case TorrentPhase.checking:
        final progress = stats.checkProgress;
        return TorrentStartupStatus(
          label: _withPercent('Checking existing data…', progress),
          progress: progress,
          detail: detail,
        );
      case TorrentPhase.buffering:
        final progress = stats.initialWindowProgress;
        if (stats.peerDiscovery.live == 0 && stats.peers == 0) {
          final found = stats.peerDiscovery.seen;
          final connecting = stats.peerDiscovery.connecting;
          return TorrentStartupStatus(
            label: 'Finding peers…',
            progress: progress,
            detail: found == 0
                ? 'No peers found yet'
                : '$found found'
                      '${connecting > 0 ? ' · $connecting connecting' : ''}',
          );
        }
        return TorrentStartupStatus(
          label: _withPercent('Buffering start…', progress),
          progress: progress,
          detail: detail,
        );
      case TorrentPhase.ready:
        return TorrentStartupStatus(
          label: 'Starting playback…',
          progress: 1,
          detail: detail,
        );
      case TorrentPhase.error:
        return const TorrentStartupStatus(
          label: 'The torrent failed to start',
          failed: true,
        );
      case TorrentPhase.unknown:
        return TorrentStartupStatus(label: 'Preparing stream…', detail: detail);
    }
  }

  static String _withPercent(String label, double? progress) =>
      progress == null ? label : '$label ${(progress * 100).round()}%';

  /// Speed and peers, whichever are non-zero; null when both are.
  static String? _detail(TorrentStats stats) {
    final parts = <String>[
      if (stats.downloadSpeed > 0) formatSpeed(stats.downloadSpeed),
      if (stats.peers > 0)
        '${stats.peers} ${stats.peers == 1 ? 'peer' : 'peers'}',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// Bytes per second in human units: `850 kB/s`, `4.2 MB/s`.
  static String formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond >= 1000000) {
      return '${(bytesPerSecond / 1000000).toStringAsFixed(1)} MB/s';
    }
    if (bytesPerSecond >= 1000) {
      return '${(bytesPerSecond / 1000).round()} kB/s';
    }
    return '${bytesPerSecond.round()} B/s';
  }
}
