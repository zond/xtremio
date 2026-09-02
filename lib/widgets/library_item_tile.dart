import 'package:flutter/material.dart';

import '../core/state/library.dart';
import 'poster_tile.dart';

/// A library item as a poster: the watched fraction of its current video
/// along the bottom edge, a badge for unseen new episodes, a check mark once
/// anything was watched to completion, and the name (plus the episode label
/// for a series) underneath. Shared by the Board's continue-watching row and
/// the Library grid.
class LibraryItemTile extends StatelessWidget {
  const LibraryItemTile({
    super.key,
    required this.item,
    required this.onTap,
    this.onLongPress,
  });

  final LibraryItemView item;
  final VoidCallback onTap;

  /// Also fired by a secondary (right) click, for desktop.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = item.progress;
    final episode = item.seasonEpisodeLabel;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                PosterImage(url: item.poster),
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
                else if (item.isWatched)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: _WatchedMark(color: theme.colorScheme.primary),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.name,
            maxLines: episode.isEmpty ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          if (episode.isNotEmpty)
            Text(
              episode,
              maxLines: 1,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
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
