import 'package:flutter/material.dart';

import 'torrent_stats.dart';

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

  /// Who is on the other end, in the convention every torrent client
  /// uses: `seeds 2 of 137 · peers 5 · 12 found`. The first number is
  /// connections that hold the whole file, the second the swarm's own
  /// seeder count from the trackers, then live connections and, when the
  /// search has turned up more addresses than that, how many.
  ///
  /// A swarm nobody could ask about (`swarmSeeders` null) simply loses its
  /// half of the first part -- `seeds 2` -- rather than printing a 0, a
  /// dash or a "?", every one of which would read as an answer about the
  /// swarm.
  static String formatSwarm(TorrentStats stats) {
    final swarm = stats.swarmSeeders;
    final seen = stats.peerDiscovery.seen;
    return [
      'seeds ${stats.connectedSeeders}${swarm == null ? '' : ' of $swarm'}',
      'peers ${stats.peers}',
      if (seen > stats.peers) '$seen found',
    ].join(' · ');
  }

  /// What the wait is when the window the reader wants is one piece wide:
  /// `Waiting for the first piece (16 MiB)…`.
  ///
  /// A piece is the unit that becomes readable -- librqbit credits
  /// verified pieces and nothing in between -- so a one-piece window can
  /// only ever read 0% or 100%. Saying which piece and how big it is
  /// describes the wait honestly; a percentage stuck at 0 while the
  /// download runs at 2 MB/s does not. [first] is the start-up wait, where
  /// nothing has played yet; a stall mid-file is waiting for the *next*
  /// one.
  static String pieceWait(TorrentStats stats, {required bool first}) {
    final size = stats.initialWindowBytes;
    final which = first ? 'first' : 'next';
    return size == null
        ? 'Waiting for the $which piece…'
        : 'Waiting for the $which piece (${formatPieceSize(size)})…';
  }

  /// `about 12 s left` at the current speed, or null when nothing is
  /// arriving or the wait is longer than the estimate is worth. An
  /// estimate, and it says so.
  static String? formatEta(TorrentStats stats) {
    final eta = stats.windowEta;
    if (eta == null) return null;
    if (eta.inSeconds < 60) return 'about ${eta.inSeconds} s left';
    return 'about ${eta.inMinutes} min left';
  }

  /// A piece's size in binary units (`16 MiB`, `512 kiB`). Piece lengths
  /// are powers of two, which the decimal units file sizes use would turn
  /// into `16.8 MB`.
  static String formatPieceSize(int bytes) {
    const units = ['B', 'kiB', 'MiB', 'GiB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final rounded = value == value.roundToDouble()
        ? value.round().toString()
        : value.toStringAsFixed(1);
    return '$rounded ${units[unit]}';
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
