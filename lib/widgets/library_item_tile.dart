import 'package:flutter/material.dart';

import '../core/state/library.dart';
import '../shell/device_profile.dart';
import 'focusable_tile.dart';
import 'poster_tile.dart';

/// A library item as a poster: the watched fraction of its current video
/// along the bottom edge, a badge for unseen new episodes, optionally a
/// check mark once anything was watched to completion, and the name (plus
/// the episode label for a series) underneath. Shared by the Board's
/// continue-watching row and the Library grid.
class LibraryItemTile extends StatelessWidget {
  const LibraryItemTile({
    super.key,
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.showWatchedMark = true,
    this.memoryId,
    this.defaultFocus = false,
    this.posterImage,
  });

  final LibraryItemView item;

  /// See [PosterImage.image]: a card with no poster URL, drawn from a
  /// picture of its own.
  final ImageProvider? posterImage;
  final VoidCallback onTap;

  /// Also fired by a secondary (right) click, for desktop.
  final VoidCallback? onLongPress;

  /// Show the check mark when [LibraryItemView.isWatched]. The Library grid
  /// wants it; a continue-watching row does not, since a series with one
  /// finished episode is there to be resumed, not marked done.
  final bool showWatchedMark;

  /// See [FocusableTile.memoryId] and [FocusableTile.defaultFocus].
  final String? memoryId;
  final bool defaultFocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = item.progress;
    final episode = item.seasonEpisodeLabel;
    final isTv = DeviceScope.isTv(context);
    // On a television the episode line under the focused tile goes to full
    // strength: a muted caption under a poster is the second thing a
    // projector in a lit room loses, after the ring itself. Off one there
    // is no [TileFocus] above and it is the muted colour it has always
    // been.
    TextStyle? episodeStyle(BuildContext context) =>
        theme.textTheme.bodySmall?.copyWith(
          color: TileFocus.maybeOf(context) ?? false
              ? theme.colorScheme.onSurface
              : theme.colorScheme.onSurfaceVariant,
        );
    return FocusableTile(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      memoryId: memoryId,
      defaultFocus: defaultFocus,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                PosterImage(url: item.poster, image: posterImage),
                if (progress != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 4,
                      backgroundColor: Colors.black45,
                    ),
                  ),
                if (item.notifications > 0)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Badge.count(count: item.notifications),
                  )
                else if (showWatchedMark && item.isWatched)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: _WatchedMark(color: theme.colorScheme.primary),
                  ),
              ],
            ),
          ),
          SizedBox(height: isTv ? PosterTile.tvCaptionGap : 6),
          // Held off the tile's edges for the reason [PosterTile] is: the
          // focus ring is drawn over these bounds, and the bold one is
          // eight pixels of it across the first letter.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              PosterTile.captionInset,
              0,
              PosterTile.captionInset,
              PosterTile.captionInset,
            ),
            // One line on a television, as [PosterTile]'s: the name, cut
            // short at its end, then the episode, which is never cut.
            child: isTv
                ? Row(
                    children: [
                      Flexible(
                        child: Text(
                          item.name,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      if (episode.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Builder(
                          builder: (context) => Text(
                            episode,
                            maxLines: 1,
                            softWrap: false,
                            style: episodeStyle(context),
                          ),
                        ),
                      ],
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: episode.isEmpty ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                      if (episode.isNotEmpty)
                        Builder(
                          builder: (context) => Text(
                            episode,
                            maxLines: 1,
                            style: episodeStyle(context),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// The "watched" check in the poster's corner.
class _WatchedMark extends StatelessWidget {
  const _WatchedMark({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.65),
      shape: BoxShape.circle,
    ),
    child: Padding(
      padding: const EdgeInsets.all(2),
      child: Icon(Icons.check, size: 16, color: color),
    ),
  );
}
