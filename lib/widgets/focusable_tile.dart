import 'package:flutter/material.dart';

import '../shell/device_profile.dart';

/// The tappable surface under every poster-like tile ([PosterTile],
/// [LibraryItemTile], the Board's "See all").
///
/// Off a television it is the plain [InkWell] those tiles always had. On a
/// TV ([DeviceScope.isTv]) the D-pad moves focus from tile to tile, so the
/// tile has to show that it holds focus and has to be on screen when it
/// does: a [FocusRing] is drawn over the child while focused, and gaining
/// focus scrolls every enclosing scrollable (the row, then the rows) so the
/// tile sits in the middle of the viewport, which keeps the next tile in
/// each direction built and reachable.
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
    return InkWell(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onSecondaryTap: widget.onSecondaryTap,
      focusNode: widget.focusNode,
      autofocus: _autofocus,
      onFocusChange: _onFocusChange,
      borderRadius: widget.borderRadius,
      child: FocusRing(
        focused: _focused,
        borderRadius: widget.borderRadius,
        child: widget.child,
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

/// The border a [FocusableTile] draws over its child while it has focus:
/// nothing when [focused] is false, so the tile keeps its size either way.
class FocusRing extends StatelessWidget {
  const FocusRing({
    super.key,
    required this.focused,
    required this.borderRadius,
    required this.child,
  });

  final bool focused;
  final BorderRadius borderRadius;
  final Widget child;

  static const double width = 3;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    position: DecorationPosition.foreground,
    decoration: BoxDecoration(
      borderRadius: borderRadius,
      border: focused
          ? Border.all(
              color: Theme.of(context).colorScheme.primary,
              width: width,
            )
          : null,
    ),
    child: child,
  );
}
