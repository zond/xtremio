import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../widgets/download_badge.dart';
import '../../widgets/focusable_tile.dart';
import '../../widgets/readout.dart';
import '../../widgets/remote_press.dart';

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
///   rows. The couple of lines are what is *shown*: a description with
///   more to say is a control the remote can press to unfold
///   ([TvDescription]), because an ellipsis with no way past it is a plot
///   the viewer cannot reach.
///
/// The bookmark stays: it is the one thing on this screen that is about
/// the title rather than about what to play, and the remote has to be
/// able to reach it.
///
/// **The header says which of its two stops comes first**, because nothing
/// else here can be trusted to. The description is built inside a
/// [LayoutBuilder] -- it measures the words against the width it is given
/// -- so its focus node is attached at layout, after the bookmark beside
/// it, and both the ladder's walk and reading order then made the bookmark
/// the header's first stop: the narrow button in the corner rather than
/// the block spanning the panel. A viewer coming down out of the app bar
/// landed on the bookmark and had to walk back for the plot, which is the
/// report this order answers. So the order is declared
/// ([FocusTraversalOrder]) and both walks read the declaration: the
/// [OrderedTraversalPolicy] here for Tab, [TvLadderRow] for the D-pad.
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

  /// Where the header's two stops stand in its walk, low first: the plot
  /// the viewer came to read, and then the button in the corner.
  static const double stopOrderDescription = 1;
  static const double stopOrderBookmark = 2;

  /// How tall a logo is drawn. Wide logos are letterboxed into whatever
  /// width is left rather than overflowing it.
  static const double logoHeight = 88;

  /// How much of the description is shown before it is unfolded. Two lines
  /// is what says which film this is; the rest is a synopsis nobody reads
  /// from a sofa -- until they want to, which is what [TvDescription] is
  /// for.
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
      // The header's two stops, walked in the order they are read rather
      // than in the order they happen to be assembled: see the class.
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
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
                    // Two short of the ten the other gaps are: the block
                    // holds itself off its own ring by [FocusRing.textInset]
                    // on every side, and that padding is part of the gap.
                    const SizedBox(height: 2),
                    FocusTraversalOrder(
                      order: const NumericFocusOrder(stopOrderDescription),
                      child: TvDescription(text: description),
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
            FocusTraversalOrder(
              order: const NumericFocusOrder(stopOrderBookmark),
              child: FocusHighlighted(
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
            ),
          ],
        ),
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
  ///
  /// The height is also what the decode is bounded to. Metahub serves a
  /// logo at the artwork's own scale, and one decoded at that scale is
  /// megabytes of texture for a strip [logoHeight] tall on a television
  /// with two gigabytes for the whole system. The height is the dimension
  /// to give, because it is the one the logo is drawn at -- the width
  /// follows it and the lettering keeps its shape. `cacheHeight` counts
  /// physical pixels, which is why the device's ratio is in it.
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
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return Image.network(
      logo,
      height: logoHeight,
      fit: BoxFit.contain,
      alignment: Alignment.centerLeft,
      semanticLabel: meta.name,
      cacheHeight: (logoHeight * ratio).round(),
      errorBuilder: (_, _, _) => name,
    );
  }
}

/// The description of a title on a television: a couple of lines, and a
/// press to see the rest.
///
/// **The ellipsis was the end of the story.** The header drew the plot as
/// plain text clipped to [TvMetaHeader.descriptionLines], which takes no
/// focus and answers no key, so on a television the rest of it could not
/// be got to at all -- reported from a Chromecast, where the only pointer
/// in the room is the D-pad. A phone has had a way past its own clamp
/// since the beginning ([MetaDetailsScreen]'s `_ExpandableText`, with a
/// More button under the words), and this is the same idea said the way a
/// remote can hear it: the words themselves are the control, and select
/// unfolds them and folds them back.
///
/// **A stop only where there is something behind the ellipsis.** The text
/// is measured against the collapsed clamp exactly as the phone's is, and
/// a description that already fits is left as words -- not a stop. A ring
/// on a block whose select does nothing is the lie this widget exists to
/// avoid, and on a remote it also costs a press to walk past.
///
/// **Pressable, so dressed as something pressable.** [Readout] is the
/// neighbouring case and wears [FocusTreatment.readout] -- the ring alone,
/// no ink -- precisely because select on it does nothing. This is the
/// opposite, so it takes what this app gives a control: the ring at
/// [FocusTreatment.row], since a block the width of the panel zoomed five
/// per cent would lift over the facts above it, and Material's own ink
/// under it, which the floor (`FocusTheme`) fills in near-white. The fill
/// is the difference a viewer reads: words that light up are words that
/// can be pressed.
///
/// **What expanding must not cost is the remote's place.** The stop is one
/// [InkWell] whose node outlives the toggle -- the tree is the same shape
/// unfolded and folded -- so focus neither moves on the press nor is left
/// on something no longer drawn. The press is a [RemotePress], so select
/// acts when the key comes *up*, the way Android activates a control and
/// the way every other stop in this app does; Material's own shortcut
/// fires on the way down and again on every repeat, which on a held key is
/// a plot flapping open and shut.
///
/// **An unfolded plot can be longer than the panel**, which is the bug in a
/// new place. [ReadableBlock] is both halves of that: [walkBlock] answers
/// the D-pad while there is any of the block off the screen, a
/// part-screenful per press, and [revealBlockAfterFrame] puts the block
/// back in front of the viewer when it folds -- the page is scrolled
/// wherever the walk left it, and a fold that only made the words short
/// would leave the remote standing above the fold. Arriving needs nothing
/// of its own: the ladder reveals this row from the side the press came
/// from, and traversal's own reveal puts a leading edge against a leading
/// edge, which for this block is its first line either way.
///
/// **A phone is left alone.** It has its own More button, and a second
/// mechanism for the same idea is two things to keep right. Off a
/// television this is the words and nothing else.
class TvDescription extends StatefulWidget {
  const TvDescription({super.key, required this.text});

  final String text;

  /// Rounds the ring. The same eight every other block of words wears.
  static const BorderRadius radius = BorderRadius.all(Radius.circular(8));

  /// Held between the ring and the words, on every side. The ring is drawn
  /// on this block's own bounds, and in Bold that is eight logical pixels
  /// of it over the first letter of every line.
  static const EdgeInsets inset = EdgeInsets.all(FocusRing.textInset);

  @override
  State<TvDescription> createState() => _TvDescriptionState();
}

class _TvDescriptionState extends State<TvDescription>
    with ReadableBlock<TvDescription> {
  bool _expanded = false;

  /// Unfolds, or folds back, and then puts what is now drawn in front of
  /// the viewer.
  ///
  /// The reveal is the half that is easy to leave out: unfolding a plot at
  /// the bottom of the panel grows it off the screen, and folding one the
  /// remote has walked down through leaves the header above the fold with
  /// the remote still standing on it. Both are the same question --
  /// where are these words now -- and [ReadableBlock] answers it once.
  void _toggle() {
    setState(() => _expanded = !_expanded);
    revealBlockAfterFrame();
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyLarge;
    final words = Text(
      widget.text,
      style: style,
      maxLines: _expanded ? null : TvMetaHeader.descriptionLines,
      overflow: _expanded ? null : TextOverflow.ellipsis,
    );
    if (!DeviceScope.isTv(context)) return words;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Measured the way the phone measures its own: the clamped text
        // laid out at the width it will really have, inside the padding.
        final painter =
            TextPainter(
              text: TextSpan(text: widget.text, style: style),
              maxLines: TvMetaHeader.descriptionLines,
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout(
              maxWidth: constraints.maxWidth - TvDescription.inset.horizontal,
            );
        final overflows = painter.didExceedMaxLines;
        painter.dispose();
        final padded = Padding(padding: TvDescription.inset, child: words);
        // The padding is there either way, so a title whose plot happens
        // to fit is laid out exactly where a title whose plot does not is.
        if (!overflows) return padded;
        // The [Focus] above the stop rather than the stop itself: it
        // cannot be focused and is skipped by traversal, so the walk is
        // exactly what it was, and a key event from the node below still
        // passes through it on the way up -- the same trick [FocusMarked]
        // and [RemotePress] play either side of it.
        return Focus(
          canRequestFocus: false,
          skipTraversal: true,
          includeSemantics: false,
          onKeyEvent: (node, event) => walkBlock(event),
          child: RemotePress(
            onTap: _toggle,
            child: FocusMarked(
              borderRadius: TvDescription.radius,
              // A button to a screen reader: what it is called is the
              // plot, and what can be done is press it. A [Readout] is
              // the other half of that sentence -- focusable, and
              // explicitly not a button.
              child: Semantics(
                button: true,
                child: InkWell(
                  onTap: _toggle,
                  borderRadius: TvDescription.radius,
                  child: padded,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
