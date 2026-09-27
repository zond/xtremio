import 'package:flutter/material.dart';

import '../core/image_disk_cache.dart';
import '../core/state/meta_item_preview.dart';
import 'focusable_tile.dart';

/// The grid a page of [PosterTile]s is laid out in: a poster and its name
/// in each cell, as many across as fit.
const SliverGridDelegateWithMaxCrossAxisExtent posterGridDelegate =
    SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 160,
      childAspectRatio: 0.56,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
    );

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

  /// How far the name is held off the tile's edges: [FocusRing.textInset],
  /// because the ring is drawn over these bounds and the bold one lands on
  /// the words. The poster above pays for it -- the row keeps the height
  /// the board picked for it, and eight pixels off a poster is nothing
  /// anyone can see, while eight pixels across a title is the title.
  static const double captionInset = FocusRing.textInset;

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
          Padding(
            padding: const EdgeInsets.fromLTRB(
              captionInset,
              0,
              captionInset,
              captionInset,
            ),
            child: Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// The rounded poster image itself, covering whatever box it is given, with
/// a neutral fallback when [url] is null or fails to load.
///
/// The decode is bounded to the box the poster is drawn in. This is the
/// most numerous image in the app -- a board strip, the discover and search
/// grids, the library -- and an addon is free to serve a poster at any
/// size: an unbounded TMDB-backed poster (1000x1500) decodes to 5.9 MB,
/// against a few hundred kilobytes at the tile's own width, so without this
/// a handful of tiles fill the whole image cache and every scroll re-decodes
/// them. `cacheWidth` counts physical pixels, which is why the device's
/// ratio is in it; only the width is given, so the source's own aspect is
/// kept and `cover` crops as it did.
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
            : LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final pixels = width.isFinite && width > 0
                      ? (width * MediaQuery.devicePixelRatioOf(context)).round()
                      : 0;
                  return Image(
                    image: DiskCachedImage.bounded(
                      url,
                      cacheWidth: pixels > 0 ? pixels : null,
                    ),
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: double.infinity,
                    errorBuilder: (_, _, _) => const _PosterFallback(),
                  );
                },
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
