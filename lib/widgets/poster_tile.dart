import 'package:flutter/material.dart';

import '../core/state/meta_item_preview.dart';
import 'focusable_tile.dart';

/// A poster with the item's name underneath; falls back to a neutral box
/// when there is no poster or it fails to load.
class PosterTile extends StatelessWidget {
  const PosterTile({
    super.key,
    required this.item,
    this.onTap,
    this.memoryId,
    this.defaultFocus = false,
  });

  final MetaItemPreview item;
  final VoidCallback? onTap;

  /// See [FocusableTile.memoryId] and [FocusableTile.defaultFocus].
  final String? memoryId;
  final bool defaultFocus;

  /// Height of the caption under the image ([PosterImage] gets the rest).
  static const double captionHeight = 38;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusableTile(
      onTap: onTap,
      memoryId: memoryId,
      defaultFocus: defaultFocus,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: PosterImage(url: item.poster)),
          const SizedBox(height: 6),
          Text(
            item.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// The rounded poster image itself, covering whatever box it is given, with
/// a neutral fallback when [url] is null or fails to load.
class PosterImage extends StatelessWidget {
  const PosterImage({super.key, required this.url});

  final String? url;

  /// Width / height of a poster of the given `posterShape`
  /// (`poster` | `landscape` | `square`).
  static double aspectRatioFor(String posterShape) => switch (posterShape) {
    'landscape' => 16 / 9,
    'square' => 1,
    _ => 2 / 3,
  };

  @override
  Widget build(BuildContext context) {
    final url = this.url;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: url == null
            ? const _PosterFallback()
            : Image.network(
                url,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                errorBuilder: (_, _, _) => const _PosterFallback(),
              ),
      ),
    );
  }
}

class _PosterFallback extends StatelessWidget {
  const _PosterFallback();

  @override
  Widget build(BuildContext context) =>
      const Center(child: Icon(Icons.movie_outlined, size: 32));
}
