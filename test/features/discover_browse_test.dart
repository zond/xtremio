import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/discover/discover_screen.dart';

import '../support/fake_core_client.dart';
import '../support/fixtures.dart';
import '../support/tv.dart';

/// The Discover tab: every catalog's rows, a type's rows, and one catalog
/// with its filters, chosen from the types across the top and a type's
/// catalog menu.
///
/// The installed addons are the default ones (`ctx_logged_out.json`):
/// Cinemeta's movie and series catalogs -- one of each needing a genre --
/// YouTube's channels, and Public Domain Movies.
void main() {
  const cinemeta = 'https://v3-cinemeta.strem.io/manifest.json';

  FakeCoreClient fullCore() => FakeCoreClient(
    state: {
      CoreField.ctx: loadCtxLoggedOutFixture(),
      CoreField.board: loadBoardFixture(),
      CoreField.discover: loadDiscoverFixture(),
      CoreField.continueWatchingPreview: loadContinueWatchingFixture(),
    },
  );

  Widget harness(FakeCoreClient core) => CoreScope(
    client: core,
    child: const MaterialApp(home: DiscoverScreen()),
  );

  /// Wide enough for the types to be a segmented row.
  void useWideScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  List<CoreAction> actionsOn(FakeCoreClient core, CoreField field) => [
    for (final action in core.dispatched)
      if (action.field == field) action,
  ];

  /// The `Load`s of the rows, by the type each asked for.
  List<String?> rowLoads(FakeCoreClient core) => [
    for (final action in actionsOn(core, CoreField.board))
      if (action.action['action'] == 'Load')
        ((action.action['args'] as Map)['args'] as Map)['type'] as String?,
  ];

  Future<void> chooseType(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).first);
    await tester.pumpAndSettle();
  }

  Future<void> chooseCatalog(WidgetTester tester, String name) async {
    await tester.tap(find.byType(DropdownMenu<int>).first);
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(MenuItemButton),
            matching: find.text(name),
          )
          .last,
    );
    // Pumped rather than settled: a catalog the engine has not answered for
    // yet is a spinner, which never settles.
    await tester.pump();
    await tester.pump();
  }

  DropdownMenu<int> catalogMenu(WidgetTester tester) =>
      tester.widget<DropdownMenu<int>>(find.byType(DropdownMenu<int>).first);

  /// The label the catalog menu shows as chosen.
  String? chosenCatalog(WidgetTester tester) {
    final menu = catalogMenu(tester);
    return menu.dropdownMenuEntries
        .where((entry) => entry.value == menu.initialSelection)
        .firstOrNull
        ?.label;
  }

  /// The catalog menu's choosable entries, headings left out.
  List<String> catalogEntries(WidgetTester tester) => [
    for (final entry in catalogMenu(tester).dropdownMenuEntries)
      if (entry.enabled) entry.label,
  ];

  testWidgets('opens on every catalog\'s rows, with the types across the '
      'top and no catalog menu', (tester) async {
    useWideScreen(tester);
    final core = FakeCoreClient(
      state: {
        CoreField.ctx: loadCtxLoggedOutFixture(),
        CoreField.board: loadBoardFixture(),
      },
    );
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    expect(rowLoads(core), [null], reason: 'every type');
    expect(
      actionsOn(core, CoreField.discover),
      isEmpty,
      reason: 'no catalog is opened until one is chosen',
    );
    // The addons' types, in stremio-core's order, after All.
    for (final label in ['All', 'Movies', 'Series', 'Channels']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.byType(DropdownMenu<int>), findsNothing);
    final board = CatalogsWithExtraState.fromJson(loadBoardFixture());
    expect(find.text(board.visibleRows.first.title), findsWidgets);
  });

  testWidgets('a type shows its rows, and a catalog menu on "Any"', (
    tester,
  ) async {
    useWideScreen(tester);
    final core = fullCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    await chooseType(tester, 'Series');
    expect(rowLoads(core), [null, 'series']);
    expect(find.byType(DropdownMenu<int>), findsOneWidget);
    expect(chosenCatalog(tester), DiscoverScreen.anyCatalogLabel);
    expect(actionsOn(core, CoreField.discover), isEmpty);
  });

  testWidgets('the catalog menu offers what can be opened without a search, '
      'a catalog that needs a genre among them', (tester) async {
    useWideScreen(tester);
    await tester.pumpWidget(harness(fullCore()));
    await tester.pumpAndSettle();
    await chooseType(tester, 'Series');

    final entries = catalogEntries(tester);
    expect(entries, containsAll(['Any', 'Popular', 'New', 'Featured']));
    // Cinemeta's "Last videos" and "Calendar videos" need ids nobody can
    // pick from a menu: stremio-core's Discover offers neither.
    expect(entries, isNot(contains('Last videos')));
    expect(entries, isNot(contains('Calendar videos')));
  });

  testWidgets('choosing a catalog opens it with its filters, and Back comes '
      'down to its rows and then to All', (tester) async {
    useWideScreen(tester);
    final core = fullCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();
    await chooseType(tester, 'Movies');

    await chooseCatalog(tester, 'Popular');
    final opened = actionsOn(core, CoreField.discover);
    expect(opened, hasLength(1));
    expect(
      opened.single.action,
      CoreActions.loadDiscover(
        ResourceRequest.cinemetaCatalog(type: 'movie', id: 'top'),
      ).action,
    );
    // The catalog's grid, and its genre filter beside the menu.
    final item = DiscoverState.fromJson(loadDiscoverFixture()).items.first;
    expect(find.text(item.name), findsWidgets);
    expect(find.byType(DropdownMenu<int>), findsNWidgets(2));
    expect(chosenCatalog(tester), 'Popular');

    await systemBack(tester);
    expect(
      actionsOn(core, CoreField.discover).last.action,
      CoreActions.unload(CoreField.discover).action,
      reason: 'the catalog is let go',
    );
    expect(chosenCatalog(tester), DiscoverScreen.anyCatalogLabel);
    expect(find.byType(DropdownMenu<int>), findsOneWidget);
    expect(rowLoads(core), [null, 'movie'], reason: 'the rows were kept');

    await systemBack(tester);
    expect(rowLoads(core), [null, 'movie', null]);
    expect(find.byType(DropdownMenu<int>), findsNothing);
  });

  testWidgets('a catalog that needs a genre opens on its first genre', (
    tester,
  ) async {
    useWideScreen(tester);
    final core = fullCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();
    await chooseType(tester, 'Movies');

    await chooseCatalog(tester, 'New');
    final request = ResourceRequest.fromJson(
      ((actionsOn(core, CoreField.discover).single.action['args']
                  as Map)['args']
              as Map)['request']
          as Map<String, dynamic>,
    );
    expect(request.base, cinemeta);
    expect(request.path.id, 'year');
    expect(request.path.extra, hasLength(1));
    expect(request.path.extra.single.name, 'genre');
  });

  testWidgets('"See all" on a row opens that catalog, with its type chosen', (
    tester,
  ) async {
    useWideScreen(tester);
    // The first row trimmed so its trailing tile is built without
    // scrolling, and nothing to continue watching above it.
    final rows = loadBoardFixture();
    final firstPage =
        ((rows['catalogs'] as List<dynamic>)[0] as List<dynamic>)[0]
            as Map<String, dynamic>;
    final items =
        (firstPage['content'] as Map<String, dynamic>)['content']
            as List<dynamic>;
    items.removeRange(2, items.length);
    final core = FakeCoreClient(
      state: {
        CoreField.ctx: loadCtxLoggedOutFixture(),
        CoreField.board: rows,
        CoreField.discover: loadDiscoverFixture(),
      },
    );
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    await tester.tap(find.text('See all').first);
    await tester.pumpAndSettle();

    final row = CatalogsWithExtraState.fromJson(rows).visibleRows.first;
    expect(
      actionsOn(core, CoreField.discover).single.action,
      CoreActions.loadDiscover(row.firstRequest).action,
    );
    expect(chosenCatalog(tester), row.title);
  });

  testWidgets('Continue watching follows the type', (tester) async {
    useWideScreen(tester);
    await tester.pumpWidget(harness(fullCore()));
    await tester.pumpAndSettle();
    const watching = 'Continue watching';
    expect(find.text(watching), findsOneWidget, reason: 'a movie is on it');

    await chooseType(tester, 'Series');
    expect(find.text(watching), findsNothing, reason: 'no series is');

    await chooseType(tester, 'Movies');
    expect(find.text(watching), findsOneWidget);
  });

  testWidgets('a type whose catalogs all need a choice says so', (
    tester,
  ) async {
    useWideScreen(tester);
    final core = FakeCoreClient(
      state: {
        CoreField.ctx: loadCtxLoggedOutFixture(),
        CoreField.board: {
          'selected': {'type': 'series', 'extra': <Object>[]},
          'catalogs': <Object>[],
          'catalogLabels': <Object>[],
        },
      },
    );
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();
    await chooseType(tester, 'Series');

    expect(find.text(DiscoverScreen.noRowsLabel), findsOneWidget);
  });
}
