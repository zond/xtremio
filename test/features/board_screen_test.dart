import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/addons/addons_screen.dart';
import 'package:xtremio/features/board/board_screen.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/discover/discover_screen.dart';
import 'package:xtremio/widgets/poster_tile.dart';

import '../support/fake_core_client.dart';
import '../support/fixtures.dart';

/// A [TextScaler] that is whatever [scale] says, however unlike a
/// multiplication that is.
@immutable
class _TableTextScaler extends TextScaler {
  const _TableTextScaler(this._table);

  final double Function(double) _table;

  @override
  double scale(double fontSize) => _table(fontSize);

  @override
  double get textScaleFactor => scale(14) / 14;
}

void main() {
  // CoreScope sits above MaterialApp, as in the app, so pushed routes see it.
  Widget harness(FakeCoreClient core) => CoreScope(
    client: core,
    child: const MaterialApp(home: BoardScreen()),
  );

  FakeCoreClient fakeCore({
    Map<String, dynamic>? board,
    Map<String, dynamic>? continueWatching,
  }) => FakeCoreClient(
    state: {
      CoreField.board: board ?? loadBoardFixture(),
      CoreField.continueWatchingPreview:
          continueWatching ?? loadContinueWatchingFixture(),
    },
  );

  /// The board fixture's first catalog is Cinemeta's Popular movies.
  String firstPopularName() =>
      CatalogsWithExtraState.fromJson(loadBoardFixture())
          .rows
          .first
          .items
          .first
          .name;

  List<CoreAction> rangeDispatches(FakeCoreClient core) => [
    for (final action in core.dispatched)
      if (action.field == CoreField.board &&
          action.action['action'] == 'CatalogsWithExtra')
        action,
  ];

  ({int start, int end}) rangeOf(CoreAction action) {
    final args = action.action['args']['args'] as Map<String, dynamic>;
    return (start: args['start'] as int, end: args['end'] as int);
  }

  /// Sets [content] on the first page of catalog [index] of a board fixture.
  Map<String, dynamic> boardWithPage(int index, Map<String, dynamic> content) {
    final board = loadBoardFixture();
    final catalogs = board['catalogs'] as List<dynamic>;
    ((catalogs[index] as List<dynamic>)[0] as Map<String, dynamic>)['content'] =
        content;
    return board;
  }

  testWidgets('loads the board, then the first rows, and renders them', (
    tester,
  ) async {
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    expect(core.dispatched.first.field, CoreField.board);
    expect(core.dispatched.first.action, CoreActions.loadBoard().action);
    final ranges = rangeDispatches(core);
    expect(ranges, hasLength(1));
    expect(rangeOf(ranges.single).start, 0);
    expect(rangeOf(ranges.single).end, greaterThanOrEqualTo(0));
    expect(
      ranges.single.action,
      CoreActions.loadBoardRange(0, rangeOf(ranges.single).end).action,
    );

    // Row headers come from catalogLabels, tiles from the Ready pages.
    expect(find.text('Continue watching'), findsOneWidget);
    expect(find.text('Popular'), findsWidgets);
    expect(find.text('Cinemeta · movie'), findsWidgets);
    expect(find.text(firstPopularName()), findsOneWidget);

    // Leaving unloads the board field only, never the whole model.
    await tester.pumpWidget(const SizedBox());
    expect(core.dispatched.last.field, CoreField.board);
    expect(
      core.dispatched.last.action,
      CoreActions.unload(CoreField.board).action,
    );
    expect(core.dispatched.where((a) => a.field == null), isEmpty);
  });

  testWidgets('continue watching shows progress and opens the video', (
    tester,
  ) async {
    final core = fakeCore();
    core.setState(CoreField.metaDetails, loadMetaDetailsFixture());
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    expect(find.text('Night of the Living Dead'), findsOneWidget);
    final progress = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(progress.value, closeTo(60000 / 5760000, 1e-9));
    expect(find.byType(Badge), findsNothing);

    await tester.tap(find.text('Night of the Living Dead'));
    await tester.pumpAndSettle();

    expect(find.byType(MetaDetailsScreen), findsOneWidget);
    final load = core.dispatched.firstWhere(
      (a) => a.field == CoreField.metaDetails,
    );
    expect(
      load.action,
      CoreActions.loadMetaDetails(
        type: 'movie',
        id: 'tt0063350',
        videoId: 'tt0063350',
      ).action,
    );
  });

  testWidgets('continue watching never shows the watched mark', (tester) async {
    // A series with one finished episode and the next one in progress is
    // watched (timesWatched > 0) but sits in the row to be resumed.
    final preview = loadContinueWatchingFixture();
    final item =
        (preview['items'] as List<dynamic>).single as Map<String, dynamic>;
    (item['state'] as Map<String, dynamic>)['timesWatched'] = 1;
    final core = fakeCore(continueWatching: preview);
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    expect(find.text('Night of the Living Dead'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing);
  });

  testWidgets('the continue watching row disappears when the list empties', (
    tester,
  ) async {
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();
    expect(find.text('Continue watching'), findsOneWidget);

    core.setState(CoreField.continueWatchingPreview, {'items': <Object>[]});
    await tester.pumpAndSettle();
    expect(find.text('Continue watching'), findsNothing);
    expect(find.text('Popular'), findsWidgets);
  });

  testWidgets('a catalog that came back empty is not shown', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // Both Cinemeta "Popular" rows (movies, series) are Ready in the fixture.
    final core = fakeCore(continueWatching: {'items': <Object>[]});
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();
    expect(find.text('Popular'), findsNWidgets(2));
    expect(find.text('Cinemeta · series'), findsNWidgets(2));

    core.setState(
      CoreField.board,
      boardWithPage(1, {
        'type': 'Err',
        'content': {'type': 'EmptyContent'},
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('Popular'), findsOneWidget);
    expect(find.text('Cinemeta · series'), findsOneWidget);
    expect(find.text('EmptyContent'), findsNothing);
  });

  testWidgets('a failed catalog keeps its row with the error', (tester) async {
    final core = fakeCore(
      continueWatching: {'items': <Object>[]},
      board: boardWithPage(0, {
        'type': 'Err',
        'content': {
          'type': 'Env',
          'content': {'code': 1, 'message': 'HTTP 503'},
        },
      }),
    );
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    expect(find.text('HTTP 503'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
    expect(find.text(firstPopularName()), findsNothing);
  });

  testWidgets('tapping a poster opens its details', (tester) async {
    final core = fakeCore(continueWatching: {'items': <Object>[]});
    core.setState(CoreField.metaDetails, loadMetaDetailsFixture());
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    final first = CatalogsWithExtraState.fromJson(loadBoardFixture())
        .rows
        .first
        .items
        .first;
    await tester.tap(find.text(first.name));
    // The field holds another title (the movie fixture), which the new
    // screen ignores: it shows a spinner (never settling) until its own
    // state arrives, so pump the route transition by hand.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(MetaDetailsScreen), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Night of the Living Dead'), findsNothing);
    final load = core.dispatched.firstWhere(
      (a) => a.field == CoreField.metaDetails,
    );
    expect(
      load.action,
      CoreActions.loadMetaDetails(type: first.type, id: first.id).action,
    );
  });

  testWidgets('"See all" opens the catalog in Discover', (tester) async {
    // Trim the first row so its trailing tile is built without scrolling.
    final board = loadBoardFixture();
    final firstPage =
        ((board['catalogs'] as List<dynamic>)[0] as List<dynamic>)[0]
            as Map<String, dynamic>;
    final items =
        (firstPage['content'] as Map<String, dynamic>)['content']
            as List<dynamic>;
    items.removeRange(2, items.length);
    final core = fakeCore(
      board: board,
      continueWatching: {'items': <Object>[]},
    );
    core.setState(CoreField.discover, loadDiscoverFixture());
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    await tester.tap(find.text('See all').first);
    await tester.pumpAndSettle();

    expect(find.byType(DiscoverScreen), findsOneWidget);
    final request = CatalogsWithExtraState.fromJson(board)
        .rows
        .first
        .firstRequest;
    final load = core.dispatched.firstWhere(
      (a) => a.field == CoreField.discover,
    );
    expect(load.action, CoreActions.loadDiscover(request).action);
    expect(request.path.id, 'top');
  });

  testWidgets('scrolling down widens the requested range once, never back', (
    tester,
  ) async {
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();
    final initial = rangeOf(rangeDispatches(core).single);
    final rowCount = CatalogsWithExtraState.fromJson(loadBoardFixture())
        .visibleRows
        .length;
    expect(initial.end, lessThan(rowCount - 1), reason: 'room to scroll');

    // Small scroll within the already requested rows: nothing new.
    await tester.drag(
      find.byKey(const Key('board-rows')),
      const Offset(0, -20),
    );
    await tester.pumpAndSettle();
    await tester.pump(BoardScreen.scrollDebounce * 2);
    expect(rangeDispatches(core), hasLength(1));

    await tester.drag(
      find.byKey(const Key('board-rows')),
      const Offset(0, -5000),
    );
    await tester.pumpAndSettle();
    await tester.pump(BoardScreen.scrollDebounce * 2);

    final ranges = rangeDispatches(core);
    expect(ranges, hasLength(2));
    final widened = rangeOf(ranges.last);
    expect(widened.start, 0, reason: 'the union keeps the top rows');
    expect(widened.end, rowCount - 1);
    expect(widened.end, greaterThan(initial.end));

    // Scrolling back up requests nothing: everything is already covered.
    await tester.drag(
      find.byKey(const Key('board-rows')),
      const Offset(0, 5000),
    );
    await tester.pumpAndSettle();
    await tester.pump(BoardScreen.scrollDebounce * 2);
    expect(rangeDispatches(core), hasLength(2));
  });

  testWidgets('shows a spinner until the board arrives, then the empty state', (
    tester,
  ) async {
    final core = FakeCoreClient(
      state: {
        CoreField.board: {'selected': null, 'catalogs': <Object>[]},
        CoreField.continueWatchingPreview: {'items': <Object>[]},
      },
    );
    await tester.pumpWidget(harness(core));
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // A profile without a single catalog: the engine plans nothing.
    core.setState(CoreField.board, {
      'selected': {'type': null, 'extra': <Object>[]},
      'catalogs': <Object>[],
      'catalogLabels': <Object>[],
    });
    await tester.pumpAndSettle();
    expect(find.text('No catalogs'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // The way out of an empty board is the Addons screen.
    // (No addon state in this fake, so its spinner never settles.)
    await tester.tap(find.text('Browse addons'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(AddonsScreen), findsOneWidget);
  });

  /// A [TextScaler] shaped like the font-scale tables Android 14 and later
  /// use: body sizes are lifted hard, the curve flattens as the size grows,
  /// and it is anchored so that 100sp still maps to 100dp. A scaler like
  /// this is the reason a layout may not probe the scale at a large round
  /// number and call the answer "the text scale".
  const from = <double>[8, 10, 12, 14, 18, 20, 24, 30, 100];
  const to = <double>[16, 20, 24, 26, 30, 32, 34, 38, 100];

  double nonLinearScale(double fontSize) {
    for (var i = 1; i < from.length; i++) {
      if (fontSize > from[i]) continue;
      final t = (fontSize - from[i - 1]) / (from[i] - from[i - 1]);
      return to[i - 1] + t * (to[i] - to[i - 1]);
    }
    return fontSize;
  }

  Widget scaledHarness(FakeCoreClient core, TextScaler scaler) => CoreScope(
    client: core,
    child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: scaler),
        child: child!,
      ),
      home: const BoardScreen(),
    ),
  );

  testWidgets('the row header grows with a non-linear text scale', (
    tester,
  ) async {
    // The header is a fixed box of text, so it has to be measured against
    // the scale of the text it holds -- 16sp here, lifted to 28 -- and not
    // against the scaler's behaviour at some far larger size, which the
    // Android tables deliberately leave at 1.0.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = fakeCore(continueWatching: {'items': <Object>[]});
    await tester.pumpWidget(
      scaledHarness(core, _TableTextScaler(nonLinearScale)),
    );
    await tester.pumpAndSettle();

    final rows = tester.getTopLeft(find.byKey(const Key('board-rows'))).dy;
    final firstTile = tester.getTopLeft(find.byType(PosterTile).first).dy;
    // 16sp is drawn at 28: the header box is 1.75x its unscaled height.
    expect(firstTile - rows, closeTo(52 * 28 / 16, 0.01));
  });

  testWidgets('the posters keep their size when the text scale grows', (
    tester,
  ) async {
    // The row is what the list scrolls by, so growing the header and the
    // caption inside a fixed extent takes the difference out of the poster
    // -- and past about 2.1x takes it below zero, which is not a cramped
    // layout but a `NOT NORMALIZED` constraints failure. The extent grows
    // with the text instead.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Future<Size> posterAt(double scale) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      await tester.pumpWidget(
        KeyedSubtree(
          key: ValueKey(scale),
          child: harness(fakeCore(continueWatching: {'items': <Object>[]})),
        ),
      );
      await tester.pumpAndSettle();
      return tester.getSize(find.byType(PosterImage).first);
    }

    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final unscaled = await posterAt(1);
    final scaled = await posterAt(2.5);

    expect(tester.takeException(), isNull);
    // The width follows from the height the layout reserved for the image,
    // so an unchanged width is the reservation holding; the drawn image is
    // never smaller, since the captions ask for less than was set aside.
    expect(scaled.width, unscaled.width);
    expect(scaled.height, greaterThanOrEqualTo(unscaled.height));
    final list = tester.widget<ListView>(find.byKey(const Key('board-rows')));
    expect(list.itemExtent, greaterThan(BoardScreen.rowExtentFor(400)));
  });

  testWidgets('rows are shorter on phone widths', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = fakeCore(continueWatching: {'items': <Object>[]});
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    final list = tester.widget<ListView>(find.byKey(const Key('board-rows')));
    expect(list.itemExtent, BoardScreen.rowExtentFor(400));
    expect(
      BoardScreen.rowExtentFor(400),
      lessThan(BoardScreen.rowExtentFor(1000)),
    );
    expect(find.text('Popular'), findsWidgets);
  });
}
