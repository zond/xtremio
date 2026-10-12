/// Helpers for the settings rows whose words open from their icon
/// ([Explained]).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/widgets/explained.dart';
import 'package:xtremio/widgets/remote_press.dart';

/// The [Explained] row titled [title].
Finder explainedRow(String title) =>
    find.byWidgetPredicate((w) => w is Explained && w.title == title);

/// Opens the explanation of the row titled [title] by tapping its icon, as a
/// viewer on a phone does. The row is scrolled into view first.
Future<void> openExplanation(WidgetTester tester, String title) async {
  final icon = find.descendant(
    of: explainedRow(title),
    matching: find.byTooltip(Explained.tooltip),
  );
  await tester.ensureVisible(icon);
  await tester.pumpAndSettle();
  await tester.tap(icon);
  await tester.pumpAndSettle();
  expect(find.byType(ExplanationDialog), findsOneWidget);
}

/// [text] in the open explanation, and nowhere else.
Finder inExplanation(String text) => find.descendant(
  of: find.byType(ExplanationDialog),
  matching: find.text(text),
);

/// Closes the open explanation with its Close button.
Future<void> closeExplanation(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byType(ExplanationDialog),
      matching: find.widgetWithText(TextButton, ExplanationDialog.closeLabel),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byType(ExplanationDialog), findsNothing);
}

/// Opens the explanation of the row titled [title] the way a remote does: the
/// row takes focus, and OK is held on it past the long-press timeout.
Future<void> holdOkOn(WidgetTester tester, String title) async {
  final words = find
      .descendant(of: explainedRow(title), matching: find.text(title))
      .first;
  await tester.ensureVisible(words);
  // The nearest stop above the title: the row itself, or the readout round
  // a row that is read rather than pressed.
  FocusNode? stop = Focus.of(tester.element(words));
  while (stop != null && !stop.canRequestFocus) {
    stop = stop.parent;
  }
  stop!.requestFocus();
  await tester.pumpAndSettle();
  await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
  await tester.pump(
    RemotePress.holdDuration + const Duration(milliseconds: 100),
  );
  await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
  await tester.pumpAndSettle();
  expect(find.byType(ExplanationDialog), findsOneWidget);
}
