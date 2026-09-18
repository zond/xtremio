import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../shell/device_profile.dart';
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

  void _register(int level, TvLadderRowState row) => _rows[level] = row;

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
      if (_rows[level]?.focusRemembered() ?? false) return true;
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
  /// stops. Zero until it has been here, which is what makes arriving at a
  /// row for the first time land on its first card.
  int _remembered = 0;

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
  bool focusRemembered() {
    final stops = _stops;
    if (stops.isEmpty) return false;
    stops[_remembered.clamp(0, stops.length - 1)].requestFocus();
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
