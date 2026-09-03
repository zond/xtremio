import 'package:flutter/material.dart';

import 'torrent_progress_card.dart';
import 'torrent_stats.dart';

/// Shown over the video when playback stalls after it has started: mpv has
/// run out of buffered data and is waiting for the torrent, which until now
/// was a bare spinner with a sentence next to it.
///
/// It is the start-up card's presentation said in the present tense, and it
/// is deliberately more sparing with percentages. The server's only measured
/// target is the *head* of the file (the initial priority window) plus a
/// hash check, so once playback is past the head there is nothing whose
/// completion can be drawn: the bar goes indeterminate and the numbers --
/// speed, seeds and peers, zeros included, which during a stall is exactly
/// the answer -- carry the news.
class TorrentStallOverlay extends StatelessWidget {
  const TorrentStallOverlay({super.key, required this.stats});

  /// The latest `stats.json`, or null while the stall polling has not
  /// answered yet (it starts over at every stall, the last answer being
  /// minutes old by then).
  final TorrentStats? stats;

  @override
  Widget build(BuildContext context) =>
      TorrentProgressCard(status: describe(stats));

  /// The label the player showed before this card existed, and what a
  /// stall says whenever the server has nothing more precise to add.
  static const String waiting = 'Buffering from the torrent…';

  /// What to say for [stats] during a stall. Null stats means nothing has
  /// come back yet (the first poll is still out, or the server has no
  /// answer for this torrent).
  static TorrentProgressStatus describe(TorrentStats? stats) {
    if (stats == null) return const TorrentProgressStatus(label: waiting);
    final detail = _detail(stats);
    switch (stats.phase) {
      case TorrentPhase.error:
        // Nothing more is coming: the server gave up on the torrent
        // mid-playback (a full disk, a download folder that went away).
        return TorrentProgressStatus(
          label: 'The torrent stopped',
          detail: stats.error,
          failed: true,
        );
      case TorrentPhase.resolvingMetadata:
        return TorrentProgressStatus(
          label: 'Waiting for the torrent…',
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
        // The head window is still filling, so the stall is the start-up
        // one arriving late (playback began on a partial window) and its
        // percentage is about the very bytes being waited for.
        final progress = stats.initialWindowProgress;
        // One piece wide: there is nothing between 0 and done to draw, so
        // the card says which piece it is waiting for and how big it is.
        if (stats.waitsForOnePiece) {
          return TorrentProgressStatus(
            label: TorrentProgressCard.pieceWait(stats, first: false),
            detail: [detail, ?TorrentProgressCard.formatEta(stats)].join(' · '),
          );
        }
        return TorrentProgressStatus(
          label: TorrentProgressCard.withPercent(waiting, progress),
          progress: progress,
          detail: detail,
        );
      case TorrentPhase.ready:
      case TorrentPhase.unknown:
        return TorrentProgressStatus(label: waiting, detail: detail);
    }
  }

  /// What the swarm is doing right now. Unlike start-up this always says,
  /// zeros and all: `0 B/s · seeds 0 · peers 0 · 12 found` is the whole
  /// diagnosis of a stall, and whether any of those connections is a seed
  /// is the difference between a slow swarm and one that cannot finish the
  /// file at all.
  static String _detail(TorrentStats stats) => [
    TorrentProgressCard.formatSpeed(stats.downloadSpeed),
    TorrentProgressCard.formatSwarm(stats),
  ].join(' · ');
}
