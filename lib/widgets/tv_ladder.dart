import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../shell/device_profile.dart';
import 'focusable_tile.dart';
import 'remote_press.dart';

/// Vertical navigation on a television, by level rather than by distance.
///
/// Flutter's directional focus takes the nearest node in the direction
/// pressed, and "nearest" is a question about where things happen to be
/// drawn: the rightmost season pill has no episode card below *it*, so a
/// press down leaves the episode row entirely and lands on whatever spans
/// the width further down. Coming back up is worse, because the row that
/// was skipped is skipped again in reverse, and a screen built of rows
/// then has stops the D-pad cannot reach at all.
///
/// So the rows of a screen say what order they are in, and a press up or
/// down moves to the next row that will take it. **Each row remembers the
/// card it was last on** and hands the remote back there, defaulting to
/// its first: walking away from the third episode and coming back lands on
/// the third episode, which is what a viewer means by going back up.
///
/// A row that cannot take the remote -- one with no cards, a season with no
/// episodes -- is passed over, and a press nothing can answer is **left
/// alone** rather than swallowed, so directional focus still gets its go.
/// Swallowing it is a dead D-pad, which is the one outcome worse than
/// landing somewhere unexpected.
///
/// **On a row where landing already chooses, select moves on**
/// ([TvLadderRow.advanceOnSelect]). A season pill switches the season when
/// the remote lands on it, an episode loads its streams, a source group
/// opens: by the time select is pressed there is nothing left for it to
/// do, and viewers pressed it and saw nothing happen. On those rows select
/// still does what the card does, and then what down does.
///
/// Levels are numbers rather than positions in a list because the rows
/// they name come and go: a film has no episode row, a title nobody has
/// played has no last-used source. Leave gaps ([TvLadderRow.level]), and a
/// row that is not on screen is simply not registered.
///
/// **A ladder can collapse** ([TvLadderRung]). A screen whose every rung is
/// drawn out is a wall: the details screen had the seasons, the episodes,
/// two rows of chips, the last-used source, the groups and their sources
/// all on the panel at once, and a 720p television has room for about half
/// of that. So each rung can be a header line instead -- what it is called
/// and what it holds -- with one of them open at a time. What is open is
/// the screen's to decide, not this widget's: which rung a title is *for*
/// is a question about the title.
class TvLadder extends StatefulWidget {
  const TvLadder({super.key, required this.child});

  final Widget child;

  static TvLadderController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_TvLadderScope>()?.controller;

  @override
  State<TvLadder> createState() => _TvLadderState();
}

class _TvLadderState extends State<TvLadder> {
  final TvLadderController _controller = TvLadderController();

  @override
  Widget build(BuildContext context) =>
      _TvLadderScope(controller: _controller, child: widget.child);
}

class _TvLadderScope extends InheritedWidget {
  const _TvLadderScope({required this.controller, required super.child});

  final TvLadderController controller;

  @override
  bool updateShouldNotify(_TvLadderScope oldWidget) =>
      controller != oldWidget.controller;
}

/// The rows of one screen, in the order the viewer walks them.
class TvLadderController {
  final Map<int, TvLadderRowState> _rows = {};

  /// Where the remote was in each row, by level and not by row.
  ///
  /// A row that is on screen keeps this itself. A rung that collapses
  /// takes its rows out of the tree entirely ([TvLadderRung]), and a row
  /// that has been disposed of remembers nothing -- so walking into the
  /// sources and coming back to the episodes landed on the first episode
  /// of the season rather than on the one whose sources those were. The
  /// level is the row's identity across that, which is what it already is
  /// for the walk itself.
  final Map<int, int> _remembered = {};

  void _register(int level, TvLadderRowState row) => _rows[level] = row;

  /// Which of the row at [level]'s focus stops it will hand the remote
  /// back to: where the remote was when it left, or its first.
  ///
  /// For what has to be right about a row *before* the remote is in it --
  /// the strip under the sources, which says everything about the card the
  /// row would land on that the card itself has no room for. Reading it
  /// from here rather than keeping a second copy is the point: two answers
  /// to "which card is the row on" disagree the moment one of them is
  /// wrong, and the disagreement is a readout describing a card the viewer
  /// is not about to reach.
  ///
  /// An index into that row's focus stops rather than into whatever it
  /// draws, so a caller counts the same things the walk does -- a card no
  /// press can reach is not one of them -- and it is not clamped to
  /// anything here, because the row it names may not be built yet.
  int rememberedStop(int level) => _remembered[level] ?? 0;

  void _unregister(int level, TvLadderRowState row) {
    if (_rows[level] == row) _rows.remove(level);
  }

  /// Moves the remote out of [from] to the nearest row above or below that
  /// will take it, and says whether one did.
  ///
  /// Every row in that direction is tried in turn, so an empty one is
  /// stepped over rather than being a hole the walk falls into.
  bool move(int from, {required bool up}) {
    final levels = _rows.keys.toList()..sort();
    final candidates = up
        ? levels.where((level) => level < from).toList().reversed
        : levels.where((level) => level > from);
    for (final level in candidates) {
      if (_rows[level]?.focusRemembered(up: up) ?? false) return true;
    }
    return false;
  }
}

/// One row of a [TvLadder]: it remembers where the remote was and answers
/// up and down presses made inside it.
///
/// Off a television this is its child and nothing else.
class TvLadderRow extends StatefulWidget {
  const TvLadderRow({
    super.key,
    required this.level,
    this.advanceOnSelect = false,
    required this.child,
  });

  /// Where this row sits in the walk, low to high. The screens that use
  /// this leave gaps between them, so a row that only sometimes exists can
  /// be dropped in without renumbering the rest.
  final int level;

  /// Whether select, once the card has done what it does, also moves the
  /// remote down a row. For rows whose cards act on focus -- see [TvLadder].
  /// Not for a row whose select is the point: a button, a sort chip, a
  /// source that plays.
  final bool advanceOnSelect;

  final Widget child;

  @override
  State<TvLadderRow> createState() => TvLadderRowState();
}

class TvLadderRowState extends State<TvLadderRow> {
  final FocusNode _node = FocusNode(
    canRequestFocus: false,
    skipTraversal: true,
    debugLabel: 'ladder row',
  );

  TvLadderController? _ladder;

  /// The card the remote was last on, as an index into this row's focus
  /// stops. Kept by the ladder under this row's level, so it survives the
  /// row being taken off the screen and put back ([TvLadderController]).
  /// Zero until the remote has been here, which is what makes arriving at
  /// a row for the first time land on its first card.
  int get _remembered => _ladder?._remembered[widget.level] ?? _ownMemory;

  set _remembered(int index) {
    _ownMemory = index;
    _ladder?._remembered[widget.level] = index;
  }

  /// The same, for a row with no ladder above it to keep it.
  int _ownMemory = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ladder = TvLadder.maybeOf(context);
    if (ladder == _ladder) return;
    _ladder?._unregister(widget.level, this);
    _ladder = ladder?.._register(widget.level, this);
  }

  @override
  void didUpdateWidget(TvLadderRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.level == widget.level) return;
    _ladder?._unregister(oldWidget.level, this);
    _ladder?._register(widget.level, this);
  }

  @override
  void dispose() {
    _ladder?._unregister(widget.level, this);
    _node.dispose();
    super.dispose();
  }

  /// This row's focus stops, in the order the D-pad walks them.
  List<FocusNode> get _stops => _node.traversalDescendants.toList();

  /// Puts the remote back where it was in this row, or on its first card.
  /// False when the row has nothing to take it -- a season with no
  /// episodes, a group whose sources have not arrived -- so the press can
  /// be offered to the row beyond it.
  ///
  /// And brings it on screen, if it is not already. A card built on
  /// [FocusableTile] scrolls itself into view when it takes focus, but a
  /// plain control -- the layout and order chips -- does not, so a press
  /// down onto a row below the fold moved the remote somewhere the viewer
  /// could not see until the next press scrolled the page. Only as far as
  /// needed, from the side the remote came from, so a row already on
  /// screen does not move.
  bool focusRemembered({bool up = false}) {
    final stops = _stops;
    if (stops.isEmpty) return false;
    final stop = stops[_remembered.clamp(0, stops.length - 1)];
    stop.requestFocus();
    final target = stop.context;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignmentPolicy: up
            ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
            : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    }
    return true;
  }

  void _onFocusChange(bool hasFocus) {
    if (!hasFocus) return;
    final focused = FocusManager.instance.primaryFocus;
    final index = focused == null ? -1 : _stops.indexOf(focused);
    if (index >= 0) _remembered = index;
  }

  /// Moves the remote down a row once the frame the card's own action
  /// schedules has been built: an episode chosen by select may put the rows
  /// below on screen, and a move made before them would step past them.
  void _advance() {
    _onFocusChange(true);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ladder?.move(widget.level, up: false);
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// A card built on [RemotePress] takes select for itself, so the press
  /// never reaches [_onKey]; it says it was pressed instead.
  bool _onActivated(RemotePressed notification) {
    _advance();
    return true;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    // A card that is a plain Flutter control activates through the app's
    // shortcuts, above this row, so the press passes through here first:
    // left alone for the control to act on, and the move follows it.
    if (widget.advanceOnSelect &&
        event is KeyDownEvent &&
        RemotePress.activateKeys.contains(key)) {
      _advance();
      return KeyEventResult.ignored;
    }
    final up = key == LogicalKeyboardKey.arrowUp;
    if (!up && key != LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.ignored;
    }
    // Remember where the press was made from before leaving: the focus
    // change on the way out arrives after this.
    _onFocusChange(true);
    final moved = _ladder?.move(widget.level, up: up) ?? false;
    return moved ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (!DeviceScope.isTv(context)) return widget.child;
    return Focus(
      focusNode: _node,
      onFocusChange: _onFocusChange,
      onKeyEvent: _onKey,
      includeSemantics: false,
      child: widget.advanceOnSelect
          ? NotificationListener<RemotePressed>(
              onNotification: _onActivated,
              child: widget.child,
            )
          : widget.child,
    );
  }
}

/// One rung of a collapsing [TvLadder]: a header line that is always on the
/// panel, and what the rung holds, drawn only while it is open.
///
/// The header is the walk's stop for this rung, so a rung that holds
/// nothing the remote can reach -- the sources while every addon is still
/// answering -- is still a line a press down lands on and a press down
/// leaves, rather than a hole. A rung with nothing to *say* at all is not
/// drawn by its screen, and the walk steps over it the way it steps over
/// any row that is not registered.
///
/// **Select opens, and Back closes.** Landing on a header does not open it:
/// a walk down the ladder would otherwise open every rung it passed and
/// leave Back with a stack of them to put away. So this is one of the rows
/// [TvLadderRow.advanceOnSelect] is explicitly not for -- select here is
/// the point rather than a leftover -- and the press that opens a rung
/// leaves the remote on the header, one press above what it opened.
///
/// Which rung is open is the screen's: [open] is read, never kept here, so
/// opening one is the same act as closing the one that was open.
class TvLadderRung extends StatelessWidget {
  const TvLadderRung({
    super.key,
    required this.level,
    required this.label,
    required this.open,
    required this.onOpen,
    this.summary = '',
    this.trailing,
    this.children = const [],
  });

  /// Where the header sits in the walk. The rows of [children] carry their
  /// own levels, between this one and the next rung's.
  final int level;

  /// What the rung is called, on the left of the line.
  final String label;

  /// What it holds, on the right: "58 from 4 addons", "Season 1 · 13". The
  /// whole of what a viewer who never opens this rung is told, so it
  /// carries counts rather than an invitation.
  final String summary;

  /// Drawn between the label and the summary -- the spinner, while the
  /// rung is still filling up.
  final Widget? trailing;

  final bool open;

  /// Open this rung, which closes whichever one was open.
  final VoidCallback onOpen;

  /// The rows inside it, each a [TvLadderRow] of its own.
  final List<Widget> children;

  /// The box one header line is drawn in at text scale 1.
  static const double headerHeight = 44;

  /// Between one rung and the next.
  static const double gap = 8;

  /// The margin either side of a header, so a header lines up with the
  /// rows inside it rather than with the edge of the panel.
  static const double sidePadding = 16;

  static const BorderRadius _radius = BorderRadius.all(Radius.circular(8));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(sidePadding, gap, sidePadding, 0),
          child: TvLadderRow(
            level: level,
            child: FocusableTile(
              onTap: onOpen,
              borderRadius: _radius,
              // A line the width of the panel: the ring and the dimming,
              // and neither the zoom nor the shadow, which on something
              // this wide would lift it over the rungs either side of it.
              treatment: FocusTreatment.row,
              child: Container(
                height: headerHeight,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: _radius,
                ),
                child: Row(
                  spacing: 8,
                  children: [
                    // Open and shut, said by the chevron as well as by
                    // whether anything is drawn underneath: a rung whose
                    // contents run off the bottom of the panel looks shut
                    // from where the viewer is sitting.
                    Icon(
                      open ? Icons.expand_more : Icons.chevron_right,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    ?trailing,
                    const Spacer(),
                    if (summary.isNotEmpty)
                      Flexible(
                        child: Text(
                          summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (open) ...children,
      ],
    );
  }
}
