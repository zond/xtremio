import 'package:flutter/material.dart';

/// One line of what a torrent-progress card says, derived from the server's
/// stats: a phase label (with the percentage when there is one), the
/// progress for a determinate bar (null for an indeterminate one), and an
/// optional detail line (download speed, peers).
final class TorrentProgressStatus {
  const TorrentProgressStatus({
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

/// The card the player puts over the video whenever the torrent, rather
/// than the engine, is what playback is waiting for: what the server is
/// doing and how far along it is, in place of a bare spinner.
///
/// Two moments fill it: `TorrentStartupOverlay` before the first frame and
/// `TorrentStallOverlay` when playback stalls later. They differ only in
/// what they say about a phase, which is why the card takes a finished
/// [TorrentProgressStatus] rather than the stats.
class TorrentProgressCard extends StatelessWidget {
  const TorrentProgressCard({super.key, required this.status});

  final TorrentProgressStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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

  /// A label with the percentage appended when there is one to append.
  static String withPercent(String label, double? progress) =>
      progress == null ? label : '$label ${(progress * 100).round()}%';

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
