/// Helpers for the tests that drive a screen with a remote.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// Whether this app tells the viewer where the remote is standing.
///
/// There are exactly two ways it does, and a screen is right when every
/// stop the D-pad can reach has one of them: a [FocusHighlight] drawn
/// round it -- what a poster, a chip, a rail destination and the panels
/// over the video wear -- or the theme floor, which marks every Material
/// control without being asked and is in force wherever [FocusTheme.apply]
/// built the theme.
///
/// **What this catches**, which is what the audit found: a screen with a
/// focus stop outside both, such as a hand-rolled [Focus] with a border of
/// its own invention (there were three of those), a control under a
/// `Theme` of its own, or a route pushed somewhere the floor does not
/// reach. And a screen the remote lands nowhere on at all, which reads
/// here as unmarked because nothing has focus to mark.
///
/// **What it cannot catch** is a Material control whose component theme
/// the floor has never been told about. That is what `FocusTheme`'s own
/// tests are for, and why the list of components there is written out one
/// by one rather than derived from anything.
bool focusIsMarked() {
  final context = _focusedContext();
  if (context == null) return false;
  if (context.findAncestorWidgetOfExactType<FocusHighlight>() != null) {
    return true;
  }
  return FocusTheme.emphasisIn(context) != null;
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
