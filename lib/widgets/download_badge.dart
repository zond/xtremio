import 'package:flutter/material.dart';

import '../core/core.dart';
import '../features/downloads/download_labels.dart';

/// What a download looks like next to a title it is not the stream picker
/// for: a ring of progress while the file arrives, a check once it is on
/// the device, a warning when it stopped. The tooltip is the state in
/// words, so the icon never has to carry the whole meaning.
///
/// With an [onDelete] the finished state is a button instead of the check,
/// the same gesture the stream tile makes of it: the icon that says a title
/// is kept is the one that stops keeping it. Every other state stays
/// passive -- a download still arriving is undone by the tile that started
/// it, where there is room to say why.
class DownloadBadge extends StatelessWidget {
  const DownloadBadge({
    super.key,
    required this.download,
    this.size = 18,
    this.onDelete,
  });

  final DownloadView download;

  /// Edge of the square the badge draws in.
  final double size;

  /// Removes this download, from the finished badge. Null leaves the badge
  /// the passive indicator it has always been, which is what a header
  /// summarising several downloads ([DownloadSummary]) wants: there is no
  /// one of them to remove.
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onDelete = this.onDelete;
    if (onDelete != null && download.state == DownloadState.complete) {
      return IconButton(
        tooltip: kDownloadDeleteTooltip,
        color: scheme.primary,
        icon: Icon(Icons.delete_outline, size: size),
        // The default 48-square tap target is taller than the row this
        // sits in; this is still a target, not the bare icon.
        padding: EdgeInsets.zero,
        constraints: BoxConstraints.tightFor(
          width: size + 18,
          height: size + 18,
        ),
        onPressed: onDelete,
      );
    }
    return Tooltip(
      message: downloadStateLabel(download),
      child: SizedBox.square(
        dimension: size,
        child: switch (download.state) {
          DownloadState.complete => Icon(
            Icons.download_done,
            size: size,
            color: scheme.primary,
          ),
          DownloadState.error => Icon(
            Icons.error_outline,
            size: size,
            color: scheme.error,
          ),
          // At zero while it is only queued: nothing is being sent yet, and
          // a spinner would claim otherwise.
          _ => CircularProgressIndicator(
            strokeWidth: 2,
            value: download.progress ?? 0,
          ),
        },
      ),
    );
  }
}

/// One line about what of a title is on the device, for a header where the
/// per-episode badges are out of sight: the state itself for a movie, the
/// counts for a series.
class DownloadSummary extends StatelessWidget {
  const DownloadSummary({
    super.key,
    required this.downloads,
    required this.metaId,
  });

  /// Every download of the title, episodes included.
  final List<DownloadView> downloads;

  /// The title's own id. An entry whose video is the title itself is the
  /// title (a movie); anything else is one of its episodes.
  final String metaId;

  /// The line to show, or null when nothing of this title is downloaded.
  static String? label(List<DownloadView> downloads, {required String metaId}) {
    final self = titleItself(downloads, metaId: metaId);
    if (self != null) return downloadStateLabel(self);
    if (downloads.isEmpty) return null;
    var complete = 0;
    var stopped = 0;
    var arriving = 0;
    for (final download in downloads) {
      switch (download.state) {
        case DownloadState.complete:
          complete++;
        case DownloadState.error:
          stopped++;
        case _:
          arriving++;
      }
    }
    return [
      if (complete > 0) '$complete downloaded',
      if (arriving > 0) '$arriving downloading',
      if (stopped > 0) '$stopped stopped',
    ].join(' · ');
  }

  /// The download of the title itself (a movie), when that is the only one
  /// there is; a series is counted instead.
  static DownloadView? titleItself(
    List<DownloadView> downloads, {
    required String metaId,
  }) {
    if (downloads.length != 1) return null;
    final only = downloads.single;
    return only.videoId == metaId ? only : null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = DownloadSummary.label(downloads, metaId: metaId);
    if (label == null) return const SizedBox.shrink();
    final self = titleItself(downloads, metaId: metaId);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (self != null)
          DownloadBadge(download: self)
        else
          Icon(
            downloads.every((download) => download.isComplete)
                ? Icons.download_done
                : Icons.downloading,
            size: 18,
            color: theme.colorScheme.primary,
          ),
        const SizedBox(width: 6),
        // Flexible, because a Row gives a plain child unbounded width: the
        // three-state line ("3 downloaded · 2 downloading · 1 stopped") is
        // wider than a phone's header column and would overflow it.
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium,
          ),
        ),
      ],
    );
  }
}
