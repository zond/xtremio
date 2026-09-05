import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../widgets/download_badge.dart';
import '../../widgets/focusable_tile.dart';

/// What a title says about itself on a television: the logo, one line of
/// facts, and enough of the description to know whether this is the film
/// you meant.
///
/// This is orientation, not reading material. A viewer sitting three
/// metres away has come to the screen to choose something to watch, and
/// the rows below are what they came to choose from, so the header takes
/// as little of the panel as it can and leaves the rest to them.
///
/// It differs from the phone header ([MetaDetailsScreen]'s own) in three
/// ways, and each is a ten-foot reason rather than a matter of taste:
///
/// - **No poster.** The artwork is already behind the whole screen as the
///   backdrop; a poster beside the text would be the same picture twice
///   and, at this size, a third of the layout.
/// - **The logo stands in for the name.** Most titles ship one, it is the
///   lettering the film is actually known by, and it reads across a room
///   in a way a text heading does not. There is a name behind it for the
///   titles that ship none, for a logo that will not load, and for a
///   screen reader ([Image.semanticLabel]) -- a missing image may never
///   disturb the layout.
/// - **The facts are one line and the description a couple.** Year,
///   runtime, genres and rating are one glance; the genres are text
///   rather than the phone's chips because a chip is a focus stop, and a
///   remote spends presses walking past every stop between it and the
///   rows.
///
/// The bookmark stays: it is the one thing on this screen that is about
/// the title rather than about what to play, and the remote has to be
/// able to reach it.
class TvMetaHeader extends StatelessWidget {
  const TvMetaHeader({
    super.key,
    required this.meta,
    required this.isInLibrary,
    required this.downloads,
    required this.onToggleLibrary,
  });

  final MetaItem meta;

  /// `libraryItem.removed == false`: the bookmark is filled.
  final bool isInLibrary;

  /// Every download of this title, episodes included; empty for none.
  final List<DownloadView> downloads;
  final VoidCallback onToggleLibrary;

  /// The bookmark's two tooltips; the phone header takes the same two, so
  /// both layouts say the same thing about the same button.
  static const String addTooltip = 'Add to library';
  static const String removeTooltip = 'Remove from library';

  /// How tall a logo is drawn. Wide logos are letterboxed into whatever
  /// width is left rather than overflowing it.
  static const double logoHeight = 88;

  /// How much of the description is shown. Two lines is what says which
  /// film this is; the rest is a synopsis nobody reads from a sofa.
  static const int descriptionLines = 2;

  /// The one compact line: year, runtime, genres, rating. Empty parts are
  /// left out rather than shown as a gap, so a title the addon knows
  /// little about gets a short line and not a row of separators.
  static String facts(MetaItem meta) {
    final genres = [for (final genre in meta.genres) genre.name].join(', ');
    final rating = meta.imdbRating;
    return [
      ?meta.releaseInfo,
      ?meta.runtime,
      if (genres.isNotEmpty) genres,
      if (rating != null) 'IMDb $rating',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final description = meta.description;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _title(context),
                const SizedBox(height: 10),
                Text(
                  facts(meta),
                  style: theme.textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (downloads.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  DownloadSummary(downloads: downloads, metaId: meta.id),
                ],
                if (description != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    description,
                    style: theme.textTheme.bodyLarge,
                    maxLines: descriptionLines,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          // The same indicator every focusable thing on a television
          // wears, rather than the circular tint Material gives a focused
          // icon button: a tint of about a tenth over a darkened backdrop
          // is the one cue a bright room takes away, and this is a control
          // the remote can land on.
          FocusHighlighted(
            borderRadius: const BorderRadius.all(Radius.circular(24)),
            builder: (context, node) => IconButton(
              focusNode: node,
              tooltip: isInLibrary ? removeTooltip : addTooltip,
              isSelected: isInLibrary,
              icon: const Icon(Icons.bookmark_border),
              selectedIcon: const Icon(Icons.bookmark),
              onPressed: onToggleLibrary,
            ),
          ),
        ],
      ),
    );
  }

  /// The logo, or the name when there is none and when the logo will not
  /// load, in a box [logoHeight] tall either way.
  ///
  /// The height is the whole point of the box. An [Image.network] given
  /// only a height occupies exactly that from its first frame, before a
  /// byte has arrived; the name that replaces it when the fetch fails is
  /// about half as tall. Without a floor under it the header, the season
  /// pills, the episode row and both rows of sources all jump up some
  /// forty pixels the moment a slow metahub answers 404 -- seconds after
  /// the screen settled, under a focus ring the viewer is already using.
  /// A missing image may never disturb the layout, and a *late* missing
  /// image is the case that rule is really about.
  Widget _title(BuildContext context) {
    final logo = meta.logo;
    final name = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: logoHeight),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          meta.name,
          style: Theme.of(context).textTheme.headlineMedium
              ?.copyWith(fontWeight: FontWeight.w600),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
    if (logo == null) return name;
    return Image.network(
      logo,
      height: logoHeight,
      fit: BoxFit.contain,
      alignment: Alignment.centerLeft,
      semanticLabel: meta.name,
      errorBuilder: (_, _, _) => name,
    );
  }
}
