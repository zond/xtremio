import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/tv_density.dart';
import '../../widgets/download_badge.dart';
import '../../widgets/focusable_tile.dart';

/// The sources of the selected video on a television: a row of group
/// cards, and beneath it the sources of whichever group is chosen.
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
/// list already has ([AppPrefs.streamsSectioned]): a card per resolution,
/// or a card per addon. It is not a second setting, and the order chips
/// above still order inside a group.
///
/// Three things about it are not cosmetic:
///
/// - **The group row stays put when a group is chosen.** The second row
///   opens under it with the chosen card marked, so the next group is one
///   sideways press away rather than a press back and a press down.
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
/// Closing the second row takes the card the remote was on off the screen
/// with it, and nothing here puts the remote back: the enclosing
/// [FocusScope] remembers what held focus before and hands it the ring
/// when a focused node goes away, which is the group card that opened the
/// row. A test walks that path, because "focus nowhere" on a television is
/// a dead D-pad and the fallback is the only thing standing between them.
class TvSourceRows extends StatelessWidget {
  const TvSourceRows({
    super.key,
    required this.groups,
    required this.openLabel,
    required this.onOpen,
    this.defaultFocus = false,
  });

  /// The groups, in the order the row draws them.
  final List<TvSourceGroup> groups;

  /// The [TvSourceGroup.label] whose sources are open beneath the row;
  /// null for none. A label no group carries is nothing open.
  final String? openLabel;

  /// Opens that group, or closes the open one (null).
  final ValueChanged<String?> onOpen;

  /// Whether the first group card is where the remote starts on this
  /// screen. False when something above it (the last-used source) is.
  final bool defaultFocus;

  /// How wide a group card is: enough for a resolution or an addon name
  /// and the line under it, narrow enough that several rungs are on the
  /// panel at once.
  static const double groupCardWidth = 208;

  /// The box a group card is drawn in at text scale 1.
  static const double groupCardHeight = 84;

  /// How wide a source card is. A release name is long, and this is the
  /// row the viewer actually reads.
  static const double sourceCardWidth = 300;

  /// The box a source card is drawn in at text scale 1: two lines of name
  /// over the badges, the addon and whoever else offered it.
  static const double sourceCardHeight = 148;

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
      focusSlack * 2 + groupCardHeight * _textFactor(context);

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
  Widget build(BuildContext context) {
    if (groups.isEmpty) return const SizedBox.shrink();
    final open = groups.where((g) => g.label == openLabel).firstOrNull;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: TvSourceRows.groupRowHeight(context),
          child: _Strip(
            children: [
              for (final (index, group) in groups.indexed)
                SizedBox(
                  width: TvSourceRows.groupCardWidth,
                  child: TvSourceGroupCard(
                    group: group,
                    chosen: group.label == openLabel,
                    defaultFocus: defaultFocus && index == 0,
                    onTap: () =>
                        onOpen(group.label == openLabel ? null : group.label),
                  ),
                ),
            ],
          ),
        ),
        if (open != null) TvSourceRow(sources: open.sources),
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
  });

  final List<TvSource> sources;

  /// Whether the first card is where the remote starts on this screen.
  final bool defaultFocus;

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
            ),
          ),
      ],
    ),
  );
}

/// A row of cards the remote walks end to end, built all at once (see
/// [TvSourceRows]).
class _Strip extends StatelessWidget {
  const _Strip({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(
      horizontal: TvSourceRows.sidePadding,
      vertical: TvSourceRows.focusSlack,
    ),
    child: Row(
      spacing: TvSourceRows.gap,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}

/// One card of the first row: a resolution rung or an addon, what it
/// holds, and whether its sources are the ones on screen.
class TvSourceGroupCard extends StatelessWidget {
  const TvSourceGroupCard({
    super.key,
    required this.group,
    required this.chosen,
    required this.onTap,
    this.defaultFocus = false,
  });

  final TvSourceGroup group;

  /// Its sources are the row underneath.
  final bool chosen;

  final VoidCallback onTap;
  final bool defaultFocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return FocusableTile(
      onTap: onTap,
      defaultFocus: defaultFocus,
      borderRadius: _cardRadius,
      child: _CardBox(
        // Chosen is a fill, a border and a weight, never the tint alone:
        // colour is the first cue a bright room takes away, and which
        // group is showing is the whole point of the row.
        color: chosen ? scheme.primaryContainer : scheme.surfaceContainerHigh,
        borderColor: chosen ? scheme.primary : Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
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
                Expanded(
                  child: Text(
                    group.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: chosen ? scheme.onPrimaryContainer : null,
                      fontWeight: chosen ? FontWeight.w700 : null,
                    ),
                  ),
                ),
              ],
            ),
            const Spacer(),
            Text(
              group.summary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
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
/// A source that the player cannot open takes no press, and so is not a
/// focus stop either -- the remote steps over it, exactly as the vertical
/// list's disabled row does. What kind of source it is says so on a badge
/// instead, since there is no play arrow to replace.
class TvSourceCard extends StatelessWidget {
  const TvSourceCard({
    super.key,
    required this.source,
    this.defaultFocus = false,
  });

  final TvSource source;
  final bool defaultFocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final detail = source.detail;
    final alsoFrom = source.alsoFrom;
    return FocusableTile(
      onTap: source.onSelect,
      onLongPress: source.onHold,
      defaultFocus: defaultFocus,
      borderRadius: _cardRadius,
      child: _CardBox(
        color: source.highlighted
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHigh,
        borderColor: source.highlighted ? scheme.secondary : Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              spacing: 8,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(source.icon, size: 18, color: scheme.onSurfaceVariant),
                Expanded(
                  child: Text(
                    source.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                ?_downloadMark(source),
              ],
            ),
            const Spacer(),
            if (source.badges.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Wrap(
                  spacing: 6,
                  children: [for (final badge in source.badges) _Badge(badge)],
                ),
              ),
            if (detail != null)
              Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            if (alsoFrom != null)
              Text(
                alsoFrom,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
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
        dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    final download = source.download;
    return download == null ? null : DownloadBadge(download: download);
  }
}

/// One fact about a source, in the same box the vertical list draws it in.
class _Badge extends StatelessWidget {
  const _Badge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
      ),
    );
  }
}

/// The ground both kinds of card are drawn on: a filled, rounded box with
/// a border that is there whether or not it is coloured, so marking a card
/// does not move anything inside it.
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
    child: Padding(padding: const EdgeInsets.all(10), child: child),
  );
}

/// Rounds a card, its ink and its focus ring; every tile in the app uses
/// the same 8 px.
const BorderRadius _cardRadius = BorderRadius.all(Radius.circular(8));

/// One source as a television card draws it, or one line of the accounting
/// that the sources rows have taken the place of.
///
/// The screen builds these: what a card shows about a stream (which addon
/// answered, what could be read out of it, who else offered the same
/// source) is the sources list's business, and what a press does about it
/// -- play it, keep it, check the addon that failed -- is the screen's.
typedef TvSource = ({
  /// The kind of source, or what the line is about.
  IconData icon,

  /// The release, or what the accounting has to say.
  String title,

  /// The addon that answered, or the rest of the sentence. Null draws no
  /// line at all.
  String? detail,

  /// Resolution, size, seeders: only what is actually known, never a
  /// placeholder for what is not.
  List<String> badges,

  /// The other addons that offered this very source, already worded.
  String? alsoFrom,

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

/// One card of the group row and the sources it opens.
typedef TvSourceGroup = ({
  /// The rung, the addon, or what the accounting card is called. It is the
  /// group's identity as well as its label: it is what says which row is
  /// open.
  String label,

  /// What the card says it holds -- the same line a collapsed section
  /// header carries on a phone.
  String summary,

  /// Drawn before the label; null for the groups that are simply sources.
  IconData? icon,

  List<TvSource> sources,
});
