import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/downloads/downloads_screen.dart';
import 'package:xtremio/features/library/library_screen.dart';
import 'package:xtremio/widgets/library_item_tile.dart';

import '../support/fake_core_client.dart';
import '../support/fake_downloads_client.dart';
import '../support/fixtures.dart';

void main() {
  // The scopes sit above MaterialApp, as in the app, so pushed routes see
  // them.
  Widget harness(FakeCoreClient core, {DownloadsClient? downloads}) =>
      CoreScope(
        client: core,
        child: DownloadsScope(
          client: downloads ?? FakeDownloadsClient(),
          child: const MaterialApp(home: LibraryScreen()),
        ),
      );

  FakeCoreClient fakeCore({
    Map<String, dynamic>? library,
    Map<String, dynamic>? ctx,
  }) => FakeCoreClient(
    state: {
      CoreField.library: library ?? loadLibraryFixture(),
      CoreField.ctx: ctx ?? loadCtxLoggedOutFixture(),
    },
  );

  /// Phone width, below [LibraryScreen.wideBreakpoint].
  void useNarrowScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  List<CoreAction> loads(FakeCoreClient core) => [
    for (final action in core.dispatched)
      if (action.action['action'] == 'Load') action,
  ];

  List<CoreAction> ctxActions(FakeCoreClient core) => [
    for (final action in core.dispatched)
      if (action.action['action'] == 'Ctx') action,
  ];

  /// The fixture with its `catalog` replaced and the given `next_page`.
  Map<String, dynamic> libraryWith({
    required List<Map<String, dynamic>> items,
    LibraryRequest? nextPage,
  }) {
    final fixture = loadLibraryFixture();
    final selectable = {
      ...fixture['selectable'] as Map<String, dynamic>,
      'next_page': nextPage == null ? null : {'request': nextPage.toJson()},
    };
    return {...fixture, 'selectable': selectable, 'catalog': items};
  }

  Map<String, dynamic> item(
    int n, {
    String type = 'movie',
    int timeOffset = 0,
    int duration = 0,
    int timesWatched = 0,
    String? videoId,
  }) => {
    '_id': 'tt$n',
    '_ctime': '2026-09-02T20:51:12.897365027Z',
    '_mtime': '2026-09-02T20:51:12.897372691Z',
    'name': 'Title $n',
    'type': type,
    'poster': null,
    'posterShape': 'poster',
    'removed': false,
    'temp': false,
    'behaviorHints': {
      'defaultVideoId': null,
      'featuredVideoId': null,
      'hasScheduledVideos': false,
    },
    'state': {
      'lastWatched': null,
      'timeWatched': 0,
      'timeOffset': timeOffset,
      'overallTimeWatched': 0,
      'timesWatched': timesWatched,
      'flaggedWatched': 0,
      'duration': duration,
      'video_id': videoId,
      'watched': null,
      'noNotif': false,
    },
  };

  testWidgets('loads every type on mount, renders the fixture, unloads', (
    tester,
  ) async {
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    expect(core.dispatched, hasLength(1));
    expect(core.dispatched.single.field, CoreField.library);
    expect(
      core.dispatched.single.action,
      CoreActions.loadLibrary(const LibraryRequest()).action,
    );
    final request =
        core.dispatched.single.action['args']['args']['request']
            as Map<String, dynamic>;
    expect(request['type'], isNull);

    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Lanterns'), findsOneWidget);
    expect(find.text('The Whisper Man'), findsOneWidget);
    expect(find.byType(LibraryItemTile), findsNWidgets(2));
    // Nothing was played yet: no progress bar, no watched mark.
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.check), findsNothing);

    // Leaving unloads the library field only, never the whole model.
    await tester.pumpWidget(const SizedBox());
    expect(core.dispatched, hasLength(2));
    expect(core.dispatched.last.field, CoreField.library);
    expect(
      core.dispatched.last.action,
      CoreActions.unload(CoreField.library).action,
    );
    expect(core.dispatched.where((a) => a.field == null), isEmpty);
  });

  testWidgets('renders the type segments and the sort menu', (tester) async {
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    final segments = find.byType(SegmentedButton<int>);
    expect(segments, findsOneWidget);
    for (final label in ['All', 'Movies', 'Series']) {
      expect(
        find.descendant(of: segments, matching: find.text(label)),
        findsOneWidget,
      );
    }
    expect(tester.widget<SegmentedButton<int>>(segments).selected, {0});

    final menu = find.byType(DropdownMenu<int>);
    expect(menu, findsOneWidget);
    expect(
      find.descendant(of: menu, matching: find.text('Sort')),
      findsWidgets,
    );
    expect(
      find.descendant(of: menu, matching: find.text('Last watched')),
      findsWidgets,
    );
    await tester.tap(menu);
    await tester.pumpAndSettle();
    for (final label in [
      'Name (A–Z)',
      'Name (Z–A)',
      'Times watched',
      'Watched',
      'Not watched',
    ]) {
      expect(
        find.descendant(
          of: find.byType(MenuItemButton),
          matching: find.text(label),
        ),
        findsWidgets,
      );
    }
  });

  testWidgets('selecting a type dispatches its request verbatim', (
    tester,
  ) async {
    final fixture = loadLibraryFixture();
    final core = fakeCore(library: fixture);
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();

    final types = LibraryState.fromJson(fixture).selectable.types;
    expect(types[1].type, 'movie');
    expect(loads(core), hasLength(2));
    expect(loads(core).last.field, CoreField.library);
    expect(
      loads(core).last.action,
      CoreActions.loadLibrary(types[1].request).action,
    );
    expect(
      loads(core).last.action['args']['args']['request'],
      (fixture['selectable']['types'] as List)[1]['request'],
    );
    // The selection is the engine's to make.
    expect(
      tester
          .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
          .selected,
      {0},
    );
  });

  testWidgets('choosing a sort dispatches its request verbatim', (
    tester,
  ) async {
    final fixture = loadLibraryFixture();
    final core = fakeCore(library: fixture);
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownMenu<int>));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(MenuItemButton),
            matching: find.text('Name (A–Z)'),
          )
          .last,
    );
    await tester.pumpAndSettle();

    final sorts = LibraryState.fromJson(fixture).selectable.sorts;
    expect(sorts[1].sort, LibrarySort.name);
    expect(loads(core), hasLength(2));
    expect(
      loads(core).last.action,
      CoreActions.loadLibrary(sorts[1].request).action,
    );
    expect(
      loads(core).last.action['args']['args']['request'],
      (fixture['selectable']['sorts'] as List)[1]['request'],
    );
  });

  testWidgets('re-selecting the current type or sort dispatches nothing', (
    tester,
  ) async {
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownMenu<int>));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(MenuItemButton),
            matching: find.text('Last watched'),
          )
          .last,
    );
    await tester.pumpAndSettle();

    expect(loads(core), hasLength(1));
  });

  testWidgets('on a phone the types are chips and still dispatch', (
    tester,
  ) async {
    useNarrowScreen(tester);
    final fixture = loadLibraryFixture();
    final core = fakeCore(library: fixture);
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    expect(find.byType(SegmentedButton<int>), findsNothing);
    final chips = find.byType(ChoiceChip);
    expect(chips, findsNWidgets(3));
    expect(tester.widget<ChoiceChip>(chips.at(0)).selected, isTrue);

    await tester.tap(find.text('Series'));
    await tester.pumpAndSettle();

    final types = LibraryState.fromJson(fixture).selectable.types;
    expect(loads(core), hasLength(2));
    expect(
      loads(core).last.action,
      CoreActions.loadLibrary(types[2].request).action,
    );
  });

  /// The engine's state after the last title of [type] was removed while
  /// that type was the filter: nothing matches, but the library still has
  /// [remainingTypes], so `selectable.types` offers All plus those (none
  /// selected, as `selectable_update` recomputes them from the items left).
  Map<String, dynamic> emptyFilter(
    String type, {
    List<String> remainingTypes = const ['series'],
  }) {
    final fixture = loadLibraryFixture();
    final request = LibraryRequest(type: type);
    Map<String, dynamic> option(String? type) => {
      'type': type,
      'selected': false,
      'request': LibraryRequest(type: type).toJson(),
    };
    return {
      ...fixture,
      'selected': {'request': request.toJson()},
      'selectable': {
        ...fixture['selectable'] as Map<String, dynamic>,
        'types': [
          option(null),
          for (final type in remainingTypes) option(type),
        ],
      },
      'catalog': <Object>[],
    };
  }

  group('an empty type filter', () {
    testWidgets('keeps the filter row and offers All', (tester) async {
      final fixture = emptyFilter('movie');
      final core = fakeCore(library: fixture);
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();

      expect(find.text('No movies in your library'), findsOneWidget);
      expect(find.text('Your library is empty'), findsNothing);
      expect(find.byType(LibraryItemTile), findsNothing);
      final segments = find.byType(SegmentedButton<int>);
      expect(segments, findsOneWidget);
      for (final label in ['All', 'Series']) {
        expect(
          find.descendant(of: segments, matching: find.text(label)),
          findsOneWidget,
        );
      }
      expect(find.byType(DropdownMenu<int>), findsOneWidget);
      // The anonymous library is not empty, so the inline hint stays.
      expect(find.textContaining('Sign in to sync'), findsOneWidget);

      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();

      final types = LibraryState.fromJson(fixture).selectable.types;
      expect(types[0].type, isNull);
      expect(loads(core), hasLength(2));
      expect(loads(core).last.field, CoreField.library);
      expect(
        loads(core).last.action,
        CoreActions.loadLibrary(types[0].request).action,
      );
      expect(
        loads(core).last.action['args']['args']['request'],
        (fixture['selectable']['types'] as List)[0]['request'],
      );
    });

    testWidgets('on a phone the chips stay too, and the label follows the '
        'type', (tester) async {
      useNarrowScreen(tester);
      final fixture = emptyFilter('tv', remainingTypes: ['movie', 'series']);
      final core = fakeCore(library: fixture);
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();

      expect(find.text('No TV in your library'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNWidgets(3));
      for (final chip in tester.widgetList<ChoiceChip>(
        find.byType(ChoiceChip),
      )) {
        expect(chip.selected, isFalse);
      }

      await tester.tap(find.text('Series'));
      await tester.pumpAndSettle();

      final types = LibraryState.fromJson(fixture).selectable.types;
      expect(loads(core), hasLength(2));
      expect(
        loads(core).last.action,
        CoreActions.loadLibrary(types[2].request).action,
      );
    });
  });

  testWidgets('shows progress, episode and watched mark per item', (
    tester,
  ) async {
    final core = fakeCore(
      library: libraryWith(
        items: [
          item(
            1,
            type: 'series',
            timeOffset: 600000,
            duration: 2400000,
            videoId: 'tt1:2:3',
          ),
          item(2, timesWatched: 1),
        ],
      ),
    );
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    final progress = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(progress.value, closeTo(0.25, 1e-9));
    expect(find.text('S2E3'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.byType(Badge), findsNothing);
  });

  testWidgets('tapping an item opens its details at the current video', (
    tester,
  ) async {
    final core = fakeCore(
      library: libraryWith(
        items: [
          item(
            1,
            type: 'series',
            timeOffset: 600000,
            duration: 2400000,
            videoId: 'tt1:2:3',
          ),
        ],
      ),
    );
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Title 1'));
    // Plain pumps: the details screen spins until its meta arrives.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    final details = tester.widget<MetaDetailsScreen>(
      find.byType(MetaDetailsScreen),
    );
    expect(details.type, 'series');
    expect(details.id, 'tt1');
    expect(details.videoId, 'tt1:2:3');
    final load = core.dispatched.firstWhere(
      (a) => a.field == CoreField.metaDetails,
    );
    expect(
      load.action,
      CoreActions.loadMetaDetails(
        type: 'series',
        id: 'tt1',
        videoId: 'tt1:2:3',
      ).action,
    );
  });

  group('long-press menu', () {
    Future<void> openMenu(WidgetTester tester, String name) async {
      await tester.longPress(find.text(name));
      await tester.pumpAndSettle();
    }

    testWidgets('Remove dispatches RemoveFromLibrary with the id', (
      tester,
    ) async {
      final core = fakeCore();
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();

      await openMenu(tester, 'Lanterns');
      await tester.tap(find.text('Remove from library'));
      await tester.pumpAndSettle();

      expect(ctxActions(core), hasLength(1));
      expect(ctxActions(core).single.field, CoreField.ctx);
      expect(
        ctxActions(core).single.action,
        CoreActions.removeFromLibrary('tt26545992').action,
      );
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('Mark as watched flips on the item state', (tester) async {
      final core = fakeCore(
        library: libraryWith(items: [item(1), item(2, timesWatched: 1)]),
      );
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();

      await openMenu(tester, 'Title 1');
      expect(find.text('Mark as not watched'), findsNothing);
      await tester.tap(find.text('Mark as watched'));
      await tester.pumpAndSettle();
      expect(
        ctxActions(core).last.action,
        CoreActions.libraryItemMarkAsWatched('tt1', watched: true).action,
      );

      await openMenu(tester, 'Title 2');
      await tester.tap(find.text('Mark as not watched'));
      await tester.pumpAndSettle();
      expect(
        ctxActions(core).last.action,
        CoreActions.libraryItemMarkAsWatched('tt2', watched: false).action,
      );
      expect(ctxActions(core).last.action['args']['args'], {
        'id': 'tt2',
        'is_watched': false,
      });
    });

    testWidgets('Rewind and notifications dispatch their Ctx actions', (
      tester,
    ) async {
      final core = fakeCore();
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();

      await openMenu(tester, 'The Whisper Man');
      await tester.tap(find.text('Rewind'));
      await tester.pumpAndSettle();
      expect(
        ctxActions(core).last.action,
        CoreActions.rewindLibraryItem('tt11561116').action,
      );

      await openMenu(tester, 'The Whisper Man');
      expect(find.text('Enable notifications'), findsNothing);
      await tester.tap(find.text('Disable notifications'));
      await tester.pumpAndSettle();
      expect(
        ctxActions(core).last.action,
        CoreActions.toggleLibraryItemNotifications(
          'tt11561116',
          disabled: true,
        ).action,
      );
      expect(ctxActions(core).last.action['args']['args'], [
        'tt11561116',
        true,
      ]);
    });
  });

  group('paging', () {
    testWidgets('does not ask for more while next_page is null', (
      tester,
    ) async {
      final core = fakeCore(
        library: libraryWith(items: [for (var i = 0; i < 60; i++) item(i)]),
      );
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(GridView), const Offset(0, -6000));
      await tester.pumpAndSettle();

      expect(core.dispatched, hasLength(1));
    });

    testWidgets('loads the next page once near the end, replaces the list', (
      tester,
    ) async {
      const nextPage = LibraryRequest(page: 2);
      final core = fakeCore(
        library: libraryWith(
          items: [for (var i = 0; i < 60; i++) item(i)],
          nextPage: nextPage,
        ),
      );
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();
      // Nothing near the top of a long grid.
      expect(core.dispatched, hasLength(1));

      await tester.drag(find.byType(GridView), const Offset(0, -6000));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(GridView), const Offset(0, -400));
      await tester.pumpAndSettle();

      List<CoreAction> nextPages() => [
        for (final action in core.dispatched)
          if (action.action['action'] == 'LibraryWithFilters') action,
      ];
      expect(nextPages(), hasLength(1));
      expect(nextPages().single.field, CoreField.library);
      expect(
        nextPages().single.action,
        CoreActions.loadLibraryNextPage().action,
      );

      // The engine publishes the cumulative list (no more pages): the grid
      // shows every item and asks for nothing else.
      core.setState(
        CoreField.library,
        libraryWith(items: [for (var i = 0; i < 70; i++) item(i)]),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(GridView), const Offset(0, -6000));
      await tester.pumpAndSettle();
      expect(find.text('Title 69'), findsOneWidget);
      expect(find.text('Title 0'), findsNothing, reason: 'scrolled away');
      expect(nextPages(), hasLength(1));
    });
  });

  group('account', () {
    testWidgets('an empty anonymous library asks to sign in', (tester) async {
      final core = fakeCore(library: libraryWith(items: []));
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();

      expect(find.text('Your library is empty'), findsOneWidget);
      expect(find.textContaining('Sign in to sync'), findsOneWidget);
      expect(find.byType(SegmentedButton<int>), findsNothing);
      expect(find.byIcon(Icons.sync), findsNothing);
    });

    testWidgets('an empty signed-in library has no sign-in hint', (
      tester,
    ) async {
      final core = fakeCore(
        library: libraryWith(items: []),
        ctx: loadCtxLoggedInFixture(),
      );
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();

      expect(find.text('Your library is empty'), findsOneWidget);
      expect(find.textContaining('Sign in to sync'), findsNothing);
      expect(find.byIcon(Icons.sync), findsOneWidget);
    });

    testWidgets('a non-empty anonymous library shows the hint inline', (
      tester,
    ) async {
      final core = fakeCore();
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();

      expect(find.textContaining('Sign in to sync'), findsOneWidget);
      expect(find.byIcon(Icons.sync), findsNothing);
      expect(find.text('Lanterns'), findsOneWidget);
    });

    testWidgets('a spinner shows before the first state arrives', (
      tester,
    ) async {
      final core = FakeCoreClient(
        state: {
          CoreField.library: {
            'selected': null,
            'selectable': {'types': [], 'sorts': [], 'next_page': null},
            'catalog': [],
          },
          CoreField.ctx: loadCtxLoggedOutFixture(),
        },
      );
      await tester.pumpWidget(harness(core));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Your library is empty'), findsNothing);
    });

    testWidgets(
      'Sync now dispatches SyncLibraryWithAPI and waits for the plan',
      (tester) async {
        final core = fakeCore(ctx: loadCtxLoggedInFixture());
        await tester.pumpWidget(harness(core));
        await tester.pumpAndSettle();

        expect(find.textContaining('Sign in to sync'), findsNothing);
        await tester.tap(find.byIcon(Icons.sync));
        await tester.pump();

        expect(ctxActions(core), hasLength(1));
        expect(ctxActions(core).single.field, CoreField.ctx);
        expect(
          ctxActions(core).single.action,
          CoreActions.syncLibraryWithAPI().action,
        );
        expect(find.byIcon(Icons.sync), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        // An unrelated error leaves the indicator alone.
        core.emit(
          const RuntimeCoreEvent({
            'event': 'Error',
            'args': {
              'error': {'type': 'Other', 'code': 2, 'message': 'x'},
              'source': {'event': 'LibraryItemRemoved', 'args': {}},
            },
          }),
        );
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        core.emit(
          const RuntimeCoreEvent({
            'event': 'LibrarySyncWithAPIPlanned',
            'args': {'uid': 'fake_user_id', 'plan': <Object>[]},
          }),
        );
        await tester.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byIcon(Icons.sync), findsOneWidget);
      },
    );

    testWidgets('a failed sync clears the indicator too', (tester) async {
      final core = fakeCore(ctx: loadCtxLoggedInFixture());
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.sync));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      core.emit(
        const RuntimeCoreEvent({
          'event': 'Error',
          'args': {
            'error': {'type': 'Other', 'code': 1, 'message': 'not logged in'},
            'source': {
              'event': 'LibrarySyncWithAPIPlanned',
              'args': {'uid': null, 'plan': <Object>[]},
            },
          },
        }),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.sync), findsOneWidget);
    });
  });

  testWidgets('the Downloaded chip opens what is kept on the device', (
    tester,
  ) async {
    useNarrowScreen(tester);
    final core = fakeCore();
    final downloads = FakeDownloadsClient();
    addTearDown(downloads.dispose);
    await tester.pumpWidget(harness(core, downloads: downloads));
    await tester.pumpAndSettle();
    final before = core.dispatched.length;

    await tester.tap(find.widgetWithText(ActionChip, 'Downloaded'));
    await tester.pumpAndSettle();

    expect(find.byType(DownloadsScreen), findsOneWidget);
    expect(
      core.dispatched,
      hasLength(before),
      reason: 'nothing in the engine knows about downloads',
    );
  });
}
