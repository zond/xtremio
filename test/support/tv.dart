/// Helpers for the tests that drive a screen with a remote.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/focus_emphasis.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/focus_theme.dart';
import 'package:xtremio/widgets/focusable_tile.dart';

/// A television: remote only, no touchscreen.
const DeviceProfile tv = DeviceProfile(isTv: true, hasTouch: false);

/// A 720p television, the smallest a TV layout has to fit.
const Size tvSize = Size(1280, 720);

void useScreen(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Presses and releases [key], then lets focus and scrolling settle.
Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

/// The system Back button, as Android delivers it: the `popRoute`
/// notification on the navigation channel, which is what `PopScope` answers.
///
/// Not a key event. A remote's Back reaches Flutter as a key first, and the
/// platform turns it into this only when nothing took the key -- so a test
/// that sent [LogicalKeyboardKey.goBack] would be testing the half of the
/// mechanism that is meant to ignore it.
Future<void> systemBack(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
    (_) {},
  );
  await tester.pumpAndSettle();
}

/// Holds [key] down for [duration] before releasing it.
Future<void> hold(
  WidgetTester tester,
  LogicalKeyboardKey key,
  Duration duration,
) async {
  await tester.sendKeyDownEvent(key);
  await tester.pump(duration);
  await tester.sendKeyUpEvent(key);
  await tester.pumpAndSettle();
}

/// The focused node's context, null when focus sits on a bare scope (a
/// route with nothing focused in it) rather than on a widget.
BuildContext? _focusedContext() {
  final node = FocusManager.instance.primaryFocus;
  if (node == null || node is FocusScopeNode) return null;
  return node.context;
}

/// The widget with primary focus sits under a [T].
bool focusIn<T extends Widget>() =>
    _focusedContext()?.findAncestorWidgetOfExactType<T>() != null;

/// What this app draws to say the remote is standing here.
///
/// There are exactly two mechanisms and three things they draw, and every
/// stop the D-pad can reach wears at least one of them.
enum FocusMark {
  /// The app's own [FocusHighlight] round this control, *lit*: the
  /// two-stroke ring, and whatever else its [FocusTreatment] wears.
  ring,

  /// The floor's stroke: the near-white [BorderSide] [FocusTheme] puts on
  /// a focused button's shape.
  stroke,

  /// The floor's fill: the ink a Material control paints while focused,
  /// in [FocusTheme]'s near-white and at least as heavy as
  /// [FocusTheme.lift] -- the whole indicator on a [ListTile], a
  /// [PopupMenuItem] or a chip, none of which can be given a side.
  fill,
}

/// What is drawn on the control the remote is standing on.
///
/// Which is a different question from what is *available* to it, and the
/// difference is the whole point: a [FocusHighlight] is in the tree either
/// side of a focus change and a theme covers a screen whether or not
/// anything on it is focused, so neither being there says anything. What
/// counts is a ring that is lit, a stroke this control's own style
/// resolves to the floor's near-white while focused, and a fill it
/// resolves to the same. All three are read off the control that holds
/// focus, and all three are what a viewer would see on it.
///
/// **What it cannot catch.** A [FocusMarked] wrapped round more than the
/// one focus stop it is documented to wrap lights for anything inside it
/// and reads here as a ring on each. And whether the ink is painted where
/// the control is drawn is beyond a widget test: that a [ListTile] paints
/// [ThemeData.focusColor] at all is `FocusTheme`'s own tests' business,
/// which is why the components there are written out one by one rather
/// than derived from anything.
Set<FocusMark> focusMarks() {
  final context = _focusedContext();
  if (context == null) return const <FocusMark>{};
  return {if (_ringLit(context)) FocusMark.ring, ..._floorMarks(context)};
}

/// The remote is standing on something this app marks.
bool focusIsMarked() => focusMarks().isNotEmpty;

/// The nearest [FocusHighlight] on either side of the focused node, lit.
///
/// Either side, because the two families put it in different places: a
/// [FocusableTile] builds the ring *inside* its [InkWell], so the node's
/// context is above it, while [FocusMarked] and [FocusHighlighted] watch
/// from *above* the control, so the node's context is below it. Looking
/// only one way is looking at the wrong widget in half the app.
bool _ringLit(BuildContext context) =>
    _ringAbove(context) || _ringBelow(context as Element);

bool _ringAbove(BuildContext context) {
  var lit = false;
  context.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is! FocusHighlight) return true;
    lit = widget.focused;
    return false;
  });
  return lit;
}

bool _ringBelow(Element element) {
  bool? lit;
  void visit(Element child) {
    if (lit != null) return;
    final widget = child.widget;
    if (widget is FocusHighlight) {
      lit = widget.focused;
      return;
    }
    child.visitChildren(visit);
  }

  element.visitChildren(visit);
  return lit ?? false;
}

/// What the theme floor is drawing on the focused control.
///
/// The nearest control *around* the node decides, because that is the one
/// whose ink and shape are painted: every button, row, tile and chip
/// builds an [InkResponse] and focuses with a node inside it, so its
/// resolved overlay is the fill and the border it hands its ink is the
/// stroke -- both already resolved for the state the control is really in.
/// The toggleables paint no ink and are read off the component theme
/// instead.
Set<FocusMark> _floorMarks(BuildContext context) {
  Element? owner;
  context.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is InkResponse ||
        widget is Switch ||
        widget is Checkbox ||
        widget is Radio) {
      owner = element;
      return false;
    }
    return true;
  });
  final control = owner;
  if (control == null) return const <FocusMark>{};
  final theme = Theme.of(control);
  final emphasis = FocusTheme.emphasisIn(control) ?? FocusEmphasis.standard;
  const focused = <WidgetState>{WidgetState.focused};
  final widget = control.widget;
  final fill = switch (widget) {
    final InkResponse ink =>
      ink.overlayColor?.resolve(focused) ?? ink.focusColor ?? theme.focusColor,
    Switch() => theme.switchTheme.overlayColor?.resolve(focused),
    Checkbox() => theme.checkboxTheme.overlayColor?.resolve(focused),
    Radio() => theme.radioTheme.overlayColor?.resolve(focused),
    _ => null,
  };
  final side = widget is InkResponse
      ? switch (widget.customBorder) {
          final OutlinedBorder border => border.side,
          _ => null,
        }
      : null;
  return {
    if (side != null && side.style != BorderStyle.none && _isFloor(side.color))
      FocusMark.stroke,
    if (fill != null && _isFloor(fill) && fill.a >= FocusTheme.lift(emphasis))
      FocusMark.fill,
  };
}

/// [color] is the near-white the floor draws in, whatever it is drawn at:
/// anything else is Flutter's own tenth, a colour a widget invented for
/// itself, or the transparent one a surface that draws its own ring passes
/// to say "not this one as well".
bool _isFloor(Color color) {
  const floor = FocusTheme.stroke;
  return color.r == floor.r && color.g == floor.g && color.b == floor.b;
}

/// The first text on the widget holding primary focus (a button's label, a
/// tile's title), null when nothing with text has it.
String? focusedLabel(WidgetTester tester) {
  final context = _focusedContext();
  if (context == null) return null;
  final texts = find.descendant(
    of: find.byWidget(context.widget),
    matching: find.byType(Text),
  );
  if (texts.evaluate().isEmpty) return null;
  return tester.widget<Text>(texts.first).data;
}

/// The name on the [FocusableTile] holding primary focus, null when focus
/// is elsewhere.
String? focusedTileName(WidgetTester tester) {
  final tile = _focusedContext()
      ?.findAncestorWidgetOfExactType<FocusableTile>();
  if (tile == null) return null;
  final texts = find.descendant(
    of: find.byWidget(tile),
    matching: find.byType(Text),
  );
  return tester.widget<Text>(texts.first).data;
}

/// The message of the [Tooltip] around the widget holding primary focus (an
/// icon button's label), null when it has none.
String? focusedTooltip() =>
    _focusedContext()?.findAncestorWidgetOfExactType<Tooltip>()?.message;
