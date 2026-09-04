import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/addons/addon_details_screen.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/search/search_screen.dart';
import 'package:xtremio/widgets/tv_text_field.dart';

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

  FakeCoreClient fakeCore({
    Map<String, dynamic>? search,
    Map<String, dynamic>? ctx,
  }) => FakeCoreClient(
    state: {CoreField.search: search ?? unloadedSearch(), CoreField.ctx: ?ctx},
  );

  /// Sets `content` on the first page of every catalog of a fixture.
  Map<String, dynamic> searchWithEveryPage(Map<String, dynamic> content) {
    final search = loadSearchFixture();
    for (final catalog in search['catalogs'] as List<dynamic>) {
      ((catalog as List<dynamic>)[0] as Map<String, dynamic>)['content'] = {
        ...content,
      };
    }
    return search;
  }

  /// An `Err` page: what an addon that could not answer looks like.
  Map<String, dynamic> failedPage(String message) => {
    'type': 'Err',
    'content': {
      'type': 'Env',
      'content': {'code': 1, 'message': message},
    },
  };

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
  Future<FakeCoreClient> searchFixture(
    WidgetTester tester, {
    Map<String, dynamic>? ctx,
  }) async {
    final core = fakeCore(ctx: ctx);
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
    expect(tester.widget<TvTextField>(field()).autofocus, isTrue);
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
    // Tall enough that the line accounting for the failures is laid out
    // under the last grid rather than past the end of the cache extent.
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await searchFixture(tester);

    // Labels come from catalogLabels: type and addon.
    expect(find.text('Movies · Cinemeta'), findsOneWidget);
    expect(find.text('Series · Cinemeta'), findsOneWidget);
    expect(find.text('Movies · Public Domain Movies'), findsOneWidget);
    expect(find.text('Night of the Living Dead'), findsWidgets);
    expect(find.text('Age of the Living Dead'), findsOneWidget);

    // The two YouTube catalogs answered HTTP 500: no header, no error text,
    // one collapsed line at the end accounting for the addon.
    expect(find.text('Channels · YouTube'), findsNothing);
    expect(find.text('Failed to fetch: HTTP 500'), findsNothing);
    expect(find.text('1 addon could not be searched'), findsOneWidget);

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

  group('the addons that could not be searched', () {
    /// The screen at 1000x4000: every section and the line under them fit.
    Future<FakeCoreClient> mount(
      WidgetTester tester, {
      Map<String, dynamic>? search,
    }) async {
      tester.view.physicalSize = const Size(1000, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final core = fakeCore(ctx: loadCtxLoggedOutFixture());
      await tester.pumpWidget(harness(core));
      await tester.pump();
      await type(tester, fixtureQuery);
      core.setState(CoreField.search, search ?? loadSearchFixture());
      await tester.pumpAndSettle();
      return core;
    }

    testWidgets('one line under the results, expanding to the addon and why', (
      tester,
    ) async {
      await mount(tester);

      // Under the hits, not among them: what did answer stays first.
      expect(
        tester.getTopLeft(find.text('1 addon could not be searched')).dy,
        greaterThan(tester.getTopLeft(find.text('Movies · Cinemeta')).dy),
      );

      await tester.tap(find.text('1 addon could not be searched'));
      await tester.pumpAndSettle();

      // Named from the profile rather than by its host.
      expect(find.text('YouTube'), findsWidgets);
      expect(find.text('v3-channels.strem.io'), findsNothing);
      expect(find.text('Failed to fetch: HTTP 500'), findsOneWidget);
      expect(find.text('Check addon'), findsOneWidget);
      expect(find.text('Uninstall'), findsOneWidget);
    });

    testWidgets('every addon failing is never blamed on the query', (
      tester,
    ) async {
      await mount(
        tester,
        search: searchWithEveryPage(failedPage('Failed to fetch: HTTP 500')),
      );

      // The query is not the problem, and there is no spelling to try.
      expect(find.textContaining('No results for'), findsNothing);
      expect(find.textContaining('Try another spelling'), findsNothing);
      expect(
        find.text('Nothing came back for “$fixtureQuery”'),
        findsOneWidget,
      );

      // Three addons behind the five catalogs, each with its own card.
      expect(find.text('3 addons could not be searched'), findsOneWidget);
      await tester.tap(find.text('3 addons could not be searched'));
      await tester.pumpAndSettle();
      expect(find.text('Failed to fetch: HTTP 500'), findsNWidgets(3));
      expect(find.text('Check addon'), findsNWidgets(3));
    });

    testWidgets('an addon answering nothing is still not a failure', (
      tester,
    ) async {
      await mount(
        tester,
        search: searchWithEveryPage(const {
          'type': 'Err',
          'content': {'type': 'EmptyContent'},
        }),
      );

      // Everything was asked and everything answered: the query really is
      // what has no hits.
      expect(find.text('No results for “$fixtureQuery”'), findsOneWidget);
      expect(find.textContaining('could not be searched'), findsNothing);
    });

    testWidgets('checking an addon opens its details on that manifest URL', (
      tester,
    ) async {
      final core = await mount(tester);

      await tester.tap(find.text('1 addon could not be searched'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check addon'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.byType(AddonDetailsScreen), findsOneWidget);
      expect(
        core.dispatched.last.action,
        CoreActions.loadAddonDetails(
          'https://v3-channels.strem.io/manifest.json',
        ).action,
      );
    });

    testWidgets('ctx is pulled only once something has failed', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final core = fakeCore(ctx: loadCtxLoggedOutFixture());
      await tester.pumpWidget(harness(core));
      await tester.pump();
      await type(tester, fixtureQuery);
      core.setState(
        CoreField.search,
        searchWithEveryPage(const {'type': 'Ready', 'content': <Object>[]}),
      );
      await tester.pumpAndSettle();

      // Nothing failed: the whole context, library included, is not worth
      // pulling for addon names nobody is going to read.
      expect(core.pulled, isNot(contains(CoreField.ctx)));

      core.setState(CoreField.search, loadSearchFixture());
      await tester.pumpAndSettle();
      expect(core.pulled, contains(CoreField.ctx));
    });
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
    expect(tester.widget<TvTextField>(field()).controller.text, isEmpty);

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
