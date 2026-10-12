import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/explained.dart';
import 'package:xtremio/widgets/remote_press.dart';

import '../support/tv.dart';

const String rowText = 'Keeps the next episode coming.';
const String switchText = 'Turns the lights on.';

/// Two explained rows, a plain one and a switch, recording what they did.
Widget harness(
  List<String> events, {
  DeviceProfile profile = const DeviceProfile(isTv: false, hasTouch: true),
}) => DeviceScope(
  profile: profile,
  child: MaterialApp(
    home: Scaffold(
      body: StatefulBuilder(
        builder: (context, setState) => ListView(
          children: [
            Explained(
              title: 'Binge watching',
              explanation: rowText,
              child: ListTile(
                leading: const ExplainIcon(Icon(Icons.skip_next_outlined)),
                title: const Text('Binge watching'),
                onTap: () => events.add('row'),
              ),
            ),
            Explained(
              title: 'Lights',
              explanation: switchText,
              child: SwitchListTile(
                secondary: const ExplainIcon.info(),
                title: const Text('Lights'),
                value: events.contains('switch'),
                onChanged: (_) => setState(() => events.add('switch')),
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);

/// The rows' own icons, as opposed to the dialog's.
Finder explainButton(String title) => find.descendant(
  of: find.widgetWithText(Explained, title),
  matching: find.byTooltip(Explained.tooltip),
);

void main() {
  group('off a television', () {
    testWidgets('the icon opens the explanation and Close shuts it, and the '
        'row is not pressed', (tester) async {
      final events = <String>[];
      await tester.pumpWidget(harness(events));

      expect(find.text(rowText), findsNothing, reason: 'the title only');
      await tester.tap(explainButton('Binge watching'));
      await tester.pumpAndSettle();

      final dialog = find.byType(ExplanationDialog);
      expect(dialog, findsOneWidget);
      expect(
        find.descendant(of: dialog, matching: find.text('Binge watching')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.text(rowText)),
        findsOneWidget,
      );
      expect(events, isEmpty);

      await tester.tap(find.text(ExplanationDialog.closeLabel));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(events, isEmpty);

      // And the rest of the row is the row's.
      await tester.tap(find.text('Binge watching'));
      await tester.pumpAndSettle();
      expect(events, ['row']);
      expect(dialog, findsNothing);
    });

    testWidgets('a row with no icon of its own gets the info icon', (
      tester,
    ) async {
      final events = <String>[];
      await tester.pumpWidget(harness(events));
      expect(
        find.descendant(
          of: explainButton('Lights'),
          matching: find.byIcon(Icons.info_outline),
        ),
        findsOneWidget,
      );
      await tester.tap(explainButton('Lights'));
      await tester.pumpAndSettle();
      expect(find.text(switchText), findsOneWidget);
      expect(events, isEmpty, reason: 'the switch did not flip');
    });

    testWidgets('a screen reader finds it, on a switch row too', (
      tester,
    ) async {
      // A switch row merges the icon's button into the row's one node, so
      // the button's own tap is the switch's there. The named action is
      // what is left to a screen reader, and it is on both kinds of row.
      final semantics = tester.ensureSemantics();
      final events = <String>[];
      await tester.pumpWidget(harness(events));

      final action = CustomSemanticsAction.getIdentifier(Explained.action);
      final lights = tester.getSemantics(find.byType(SwitchListTile));
      expect(lights.getSemanticsData().customSemanticsActionIds, [action]);
      lights.owner!.performAction(
        lights.id,
        SemanticsAction.customAction,
        action,
      );
      await tester.pumpAndSettle();
      expect(find.text(switchText), findsOneWidget);
      expect(events, isEmpty);
      await tester.tap(find.text(ExplanationDialog.closeLabel));
      await tester.pumpAndSettle();

      // A plain row keeps the icon a node of its own, named by its
      // tooltip, and the row carries the action as well.
      expect(
        tester.getSemantics(explainButton('Binge watching')),
        matchesSemantics(
          tooltip: Explained.tooltip,
          isButton: true,
          hasTapAction: true,
          hasFocusAction: true,
          isFocusable: true,
          hasEnabledState: true,
          isEnabled: true,
        ),
      );
      final binge = tester.getSemantics(find.byType(ListTile).first);
      expect(binge.getSemanticsData().customSemanticsActionIds, [action]);
      semantics.dispose();
    });
  });

  group('on a television', () {
    Future<void> pumpTv(WidgetTester tester, List<String> events) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(harness(events, profile: tv));
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), 'Binge watching');
    }

    testWidgets('the icon is no stop of its own', (tester) async {
      final events = <String>[];
      await pumpTv(tester, events);
      expect(find.byTooltip(Explained.tooltip), findsNothing);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), 'Lights', reason: 'one stop per row');
    });

    testWidgets('a held OK opens the explanation, its repeats press nothing, '
        'and Back returns the remote to the row', (tester) async {
      final events = <String>[];
      await pumpTv(tester, events);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(
        RemotePress.holdDuration + const Duration(milliseconds: 50),
      );
      await tester.pumpAndSettle();
      expect(find.text(rowText), findsOneWidget);
      expect(focusedLabel(tester), ExplanationDialog.closeLabel);
      for (var i = 0; i < 5; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text(rowText), findsOneWidget, reason: 'still open');
      expect(events, isEmpty);

      await systemBack(tester);
      expect(find.byType(ExplanationDialog), findsNothing);
      expect(focusedLabel(tester), 'Binge watching');
      expect(events, isEmpty);
    });

    testWidgets('OK on Close shuts it too, back on the row', (tester) async {
      final events = <String>[];
      await pumpTv(tester, events);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await hold(
        tester,
        LogicalKeyboardKey.select,
        RemotePress.holdDuration + const Duration(milliseconds: 100),
      );
      expect(find.text(switchText), findsOneWidget);
      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(ExplanationDialog), findsNothing);
      expect(focusedLabel(tester), 'Lights');
      expect(events, isEmpty);
    });

    testWidgets('a short press is the row\'s own', (tester) async {
      final events = <String>[];
      await pumpTv(tester, events);
      await press(tester, LogicalKeyboardKey.select);
      expect(events, ['row']);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.select);
      expect(events, ['row', 'switch']);
      expect(find.byType(ExplanationDialog), findsNothing);
    });
  });
}
