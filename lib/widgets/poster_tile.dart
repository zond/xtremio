import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/image_disk_cache.dart';
import '../core/state/meta_item_preview.dart';
import '../shell/device_profile.dart';
import '../shell/tv_density.dart';
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

/// The grid of posters [context] draws: [posterGridDelegate], or on a
/// television [TvPosterGridDelegate] -- the television's one poster size,
/// the same as a row's ([PosterTile.tvImageHeight]), rather than whatever
/// width the window divides into.
SliverGridDelegate posterGridDelegateOf(BuildContext context) =>
    DeviceScope.isTv(context)
    ? TvPosterGridDelegate(
        textFactor: math.max(1, TvDensity.textFactorOf(context)),
      )
    : posterGridDelegate;

/// A grid of tiles exactly as big as a television row's: a
/// [PosterTile.tvImageHeight] poster, two-thirds as wide, over the caption
/// a row gives it -- its box grown with the text, as a row's is -- and as
/// many across as fit, from the left.
@immutable
class TvPosterGridDelegate extends SliverGridDelegate {
  const TvPosterGridDelegate({this.textFactor = 1});

  /// [TvDensity.textFactorOf], never below 1.
  final double textFactor;

  /// The gap between tiles, both ways: a row's.
  static const double spacing = 12;

  static const double tileWidth = PosterTile.tvImageWidth;

  double get tileHeight =>
      PosterTile.tvImageHeight +
      PosterTile.captionInset +
      PosterTile.tvCaptionHeight * textFactor;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final across = math.max(
      1,
      ((constraints.crossAxisExtent + spacing) / (tileWidth + spacing)).floor(),
    );
    return SliverGridRegularTileLayout(
      crossAxisCount: across,
      mainAxisStride: tileHeight + spacing,
      crossAxisStride: tileWidth + spacing,
      childMainAxisExtent: tileHeight,
      childCrossAxisExtent: tileWidth,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  @override
  bool shouldRelayout(TvPosterGridDelegate oldDelegate) =>
      oldDelegate.textFactor != textFactor;
}

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

  /// Height of the caption under the image ([PosterImage] gets the rest):
  /// the gap above it and two lines of name.
  static const double captionHeight = 38;

  /// [captionHeight] on a television, where a name is one line, cut short
  /// at its end rather than broken across two: a [tvCaptionGap] and the
  /// one line. A column [tvImageWidth] wide holds too few letters for a
  /// second line to break anywhere but inside a word.
  static const double tvCaptionHeight = tvCaptionGap + 16;

  /// The gap between a poster and its name on a television.
  static const double tvCaptionGap = 4;

  /// [captionHeight] or [tvCaptionHeight], for [context].
  static double captionHeightOf(BuildContext context) =>
      DeviceScope.isTv(context) ? tvCaptionHeight : captionHeight;

  /// How far the name is held off the tile's edges: [FocusRing.textInset],
  /// because the ring is drawn over these bounds and the bold one lands on
  /// the words. The poster above pays for it -- the row keeps the height
  /// the board picked for it, and eight pixels off a poster is nothing
  /// anyone can see, while eight pixels across a title is the title.
  static const double captionInset = FocusRing.textInset;

  /// How tall a poster is on a television, wherever it is drawn: the one
  /// size, so a title looks the same in a row as it does in a grid.
  ///
  /// The largest that puts two whole rows of Discover under its type pills
  /// on a Google TV -- a 1920x1080 panel at a pixel ratio of 2, so 960x540
  /// to lay out on, 430 of it under the pills once the overscan band is
  /// kept clear -- with the one-line heading and caption at the
  /// television's text scale. A row there is 213.9 (`CatalogRows`), two
  /// of them 427.8; a 142 poster would make it 215.9. Divisible by three,
  /// so [tvImageWidth] is a whole two-thirds of it.
  static const double tvImageHeight = 141;

  /// [tvImageHeight]'s width: the poster's 2:3.
  static const double tvImageWidth = tvImageHeight * 2 / 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isTv = DeviceScope.isTv(context);
    return FocusableTile(
      onTap: onTap,
      memoryId: memoryId,
      defaultFocus: defaultFocus,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: PosterImage(url: item.poster)),
          SizedBox(height: isTv ? tvCaptionGap : 6),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              captionInset,
              0,
              captionInset,
              captionInset,
            ),
            child: Text(
              item.name,
              maxLines: isTv ? 1 : 2,
              softWrap: !isTv,
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
  const PosterImage({super.key, required this.url, this.image});

  final String? url;

  /// A picture that is not at a URL -- a video's own frame -- drawn in
  /// place of [url]'s, falling back to the icon the same way.
  final ImageProvider? image;

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
    final image = this.image;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: image != null
            ? Image(
                image: image,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                errorBuilder: (_, _, _) => const _PosterFallback(),
              )
            : url == null
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
