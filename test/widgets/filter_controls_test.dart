import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
