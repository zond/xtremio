import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/search/search_screen.dart';

import '../support/fake_core_client.dart';
import '../support/fixtures.dart';

void main() {
  /// The query the search fixture was recorded for.
  const fixtureQuery = 'night of the living dead';

  /// Just short of the debounce, then over it.
  const almostDebounce = Duration(milliseconds: 399);
  const oneMs = Duration(milliseconds: 1);

  /// A core whose `search` field is unloaded, as it is when the screen
  /// opens in the app.
  Map<String, dynamic> unloadedSearch() => {
    'selected': null,
    'catalogs': <Object>[],
    'catalogLabels': <Object>[],
  };

  // CoreScope sits above MaterialApp, as in the app, so pushed routes see it.
  Widget harness(FakeCoreClient core) => CoreScope(
    client: core,
    child: const MaterialApp(home: SearchScreen()),
  );

  FakeCoreClient fakeCore({Map<String, dynamic>? search}) =>
      FakeCoreClient(state: {CoreField.search: search ?? unloadedSearch()});

  Finder field() => find.byKey(const Key('search-field'));

  List<CoreAction> searchDispatches(FakeCoreClient core) => [
    for (final action in core.dispatched)
      if (action.field == CoreField.search) action,
  ];

  List<CoreAction> loads(FakeCoreClient core) => [
    for (final action in searchDispatches(core))
      if (action.action['action'] == 'Load') action,
  ];

  List<CoreAction> ranges(FakeCoreClient core) => [
    for (final action in searchDispatches(core))
      if (action.action['action'] == 'CatalogsWithExtra') action,
  ];

  List<dynamic> extraOf(CoreAction load) =>
      load.action['args']['args']['extra'] as List<dynamic>;

  /// Types [query] and lets the debounce fire.
  Future<void> type(WidgetTester tester, String query) async {
    await tester.enterText(field(), query);
    await tester.pump(SearchScreen.debounce);
    await tester.pump();
  }

  /// Types the fixture's query and hands the screen the recorded state.
  Future<FakeCoreClient> searchFixture(WidgetTester tester) async {
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pump();
    await type(tester, fixtureQuery);
    core.setState(CoreField.search, loadSearchFixture());
    await tester.pumpAndSettle();
    return core;
  }

  int fixtureCatalogCount() =>
      (loadSearchFixture()['catalogs'] as List<dynamic>).length;

  testWidgets('opens with a hint and the field focused, loading nothing', (
    tester,
  ) async {
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    expect(find.text('Search movies, series and channels'), findsOneWidget);
    expect(tester.widget<TextField>(field()).autofocus, isTrue);
    expect(core.dispatched, isEmpty);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('typing dispatches one Load for the final text after the pause', (
    tester,
  ) async {
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pump();

    await tester.enterText(field(), 'night');
    await tester.pump(almostDebounce);
    await tester.enterText(field(), 'night of');
    await tester.pump(almostDebounce);
    expect(loads(core), isEmpty, reason: 'still within the debounce');

    await tester.pump(oneMs);
    final load = loads(core).single;
    expect(extraOf(load), [
      ['search', 'night of'],
    ]);
    expect(load.action, CoreActions.loadSearch('night of').action);

    // The same query again is not re-sent (each Load writes search history).
    await tester.enterText(field(), 'night of ');
    await tester.pump(SearchScreen.debounce);
    expect(loads(core), hasLength(1));
  });

  testWidgets('requests every planned catalog once the plan arrives', (
    tester,
  ) async {
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pump();
    await type(tester, fixtureQuery);
    expect(loads(core), hasLength(1));
    expect(ranges(core), isEmpty, reason: 'nothing planned yet');

    // The engine answers with the planned catalogs (and, in the fixture,
    // their results).
    core.setState(CoreField.search, loadSearchFixture());
    await tester.pumpAndSettle();

    final range = ranges(core).single;
    expect(
      range.action,
      CoreActions.loadSearchRange(0, fixtureCatalogCount() - 1).action,
    );

    // A library write re-emits the same state: no second range.
    core.setState(CoreField.search, loadSearchFixture());
    await tester.pumpAndSettle();
    expect(ranges(core), hasLength(1));
  });

  testWidgets('a plan for another query is not ranged', (tester) async {
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pump();
    await type(tester, 'something else');

    // Stale state from the previous query; its catalogs are about to be
    // replaced, so asking for their pages would be wasted.
    core.setState(CoreField.search, loadSearchFixture());
    // Plain pumps: the indeterminate progress bar never settles.
    await tester.pump();
    await tester.pump();
    expect(ranges(core), isEmpty);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Night of the Living Dead'), findsNothing);
  });

  testWidgets('renders one section per catalog that answered', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await searchFixture(tester);

    // Labels come from catalogLabels: type and addon.
    expect(find.text('Movies · Cinemeta'), findsOneWidget);
    expect(find.text('Series · Cinemeta'), findsOneWidget);
    expect(find.text('Movies · Public Domain Movies'), findsOneWidget);
    expect(find.text('Night of the Living Dead'), findsWidgets);
    expect(find.text('Age of the Living Dead'), findsOneWidget);

    // The failed YouTube rows keep a compact error each.
    expect(find.text('Channels · YouTube'), findsNWidgets(2));
    expect(find.text('Failed to fetch: HTTP 500'), findsNWidgets(2));
    expect(find.byIcon(Icons.cloud_off_outlined), findsNWidgets(2));

    // Everything settled: no progress bar.
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('a catalog that came back empty has no section', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = await searchFixture(tester);
    expect(find.text('Series · Cinemeta'), findsOneWidget);

    final search = loadSearchFixture();
    final catalogs = search['catalogs'] as List<dynamic>;
    ((catalogs[1] as List<dynamic>)[0] as Map<String, dynamic>)['content'] = {
      'type': 'Err',
      'content': {'type': 'EmptyContent'},
    };
    core.setState(CoreField.search, search);
    await tester.pumpAndSettle();

    expect(find.text('Series · Cinemeta'), findsNothing);
    expect(find.text('EmptyContent'), findsNothing);
    expect(find.text('Movies · Cinemeta'), findsOneWidget);
  });

  testWidgets('shows "no results" when every catalog settled without hits', (
    tester,
  ) async {
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pump();
    await type(tester, fixtureQuery);

    final search = loadSearchFixture();
    for (final catalog in search['catalogs'] as List<dynamic>) {
      ((catalog as List<dynamic>)[0] as Map<String, dynamic>)['content'] = {
        'type': 'Err',
        'content': {'type': 'EmptyContent'},
      };
    }
    core.setState(CoreField.search, search);
    await tester.pumpAndSettle();

    expect(find.text('No results for “$fixtureQuery”'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('a plan whose pages are not in yet shows progress only', (
    tester,
  ) async {
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pump();
    await type(tester, fixtureQuery);

    // Right after Load: planned, nothing requested (content null).
    final search = loadSearchFixture();
    for (final catalog in search['catalogs'] as List<dynamic>) {
      ((catalog as List<dynamic>)[0] as Map<String, dynamic>)['content'] = null;
    }
    core.setState(CoreField.search, search);
    await tester.pump();
    await tester.pump();

    expect(ranges(core), hasLength(1));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('No results'), findsNothing);
    expect(find.text('Movies · Cinemeta'), findsNothing);
  });

  testWidgets('clearing the field unloads the search and shows the hint', (
    tester,
  ) async {
    final core = await searchFixture(tester);
    expect(find.text('Night of the Living Dead'), findsWidgets);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();

    expect(
      core.dispatched.last.action,
      CoreActions.unload(CoreField.search).action,
    );
    expect(core.dispatched.last.field, CoreField.search);
    expect(find.text('Search movies, series and channels'), findsOneWidget);
    expect(find.text('Night of the Living Dead'), findsNothing);
    expect(tester.widget<TextField>(field()).controller!.text, isEmpty);

    // Typing the same query again is a fresh search.
    await type(tester, fixtureQuery);
    expect(loads(core), hasLength(2));
  });

  testWidgets('clearing a query that was never sent dispatches nothing', (
    tester,
  ) async {
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pump();

    await tester.enterText(field(), 'nig');
    await tester.pump(almostDebounce);
    await tester.enterText(field(), '');
    await tester.pump(SearchScreen.debounce);

    expect(core.dispatched, isEmpty);
    expect(find.text('Search movies, series and channels'), findsOneWidget);
  });

  testWidgets('Enter searches without waiting for the debounce', (
    tester,
  ) async {
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pump();

    await tester.enterText(field(), 'night');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(loads(core).single.action, CoreActions.loadSearch('night').action);

    // The pending timer fires later with the same query: still one Load.
    await tester.pump(SearchScreen.debounce);
    expect(loads(core), hasLength(1));
  });

  testWidgets('leaving unloads the search field only', (tester) async {
    final core = await searchFixture(tester);

    await tester.pumpWidget(const SizedBox());

    expect(core.dispatched.last.field, CoreField.search);
    expect(
      core.dispatched.last.action,
      CoreActions.unload(CoreField.search).action,
    );
    expect(core.dispatched.where((a) => a.field == null), isEmpty);
    expect(core.dispatched.where((a) => a.field != CoreField.search), isEmpty);
  });

  testWidgets('tapping a poster opens its details', (tester) async {
    final core = await searchFixture(tester);
    core.setState(CoreField.metaDetails, loadMetaDetailsFixture());

    final first = CatalogsWithExtraState.fromJson(loadSearchFixture())
        .rows
        .first
        .items
        .first;
    await tester.tap(find.text(first.name).first);
    await tester.pumpAndSettle();

    expect(find.byType(MetaDetailsScreen), findsOneWidget);
    final load = core.dispatched.firstWhere(
      (a) => a.field == CoreField.metaDetails,
    );
    expect(
      load.action,
      CoreActions.loadMetaDetails(type: first.type, id: first.id).action,
    );
    expect(first.id, 'tt0063350');
  });
}
