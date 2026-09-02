import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/discover/discover_screen.dart';

import '../support/fake_core_client.dart';
import '../support/fixtures.dart';

void main() {
  final topMovies = ResourceRequest.cinemetaCatalog(type: 'movie', id: 'top');

  // CoreScope sits above MaterialApp, as in the app, so pushed routes see it.
  Widget harness(FakeCoreClient core, {ResourceRequest? request}) => CoreScope(
    client: core,
    child: MaterialApp(home: DiscoverScreen(request: request)),
  );

  /// Phone width, below [DiscoverScreen.wideBreakpoint].
  void useNarrowScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// A `discover` state with one loaded page and the given `selectable`.
  Map<String, dynamic> stateWith({
    required Map<String, dynamic> selectable,
    ResourceRequest? selected,
  }) => {
    'selected': {'request': (selected ?? topMovies).toJson()},
    'selectable': selectable,
    'catalog': [
      {
        'request': (selected ?? topMovies).toJson(),
        'content': {
          'type': 'Ready',
          'content': [
            {'id': 'tt1', 'type': 'movie', 'name': 'Only Item'},
          ],
        },
      },
    ],
  };

  Map<String, dynamic> option(String? value, bool selected, String extra) => {
    'value': value,
    'selected': selected,
    'request': ResourceRequest.cinemetaCatalog(
      type: 'movie',
      id: 'top',
      extra: [if (value != null) ExtraValue(extra, value)],
    ).toJson(),
  };

  List<CoreAction> loads(FakeCoreClient core) => [
    for (final action in core.dispatched)
      if (action.action['action'] == 'Load') action,
  ];

  group('DiscoverState', () {
    test('reads the recorded Cinemeta page', () {
      final state = DiscoverState.fromJson(loadDiscoverFixture());
      expect(state.selected?.path.id, 'top');
      expect(state.pages, hasLength(1));
      expect(state.items, hasLength(50));
      expect(state.items.first.name, isNotEmpty);
      expect(state.items.first.poster, startsWith('https://'));
      expect(state.hasNextPage, isTrue);
      expect(state.nextPage?.path.extra, const [ExtraValue('skip', '50')]);
      expect(state.isLoadingMore, isFalse);
    });

    test('reads the selectable filters', () {
      final selectable = DiscoverState.fromJson(loadDiscoverFixture())
          .selectable;

      expect(
        [for (final t in selectable.types) t.label],
        ['movie', 'series', 'channel'],
      );
      expect(selectable.selectedType?.label, 'movie');
      expect(selectable.types[1].request.path.type, 'series');
      expect(
        selectable.types[2].request.base,
        'https://v3-channels.strem.io/manifest.json',
      );

      expect(
        [for (final c in selectable.catalogs) c.label],
        ['Popular', 'New', 'Featured', 'publicdomainmovies'],
      );
      expect(selectable.selectedCatalog?.label, 'Popular');
      expect(selectable.catalogs[1].request.path.id, 'year');

      expect(selectable.extra, hasLength(1));
      final genre = selectable.extra.single;
      expect(genre.name, 'genre');
      expect(genre.isRequired, isFalse);
      expect(genre.options, hasLength(20));
      expect(genre.options.first.value, isNull);
      expect(genre.options.first.selected, isTrue);
      expect(genre.selectedOption?.value, isNull);
      expect(genre.options[1].value, 'Action');
      expect(genre.options[1].request.path.extra, const [
        ExtraValue('genre', 'Action'),
      ]);

      expect(selectable.nextPage?.path.extra, const [ExtraValue('skip', '50')]);
      expect(selectable.isEmpty, isFalse);
    });

    test('tolerates an unloaded model', () {
      final state = DiscoverState.fromJson({
        'selected': null,
        'selectable': {
          'types': [],
          'catalogs': [],
          'extra': [],
          'nextPage': null,
        },
        'catalog': [],
      });
      expect(state.selected, isNull);
      expect(state.selectable.isEmpty, isTrue);
      expect(state.selectedCatalogName, isNull);
      expect(state.hasNextPage, isFalse);
    });
  });

  testWidgets(
    'without a request lets the engine pick, shows the catalog name, unloads',
    (tester) async {
      final fixture = loadDiscoverFixture();
      final core = FakeCoreClient(state: {CoreField.discover: fixture});
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();

      expect(core.dispatched, hasLength(1));
      expect(core.dispatched.single.field, CoreField.discover);
      expect(
        core.dispatched.single.action,
        CoreActions.loadDiscoverDefault().action,
      );

      // App bar names the selected catalog.
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Popular'),
        ),
        findsOneWidget,
      );
      final firstName = DiscoverState.fromJson(fixture).items.first.name;
      expect(find.text(firstName), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      expect(
        core.dispatched.last.action,
        CoreActions.unload(CoreField.discover).action,
      );
    },
  );

  testWidgets('with a request loads exactly that catalog', (tester) async {
    final request = ResourceRequest.cinemetaCatalog(type: 'series', id: 'top');
    final fixture = loadDiscoverFixture();
    final core = FakeCoreClient(state: {CoreField.discover: fixture});
    await tester.pumpWidget(harness(core, request: request));
    // The field still holds another catalog (the movie fixture), which this
    // screen ignores: a spinner (never settling) until its own state is in.
    await tester.pump();
    await tester.pump();

    expect(core.dispatched, hasLength(1));
    expect(
      core.dispatched.single.action,
      CoreActions.loadDiscover(request).action,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final movieName = DiscoverState.fromJson(fixture).items.first.name;
    expect(find.text(movieName), findsNothing);
  });

  testWidgets(
    'covered by a second Discover, keeps its rows and takes the field back '
    'when it is on top again',
    (tester) async {
      final fixture = loadDiscoverFixture();
      final movieName = DiscoverState.fromJson(fixture).items.first.name;
      final core = FakeCoreClient(state: {CoreField.discover: fixture});
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();
      expect(core.dispatched, hasLength(1));
      expect(find.text(movieName), findsOneWidget);

      // A genre chip on a details screen pushes a second Discover with its
      // own request over this one; the shared field now serves it.
      final topSeries = ResourceRequest.cinemetaCatalog(
        type: 'series',
        id: 'top',
      );
      Navigator.of(tester.element(find.byType(DiscoverScreen))).push(
        MaterialPageRoute<void>(
          builder: (_) => DiscoverScreen(request: topSeries),
        ),
      );
      // (Its spinner never settles until its state is in, so pump the route
      // transition by hand.)
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(core.dispatched, hasLength(2));
      expect(
        core.dispatched.last.action,
        CoreActions.loadDiscover(topSeries).action,
      );
      // The new screen does not show the covered one's catalog meanwhile.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text(movieName), findsNothing);
      expect(find.text(movieName, skipOffstage: false), findsOneWidget);

      core.setState(
        CoreField.discover,
        stateWith(
          selected: topSeries,
          selectable: {
            'types': [],
            'catalogs': [],
            'extra': [],
            'nextPage': null,
          },
        ),
      );
      await tester.pumpAndSettle();

      // The second screen shows its catalog; the covered one neither
      // reloaded nor went blank (or over to the series) on that state.
      expect(core.dispatched, hasLength(2));
      expect(find.text('Only Item'), findsOneWidget);
      expect(find.text(movieName), findsNothing);
      expect(find.text(movieName, skipOffstage: false), findsOneWidget);
      expect(find.text('Only Item', skipOffstage: false), findsOneWidget);
      expect(
        find.byType(CircularProgressIndicator, skipOffstage: false),
        findsNothing,
      );

      // Back: the first screen loads the catalog the engine had picked for
      // it again (not the default), and the popped screen leaves the field
      // to it.
      Navigator.of(tester.element(find.byType(DiscoverScreen).last)).pop();
      await tester.pumpAndSettle();
      expect(find.byType(DiscoverScreen), findsOneWidget);
      expect(find.text(movieName), findsOneWidget);
      expect(core.dispatched, hasLength(3));
      expect(
        core.dispatched.last.action,
        CoreActions.loadDiscover(topMovies).action,
      );

      // Its own exit unloads the field as usual, once.
      await tester.pumpWidget(const SizedBox());
      expect(
        core.dispatched.last.action,
        CoreActions.unload(CoreField.discover).action,
      );
      expect(
        core.dispatched.where((a) => a.action['action'] == 'Unload'),
        hasLength(1),
      );
    },
  );

  testWidgets('coming back from details does not reload the catalog', (
    tester,
  ) async {
    final fixture = loadDiscoverFixture();
    final first = DiscoverState.fromJson(fixture).items.first;
    final core = FakeCoreClient(state: {CoreField.discover: fixture});
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    await tester.tap(find.text(first.name));
    // The details screen spins (never settling) until its state is in, so
    // pump the route transition by hand.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(MetaDetailsScreen), findsOneWidget);
    expect(loads(core), hasLength(2));
    expect(loads(core).last.field, CoreField.metaDetails);

    Navigator.of(tester.element(find.byType(MetaDetailsScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(DiscoverScreen), findsOneWidget);
    expect(find.text(first.name), findsOneWidget);
    expect(
      core.dispatched.where((a) => a.field == CoreField.discover),
      hasLength(1),
      reason: 'the field still holds this catalog',
    );
  });

  testWidgets('renders the filter bar from the recorded selectable', (
    tester,
  ) async {
    final core = FakeCoreClient(
      state: {CoreField.discover: loadDiscoverFixture()},
    );
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    // Wide layout (the default 800 px test window): a segmented button.
    final segments = find.byType(SegmentedButton<int>);
    expect(segments, findsOneWidget);
    for (final label in ['Movies', 'Series', 'Channels']) {
      expect(
        find.descendant(of: segments, matching: find.text(label)),
        findsOneWidget,
      );
    }
    expect(tester.widget<SegmentedButton<int>>(segments).selected, {0});

    // Catalog dropdown shows the selected catalog and offers the others.
    final menus = find.byType(DropdownMenu<int>);
    expect(menus, findsNWidgets(2));
    expect(
      find.descendant(of: menus.at(0), matching: find.text('Catalog')),
      findsWidgets,
    );
    expect(
      find.descendant(of: menus.at(0), matching: find.text('Popular')),
      findsWidgets,
    );
    await tester.tap(menus.at(0));
    await tester.pumpAndSettle();
    for (final name in ['New', 'Featured', 'publicdomainmovies']) {
      expect(
        find.descendant(
          of: find.byType(MenuItemButton),
          matching: find.text(name),
        ),
        findsWidgets,
      );
    }
    // Close it again without choosing.
    await tester.tapAt(const Offset(790, 590));
    await tester.pumpAndSettle();

    // Genre dropdown, with "Any" for the null option.
    expect(
      find.descendant(of: menus.at(1), matching: find.text('Genre')),
      findsWidgets,
    );
    expect(
      find.descendant(of: menus.at(1), matching: find.text('Any')),
      findsWidgets,
    );
    await tester.tap(menus.at(1));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(MenuItemButton),
        matching: find.text('Action'),
      ),
      findsWidgets,
    );
  });

  testWidgets('selecting a type dispatches its request', (tester) async {
    final fixture = loadDiscoverFixture();
    final core = FakeCoreClient(state: {CoreField.discover: fixture});
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Series'));
    await tester.pumpAndSettle();

    final types = DiscoverState.fromJson(fixture).selectable.types;
    expect(loads(core), hasLength(2));
    expect(loads(core).last.field, CoreField.discover);
    expect(
      loads(core).last.action,
      CoreActions.loadDiscover(types[1].request).action,
    );
    // The selection is the engine's to make: nothing moves before the next
    // state arrives.
    expect(
      tester
          .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
          .selected,
      {0},
    );
  });

  testWidgets('choosing a genre dispatches the request with that extra', (
    tester,
  ) async {
    final core = FakeCoreClient(
      state: {CoreField.discover: loadDiscoverFixture()},
    );
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownMenu<int>).at(1));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(MenuItemButton),
            matching: find.text('Drama'),
          )
          .last,
    );
    await tester.pumpAndSettle();

    expect(loads(core), hasLength(2));
    final args = loads(core).last.action['args']['args'];
    final request = ResourceRequest.fromJson(
      args['request'] as Map<String, dynamic>,
    );
    expect(request.base, kCinemetaManifestUrl);
    expect(request.path.id, 'top');
    expect(request.path.extra, const [ExtraValue('genre', 'Drama')]);
  });

  testWidgets('choosing another catalog dispatches its request', (
    tester,
  ) async {
    final fixture = loadDiscoverFixture();
    final core = FakeCoreClient(state: {CoreField.discover: fixture});
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownMenu<int>).at(0));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(MenuItemButton),
            matching: find.text('Featured'),
          )
          .last,
    );
    await tester.pumpAndSettle();

    final catalogs = DiscoverState.fromJson(fixture).selectable.catalogs;
    expect(loads(core), hasLength(2));
    expect(
      loads(core).last.action,
      CoreActions.loadDiscover(catalogs[2].request).action,
    );
    expect(catalogs[2].request.path.id, 'imdbRating');
  });

  testWidgets('re-selecting the current entry dispatches nothing', (
    tester,
  ) async {
    final core = FakeCoreClient(
      state: {CoreField.discover: loadDiscoverFixture()},
    );
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownMenu<int>).at(0));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(MenuItemButton),
            matching: find.text('Popular'),
          )
          .last,
    );
    await tester.pumpAndSettle();

    expect(loads(core), hasLength(1));
  });

  testWidgets('a required extra offers no "Any" option', (tester) async {
    final core = FakeCoreClient(
      state: {
        CoreField.discover: stateWith(
          selectable: {
            'types': [],
            'catalogs': [],
            'extra': [
              {
                'name': 'year',
                'isRequired': true,
                'options': [
                  option('2026', true, 'year'),
                  option('2025', false, 'year'),
                ],
              },
            ],
            'nextPage': null,
          },
        ),
      },
    );
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    final menu = find.byType(DropdownMenu<int>);
    expect(menu, findsOneWidget);
    expect(
      find.descendant(of: menu, matching: find.text('Year')),
      findsWidgets,
    );
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('Any'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(MenuItemButton),
        matching: find.text('2025'),
      ),
      findsWidgets,
    );
  });

  testWidgets('on a phone the types are chips and still dispatch', (
    tester,
  ) async {
    useNarrowScreen(tester);
    final fixture = loadDiscoverFixture();
    final core = FakeCoreClient(state: {CoreField.discover: fixture});
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    expect(find.byType(SegmentedButton<int>), findsNothing);
    final chips = find.byType(ChoiceChip);
    expect(chips, findsNWidgets(3));
    expect(tester.widget<ChoiceChip>(chips.at(0)).selected, isTrue);
    expect(tester.widget<ChoiceChip>(chips.at(2)).selected, isFalse);

    await tester.tap(find.text('Channels'));
    await tester.pumpAndSettle();

    final types = DiscoverState.fromJson(fixture).selectable.types;
    expect(loads(core), hasLength(2));
    expect(
      loads(core).last.action,
      CoreActions.loadDiscover(types[2].request).action,
    );
  });

  testWidgets('follows the engine when the selection changes', (tester) async {
    final fixture = loadDiscoverFixture();
    final core = FakeCoreClient(state: {CoreField.discover: fixture});
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    // The engine answers a type change: series selected, other catalogs.
    // (A state for a catalog this screen did not ask for would be another
    // Discover screen's, and ignored.)
    final series = ResourceRequest.cinemetaCatalog(type: 'series', id: 'top');
    await tester.tap(find.text('Series'));
    await tester.pump();
    expect(loads(core).last.action, CoreActions.loadDiscover(series).action);
    core.setState(
      CoreField.discover,
      stateWith(
        selected: series,
        selectable: {
          'types': [
            {'type': 'movie', 'selected': false, 'request': topMovies.toJson()},
            {'type': 'series', 'selected': true, 'request': series.toJson()},
          ],
          'catalogs': [
            {
              'catalog': 'Popular',
              'selected': true,
              'request': series.toJson(),
            },
            {
              'catalog': 'Featured',
              'selected': false,
              'request': ResourceRequest.cinemetaCatalog(
                type: 'series',
                id: 'imdbRating',
              ).toJson(),
            },
          ],
          'extra': [],
          'nextPage': null,
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
          .selected,
      {1},
    );
    expect(find.byType(DropdownMenu<int>), findsOneWidget);
    expect(find.text('Only Item'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('Popular')),
      findsOneWidget,
    );
  });

  testWidgets('hides the filter bar while nothing is selectable', (
    tester,
  ) async {
    final core = FakeCoreClient(
      state: {
        CoreField.discover: {
          'selected': null,
          'selectable': {
            'types': [],
            'catalogs': [],
            'extra': [],
            'nextPage': null,
          },
          'catalog': [],
        },
      },
    );
    await tester.pumpWidget(harness(core));
    await tester.pump();

    expect(find.text('Discover'), findsOneWidget);
    expect(find.byType(SegmentedButton<int>), findsNothing);
    expect(find.byType(DropdownMenu<int>), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('loads the next page once near the end of the grid', (
    tester,
  ) async {
    final fixture = loadDiscoverFixture();
    final core = FakeCoreClient(state: {CoreField.discover: fixture});
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();
    expect(core.dispatched, hasLength(1));

    await tester.drag(find.byType(GridView), const Offset(0, -4000));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(GridView), const Offset(0, -400));
    await tester.pumpAndSettle();

    final nextPages = [
      for (final action in core.dispatched)
        if (action.action['action'] == 'CatalogWithFilters') action,
    ];
    expect(nextPages, hasLength(1));
    expect(nextPages.single.action, CoreActions.loadDiscoverNextPage().action);

    // The engine appends a loading page; a second page is requested only
    // once that one is ready and the engine still offers another.
    final page = (fixture['catalog'] as List<dynamic>).first;
    core.setState(CoreField.discover, {
      ...fixture,
      'catalog': [
        page,
        {
          'request': DiscoverState.fromJson(fixture).nextPage!.toJson(),
          'content': {'type': 'Loading'},
        },
      ],
    });
    // Plain pumps (the trailing spinner never settles): one for the state
    // pull to resolve, one for the rebuild.
    await tester.pump();
    await tester.pump();
    await tester.drag(find.byType(GridView), const Offset(0, -400));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect([
      for (final action in core.dispatched)
        if (action.action['action'] == 'CatalogWithFilters') action,
    ], hasLength(1));
  });

  testWidgets(
    'shows a spinner while the first page loads and the error otherwise',
    (tester) async {
      Map<String, dynamic> loading(Map<String, dynamic> content) => {
        'selected': {'request': topMovies.toJson()},
        'selectable': {
          'types': [],
          'catalogs': [],
          'extra': [],
          'nextPage': null,
        },
        'catalog': [
          {'request': topMovies.toJson(), 'content': content},
        ],
      };
      final core = FakeCoreClient(
        state: {
          CoreField.discover: loading({'type': 'Loading'}),
        },
      );
      await tester.pumpWidget(harness(core));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      core.setState(
        CoreField.discover,
        loading({
          'type': 'Err',
          'content': {
            'type': 'Env',
            'content': {'message': 'HTTP 503'},
          },
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('HTTP 503'), findsOneWidget);
      expect(find.text('Could not load this catalog'), findsOneWidget);
    },
  );
}
