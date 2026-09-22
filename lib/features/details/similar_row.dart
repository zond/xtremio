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

/// What the control that asks again is called, where there is room for a
/// word -- the television's card.
const String kAskAgainLabel = 'Ask again';

/// The whole of what that control does, for a screen reader and for the
/// phone's tooltip. "Ask again" on its own says nothing about what is
/// being asked, and an icon says less than that.
const String kAskAgainHint = 'Ask again for more like this';

/// What is said when a re-ask comes back with nothing to put on the row.
/// Once, and briefly: a press that changed nothing and said nothing is a
/// dead button.
const String kNothingNewSimilar = 'Nothing new came back; these stay.';

/// How a title's suggestions are asked for: [MoreLikeThis.forItem]'s own
/// shape, so the real one is a tear-off.
typedef SimilarAsk = Future<List<SimilarTitle>> Function({
  required String type,
  required String id,
  required String name,
  int? year,
  bool afresh,
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
    this.onAskAgain,
    this.asking = false,
  });

  /// What survived the guard, in the model's own order; null while the
  /// ask is still out. Empty never reaches here -- a row with nothing in
  /// it is not drawn at all, and the details screen is what decides that.
  final List<SimilarTitle>? titles;

  /// Open that title's own details screen.
  final ValueChanged<MetaItemPreview> onOpen;

  /// Ask the model again about the title this row is under, as the last
  /// card of the strip ([_AskAgainCard]); null for a row that has no such
  /// card, which is every row off a television -- the phone keeps the
  /// control in the section header instead ([SimilarSection]).
  final VoidCallback? onAskAgain;

  /// Whether that ask is out. The row keeps every suggestion it has while
  /// it is, and the card is what says so.
  final bool asking;

  /// The poster, at the size the drawing settled on: small enough that
  /// seven fit across a 720p panel with the ladder above them.
  static const double posterWidth = 120;
  static const double posterHeight = 180;

  /// The ask-again card, narrower than a poster because it holds an icon
  /// and one word rather than artwork, and because the posters are what
  /// the row is for.
  static const double askAgainWidth = 96;

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
                // Last, so that a press past the last poster lands on it:
                // see [_AskAgainCard] for why it is in the strip at all.
                if (onAskAgain case final askAgain?)
                  _AskAgainCard(onPressed: askAgain, asking: asking),
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

/// The way to ask the model again, on a television: the last card of the
/// strip, shaped like the posters beside it.
///
/// **It is a card in the row and not a control on the header**, and that
/// is the ladder's own convention rather than a choice made here. The
/// remote is standing *in* the strip, a press past the last poster is
/// where it already goes, and [TvCardStrip] swallows that press at the end
/// of the row -- so a card put there is one press from the suggestions and
/// one press back, with nothing new to learn. A header control would be a
/// second focus stop on a line that is exactly one stop everywhere else on
/// this screen, and would want a press *up*, out of the row, to reach.
///
/// **Nothing here asks for the remote.** No `defaultFocus`, no
/// `memoryId`: the rung opens on the first poster and this is at the far
/// end of it, which is the same rule the rung itself is written to.
///
/// **It keeps its tap while an ask is out.** A [FocusableTile] with no
/// `onTap` is not a focus stop at all, so disabling it would take the
/// remote off the card the viewer had just pressed and drop it somewhere
/// they did not choose. One ask at a time is the screen's guard; the card
/// only says that one is out.
class _AskAgainCard extends StatelessWidget {
  const _AskAgainCard({required this.onPressed, required this.asking});

  final VoidCallback onPressed;
  final bool asking;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final factor = SimilarTitlesRow._textFactor(context);
    return SizedBox(
      width: SimilarTitlesRow.askAgainWidth,
      child: FocusableTile(
        onTap: onPressed,
        child: Semantics(
          container: true,
          button: true,
          excludeSemantics: true,
          label: kAskAgainHint,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                // A poster's height, so the card sits on the same two
                // lines the row is ruled by rather than floating in it.
                height: SimilarTitlesRow.posterHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: const BorderRadius.all(Radius.circular(8)),
                  ),
                  child: Center(
                    child: asking
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.refresh, color: scheme.onSurfaceVariant),
                  ),
                ),
              ),
              SizedBox(
                height: SimilarTitlesRow.captionHeight * factor,
                child: Padding(
                  // The inset every caption in this row is held off its
                  // tile's edges by; see [_SimilarPoster].
                  padding: const EdgeInsets.fromLTRB(
                    FocusRing.textInset,
                    6,
                    FocusRing.textInset,
                    FocusRing.textInset,
                  ),
                  child: Text(
                    kAskAgainLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
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
///
/// The way to ask again is a plain icon control in that heading, beside
/// the words it belongs to. A phone has a finger rather than a D-pad, so
/// there is no walk to preserve and nothing to be said for burying the
/// control at the end of a sideways scroll ([_AskAgainCard] is the other
/// half of this, and says why a television is not the same).
class SimilarSection extends StatelessWidget {
  const SimilarSection({
    super.key,
    required this.titles,
    required this.onOpen,
    this.onAskAgain,
    this.asking = false,
  });

  final List<SimilarTitle>? titles;
  final ValueChanged<MetaItemPreview> onOpen;

  /// Ask the model again about the title this section is under; null for
  /// a section with no such control.
  final VoidCallback? onAskAgain;

  /// Whether that ask is out.
  final bool asking;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titles = this.titles;
    final askAgain = onAskAgain;
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
              // Nothing to ask again about until there is a first answer,
              // and the first ask is already out while this says so.
              if (titles != null && askAgain != null)
                IconButton(
                  // Unpressable while an ask is out, which a phone can
                  // afford: there is no remote standing on the control to
                  // be dropped when it stops being one. The guard that
                  // makes four presses one call is the screen's either
                  // way.
                  onPressed: asking ? null : askAgain,
                  tooltip: kAskAgainHint,
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                  icon: asking
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
            ],
          ),
        ),
        SimilarTitlesRow(titles: titles, onOpen: onOpen),
      ],
    );
  }
}
