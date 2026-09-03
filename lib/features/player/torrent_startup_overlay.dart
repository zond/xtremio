import 'package:flutter/material.dart';

import 'torrent_progress_card.dart';
import 'torrent_stats.dart';

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
  Widget build(BuildContext context) =>
      TorrentProgressCard(status: describe(stats));

  /// What to say for [stats]. Null stats means the server has not answered
  /// for this torrent yet (unreachable, or a 404 before the engine exists).
  static TorrentProgressStatus describe(TorrentStats? stats) {
    if (stats == null) {
      return const TorrentProgressStatus(label: 'Connecting to server…');
    }
    final detail = _detail(stats);
    switch (stats.phase) {
      case TorrentPhase.resolvingMetadata:
        return TorrentProgressStatus(
          label: 'Fetching torrent metadata…',
          detail: detail,
        );
      case TorrentPhase.checking:
        final progress = stats.checkProgress;
        return TorrentProgressStatus(
          label: TorrentProgressCard.withPercent(
            'Checking existing data…',
            progress,
          ),
          progress: progress,
          detail: detail,
        );
      case TorrentPhase.buffering:
        final progress = stats.initialWindowProgress;
        if (stats.peerDiscovery.live == 0 && stats.peers == 0) {
          final found = stats.peerDiscovery.seen;
          final connecting = stats.peerDiscovery.connecting;
          return TorrentProgressStatus(
            label: 'Finding peers…',
            progress: progress,
            detail: found == 0
                ? 'No peers found yet'
                : '$found found'
                      '${connecting > 0 ? ' · $connecting connecting' : ''}',
          );
        }
        return TorrentProgressStatus(
          label: TorrentProgressCard.withPercent('Buffering start…', progress),
          progress: progress,
          detail: detail,
        );
      case TorrentPhase.ready:
        return TorrentProgressStatus(
          label: 'Starting playback…',
          progress: 1,
          detail: detail,
        );
      case TorrentPhase.error:
        // The server's reason (a magnet whose metadata never arrived, an
        // add that failed) is the detail; nothing measurable follows.
        return TorrentProgressStatus(
          label: 'The torrent failed to start',
          detail: stats.error,
          failed: true,
        );
      case TorrentPhase.unknown:
        return TorrentProgressStatus(
          label: 'Preparing stream…',
          detail: detail,
        );
    }
  }

  /// Speed and peers, whichever are non-zero; null when both are.
  static String? _detail(TorrentStats stats) {
    final parts = <String>[
      if (stats.downloadSpeed > 0)
        TorrentProgressCard.formatSpeed(stats.downloadSpeed),
      if (stats.peers > 0)
        '${stats.peers} ${stats.peers == 1 ? 'peer' : 'peers'}',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}
