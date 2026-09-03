import 'dart:math' as math;

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
    this.piece,
    this.detail,
    this.failed = false,
  });

  final String label;

  /// `0..1`, or null when nothing measurable is going on yet.
  final double? progress;

  /// The single piece the reader is sitting on, when the server knows it.
  /// It replaces [progress] as what the bar draws, because it is a
  /// measurement of the very bytes the wait is for -- and it is drawn by
  /// [PieceProgressBar], which owes it three honesty rules a plain
  /// percentage does not.
  ///
  /// Null is "we do not know", not "nothing downloaded", so a null piece
  /// falls back to [progress] rather than to a bar sitting at zero.
  final InFlightPiece? piece;

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
                // The piece the reader waits on when the server knows it;
                // otherwise determinate when there is a percentage, and the
                // indeterminate sweep -- which says "something is happening
                // that cannot be measured", never "zero" -- when there is
                // not.
                if (status.piece case final piece?)
                  PieceProgressBar(piece: piece)
                else
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

  /// The same wait once the server says how far into that piece it is:
  /// `Waiting for piece 137, 6.3 of 16.0 MiB…`.
  ///
  /// Which piece it is comes from the server, so it is the piece's index
  /// in the torrent rather than a number this counted itself; the bytes
  /// are the piece's own, which is why a short last piece reads honestly.
  static String piecePosition(InFlightPiece piece) =>
      'Waiting for piece ${piece.index}, '
      '${formatPieceBytes(piece.downloadedBytes, piece.totalBytes)}…';

  /// `6.3 of 16.0 MiB`: two byte counts in the unit the larger of them
  /// takes, named once. Binary units, like [formatPieceSize], because
  /// piece lengths are powers of two.
  static String formatPieceBytes(int part, int total) {
    const units = ['B', 'kiB', 'MiB', 'GiB'];
    var scale = 1.0;
    var unit = 0;
    while (total / scale >= 1024 && unit < units.length - 1) {
      scale *= 1024;
      unit++;
    }
    final digits = unit == 0 ? 0 : 1;
    return '${(part / scale).toStringAsFixed(digits)} of '
        '${(total / scale).toStringAsFixed(digits)} ${units[unit]}';
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

/// The bar for the one piece the reader is waiting on, which is the only
/// thing on this card measuring bytes that are still moving -- and the only
/// one that has to be careful about it.
///
/// Three rules, all of them the server's own (`stream-server`'s README,
/// "The in-flight piece"), and none of them what a plain
/// `LinearProgressIndicator(value: piece.progress)` would do:
///
/// * **Full is not finished.** `downloadedBytes` counts chunks the moment
///   they are written to disk; the hash is only checked once the last one
///   is in. So a full count means "complete enough to be hashed", and the
///   bar holds at [unverifiedCap] until `verified` -- which is then what
///   fills it.
/// * **It never runs backwards.** A decrease is a piece that failed its
///   hash check and was discarded, not progress being undone: the bar
///   stays where it got to rather than animating down.
/// * **A different piece is a different wait**, so it starts where that
///   piece is, at once and with no transition -- the reader moved (a seek,
///   a re-open), and nothing about the old piece's fill is news about the
///   new one.
///
/// Nothing here animates: the value is drawn as it is, so "no transition"
/// is the absence of one rather than one that is cancelled.
class PieceProgressBar extends StatefulWidget {
  const PieceProgressBar({super.key, required this.piece});

  final InFlightPiece piece;

  /// How full an unverified piece is allowed to draw. Short of the end on
  /// purpose: the bytes are all on disk but none of them can be served
  /// until the hash checks out, and a bar at the end would say they can.
  static const double unverifiedCap = 0.97;

  /// What [piece] on its own says the bar should read, before the
  /// no-going-backwards rule the state applies on top.
  static double target(InFlightPiece piece) =>
      piece.verified ? 1 : math.min(piece.progress, unverifiedCap);

  @override
  State<PieceProgressBar> createState() => _PieceProgressBarState();
}

class _PieceProgressBarState extends State<PieceProgressBar> {
  late int _index = widget.piece.index;
  late double _value = PieceProgressBar.target(widget.piece);

  @override
  void didUpdateWidget(covariant PieceProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final piece = widget.piece;
    final target = PieceProgressBar.target(piece);
    // No `setState`: a build follows this call anyway, and there is no
    // animation to start -- which is the point.
    if (piece.index != _index) {
      _index = piece.index;
      _value = target;
    } else if (target > _value) {
      _value = target;
    }
    // A decrease within one piece is a failed hash check. Hold.
  }

  @override
  Widget build(BuildContext context) => LinearProgressIndicator(value: _value);
}
