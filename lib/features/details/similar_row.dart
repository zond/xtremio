/// What a model said this title is like, drawn as a row of posters: the
/// one place in the app that shows a suggestion.
///
/// Everything behind it is `features/similar/` -- the ask, the guard that
/// drops titles no catalogue confirms, the memory. This file is what the
/// viewer sees of it, and it is deliberately the least it can be: a
/// poster, the name and the year.
///
/// **The name is not optional.** Every other poster in the app stands for
/// something the viewer already chose -- a board row they installed, a
/// search they typed, a title in their library -- and the artwork alone
/// identifies it. These are films they have not seen, which is the whole
/// point of the row, so a poster with no name under it is a picture of a
/// stranger. That is what the 120x180 poster buys: room for two lines of
/// text under it and seven of them across a 720p panel
/// (`test/prototypes/details_density.dart`, `details_3_recommendations.png`).
///
/// **The model's reason is not drawn.** A [SimilarTitle] carries one -- a
/// dozen words about why this film is here -- and a 120 px column has
/// nowhere to put it. It is the row's semantics label instead, so a
/// screen reader has it and the layout does not have to grow a line for
/// it.
///
/// The row draws the same on a television and on a phone. [FocusableTile]
/// is an [InkWell] off a television and [TvCardStrip] is a plain sideways
/// scroll there, so the difference is the remote, which is where it
/// belongs.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/tv_density.dart';
import '../../widgets/focusable_tile.dart';
import '../../widgets/poster_tile.dart';
import '../similar/more_like_this.dart';
import '../similar/similar_resolver.dart';
import 'tv_source_row.dart';

/// What the rung and the phone section are called.
const String kMoreLikeThisLabel = 'More like this';

/// What the header says while the answer is still out -- which is most of
/// the time the viewer is looking at it, since the ask takes seconds.
const String kLookingForSimilar = 'Looking for titles…';

/// How a title's suggestions are asked for: [MoreLikeThis.forItem]'s own
/// shape, so the real one is a tear-off.
typedef SimilarAsk = Future<List<SimilarTitle>> Function({
  required String type,
  required String id,
  required String name,
  int? year,
});

/// How that asker is built once the preferences are known.
///
/// A factory over the preferences rather than an asker, for the reason
/// [SimilarProviderFactory] is one a layer down: the key and the model are
/// preferences, and one built at start-up would be holding the old ones.
typedef SimilarAskBuilder = SimilarAsk Function(AppPrefs prefs);

/// Supplies how "More like this" is asked, for the details screen -- the
/// same seam, and for the same reason, as `PlaybackScope.archiveSniff`: a
/// test answers what a model would without a key, a network or a wait.
///
/// Absent, the screen builds a [MoreLikeThis] of its own. One per screen
/// rather than one per app, which costs a catalogue search per title per
/// visit and nothing else: what a model answered is remembered in the
/// preferences file and is not asked twice either way.
class SimilarScope extends InheritedWidget {
  const SimilarScope({super.key, required this.askFor, required super.child});

  final SimilarAskBuilder askFor;

  static SimilarAskBuilder of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SimilarScope>()?.askFor ??
      _theModel;

  static SimilarAsk _theModel(AppPrefs prefs) =>
      MoreLikeThis(prefs: prefs).forItem;

  @override
  bool updateShouldNotify(SimilarScope oldWidget) => askFor != oldWidget.askFor;
}

/// The row itself: [titles] as posters, or -- while the answer is still
/// out (null) -- a spinner in a box exactly the row's own size.
///
/// **The box is reserved, not fitted.** The answer arrives three seconds
/// in, sometimes never, and by then the viewer is reading the screen. A
/// row that grew from nothing to 228 px when it landed would move
/// everything under it out from under them, which is the same fault the
/// source detail strip is a fixed height for.
class SimilarTitlesRow extends StatelessWidget {
  const SimilarTitlesRow({
    super.key,
    required this.titles,
    required this.onOpen,
  });

  /// What survived the guard, in the model's own order; null while the
  /// ask is still out. Empty never reaches here -- a row with nothing in
  /// it is not drawn at all, and the details screen is what decides that.
  final List<SimilarTitle>? titles;

  /// Open that title's own details screen.
  final ValueChanged<MetaItemPreview> onOpen;

  /// The poster, at the size the drawing settled on: small enough that
  /// seven fit across a 720p panel with the ladder above them.
  static const double posterWidth = 120;
  static const double posterHeight = 180;

  /// The box under it, holding the name and the year at text scale 1.
  /// Two lines, the gap above them and the inset the focus ring needs.
  static const double captionHeight = 48;

  /// How much bigger text is here than at the size that box was picked
  /// for, never below 1 -- the same rule the source cards are measured by.
  static double _textFactor(BuildContext context) =>
      math.max(1, TvDensity.textFactorOf(context));

  /// The height of the whole row, room for a focused poster to grow into
  /// included. What the spinner stands in at.
  static double rowHeight(BuildContext context) =>
      TvSourceRows.focusSlack * 2 +
      posterHeight +
      captionHeight * _textFactor(context);

  @override
  Widget build(BuildContext context) {
    final titles = this.titles;
    return SizedBox(
      height: rowHeight(context),
      child: titles == null
          ? const Center(child: CircularProgressIndicator())
          : TvCardStrip(
              children: [
                for (final title in titles)
                  _SimilarPoster(
                    title: title,
                    onOpen: () => onOpen(title.item),
                  ),
              ],
            ),
    );
  }
}

/// One suggestion: the poster, the name and the year under it.
class _SimilarPoster extends StatelessWidget {
  const _SimilarPoster({required this.title, required this.onOpen});

  final SimilarTitle title;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = title.item;
    final year = yearIn(item.releaseInfo);
    final factor = SimilarTitlesRow._textFactor(context);
    return SizedBox(
      width: SimilarTitlesRow.posterWidth,
      child: FocusableTile(
        onTap: onOpen,
        // The whole of what the model said, where the layout has no room
        // for it: a reader hears why this film is in the row, and the row
        // stays two lines deep.
        child: Semantics(
          container: true,
          excludeSemantics: true,
          label: [
            item.name,
            if (year != null) '$year',
            if (title.why.isNotEmpty) title.why,
          ].join('. '),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: SimilarTitlesRow.posterWidth,
                height: SimilarTitlesRow.posterHeight,
                child: PosterImage(url: item.poster),
              ),
              SizedBox(
                height: SimilarTitlesRow.captionHeight * factor,
                child: Padding(
                  // Held off the tile's edges because the ring is drawn
                  // on them and the bold one lands on the words; the same
                  // inset [PosterTile] gives its caption.
                  padding: const EdgeInsets.fromLTRB(
                    FocusRing.textInset,
                    6,
                    FocusRing.textInset,
                    FocusRing.textInset,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                      if (year != null)
                        Text(
                          '$year',
                          maxLines: 1,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The same films on a phone and a desktop, where there is no ladder to
/// hang a rung on: a heading and the row under it, one more section of the
/// scroll.
///
/// It says it is looking in the heading exactly as the rung's header does,
/// so the section does not appear empty and then fill.
class SimilarSection extends StatelessWidget {
  const SimilarSection({super.key, required this.titles, required this.onOpen});

  final List<SimilarTitle>? titles;
  final ValueChanged<MetaItemPreview> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titles = this.titles;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            spacing: 8,
            children: [
              Text(kMoreLikeThisLabel, style: theme.textTheme.titleMedium),
              if (titles == null)
                Expanded(
                  child: Text(
                    kLookingForSimilar,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
        SimilarTitlesRow(titles: titles, onOpen: onOpen),
      ],
    );
  }
}
