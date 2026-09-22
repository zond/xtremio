import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/focusable_tile.dart';
import 'package:xtremio/widgets/readout.dart';

import '../support/tv.dart';

/// A block of words the remote can stand on.
///
/// The bug this is about is a television one and has nothing to do with
/// how the words are drawn: on a television the page scrolls by moving
/// focus, so a row that takes no focus is a row the page never scrolls to
/// -- jumped over on the way past, and, when it is the last thing on the
/// screen or taller than what is left of it, partly unreadable for good.
///
/// So the three things a readout has to be are checked here on blocks of a
/// known height, rather than on whatever the settings screen's paragraphs
/// happen to measure this month: it is a stop, it is marked in a way that
/// does not claim to be pressable, and focusing it puts the whole of it in
/// front of the viewer -- by scrolling it in when it fits, and by walking
/// it a part-screenful at a time when it does not.
void main() {
  const phone = DeviceProfile(isTv: false, hasTouch: true);

  /// A control, so there is something either side of the block to walk
  /// from and to.
  Widget stop(String label) => TextButton(onPressed: () {}, child: Text(label));

  /// A readout [height] tall that says where its first and last lines are,
  /// which is the whole of what "brought into view" has to be asked about.
  Widget block(String label, double height) => Readout(
    child: SizedBox(
      height: height,
      child: Column(
        children: [
          Text('$label: first line'),
          const Spacer(),
          Text('$label: last line'),
        ],
      ),
    ),
  );

  Widget page(List<Widget> children, {DeviceProfile device = tv}) {
    final prefs = AppPrefs.inMemory()..setFocusEmphasis(FocusEmphasis.bold);
    addTearDown(prefs.dispose);
    return DeviceScope(
      profile: device,
      child: PrefsScope(
        prefs: prefs,
        child: MaterialApp(
          theme: XtremioApp.themeFor(
            isTv: device.isTv,
            emphasis: FocusEmphasis.bold,
          ),
          home: Scaffold(body: ListView(children: children)),
        ),
      ),
    );
  }

  /// The whole of what [finder] draws is on the screen.
  bool whollyOnScreen(WidgetTester tester, Finder finder) {
    final rect = tester.getRect(finder);
    return rect.top >= -0.5 && rect.bottom <= tvSize.height + 0.5;
  }

  /// Walks down onto the block, which is the second stop on these pages.
  Future<void> downOntoTheBlock(WidgetTester tester) async {
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedLabel(tester), 'above');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<Readout>(), isTrue, reason: 'the remote reached the block');
  }

  testWidgets('the remote stops on a block of words, and it wears the ring '
      'alone', (tester) async {
    useScreen(tester, tvSize);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      page([stop('above'), block('note', 120), stop('below')]),
    );
    await tester.pumpAndSettle();

    await downOntoTheBlock(tester);

    // The ring, and not the floor's fill: the fill is what this app draws
    // under a control the remote is standing on, and pressing this one
    // does nothing at all.
    expect(focusMarks(), {FocusMark.ring});
    expect(
      find.descendant(of: find.byType(Readout), matching: find.byType(InkWell)),
      findsNothing,
      reason: 'no ink: a readout is not a control and must not ripple',
    );
    // And the same thing said to a screen reader: something focusable, not
    // something to press.
    final semantics = tester.getSemantics(find.byType(Readout)).flagsCollection;
    expect(semantics.isFocused, Tristate.isTrue);
    expect(semantics.isButton, isFalse);
    handle.dispose();
  });

  testWidgets('a bare line of text is held off the ring', (tester) async {
    // The ring is drawn on the block's own bounds, and in Bold that is
    // eight logical pixels of it -- over the first letter of every line of
    // a paragraph that was stretched edge to edge. A [ListTile] brings its
    // own sixteen and passes nothing; a note under a field has to ask.
    useScreen(tester, tvSize);
    await tester.pumpWidget(
      page([
        const Readout(
          padding: EdgeInsets.all(FocusRing.textInset),
          child: Text('a note under a field'),
        ),
      ]),
    );
    await tester.pumpAndSettle();

    final ring = tester.getRect(find.byType(Readout));
    final words = tester.getRect(find.text('a note under a field'));
    expect(words.left - ring.left, greaterThanOrEqualTo(FocusRing.textInset));
    expect(ring.right - words.right, greaterThanOrEqualTo(FocusRing.textInset));
    expect(words.top - ring.top, greaterThanOrEqualTo(FocusRing.textInset));
  });

  testWidgets('a phone is not stopped by one', (tester) async {
    // Focus off a television is for a keyboard and for accessibility,
    // where the words are reachable by touch and by screen reader already.
    // A Tab stop in front of every note on the settings screen would be a
    // cost with nothing bought.
    useScreen(tester, const Size(400, 800));
    await tester.pumpWidget(
      page([stop('above'), block('note', 120), stop('below')], device: phone),
    );
    await tester.pumpAndSettle();

    await press(tester, LogicalKeyboardKey.tab);
    expect(focusedLabel(tester), 'above');
    await press(tester, LogicalKeyboardKey.tab);
    expect(focusedLabel(tester), 'below');
    expect(
      find.descendant(of: find.byType(Readout), matching: find.byType(Focus)),
      findsNothing,
      reason: 'off a television it is its child and nothing else',
    );
  });

  testWidgets('a block under the fold is brought on screen whole', (
    tester,
  ) async {
    // Forty-eight logical pixels of room under the fold and a block that
    // needs two hundred: the case the owner met, where the last lines of
    // the model-test report stayed off the bottom of the television.
    useScreen(tester, tvSize);
    await tester.pumpWidget(
      page([
        stop('above'),
        const SizedBox(height: 620),
        block('note', 200),
        stop('below'),
      ]),
    );
    await tester.pumpAndSettle();
    expect(
      whollyOnScreen(tester, find.text('note: last line')),
      isFalse,
      reason: 'the block starts off the bottom of the screen',
    );

    await downOntoTheBlock(tester);

    expect(whollyOnScreen(tester, find.text('note: first line')), isTrue);
    expect(
      whollyOnScreen(tester, find.text('note: last line')),
      isTrue,
      reason:
          'a row scrolled to its top with its last lines off the screen '
          'is the bug, not the fix',
    );
  });

  testWidgets('a block that fits takes no press of its own', (tester) async {
    // The other half of that: once it is all on screen there is nothing
    // left to walk, so the press goes where it always went. A readout that
    // ate the down key would be a remote trapped on a paragraph.
    useScreen(tester, tvSize);
    await tester.pumpWidget(
      page([stop('above'), block('note', 120), stop('below')]),
    );
    await tester.pumpAndSettle();

    await downOntoTheBlock(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedLabel(tester), 'below');
  });

  testWidgets('one taller than the screen starts at its first line and is '
      'walked to its last', (tester) async {
    // Sixteen hundred logical pixels against a 720 television: this one
    // cannot be shown at once, so "brought into view" has to mean that
    // every line of it can be got to. Flutter's own traversal reveals a
    // stop with one edge against one edge of the viewport, which for a
    // block this tall means landing on its *last* line on the way down --
    // and the next press moves the remote off, so the top was unreadable.
    useScreen(tester, tvSize);
    await tester.pumpWidget(
      page([stop('above'), block('report', 1600), stop('below')]),
    );
    await tester.pumpAndSettle();

    await downOntoTheBlock(tester);
    expect(
      whollyOnScreen(tester, find.text('report: first line')),
      isTrue,
      reason: 'reading starts at the top of the block',
    );

    for (
      var presses = 0;
      presses < 6 && !whollyOnScreen(tester, find.text('report: last line'));
      presses++
    ) {
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(
        focusIn<Readout>(),
        isTrue,
        reason: 'the walk keeps the remote on the block until it is read',
      );
    }
    expect(
      whollyOnScreen(tester, find.text('report: last line')),
      isTrue,
      reason: 'every line of it has been on the screen',
    );

    // And then it lets go: a block that kept the down key for ever would
    // be worse than one that could not be reached.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedLabel(tester), 'below');
  });

  testWidgets('and starts at its first line coming up the page as well', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    await tester.pumpWidget(
      page([stop('above'), block('report', 1600), stop('below')]),
    );
    await tester.pumpAndSettle();

    await pressUntil(
      tester,
      LogicalKeyboardKey.arrowDown,
      () => focusedLabel(tester) == 'below',
      target: 'the stop under the block',
    );
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusIn<Readout>(), isTrue);
    expect(
      whollyOnScreen(tester, find.text('report: first line')),
      isTrue,
      reason:
          'whichever way the remote came, a paragraph is read from the '
          'top',
    );

    // Up again leaves, for the reason down does at the other end.
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedLabel(tester), 'above');
  });
}

/// Presses [key] until [reached] answers, and says what it was after when
/// it never does.
Future<void> pressUntil(
  WidgetTester tester,
  LogicalKeyboardKey key,
  bool Function() reached, {
  required String target,
  int limit = 12,
}) async {
  for (var i = 0; i < limit && !reached(); i++) {
    await press(tester, key);
  }
  expect(reached(), isTrue, reason: 'the remote never reached $target');
}
