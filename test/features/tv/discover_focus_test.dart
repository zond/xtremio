import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/discover/discover_screen.dart';
import 'package:xtremio/shell/device_profile.dart';

import '../../support/fake_core_client.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

final topMovies = ResourceRequest.cinemetaCatalog(type: 'movie', id: 'top');

/// Cinemeta's Popular movies, 50 of them, with types, catalogs and a genre.
FakeCoreClient fakeCore() =>
    FakeCoreClient(state: {CoreField.discover: loadDiscoverFixture()});

Widget harness(FakeCoreClient core, {Widget? home}) => DeviceScope(
  profile: tv,
  child: CoreScope(
    client: core,
    child: MaterialApp(home: home ?? const DiscoverScreen()),
  ),
);

/// The names of the fixture's items, in grid order.
List<String> names() => [
  for (final item in DiscoverState.fromJson(loadDiscoverFixture()).items)
    item.name,
];

/// Columns of the poster grid at [tvSize]: 1280 wide less the padding, over
/// tiles at most 160 wide.
const int columns = 8;

void main() {
  testWidgets('the D-pad walks the filter bar, then the grid, row by row', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();
    final items = names();
    // The tab takes no focus of its own.
    expect(focusedLabel(tester), isNull);

    // Down from nowhere lands on the type segments.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<SegmentedButton<int>>(), isTrue);
    expect(focusedLabel(tester), 'Movies');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), 'Series');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), 'Channels');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), 'Catalog: Popular');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), 'Genre: Any');
    expect(find.byType(DropdownMenu<int>), findsNothing);

    // Down enters the grid; left reaches its first column; right walks the
    // row; down keeps the column and moves a row.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTileName(tester), isNotNull);
    for (var i = 0; i < columns && focusedTileName(tester) != items[0]; i++) {
      await press(tester, LogicalKeyboardKey.arrowLeft);
    }
    expect(focusedTileName(tester), items[0]);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTileName(tester), items[1]);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTileName(tester), items[1 + columns]);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedTileName(tester), items[columns]);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedTileName(tester), items[0]);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedTileName(tester), isNull, reason: 'back in the filter bar');
  });

  testWidgets('down walks the grid past the rows that were built at first', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();
    final items = names();
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    for (var i = 0; i < columns && focusedTileName(tester) != items[0]; i++) {
      await press(tester, LogicalKeyboardKey.arrowLeft);
    }
    expect(focusedTileName(tester), items[0]);
    // Row 6 (index 40) is well past a 720 px viewport plus its cache: each
    // step has to scroll the grid so the next row exists to move to.
    expect(find.text(items[5 * columns]), findsNothing);
    for (var row = 1; row <= 5; row++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedTileName(tester), items[row * columns], reason: 'row $row');
    }
    final focused = tester.getRect(find.text(items[5 * columns]));
    expect(focused.top, greaterThan(0));
    expect(focused.bottom, lessThan(tvSize.height));
    expect(find.text(items[0]), findsNothing, reason: 'the grid scrolled');
  });

  testWidgets('select on a poster opens its details', (tester) async {
    useScreen(tester, tvSize);
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    final name = focusedTileName(tester)!;

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    // (The details' spinner never settles: the fake has no meta for it.)
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final details = tester.widget<MetaDetailsScreen>(
      find.byType(MetaDetailsScreen),
    );
    final item = DiscoverState.fromJson(loadDiscoverFixture()).items
        .singleWhere((item) => item.name == name);
    expect(details.id, item.id);
    expect(details.type, item.type);
  });

  testWidgets('the genre menu opens on the D-pad and dispatches a pick', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.arrowDown);
    for (var i = 0; i < 4; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(focusedLabel(tester), 'Genre: Any');
    final before = core.dispatched.length;

    await press(tester, LogicalKeyboardKey.select);
    expect(focusedLabel(tester), 'Any');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedLabel(tester), 'Action');
    await press(tester, LogicalKeyboardKey.select);

    expect(core.dispatched, hasLength(before + 1));
    final request = core.dispatched.last.action['args']['args']['request'];
    expect(request['path']['extra'], [
      ['genre', 'Action'],
    ]);
    expect(find.byType(MenuItemButton), findsNothing);
    expect(focusedLabel(tester), 'Genre: Any');
  });

  testWidgets('a Discover pushed over another screen starts on its first '
      'poster; the tab does not', (tester) async {
    useScreen(tester, tvSize);
    await tester.pumpWidget(
      harness(
        fakeCore(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DiscoverScreen(request: topMovies),
                ),
              ),
              child: const Text('See all'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(focusedLabel(tester), 'See all');

    await press(tester, LogicalKeyboardKey.select);
    expect(find.byType(DiscoverScreen), findsOneWidget);
    expect(focusedTileName(tester), names()[0]);

    // Back on the first screen, focus is where it was.
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(DiscoverScreen), findsNothing);
    expect(focusedLabel(tester), 'See all');
  });
}
