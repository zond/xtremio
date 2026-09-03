import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/filter_controls.dart';

void main() {
  const options = [
    FilterOption(label: 'All', selected: true, request: 'all'),
    FilterOption(label: 'Movies', selected: false, request: 'movie'),
    FilterOption(label: 'Series', selected: false, request: 'series'),
  ];

  Widget harness(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('segments show the engine selection and report a tap', (
    tester,
  ) async {
    final selected = <String>[];
    await tester.pumpWidget(
      harness(FilterSegments(options: options, onSelect: selected.add)),
    );

    expect(
      tester
          .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
          .selected,
      {0},
    );
    await tester.tap(find.text('Series'));
    await tester.pumpAndSettle();
    expect(selected, ['series']);
    // The selection stays the engine's until a new state arrives.
    expect(
      tester
          .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
          .selected,
      {0},
    );
  });

  testWidgets('chips ignore a tap on the selected option', (tester) async {
    final selected = <String>[];
    await tester.pumpWidget(
      harness(FilterChips(options: options, onSelect: selected.add)),
    );

    expect(
      tester.widget<ChoiceChip>(find.byType(ChoiceChip).first).selected,
      isTrue,
    );
    await tester.tap(find.text('All'));
    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();
    expect(selected, ['movie']);
  });

  testWidgets('menu lists every option and dispatches the chosen one', (
    tester,
  ) async {
    final selected = <String>[];
    await tester.pumpWidget(
      harness(
        FilterMenu(label: 'Type', options: options, onSelect: selected.add),
      ),
    );

    final menu = find.byType(DropdownMenu<int>);
    expect(
      find.descendant(of: menu, matching: find.text('Type')),
      findsWidgets,
    );
    expect(find.descendant(of: menu, matching: find.text('All')), findsWidgets);

    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(MenuItemButton),
            matching: find.text('Movies'),
          )
          .last,
    );
    await tester.pumpAndSettle();
    expect(selected, ['movie']);
  });

  group('on a TV the menu is a button', () {
    const tv = DeviceProfile(isTv: true, hasTouch: false);

    Widget tvHarness(Widget child) =>
        DeviceScope(profile: tv, child: harness(child));

    /// The label on the widget holding primary focus.
    String? focusedLabel(WidgetTester tester) {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) return null;
      final texts = find.descendant(
        of: find.byWidget(context.widget),
        matching: find.byType(Text),
      );
      return texts.evaluate().isEmpty
          ? null
          : tester.widget<Text>(texts.first).data;
    }

    Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    testWidgets('reads the label and the selection, and is no dropdown', (
      tester,
    ) async {
      await tester.pumpWidget(
        tvHarness(
          FilterMenu(label: 'Type', options: options, onSelect: (_) {}),
        ),
      );
      expect(find.byType(DropdownMenu<int>), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Type: All'), findsOneWidget);
      expect(find.byType(MenuItemButton), findsNothing);

      // With nothing selected the button is the bare label.
      await tester.pumpWidget(
        tvHarness(
          FilterMenu(
            label: 'Genre',
            options: [
              for (final option in options)
                FilterOption(
                  label: option.label,
                  selected: false,
                  request: option.request,
                ),
            ],
            onSelect: (_) {},
          ),
        ),
      );
      expect(find.widgetWithText(OutlinedButton, 'Genre'), findsOneWidget);
    });

    testWidgets('select opens the menu on the selected entry, the D-pad '
        'walks it, select picks and focus returns to the button', (
      tester,
    ) async {
      final selected = <String>[];
      await tester.pumpWidget(
        tvHarness(
          FilterMenu(label: 'Type', options: options, onSelect: selected.add),
        ),
      );
      await press(tester, LogicalKeyboardKey.tab);
      expect(focusedLabel(tester), 'Type: All');

      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(MenuItemButton), findsNWidgets(3));
      expect(focusedLabel(tester), 'All');

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), 'Movies');
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), 'Series', reason: 'stops at the end');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(tester), 'Movies');

      await press(tester, LogicalKeyboardKey.select);
      expect(selected, ['movie']);
      expect(find.byType(MenuItemButton), findsNothing);
      expect(focusedLabel(tester), 'Type: All');
    });

    testWidgets('picking the current entry closes without dispatching', (
      tester,
    ) async {
      final selected = <String>[];
      await tester.pumpWidget(
        tvHarness(
          FilterMenu(label: 'Type', options: options, onSelect: selected.add),
        ),
      );
      await press(tester, LogicalKeyboardKey.tab);
      await press(tester, LogicalKeyboardKey.select);
      expect(focusedLabel(tester), 'All');
      await press(tester, LogicalKeyboardKey.select);
      expect(selected, isEmpty);
      expect(find.byType(MenuItemButton), findsNothing);
      expect(focusedLabel(tester), 'Type: All');
    });

    testWidgets('BACK closes the open menu instead of leaving the screen', (
      tester,
    ) async {
      await tester.pumpWidget(
        tvHarness(
          FilterMenu(label: 'Type', options: options, onSelect: (_) {}),
        ),
      );
      await press(tester, LogicalKeyboardKey.tab);
      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(MenuItemButton), findsNWidgets(3));

      final handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(handled, isTrue);
      expect(find.byType(MenuItemButton), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Type: All'), findsOneWidget);
      expect(focusedLabel(tester), 'Type: All');

      // Closed, BACK is the screen's own again.
      expect(await tester.binding.handlePopRoute(), isFalse);
    });
  });
}
