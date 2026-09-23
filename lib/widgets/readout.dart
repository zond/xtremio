import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/services.dart';

import '../shell/device_profile.dart';
import 'focusable_tile.dart';

/// A block the viewer reads rather than presses, made a stop the remote
/// can land on.
///
/// **On a television the only way to scroll is to move focus.** The scroll
/// view follows the focused widget, so a row that takes no focus is a row
/// the remote jumps over and the page never scrolls to: the viewer walks
/// from the control above it to the control below it and the words in
/// between go past. Where such a block is the last thing on the screen, or
/// is taller than the space left under the control above it, some of it
/// can never be read at all -- which is how this was found, on a
/// Chromecast, on the longest read-only block in the app: the result of
/// "Test this model" in Settings, a readout of judgement, agreement,
/// invented films and speed that is exactly what somebody sits down to
/// read.
///
/// So a block of words becomes a stop. Not a control: select does nothing
/// here, and there is nothing for it to do.
///
/// **Focused, it is marked; it is never dressed as something pressable.**
/// That is what [FocusTreatment.readout] already means in this app -- the
/// player's seek bar and the sharing light wear it -- and it is the ring
/// alone: no zoom and no shadow, because nothing here is an object lifted
/// off a row, and no dimming, because the dimming is read off a family of
/// neighbours going dark together and a paragraph has no such family. No
/// ink either, which is the other half of the promise: the theme floor
/// fills a control the remote is standing on, and a paragraph that filled
/// like a button and then swallowed select would be a worse lie than one
/// that could not be reached.
///
/// **A focused readout is brought fully into view, not merely touched.**
/// That is [ReadableBlock]'s, which is where the two halves of it are
/// written down: bringing the whole block on screen, and walking one that
/// is taller than the screen a part-screenful at a time.
///
/// **A phone is left alone.** Focus there is for a keyboard and for
/// accessibility, where the words are already reachable by touch and by
/// screen reader; an extra Tab stop in front of every note on the settings
/// screen is a cost with nothing bought. Off a television this widget is
/// its child and nothing else, like [FocusMarked] and [FocusHighlighted]
/// above it.
class Readout extends StatefulWidget {
  const Readout({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
  });

  final Widget child;

  /// Held between the ring and what is inside it, on a television only.
  ///
  /// A block that brings its own padding -- a [ListTile], a section that
  /// is already inset from the edges of the screen -- wants none of this
  /// and leaves it at zero. A bare line of text wants
  /// [FocusRing.textInset]: the ring is drawn on the block's own bounds,
  /// and in Bold that is eight logical pixels of it over the first letter
  /// of every line.
  final EdgeInsetsGeometry padding;

  /// Rounds the ring. The same eight [FocusMarked] gives a row, since a
  /// readout sits among rows.
  final BorderRadius borderRadius;

  @override
  State<Readout> createState() => _ReadoutState();
}

/// Where a block sits in the scroll view around it: the offsets at which
/// its top would be at the top of the viewport and its bottom at the
/// bottom of it.
///
/// For a block that fits, [bottom] is the smaller of the two and the pair
/// is the range of offsets that show the whole of it. For one that does
/// not, they are the other way round and the pair is the range over which
/// any of it is on screen, which is what walking it means.
typedef _Where = ({ScrollPosition position, double top, double bottom});

/// The scrolling a block of words needs before a viewer can read it with a
/// remote, for the [State] of a widget that makes one a focus stop.
///
/// Two halves. [revealBlock] brings the whole of the block on screen,
/// moving as little as it can: Flutter's traversal reveals a stop with one
/// edge against one edge of the viewport, which is enough for a row and is
/// not a promise about the other edge, so the last lines of a tall block
/// stay off the screen and the press that would scroll to them moves focus
/// past it instead. [walkBlock] answers the D-pad for a block taller than
/// the viewport, which cannot be shown at once and whose middle is
/// otherwise off the screen for good.
///
/// *When* to reveal is the caller's: a readout does it on taking focus, and
/// the details header's description does it when the viewer folds the plot
/// back up and the page is left scrolled through words that are gone.
///
/// Two widgets mix this in, and they disagree about everything else: a
/// [Readout] is words the remote can stand on and select does nothing to,
/// and the details header's description is a control that expands under
/// select. Where the words are on the screen is the same question for
/// both, and answering it twice is how the second copy goes wrong.
mixin ReadableBlock<T extends StatefulWidget> on State<T> {
  /// How long a scroll this asks for takes. The same as a tile's, so a
  /// walk down a screen that mixes the two moves at one speed.
  static const Duration scrollDuration = Duration(milliseconds: 200);

  /// How much of the viewport one press moves a block that is taller than
  /// the viewport. Not a whole one: the lines at the fold would be scrolled
  /// past before they were read.
  static const double screenful = 0.8;

  /// A scroll shorter than this is not worth asking for, and -- far more
  /// importantly -- is not worth taking a press for. Sub-pixel rounding
  /// out of [RenderAbstractViewport.getOffsetToReveal] would otherwise
  /// leave a block swallowing every press of the down key with nothing
  /// moving, which is a remote trapped on a paragraph.
  static const double slack = 0.5;

  /// [revealBlock] once the frame that is being built has been laid out.
  ///
  /// A block takes focus while the list around it is still laying itself
  /// out, and grows and shrinks when the viewer expands it; an offset read
  /// before that frame is an offset into the wrong tree.
  void revealBlockAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) revealBlock();
    });
  }

  _Where? _where() {
    if (!mounted) return null;
    final position = Scrollable.maybeOf(context)?.position;
    final box = context.findRenderObject();
    if (position == null || box is! RenderBox || !box.hasSize) return null;
    if (!position.hasPixels || !position.hasViewportDimension) return null;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return null;
    return (
      position: position,
      top: viewport.getOffsetToReveal(box, 0).offset,
      bottom: viewport.getOffsetToReveal(box, 1).offset,
    );
  }

  /// Brings the whole block on screen, moving as little as possible.
  ///
  /// A block that fits is pulled into the range of offsets that show all
  /// of it -- from whichever end it was hanging over, and not at all when
  /// it was already inside. That is the whole of the bug for most of these:
  /// Flutter's traversal reveals a stop with one edge against one edge of
  /// the viewport, which is enough for a row and is not a promise about
  /// the other edge.
  ///
  /// A block that is taller than the viewport cannot be shown at once, and
  /// what it must not do is land on its *last* line -- which is exactly
  /// what the traversal does with it on the way down the page, and what a
  /// Tab does with it in either direction. So it starts at its first line,
  /// whichever way the remote came, and [walkBlock] walks the rest:
  /// reading starts at the top of a paragraph and there is only one way to
  /// be predictable about this.
  void revealBlock() {
    final at = _where();
    if (at == null) return;
    final position = at.position;
    // Taller than the viewport is the inverted case: `top` -- the offset
    // that puts the block's first line at the top of the screen -- is then
    // the *earlier* offset of the two, because showing the last line means
    // scrolling past everything above it.
    final tall = at.bottom > at.top;
    final target = _clamp(
      tall ? at.top : _clamp(position.pixels, at.bottom, at.top),
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _scrollTo(position, target);
  }

  /// Walks a block that is taller than the viewport, a part-screenful at a
  /// time, and hands the press on the moment there is nothing of it left
  /// in that direction.
  ///
  /// This is the half that makes the tall case readable at all: revealing
  /// such a block can only ever show one end of it, and the press that
  /// would show the rest is the press that moves focus to whatever is
  /// below -- so without this the middle of a long block is off the screen
  /// for good. A block that fits takes none of this: after [revealBlock]
  /// there is nothing of it past either edge, so the test below answers
  /// false and the key goes where it always went.
  KeyEventResult walkBlock(KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final forward = event.logicalKey == LogicalKeyboardKey.arrowDown;
    final back = event.logicalKey == LogicalKeyboardKey.arrowUp;
    if (!forward && !back) return KeyEventResult.ignored;
    final at = _where();
    if (at == null) return KeyEventResult.ignored;
    final position = at.position;
    // The offset at which the edge the press is heading for would be
    // against its side of the viewport. Past the current offset in the
    // direction of travel, there is still some of this block over there.
    final edge = forward ? at.bottom : at.top;
    final left = edge - position.pixels;
    if (forward ? left <= slack : left >= -slack) {
      return KeyEventResult.ignored;
    }
    final step = position.viewportDimension * screenful;
    final target = _clamp(
      forward
          ? math.min(edge, position.pixels + step)
          : math.max(edge, position.pixels - step),
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    // Nothing to give: the list is against its end, and a press taken for
    // a scroll that cannot happen is the remote stuck here.
    if ((target - position.pixels).abs() < slack) {
      return KeyEventResult.ignored;
    }
    _scrollTo(position, target);
    return KeyEventResult.handled;
  }

  void _scrollTo(ScrollPosition position, double target) {
    if ((target - position.pixels).abs() < slack) return;
    position.animateTo(target, duration: scrollDuration, curve: Curves.easeOut);
  }

  static double _clamp(double value, double low, double high) =>
      math.min(math.max(value, low), high);
}

class _ReadoutState extends State<Readout> with ReadableBlock<Readout> {
  bool _focused = false;

  void _onFocusChange(bool focused) {
    if (!mounted || focused == _focused) return;
    setState(() => _focused = focused);
    // The ring changes the block's painting and not its size, but a
    // readout can take focus while the list around it is still laying
    // itself out -- so the offsets are read after the frame, never in it.
    if (focused) revealBlockAfterFrame();
  }

  @override
  Widget build(BuildContext context) {
    if (!DeviceScope.isTv(context)) return widget.child;
    return Focus(
      onFocusChange: _onFocusChange,
      onKeyEvent: (node, event) => walkBlock(event),
      child: FocusHighlight(
        focused: _focused,
        borderRadius: widget.borderRadius,
        treatment: FocusTreatment.readout,
        child: Padding(padding: widget.padding, child: widget.child),
      ),
    );
  }
}
