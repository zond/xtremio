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
class FocusableTile extends StatefulWidget {
  const FocusableTile({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.focusNode,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;

  /// The node the tile focuses with; one is created when null.
  final FocusNode? focusNode;

  /// Clips the ink and rounds the ring; every tile uses 8 px.
  final BorderRadius borderRadius;

  /// How long the scroll that brings a newly focused tile into view takes.
  static const Duration scrollDuration = Duration(milliseconds: 200);

  @override
  State<FocusableTile> createState() => _FocusableTileState();
}

class _FocusableTileState extends State<FocusableTile> {
  bool _focused = false;

  void _onFocusChange(bool focused) {
    if (!mounted) return;
    setState(() => _focused = focused);
    if (!focused) return;
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
