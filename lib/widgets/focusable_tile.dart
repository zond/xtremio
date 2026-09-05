import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/focus_emphasis.dart';
import '../core/prefs_client.dart';
import '../shell/device_profile.dart';
import 'remote_press.dart';

/// The tappable surface under every poster-like tile ([PosterTile],
/// [LibraryItemTile], the Board's "See all").
///
/// Off a television it is the plain [InkWell] those tiles always had. On a
/// TV ([DeviceScope.isTv]) the D-pad moves focus from tile to tile, so the
/// tile has to show that it holds focus and has to be on screen when it
/// does: a [FocusHighlight] marks the child while focused, and gaining
/// focus scrolls every enclosing scrollable (the row, then the rows) so the
/// tile sits in the middle of the viewport, which keeps the next tile in
/// each direction built and reachable. The remote's keys go through a
/// [RemotePress]: select taps on release, a held select or the menu key is
/// the tile's long press (or, failing that, its secondary tap: the two mean
/// "more options" on a phone and a desktop).
///
/// A TV also needs somewhere for focus to start. Under a [FocusMemory] the
/// tile remembers itself (by [memoryId]) as the last focused tile of that
/// memory whenever it gains focus, and autofocuses when it is built as
/// that remembered tile; with nothing remembered yet, the tile built with
/// [defaultFocus] (a screen's first tile) autofocuses instead. The shell
/// keeps one memory per tab, so a tab rebuilt after a switch puts focus
/// back where it was. Without a memory above it, [defaultFocus] alone
/// decides.
class FocusableTile extends StatefulWidget {
  const FocusableTile({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.focusNode,
    this.memoryId,
    this.defaultFocus = false,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;

  /// The node the tile focuses with; one is created when null.
  final FocusNode? focusNode;

  /// What the enclosing [FocusMemory] remembers this tile as; unique within
  /// that memory and stable across rebuilds. Null: never remembered.
  final String? memoryId;

  /// Autofocus on a TV when nothing is remembered (or there is no memory).
  final bool defaultFocus;

  /// Clips the ink and rounds the ring; every tile uses 8 px.
  final BorderRadius borderRadius;

  /// How long the scroll that brings a newly focused tile into view takes.
  static const Duration scrollDuration = Duration(milliseconds: 200);

  @override
  State<FocusableTile> createState() => _FocusableTileState();
}

class _FocusableTileState extends State<FocusableTile> {
  bool _focused = false;

  /// Decided once, when the tile is first built, and never again: a tile
  /// autofocuses on appearing as the remembered (or default) tile, not on
  /// later becoming it. A list that rebuilds an existing tile with another
  /// item's id (an unkeyed strip whose rows shift when one is inserted
  /// above them) must not pull focus off wherever the user has it; and
  /// [Focus] re-applies autofocus whenever the flag turns true, so it has
  /// to stay whatever it was.
  late final bool _autofocus = _decideAutofocus(FocusMemory.maybeOf(context));

  bool _decideAutofocus(FocusMemoryStore? memory) {
    if (memory == null) return widget.defaultFocus;
    final remembered = memory.lastFocused;
    if (remembered == null) return widget.defaultFocus;
    return widget.memoryId != null && remembered == widget.memoryId;
  }

  void _onFocusChange(bool focused) {
    if (!mounted) return;
    setState(() => _focused = focused);
    if (!focused) return;
    final id = widget.memoryId;
    if (id != null) FocusMemory.maybeOf(context)?.lastFocused = id;
    Scrollable.ensureVisible(
      context,
      alignment: 0.5,
      duration: FocusableTile.scrollDuration,
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!DeviceScope.isTv(context)) {
      return InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onSecondaryTap: widget.onSecondaryTap,
        focusNode: widget.focusNode,
        borderRadius: widget.borderRadius,
        child: widget.child,
      );
    }
    return RemotePress(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress ?? widget.onSecondaryTap,
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onSecondaryTap: widget.onSecondaryTap,
        focusNode: widget.focusNode,
        autofocus: _autofocus,
        onFocusChange: _onFocusChange,
        borderRadius: widget.borderRadius,
        child: FocusHighlight(
          focused: _focused,
          borderRadius: widget.borderRadius,
          // Nothing drawn inside a tile is a focus stop. The tile takes
          // focus as a whole and the [RemotePress] above takes select, so
          // a control in here is one the remote can land on and cannot
          // press -- and the ring, which follows the tile's whole subtree,
          // says the tile is focused while the D-pad is really sitting on
          // a dead button somewhere in it. That was the installed addon
          // list: down walked its ⋮ menus, one per row, and the walk
          // could not reach anything below a menu that was not another
          // menu. Something that must be pressed goes beside the tile.
          child: ExcludeFocus(
            child: TileFocus(focused: _focused, child: widget.child),
          ),
        ),
      ),
    );
  }
}

/// Which [FocusableTile] (by [FocusableTile.memoryId]) was focused last
/// under one [FocusMemory]. Mutable on purpose: the tiles write it as focus
/// moves and read it when built, and nothing has to rebuild for that.
class FocusMemoryStore {
  String? lastFocused;
}

/// Hands a [FocusMemoryStore] to the [FocusableTile]s below it; the shell
/// puts one around each tab's body.
class FocusMemory extends InheritedWidget {
  const FocusMemory({super.key, required this.store, required super.child});

  final FocusMemoryStore store;

  static FocusMemoryStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FocusMemory>()?.store;

  @override
  bool updateShouldNotify(FocusMemory oldWidget) => store != oldWidget.store;
}

/// Whether the [FocusableTile] around this context holds focus, for the
/// parts of a tile that want to say so themselves -- a caption that is
/// muted until the remote is on it.
///
/// Null where there is no tile above (off a television, where nothing
/// draws a focus indicator at all), which is not the same as false: a
/// phone's caption is not "the unfocused one", it is the only one.
class TileFocus extends InheritedWidget {
  const TileFocus({super.key, required this.focused, required super.child});

  final bool focused;

  static bool? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TileFocus>()?.focused;

  @override
  bool updateShouldNotify(TileFocus oldWidget) => focused != oldWidget.focused;
}

/// The whole focus indicator on a television: the two-stroke [FocusRing],
/// a slight zoom and a shadow under what is focused, and -- in
/// [FocusEmphasis.bold] -- everything that is *not* focused dimmed.
///
/// One colour cannot carry this on its own. The indicator is drawn over
/// poster art, on a display the app knows nothing about; the owner's is a
/// projector in a room that is not always dark, where a mid-luminance line
/// over a busy poster is the first thing to disappear. So there are three
/// separate cues, and each survives what the others do not: two strokes of
/// opposite luminance mean any background contrasts with one of them, the
/// zoom is a size difference that no amount of ambient light can wash out,
/// and the shadow lifts the tile off the row the way the Google TV home
/// screen does.
class FocusHighlight extends StatelessWidget {
  const FocusHighlight({
    super.key,
    required this.focused,
    required this.borderRadius,
    required this.child,
  });

  final bool focused;
  final BorderRadius borderRadius;
  final Widget child;

  /// How much bigger the focused thing is drawn. Enough to be read as a
  /// size difference from three metres away, small enough that a row of
  /// posters does not jump about as focus walks it.
  static const double focusedScale = 1.05;

  /// How long the zoom (and the dimming) takes. Short: the remote is
  /// already on the next tile.
  static const Duration duration = Duration(milliseconds: 120);

  /// What everything that is not focused is drawn at, in
  /// [FocusEmphasis.bold] only. Dimming the surroundings is the strongest
  /// cue there is when the display itself cannot deliver contrast, and far
  /// too heavy for a dark room -- hence a choice rather than the default.
  static const double dimmedOpacity = 0.45;

  /// The shadow under the focused tile.
  static const List<BoxShadow> shadow = [
    BoxShadow(color: Color(0x99000000), blurRadius: 16, offset: Offset(0, 4)),
  ];

  /// The emphasis in force below [context]: the viewer's choice, or
  /// [FocusEmphasis.standard] where there is no [PrefsScope] (a widget
  /// test) or the preferences have not loaded yet.
  static FocusEmphasis emphasisOf(BuildContext context) =>
      PrefsScope.maybeOf(context)?.focusEmphasis ?? FocusEmphasis.standard;

  @override
  Widget build(BuildContext context) {
    final emphasis = emphasisOf(context);
    Widget content = FocusRing(
      focused: focused,
      borderRadius: borderRadius,
      emphasis: emphasis,
      child: child,
    );
    if (emphasis == FocusEmphasis.bold) {
      content = AnimatedOpacity(
        opacity: focused ? 1 : dimmedOpacity,
        duration: duration,
        child: content,
      );
    }
    return AnimatedScale(
      scale: focused ? focusedScale : 1,
      duration: duration,
      curve: Curves.easeOut,
      // Behind the child, so the blur falls outside the tile: an
      // elevation, not a veil over the poster.
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: focused ? shadow : null,
        ),
        child: content,
      ),
    );
  }
}

/// A control that takes focus itself -- a [ChoiceChip], say -- wearing the
/// same indicator a [FocusableTile] does, rather than growing a ring of its
/// own. [builder] is handed the [FocusNode] to give the control, and the
/// highlight follows it.
///
/// The node is the control's own, so nothing is added to the focus tree and
/// traversal is exactly what it was. Off a television this is its child and
/// nothing else: focus there follows a pointer or Tab, and Material's own
/// highlight is enough.
class FocusHighlighted extends StatefulWidget {
  const FocusHighlighted({
    super.key,
    required this.borderRadius,
    required this.builder,
  });

  /// Rounds the ring; a stadium-shaped control wants a radius of at least
  /// half its height (the radii are scaled down to fit, never up).
  final BorderRadius borderRadius;

  final Widget Function(BuildContext context, FocusNode node) builder;

  @override
  State<FocusHighlighted> createState() => _FocusHighlightedState();
}

class _FocusHighlightedState extends State<FocusHighlighted> {
  late final FocusNode _node = FocusNode()..addListener(_onFocusChange);
  bool _focused = false;

  void _onFocusChange() {
    if (mounted && _node.hasFocus != _focused) {
      setState(() => _focused = _node.hasFocus);
    }
  }

  @override
  void dispose() {
    _node.removeListener(_onFocusChange);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.builder(context, _node);
    if (!DeviceScope.isTv(context)) return child;
    return FocusHighlight(
      focused: _focused,
      borderRadius: widget.borderRadius,
      child: child,
    );
  }
}

/// The ring drawn over a focused child: a dark outer stroke and a light
/// inner one, each half of the ring's width.
///
/// Two strokes rather than one because the background is unknown -- poster
/// art, on a washed-out projector image. Whatever is underneath, it
/// contrasts with one of them, which is what WCAG's focus-appearance
/// guidance asks of an indicator drawn over arbitrary content. Neither
/// stroke is the theme's violet: its luminance is the whole problem.
///
/// Nothing is painted when [focused] is false, and the tree is the same
/// shape either way, so a tile keeps its size and its child keeps its
/// state as focus comes and goes.
class FocusRing extends StatelessWidget {
  const FocusRing({
    super.key,
    required this.focused,
    required this.borderRadius,
    required this.child,
    this.emphasis = FocusEmphasis.standard,
  });

  final bool focused;
  final BorderRadius borderRadius;
  final FocusEmphasis emphasis;
  final Widget child;

  /// Both strokes together, in logical pixels. Four, not the three this
  /// started at: a television is watched from two or three metres, not
  /// from forty centimetres, and on a 320 dpi box each of these is two
  /// physical pixels.
  static const double width = 4;

  /// Both strokes together in [FocusEmphasis.bold].
  static const double boldWidth = 8;

  /// The outer stroke: near-black, so it reads against a bright poster and
  /// against a bright room's washed-out whites.
  static const Color outerColor = Color(0xE6000000);

  /// The inner stroke: near-white, so it reads against a dark poster.
  static const Color innerColor = Color(0xFFF2F2F2);

  static double widthFor(FocusEmphasis emphasis) =>
      emphasis == FocusEmphasis.bold ? boldWidth : width;

  /// [radius] pulled in by [by] on every corner, so the inner stroke sits
  /// concentric inside the outer one rather than cutting its corners.
  static BorderRadius insetRadius(BorderRadius radius, double by) =>
      BorderRadius.only(
        topLeft: _insetCorner(radius.topLeft, by),
        topRight: _insetCorner(radius.topRight, by),
        bottomLeft: _insetCorner(radius.bottomLeft, by),
        bottomRight: _insetCorner(radius.bottomRight, by),
      );

  static Radius _insetCorner(Radius radius, double by) =>
      Radius.elliptical(math.max(0, radius.x - by), math.max(0, radius.y - by));

  @override
  Widget build(BuildContext context) {
    final stroke = widthFor(emphasis) / 2;
    return Stack(
      // The ring is an overlay: the child is laid out against the
      // constraints the tile was given, exactly as if it were not here.
      fit: StackFit.passthrough,
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: borderRadius,
                border: focused
                    ? Border.all(color: outerColor, width: stroke)
                    : null,
              ),
              child: Padding(
                padding: EdgeInsets.all(stroke),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: insetRadius(borderRadius, stroke),
                    border: focused
                        ? Border.all(color: innerColor, width: stroke)
                        : null,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
