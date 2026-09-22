import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../shell/tv_density.dart';
import '../../widgets/download_badge.dart';
import '../../widgets/focusable_tile.dart';
import '../../widgets/tv_ladder.dart';

/// The sources of the selected video on a television: a row of group
/// pills, and beneath it the sources of whichever group is chosen.
///
/// The phone and the desktop list every source in one vertical column, cut
/// into collapsible sections. A remote cannot walk that: a title with six
/// addons answering is a hundred rows deep, and the column is the wrong
/// shape for a screen that is all width. So the same two levels the
/// sections already have become two rows -- the first one groups, the
/// second one sources -- which is the shape every other row on this screen
/// is in and the one the D-pad is built for.
///
/// What the first level groups *by* is the layout preference the sources
/// list already has ([AppPrefs.streamsSectioned]): a pill per resolution,
/// or a pill per addon. It is not a second setting, and the order chips
/// above still order inside a group.
///
/// Three things about it are not cosmetic:
///
/// - **Walking the group row opens what the remote lands on.** A group is
///   a choice of what the second row shows, and a highlight says as much
///   as a press does: the row under the remote is always the row for the
///   pill it is on, and select is left to go down into it. The group row
///   itself stays put, so the next group is one sideways press away rather
///   than a press back and a press down.
/// - **Both rows are built all at once.** Directional focus only
///   considers widgets that have been built, so a lazily built strip hands
///   the D-pad back at the last realised card. Each row is a
///   [SingleChildScrollView] over a [Row], the same shape the season pills
///   and the episode cards use.
/// - **Which group is open is the screen's, not a preference.** The
///   phone's open sections are a global set that survives a restart; here
///   exactly one row is open at a time and Back closes it, which is a
///   different thing wearing the same word. Nothing about opening a group
///   on a television is written down.
///
/// **Up and down move by level, not by distance** ([TvLadder]): the group
/// row and the row of sources it opens are two rungs of the screen's
/// ladder, and each hands the remote back to the card it was last on.
///
/// Closing the second row takes the card the remote was on off the screen
/// with it, and nothing here puts the remote back: the enclosing
/// [FocusScope] remembers what held focus before and hands it the ring
/// when a focused node goes away, which is the group pill that opened the
/// row. A test walks that path, because "focus nowhere" on a television is
/// a dead D-pad and the fallback is the only thing standing between them.
class TvSourceRows extends StatefulWidget {
  const TvSourceRows({
    super.key,
    required this.groups,
    required this.openLabel,
    required this.onOpen,
    this.onFocusGroup,
    required this.groupLevel,
    required this.sourceLevel,
    this.defaultFocus = false,
  });

  /// Which rung of the screen's [TvLadder] each of these two rows is.
  final int groupLevel;
  final int sourceLevel;

  /// The groups, in the order the row draws them.
  final List<TvSourceGroup> groups;

  /// The [TvSourceGroup.label] whose sources are open beneath the row;
  /// null for none. A label no group carries is nothing open.
  final String? openLabel;

  /// Opens that group, or closes the open one (null).
  final ValueChanged<String?> onOpen;

  /// The remote has come to rest on a group pill, which is the viewer
  /// asking for that group's sources. Separate from [onOpen] because the
  /// screen answers it differently: a row the viewer has just put away
  /// with Back must not come straight back when focus returns to the pill
  /// it was opened from. Falls back to [onOpen] when nobody is listening.
  final ValueChanged<String>? onFocusGroup;

  /// Whether the first group pill is where the remote starts on this
  /// screen. False when something above it (the last-used source) is.
  final bool defaultFocus;

  /// How wide a group pill is allowed to get.
  ///
  /// A resolution is one word and the pill is as wide as that word. An
  /// addon's name is not: `caching.stremio.net` drawn in full is most of
  /// a quarter of the panel, and four of those are a row the remote has
  /// to scroll. So a long label ellipsizes at the width the card this
  /// replaced used to be, and the row stays a row of choices.
  static const double maxPillWidth = 208;

  /// How tall a group pill is drawn at text scale 1.
  ///
  /// A resolution is one word and a count. The 208x84 card this replaced
  /// carried an icon, the word, and two lines of summary under it -- four
  /// of them were the whole panel, and the screen had five other rungs to
  /// fit. The pill is as tall as the word needs and as wide as the word
  /// is, which is what lets the sources, the episodes and the last-used
  /// card share a 720p panel.
  static const double pillHeight = 36;

  /// How wide a source card is: two lines of a release name, which is what
  /// the row is really for.
  static const double sourceCardWidth = 260;

  /// The box a source card is drawn in at text scale 1: two lines of
  /// release name over one line of facts.
  static const double sourceCardHeight = 96;

  /// The gap between two cards.
  static const double gap = 12;

  /// The margin at either end of a row.
  static const double sidePadding = 16;

  /// Room kept above and below the cards for a focused one to grow into.
  /// A strip clips to exactly its own bounds, so without it the zoom and
  /// the shadow are cut off at both edges and read as a crop.
  static const double focusSlack = 12;

  /// The height of the group row, including that room.
  static double groupRowHeight(BuildContext context) =>
      focusSlack * 2 + pillHeight * _textFactor(context);

  /// The height of the row of sources under it.
  static double sourceRowHeight(BuildContext context) =>
      focusSlack * 2 + sourceCardHeight * _textFactor(context);

  /// How much bigger text is here than at the size these boxes were picked
  /// for, never below 1: the boxes are an exact fit at 1 and the padding
  /// in them is fixed, so a smaller system font would overflow rather than
  /// shrink them.
  static double _textFactor(BuildContext context) =>
      math.max(1, TvDensity.textFactorOf(context));

  @override
  State<TvSourceRows> createState() => _TvSourceRowsState();
}

class _TvSourceRowsState extends State<TvSourceRows> {
  /// Whether the group the remote was handed on arrival has been shown.
  ///
  /// Once per row, and never again: Back closes an open row by rebuilding
  /// this one with nothing open and the remote back on the pill that
  /// opened it, so opening it again there would make Back do nothing at
  /// all. The groups arrive after the screen does -- the addons are still
  /// answering -- so this cannot simply be done in [initState].
  bool _shownOnArrival = false;

  @override
  void initState() {
    super.initState();
    _showOnArrival();
  }

  @override
  void didUpdateWidget(TvSourceRows oldWidget) {
    super.didUpdateWidget(oldWidget);
    _showOnArrival();
  }

  /// Opens the group the remote starts on, so the highlight tells the
  /// truth from the first frame.
  ///
  /// The pill that takes focus by default says which resolution -- or
  /// which addon -- the screen is showing, and a highlight over a shut row
  /// says it about nothing: every other way of landing on a group opens
  /// it, so this one did too, one press later and only because the viewer
  /// pressed select on a pill they were already standing on.
  ///
  /// Nothing happens when the remote starts somewhere else ([defaultFocus]
  /// is false whenever another rung is the one the title is for), nor when
  /// a group is open already.
  void _showOnArrival() {
    if (_shownOnArrival || !widget.defaultFocus) return;
    final first = widget.groups.firstOrNull;
    if (first == null) return;
    _shownOnArrival = true;
    if (widget.openLabel != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) (widget.onFocusGroup ?? widget.onOpen)(first.label);
    });
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.groups;
    final openLabel = widget.openLabel;
    if (groups.isEmpty) return const SizedBox.shrink();
    final open = groups.where((g) => g.label == openLabel).firstOrNull;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TvLadderRow(
          level: widget.groupLevel,
          advanceOnSelect: true,
          child: SizedBox(
            height: TvSourceRows.groupRowHeight(context),
            child: _Strip(
              children: [
                for (final (index, group) in groups.indexed)
                  TvSourceGroupPill(
                    group: group,
                    chosen: group.label == openLabel,
                    defaultFocus: widget.defaultFocus && index == 0,
                    // Opening, not toggling: the remote standing here is
                    // already what opened this row, so a press that closed
                    // it again would make select mean the opposite of what
                    // it means everywhere else on the screen. Back is what
                    // closes a row.
                    onTap: () => widget.onOpen(group.label),
                    onFocused: () =>
                        (widget.onFocusGroup ?? widget.onOpen)(group.label),
                  ),
              ],
            ),
          ),
        ),
        if (open != null)
          TvLadderRow(
            level: widget.sourceLevel,
            child: TvSourceRow(sources: open.sources),
          ),
      ],
    );
  }
}

/// One strip of source cards, scrolled sideways: the second level of
/// [TvSourceRows], and on its own the one-card row the last-used source is
/// drawn in.
class TvSourceRow extends StatelessWidget {
  const TvSourceRow({
    super.key,
    required this.sources,
    this.defaultFocus = false,
    this.focusNode,
  });

  final List<TvSource> sources;

  /// Whether the first card is where the remote starts on this screen.
  final bool defaultFocus;

  /// The node the first card focuses with, for a screen that has to put
  /// the remote on that card itself rather than by [defaultFocus] -- which
  /// only ever takes when nothing else is focused yet (see
  /// [MetaDetailsScreen]'s last-used card, the one caller).
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: TvSourceRows.sourceRowHeight(context),
    child: _Strip(
      children: [
        for (final (index, source) in sources.indexed)
          SizedBox(
            width: TvSourceRows.sourceCardWidth,
            child: TvSourceCard(
              source: source,
              defaultFocus: defaultFocus && index == 0,
              focusNode: index == 0 ? focusNode : null,
            ),
          ),
      ],
    ),
  );
}

/// A row of cards the remote walks end to end, built all at once (see
/// [TvSourceRows]), and which a sideways press cannot walk out of.
///
/// Directional traversal takes the nearest node in the direction pressed,
/// and "nearest" is not confined to the row: a press past the last card
/// found the layout toggle in the header above and left the sources
/// altogether, several rows from where the remote was, with no press that
/// obviously undoes it. So the two keys that run along the row are
/// swallowed at its ends -- the same thing the shell's rail does with up
/// and down at its own ends, and for the same reason. Every other key
/// passes, so up and down still leave the row.
class _Strip extends StatelessWidget {
  const _Strip({required this.children});

  final List<Widget> children;

  /// Left at the first card and right at the last stay where they are.
  /// The cards a source cannot be played from are not focus stops and so
  /// are not in this list, which is what makes the ends the ends.
  static KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final back = key == LogicalKeyboardKey.arrowLeft;
    if (!back && key != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    final focused = FocusManager.instance.primaryFocus;
    if (focused == null) return KeyEventResult.ignored;
    final cards = node.traversalDescendants.toList();
    final index = cards.indexOf(focused);
    if (index < 0) return KeyEventResult.ignored;
    final atEnd = back ? index == 0 : index == cards.length - 1;
    return atEnd ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final strip = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: TvSourceRows.sidePadding,
        vertical: TvSourceRows.focusSlack,
      ),
      child: Row(
        spacing: TvSourceRows.gap,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: children,
      ),
    );
    if (!DeviceScope.isTv(context)) return strip;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onKeyEvent: _onKey,
      child: strip,
    );
  }
}

/// One pill of the first row: a resolution rung, an addon, or the line of
/// accounting the sources rows have nowhere else to put -- what it is
/// called, how many it holds, and whether those are the sources on screen.
///
/// A pill and not a card, because a resolution is one word. It is as wide
/// as its own label, so the row is read as a set of choices rather than as
/// a wall of boxes, and eight of them still fit across a 720p panel.
class TvSourceGroupPill extends StatelessWidget {
  const TvSourceGroupPill({
    super.key,
    required this.group,
    required this.chosen,
    required this.onTap,
    this.onFocused,
    this.defaultFocus = false,
  });

  final TvSourceGroup group;

  /// Its sources are the row underneath.
  final bool chosen;

  final VoidCallback onTap;

  /// The remote has come to rest on this pill, which opens its sources
  /// (see [TvSourceRows]).
  final VoidCallback? onFocused;

  final bool defaultFocus;

  /// Half the height, so the box comes out a stadium: the painter clamps a
  /// corner to half the box it is drawn on and never grows one.
  static const BorderRadius _radius = BorderRadius.all(
    Radius.circular(TvSourceRows.pillHeight / 2),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final count = group.count;
    return FocusableTile(
      onTap: onTap,
      onFocused: onFocused,
      defaultFocus: defaultFocus,
      borderRadius: _radius,
      // A row of stadiums side by side: the ring, and none of the lift a
      // poster gets. The chosen one is already marked by its fill.
      treatment: FocusTreatment.row,
      child: Container(
        height: TvSourceRows.pillHeight,
        constraints: const BoxConstraints(maxWidth: TvSourceRows.maxPillWidth),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          // Chosen is a fill, a border and a weight, never the tint alone:
          // colour is the first cue a bright room takes away, and which
          // group is showing is the whole point of the row.
          color: chosen ? scheme.primaryContainer : scheme.surfaceContainerHigh,
          borderRadius: _radius,
          border: Border.all(
            color: chosen ? scheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            if (group.icon != null)
              Icon(
                group.icon,
                size: 18,
                color: chosen
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
            Flexible(
              child: Text(
                group.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: chosen ? scheme.onPrimaryContainer : null,
                  fontWeight: chosen ? FontWeight.w700 : null,
                ),
              ),
            ),
            // The count is a second line of text and not part of the
            // label: the label is the choice and the count is what is
            // behind it, so the count is drawn quieter -- and the label on
            // its own is what anything looking for this pill by name
            // finds.
            if (count != null)
              Text(
                '· $count',
                maxLines: 1,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: chosen
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One card of the second row: a source to play, or a line of the
/// accounting that has nowhere else to go (see [TvSourceRows]).
///
/// The release name leads, because it is the one thing on the card that
/// tells two sources apart, and under it one line of facts -- seeders,
/// size, and whichever of the resolution and the addon the pill above does
/// not already say. What used to be a second and a third line (the badges,
/// the addon, "Also from ...") is that one line now: the card is 96 dp
/// tall so that the episodes and the last-used source can be on the panel
/// with it.
///
/// A source that the player cannot open takes no press, and so is not a
/// focus stop either -- the remote steps over it, exactly as the vertical
/// list's disabled row does. What kind of source it is leads the facts
/// line instead, since there is no play arrow to replace.
class TvSourceCard extends StatelessWidget {
  const TvSourceCard({
    super.key,
    required this.source,
    this.defaultFocus = false,
    this.focusNode,
  });

  final TvSource source;
  final bool defaultFocus;

  /// See [TvSourceRow.focusNode]; one is made for the card when null.
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return FocusableTile(
      onTap: source.onSelect,
      onLongPress: source.onHold,
      defaultFocus: defaultFocus,
      focusNode: focusNode,
      borderRadius: _cardRadius,
      child: _CardBox(
        color: source.highlighted
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHigh,
        borderColor: source.highlighted ? scheme.secondary : Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Row(
                spacing: 6,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(source.icon, size: 16, color: scheme.onSurfaceVariant),
                  Expanded(
                    child: Text(
                      breakableRelease(source.title),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurface,
                        height: 1.25,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Row(
              spacing: 6,
              children: [
                Expanded(
                  child: Text(
                    source.facts.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                ?_downloadMark(source),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// What the card says about the copy on the device: the same badge the
  /// episode cards wear, or a ring while a pin is still being taken. The
  /// press that starts or drops one is the card's own hold ([TvSource]),
  /// because a button drawn inside a focusable thing cannot be reached by
  /// a remote at all.
  Widget? _downloadMark(TvSource source) {
    if (source.downloading) {
      return const SizedBox.square(
        dimension: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    final download = source.download;
    return download == null ? null : DownloadBadge(download: download);
  }
}

/// [release] with a break opportunity after every separator a release name
/// is built out of.
///
/// `Avalon.2001.1080p.BluRay.x264-CiNEFiLE` is one word as far as Unicode
/// line breaking is concerned: nothing in UAX #14 breaks after a full stop
/// between two letters. So a card 260 wide broke it wherever the second
/// line happened to start -- `Avalon.2001.1080p.BluRay.x2` / `64-CiNEFiLE`
/// -- which splits the very tokens a viewer reads the name by. A
/// zero-width space after each `.`, `_` and `-` gives the layout somewhere
/// to break that a reader would have broken it anyway, and nothing is
/// added anywhere else: a space is already a break opportunity, and a
/// release with neither still breaks mid-token because a word longer than
/// the line has to.
///
/// The character is invisible and has no width, so the line is drawn
/// exactly as it reads. It is in the string the card lays out and
/// therefore in what a widget test finds by text, which is why the test
/// helpers take it back out again rather than every assertion spelling it.
String breakableRelease(String release) =>
    release.replaceAllMapped(RegExp(r'[._-]'), (m) => '${m[0]}​');

/// The ground a card is drawn on: a filled, rounded box with a border that
/// is there whether or not it is coloured, so marking a card does not move
/// anything inside it.
class _CardBox extends StatelessWidget {
  const _CardBox({
    required this.color,
    required this.borderColor,
    required this.child,
  });

  final Color color;
  final Color borderColor;
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      borderRadius: _cardRadius,
      border: Border.all(color: borderColor, width: 2),
    ),
    child: Padding(padding: const EdgeInsets.all(8), child: child),
  );
}

/// Rounds a card, its ink and its focus ring; every tile in the app uses
/// the same 8 px.
const BorderRadius _cardRadius = BorderRadius.all(Radius.circular(8));

/// One source as a television card draws it, or one line of the accounting
/// that the sources rows have taken the place of.
///
/// The screen builds these: what a card shows about a stream (which release
/// it is, what could be read out of it, which addon answered) is the
/// sources list's business, and what a press does about it -- play it, keep
/// it, check the addon that failed -- is the screen's.
typedef TvSource = ({
  /// The kind of source, or what the line is about.
  IconData icon,

  /// The release name ([releaseNameOf]), or what the accounting has to
  /// say.
  String title,

  /// The one line under it, already in the order it reads and with only
  /// what is actually known in it -- never a placeholder for what is not.
  /// Joined with a middle dot by the card.
  List<String> facts,

  /// This is the source the title was last played from.
  bool highlighted,

  /// The copy on the device, when there is one.
  DownloadView? download,

  /// A pin for it is in flight.
  bool downloading,

  /// Select. Null takes no press and no focus.
  VoidCallback? onSelect,

  /// A held select, or the remote's menu key. Null leaves a hold meaning
  /// what it meant before: a tap on release.
  VoidCallback? onHold,
});

/// One pill of the group row and the sources it opens.
typedef TvSourceGroup = ({
  /// The rung, the addon, or what the accounting pill is called. It is the
  /// group's identity as well as its label: it is what says which row is
  /// open.
  String label,

  /// How many sources are behind it, drawn after the label -- "1080p ·
  /// 31". Null for a group whose count is not the useful thing about it.
  ///
  /// A count and not the sentence a collapsed section header carries on a
  /// phone ("31 streams · best 90 seeders"): a pill is one word wide, and
  /// the swarm is on each card in the row the pill opens.
  String? count,

  /// Drawn before the label; null for the groups that are simply sources.
  IconData? icon,

  List<TvSource> sources,
});
