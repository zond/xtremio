import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../shell/external_link.dart';
import '../../widgets/download_badge.dart';
import '../../widgets/focusable_tile.dart';
import '../../widgets/tv_ladder.dart';
import '../../widgets/poster_tile.dart';
import '../../widgets/text_overflow.dart';
import '../../widgets/remote_press.dart';
import 'episode_thumbnail.dart';
import 'title_scores.dart';
import 'tv_backdrop.dart';
import 'tv_meta_header.dart';

/// The artwork behind the collapsing app bar on a phone and a desktop,
/// with the title's logo standing on it.
///
/// Both decodes are bounded to the boxes they are drawn in, for the reason
/// [TvBackdrop] gives: this artwork is never drawn wider than the bar, so
/// decoding it wider only costs memory, and a metahub background decoded
/// at its own size is several megabytes of texture. The bar is not the
/// screen, though -- the wide layout gives it what is left beside the
/// sources pane -- so the width comes from the bar's own constraints
/// rather than from [MediaQuery]. The logo is the other way round: its
/// height is the one dimension it is drawn at, so its height is what is
/// bounded and the width follows, keeping the lettering's shape. Both
/// counts are physical pixels, which is why the device's ratio is in them.
class DetailsBackdrop extends StatelessWidget {
  const DetailsBackdrop({super.key, required this.url, required this.logo});

  final String? url;
  final String? logo;

  /// How tall the logo is drawn over the artwork.
  static const double logoHeight = 56;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = this.url;
    final logo = this.logo;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final pixels = width.isFinite && width > 0
            ? (width * ratio).round()
            : 0;
        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: scheme.surfaceContainerHighest),
            if (url != null)
              Image(
                image: DiskCachedImage.bounded(
                  url,
                  cacheWidth: pixels > 0 ? pixels : null,
                ),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black26,
                    Colors.black38,
                    scheme.surface.withValues(alpha: 0.85),
                  ],
                ),
              ),
            ),
            if (logo != null)
              Positioned(
                left: 16,
                right: 16,
                bottom: 64,
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Image(
                    image: DiskCachedImage.bounded(
                      logo,
                      cacheHeight: (logoHeight * ratio).round(),
                    ),
                    height: logoHeight,
                    fit: BoxFit.contain,
                    alignment: Alignment.bottomLeft,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The IMDb rating, and the way to the page it came from.
///
/// A link only when the addon sent the rating with an address
/// ([MetaItem.imdbLink]); without one the rating is the plain line it has
/// always been, since the address is never built here out of an id.
///
/// The television has none of this. This is the phone's and the desktop's
/// header ([TvMetaHeader] is the other one), which is where a browser can
/// be relied on: a set-top box usually has nothing to hand the address to,
/// and the remote would gain a stop whose whole answer is "could not open".
class ImdbRating extends StatelessWidget {
  const ImdbRating({super.key, required this.rating, this.url});

  final String rating;

  /// The title's page on IMDb; null leaves the rating unclickable.
  final String? url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = this.url;
    final line = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.star_rounded, size: 18, color: Colors.amber.shade400),
        const SizedBox(width: 4),
        Text(rating, style: theme.textTheme.labelLarge),
        const SizedBox(width: 4),
        Text(
          'IMDb',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (url != null) ...[
          const SizedBox(width: 4),
          Icon(
            Icons.open_in_new,
            size: 13,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ],
    );
    if (url == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: line,
      );
    }
    // Hugging the words rather than the column's width -- [DetailsScores]
    // lays it out in a [Wrap], which sizes it to them -- so a tap lands
    // where the thing it opens is drawn.
    return InkWell(
      onTap: () => openInBrowser(context, url),
      borderRadius: BorderRadius.circular(6),
      child: Semantics(
        link: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: line,
        ),
      ),
    );
  }
}

class DetailsMetaHeader extends StatelessWidget {
  const DetailsMetaHeader({
    super.key,
    required this.meta,
    required this.isWide,
    required this.isInLibrary,
    required this.downloads,
    required this.onGenre,
    required this.onToggleLibrary,
    this.onTrailer,
    this.ratings,
  });

  final MetaItem meta;
  final bool isWide;

  /// The scores beyond the addon's IMDb rating ([DetailsScores]); null
  /// while none is known.
  final TitleRatings? ratings;

  /// Opens the title's trailer; null draws no button, for a title that has
  /// none ([MetaItem.trailerUrl]).

  /// `libraryItem.removed == false`: the bookmark is filled.
  final bool isInLibrary;

  /// Every download of this title, episodes included; empty for none.
  final List<DownloadView> downloads;
  final ValueChanged<ResourceRequest> onGenre;
  final VoidCallback onToggleLibrary;
  final VoidCallback? onTrailer;

  static const String addTooltip = TvMetaHeader.addTooltip;
  static const String removeTooltip = TvMetaHeader.removeTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final facts = [?meta.releaseInfo, ?meta.runtime, meta.type].join(' · ');
    final scores = shownScores(meta, ratings);
    final genres = meta.genres;
    final posterWidth = isWide ? 130.0 : 90.0;
    final description = meta.description;

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(facts, style: theme.textTheme.labelLarge),
              ),
            ),
            IconButton(
              tooltip: isInLibrary ? removeTooltip : addTooltip,
              isSelected: isInLibrary,
              icon: const Icon(Icons.bookmark_border),
              selectedIcon: const Icon(Icons.bookmark),
              onPressed: onToggleLibrary,
            ),
          ],
        ),
        if (downloads.isNotEmpty) ...[
          const SizedBox(height: 6),
          DownloadSummary(downloads: downloads, metaId: meta.id),
        ],
        if (scores.isNotEmpty) ...[
          const SizedBox(height: 4),
          DetailsScores(meta: meta, ratings: ratings),
        ],
        if (genres.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: -8,
            children: [
              // Wrapped for the same reason the filter chips are: the
              // floor fills a chip and cannot outline one. This header is
              // the phone's and the desktop's -- a television gets
              // [TvMetaHeader] instead -- so [FocusMarked] is its child
              // and nothing else here today. It is on every chip in the
              // app all the same, so which chips are marked is something
              // to read rather than to trace.
              for (final genre in genres)
                FocusMarked(
                  borderRadius: FocusMarked.stadium,
                  child: ActionChip(
                    label: Text(genre.name),
                    visualDensity: VisualDensity.compact,
                    onPressed: switch (genre.discoverRequest) {
                      null => null,
                      final request => () => onGenre(request),
                    },
                  ),
                ),
            ],
          ),
        ],
        if (isWide && description != null) ...[
          const SizedBox(height: 12),
          ExpandableText(description),
        ],
        // Under the description, which is where it goes in either width:
        // in the column beside the poster when that is where the words are.
        if (isWide && onTrailer != null) ...[
          const SizedBox(height: 12),
          TrailerButton(onPressed: onTrailer!),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: posterWidth,
                height: posterWidth * 1.5,
                child: PosterImage(url: meta.poster),
              ),
              const SizedBox(width: 16),
              Expanded(child: details),
            ],
          ),
          if (!isWide && description != null) ...[
            const SizedBox(height: 12),
            ExpandableText(description),
          ],
          if (!isWide && onTrailer != null) ...[
            const SizedBox(height: 12),
            TrailerButton(onPressed: onTrailer!),
          ],
        ],
      ),
    );
  }
}

/// The title's trailer, under its description: a YouTube video the meta
/// addon listed, opened in the YouTube app (a browser where there is none)
/// -- the embedded server has no YouTube resolver, so the player could only
/// fail on it. One button for both layouts; a television wraps it in the
/// ring its header's stops wear.
class TrailerButton extends StatelessWidget {
  const TrailerButton({super.key, required this.onPressed, this.focusNode});

  final VoidCallback onPressed;
  final FocusNode? focusNode;

  static const String label = 'Trailer';

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    focusNode: focusNode,
    onPressed: onPressed,
    icon: const Icon(Icons.smart_display_outlined),
    label: const Text(label),
  );
}

/// Body text clamped to a few lines with a "More" toggle when it overflows.
class ExpandableText extends StatefulWidget {
  const ExpandableText(this.text, {super.key});

  final String text;

  static const int collapsedLines = 4;

  @override
  State<ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium;
    return LayoutBuilder(
      builder: (context, constraints) {
        final overflows = textOverflows(
          context,
          widget.text,
          style: style,
          maxLines: ExpandableText.collapsedLines,
          maxWidth: constraints.maxWidth,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: style,
              maxLines: _expanded ? null : ExpandableText.collapsedLines,
              overflow: _expanded ? null : TextOverflow.ellipsis,
            ),
            if (overflows)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(_expanded ? 'Less' : 'More'),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The seasons of a series, as one horizontally scrolling row of pills with
/// the current one filled. Season 0 is `Specials`; every other pill is the
/// bare number, beside a "Season" label so that a lone `3` says what it is.
///
/// One shape on every device, because a season is a single short token and
/// a row of them is readable at a glance. A segmented control where there
/// is room, a menu on a television, a dropdown everywhere else -- each
/// would spend a press on opening and another on choosing, and the two
/// that open a list would open it as a very narrow, very tall column of
/// digits, which on a remote is a long vertical crawl.
///
/// Three things it has to do that a plain row would not:
///
/// - **Every pill is built at once**: a [Row] inside a
///   [SingleChildScrollView], never a lazy [ListView]. Flutter's
///   directional traversal only considers widgets that have been built, so
///   a lazily built row silently stops the D-pad at the last realised pill
///   however many seasons the series has.
/// - **A pill is as wide as it needs to be**, up to an even share of the
///   row. Two seasons stretched across a television read as two buttons
///   for something else entirely, so the even share is a ceiling now and
///   [SeasonSelector._maxPillWidth] is the other one; the row is packed
///   at the left like every other row on the screen. What that costs is
///   that directional focus, which prefers whatever overlaps the press
///   horizontally, no longer finds the pills from anywhere along the row
///   below. That is [TvLadder]'s job on this screen and not geometry's:
///   the pills are a rung, and an up press from the episodes reaches them
///   from anywhere along the row.
/// - **The selected pill is scrolled into view** when the season changes or
///   the row is built for another title, so season 12 does not open with
///   the row parked at 1. Only the row moves: [ScrollPosition.ensureVisible]
///   on its own position, rather than [Scrollable.ensureVisible], which
///   would drag the page's vertical scroll along with it.
class SeasonSelector extends StatefulWidget {
  const SeasonSelector({
    super.key,
    required this.seasons,
    required this.selected,
    required this.onChanged,
  });

  final List<int> seasons;
  final int selected;
  final ValueChanged<int> onChanged;

  /// What one pill reads: the number alone, and season 0 by its name.
  static String label(int season) => season == 0 ? 'Specials' : '$season';

  /// How long the scroll that brings the selected pill into view takes.
  static const Duration revealDuration = Duration(milliseconds: 200);

  /// The space between two pills.
  static const double _gap = 8;

  /// The widest a pill is drawn, however few seasons share the row. Enough
  /// for `Specials` and the padding a chip puts around it.
  static const double _maxPillWidth = 120;

  /// Rounds the focus ring around a pill. A chip is stadium-shaped, and a
  /// radius this side of half its height is drawn as one (the radii are
  /// scaled down to fit the box, never up).
  static const BorderRadius _pillRadius = BorderRadius.all(Radius.circular(40));

  @override
  State<SeasonSelector> createState() => _SeasonSelectorState();
}

class _SeasonSelectorState extends State<SeasonSelector> {
  final ScrollController _controller = ScrollController();

  /// One key per season, so the reveal below can find the pill's box.
  final Map<int, GlobalKey> _pills = {};

  /// One focus node per season, kept for as long as this row is on screen.
  ///
  /// A node per *season* rather than one for "the selected pill": focusing
  /// a pill is what changes the season here, so a node that followed the
  /// selection would be taken off the chip the remote had just landed on
  /// and handed to another, which is focus disappearing mid-press.
  final Map<int, FocusNode> _nodes = {};

  FocusNode _nodeFor(int season) =>
      _nodes.putIfAbsent(season, () => FocusNode(debugLabel: 'season $season'));

  @override
  void initState() {
    super.initState();
    _revealSelected();
  }

  @override
  void didUpdateWidget(SeasonSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected ||
        !listEquals(oldWidget.seasons, widget.seasons)) {
      _revealSelected();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// Centres the selected pill in the row, once the frame that laid it out
  /// is on screen: the pill of a season chosen this frame has no box yet.
  void _revealSelected() {
    final season = widget.selected;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final box = _pills[season]?.currentContext?.findRenderObject();
      if (box == null) return;
      _controller.position.ensureVisible(
        box,
        alignment: 0.5,
        duration: SeasonSelector.revealDuration,
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    _pills.removeWhere((season, _) => !widget.seasons.contains(season));
    return Row(
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Text('Season', style: theme.textTheme.labelLarge),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // An even share of the row each as a *minimum*, and never
              // wider than [SeasonSelector._maxPillWidth]: a series with
              // two seasons draws two ordinary pills at the left rather
              // than two halves of a television, and one with thirty keeps
              // them at their own width and scrolls.
              //
              // Never below zero: past about thirty pills the gaps alone
              // are wider than the row, and a negative minimum is not a
              // cramped layout but a `NOT NORMALIZED` constraints failure
              // that takes the episode list down with it. A series that
              // long scrolls at its pills' own width, which is the same
              // thing an even share of nothing would be.
              final even =
                  (constraints.maxWidth -
                      SeasonSelector._gap * (widget.seasons.length - 1)) /
                  widget.seasons.length;
              final share = even > 0
                  ? (even < SeasonSelector._maxPillWidth
                        ? even
                        : SeasonSelector._maxPillWidth)
                  : 0.0;
              return SingleChildScrollView(
                controller: _controller,
                scrollDirection: Axis.horizontal,
                child: Row(
                  spacing: SeasonSelector._gap,
                  children: [
                    for (final season in widget.seasons)
                      ConstrainedBox(
                        key: _pills.putIfAbsent(season, GlobalKey.new),
                        constraints: BoxConstraints(minWidth: share),
                        // The same indicator every focusable thing on a
                        // television wears, rather than a ring of the
                        // pill's own: a chip's built-in focus highlight is
                        // a tint, which is exactly the cue a bright room
                        // takes away.
                        // The season on screen is where a press down
                        // into this row lands: any other pill would
                        // switch the season just by being landed on.
                        child: TvLadderHome(
                          isHome: season == widget.selected,
                          child: FocusHighlighted(
                            borderRadius: SeasonSelector._pillRadius,
                            focusNode: _nodeFor(season),
                            // The remote landing on a pill is the viewer
                            // asking to see that season: the episodes below
                            // follow the highlight, and select is left to
                            // mean the press that goes down into them.
                            onFocused: () => widget.onChanged(season),
                            builder: (context, node) => ChoiceChip(
                              focusNode: node,
                              label: Text(SeasonSelector.label(season)),
                              showCheckmark: false,
                              selected: season == widget.selected,
                              // Selected or not, every pill takes a press and
                              // is a focus stop: a chip with no callback is
                              // neither, which would leave a remote unable to
                              // rest on the season already on screen.
                              onSelected: (_) => widget.onChanged(season),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class EpisodeTile extends StatelessWidget {
  const EpisodeTile({
    super.key,
    required this.video,
    required this.isSelected,
    required this.isWatched,
    required this.isReleased,
    required this.onTap,
    required this.onLongPress,
    this.download,
    this.onDeleteDownload,
  });

  final VideoInfo video;
  final bool isSelected;
  final bool isWatched;
  final bool isReleased;

  /// This episode's download, whatever source it was taken from; null when
  /// it is not kept on the device.
  final DownloadView? download;

  /// Removes [download], which the badge offers once the file is whole.
  final void Function(DownloadView entry)? onDeleteDownload;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// The watched check (or the selection's play arrow), with the download
  /// badge in front of it when this episode is kept on the device.
  ///
  /// The badge deletes the download once the file is whole. Not with a
  /// remote, though: a button inside a tile the remote activates as a whole
  /// cannot be focused, and this row's long press already means "watched",
  /// so on a television the episode's copy is removed from its stream tile
  /// -- select the episode, hold select on the release that is kept.
  Widget? _trailing(ThemeData theme) {
    final download = this.download;
    final state = isWatched
        ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
        : isSelected
        ? const Icon(Icons.play_arrow)
        : null;
    if (download == null) return state;
    final onDelete = onDeleteDownload;
    final badge = DownloadBadge(
      download: download,
      onDelete: onDelete == null ? null : () => onDelete(download),
    );
    if (state == null) return badge;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [badge, const SizedBox(width: 8), state],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = episodeDateLabel(video);
    final episode = video.episode;
    final title = video.title.isEmpty && episode != null
        ? 'Episode $episode'
        : video.title;
    final tile = ListTile(
      selected: isSelected,
      enabled: isReleased,
      onTap: onTap,
      onLongPress: onLongPress,
      leading: EpisodeThumbnail(video: video),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: date == null && isReleased
          ? null
          : Text(
              [?date, if (!isReleased) 'Upcoming'].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
      trailing: _trailing(theme),
    );
    if (!DeviceScope.isTv(context)) return tile;
    return RemotePress(onTap: onTap, onLongPress: onLongPress, child: tile);
  }
}
