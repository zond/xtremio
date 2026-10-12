import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/discover/catalog_rows.dart';
import 'package:xtremio/features/for_you/for_you_controller.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/tv_density.dart';
import 'package:xtremio/widgets/poster_tile.dart';

import '../support/fake_core_client.dart';
import '../support/fake_prefs_client.dart';
import '../support/fixtures.dart';
import '../support/library_items.dart';
import '../support/tv.dart';

/// A catalogue and a "More like this" server in a map, counting what they
/// are asked and how much of it at once.
class _FakeAsk {
  /// Source id to what the server answers for it.
  final Map<String, List<SuggestedTitle>> answers = {};

  /// Series id to its episodes.
  final Map<String, List<ShowEpisode>> shows = {};

  /// Title to the catalogue's item for it: `(id, year, type)`.
  final Map<String, (String, int, String)> catalogue = {};

  /// While set, every suggestion waits for it.
  Completer<void>? gate;

  final List<String> suggested = [];
  int inFlight = 0;
  int mostInFlight = 0;

  void suggests(String source, List<String> titles) => answers[source] = [
    for (final title in titles)
      SuggestedTitle(title: title, year: catalogue[title]?.$2 ?? 2000, why: ''),
  ];

  /// A title the catalogue knows, as `tt<n>`.
  void knows(
    String title,
    String id, {
    int year = 2000,
    String type = 'movie',
  }) => catalogue[title] = (id, year, type);

  ForYouAsk get ask => ForYouAsk(
    suggest: ({required type, required id}) async {
      suggested.add('$type/$id');
      inFlight++;
      if (inFlight > mostInFlight) mostInFlight = inFlight;
      try {
        await gate?.future;
        await Future<void>.delayed(Duration.zero);
        return answers[id] ?? const [];
      } finally {
        inFlight--;
      }
    },
    search: (type, query) async {
      final known = catalogue[query];
      if (known == null || known.$3 != type) return const [];
      return [
        {
          'id': known.$1,
          'imdb_id': known.$1,
          'type': known.$3,
          'name': query,
          'releaseInfo': '${known.$2}',
          'poster': null,
        },
      ];
    },
    episodes: (id) async => shows[id],
  );
}

void main() {
  late _FakeAsk fake;
  late AppPrefs prefs;
  late FakeCoreClient core;

  setUp(() => fake = _FakeAsk());

  Future<void> mount(
    WidgetTester tester, {
    required List<Map<String, dynamic>> library,
    Map<String, dynamic>? continueWatching,
    Map<String, dynamic> stored = const {},
    bool settle = true,
    DeviceProfile device = DeviceProfile.fallback,
  }) async {
    if (device.isTv) {
      useScreen(tester, tvSize);
    } else {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    prefs = AppPrefs(client: FakePrefsClient({...stored}));
    addTearDown(prefs.dispose);
    await prefs.load();
    core = FakeCoreClient(
      state: {
        CoreField.board: loadBoardFixture(),
        CoreField.continueWatchingPreview:
            continueWatching ?? {'items': <Object>[]},
        CoreField.libraryItems: libraryItemsState(library),
      },
    );
    await tester.pumpWidget(
      DeviceScope(
        profile: device,
        child: CoreScope(
          client: core,
          child: PrefsScope(
            prefs: prefs,
            child: ForYouScope(
              askFor: (_) => fake.ask,
              child: MaterialApp(
                builder: device.isTv ? TvMediaQuery.builder : null,
                home: Scaffold(
                  body: CatalogRows(defaultFocus: true, onSeeAll: (_) {}),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  /// The For you tiles' labels, in row order.
  List<String> tiles(WidgetTester tester) {
    final labels = <String>[];
    for (final element
        in find.bySemanticsLabel(RegExp(r'\. Because you ')).evaluate()) {
      labels.add((element.widget as Semantics).properties.label!);
    }
    return labels;
  }

  testWidgets('sources weigh what the rules say, and the row says why', (
    tester,
  ) async {
    fake
      ..knows('Shared', 'tt100')
      ..knows('From Saved', 'tt101')
      ..knows('From Watched', 'tt102')
      ..knows('Liked Pick', 'tt103')
      ..knows('Already Mine', 'tt-temp')
      ..knows('Hated', 'tt104')
      ..knows('Dismissed', 'tt105')
      ..knows('Invented', 'tt106', year: 1990)
      ..suggests('tt-saved', ['From Saved', 'Shared', 'Already Mine'])
      ..suggests('tt-watched', ['From Watched', 'Shared', 'Hated'])
      ..suggests('tt-both', ['Shared', 'Dismissed'])
      ..suggests('tt-liked', ['Liked Pick', 'Invented'])
      ..suggests('tt-disliked', ['Never Asked']);
    // A model naming a year the catalogue disagrees with: not this film.
    fake.answers['tt-liked']![1] = const SuggestedTitle(
      title: 'Invented',
      year: 2024,
      why: '',
    );
    final at = DateTime.utc(2026);
    await mount(
      tester,
      library: [
        libraryItemJson('tt-saved', name: 'Saved Film'),
        libraryItemJson(
          'tt-watched',
          name: 'Watched Film',
          temp: true,
          removed: true,
          timesWatched: 1,
          lastWatched: '2026-05-01T00:00:00Z',
        ),
        libraryItemJson('tt-both', name: 'Both Film', timesWatched: 1),
        libraryItemJson(
          'tt-liked',
          name: 'Liked Film',
          temp: true,
          removed: true,
          flaggedWatched: 1,
        ),
        libraryItemJson('tt-disliked', name: 'Hated Film', timesWatched: 1),
        libraryItemJson('tt-temp', temp: true, removed: true, timeOffset: 9),
      ],
      stored: {
        AppPrefs.facesKey: Faces.empty
            .marking('tt-liked', Face.like, at)
            .marking('tt-disliked', Face.dislike, at)
            .marking('tt104', Face.dislike, at)
            .marking('tt105', Face.dismissed, at)
            .toJson(),
      },
    );

    expect(find.text(CatalogRows.forYouTitle), findsOneWidget);
    expect(fake.suggested, isNot(contains('movie/tt-disliked')));
    expect(tiles(tester), [
      // 1 (saved) + 1 (watched) + 2 (both): the heaviest, named by both.
      'Shared. Because you watched Both Film',
      // Liked: 1 (watched) + 1 (happy face).
      'Liked Pick. Because you liked Liked Film',
      // Weight 1 each; the latest source first.
      'From Watched. Because you watched Watched Film',
      'From Saved. Because you saved Saved Film',
    ]);
    // The reason is a screen reader's, never drawn on the tile.
    expect(find.textContaining('Because you'), findsNothing);
    expect(find.text('Shared'), findsOneWidget);

    // The long press tells the whole of it: every source, strongest first,
    // in words, and the total. Shared: Both Film (watched and saved, 2),
    // then the two of weight 1, the later first.
    await tester.longPress(
      find.bySemanticsLabel('Shared. Because you watched Both Film'),
    );
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    String? below(String text) =>
        find.descendant(of: sheet, matching: find.text(text)).evaluate().isEmpty
        ? null
        : text;
    expect([
      below('Watched and saved: Both Film (×2)'),
      below('Watched: Watched Film'),
      below('Saved: Saved Film'),
      below('4 points'),
    ], everyElement(isNotNull));
    final tops = [
      for (final text in [
        'Watched and saved: Both Film (×2)',
        'Watched: Watched Film',
        'Saved: Saved Film',
        '4 points',
        CatalogRows.notInterestedLabel,
      ])
        tester
            .getTopLeft(find.descendant(of: sheet, matching: find.text(text)))
            .dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // One source: one line.
    await tester.longPress(
      find.bySemanticsLabel('From Saved. Because you saved Saved Film'),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: sheet, matching: find.textContaining(':')),
      findsOneWidget,
    );
    expect(find.text('Saved: Saved Film'), findsOneWidget);
    expect(find.text('1 point'), findsOneWidget);
  });

  testWidgets('sits under Continue watching and above the catalogs', (
    tester,
  ) async {
    final watching = loadContinueWatchingFixture();
    final first = ContinueWatchingState.fromJson(watching).items.first;
    fake
      ..knows('Pick', 'tt200')
      ..knows(first.name, first.id)
      ..suggests('tt-saved', [first.name, 'Pick']);
    // The Continue watching item is not in the library list given here, so
    // only its being on that row keeps it off this one.
    await mount(
      tester,
      library: [libraryItemJson('tt-saved', name: 'Saved')],
      continueWatching: watching,
    );
    expect(tiles(tester), ['Pick. Because you saved Saved']);
    final cw = tester.getTopLeft(find.text('Continue watching')).dy;
    final forYou = tester.getTopLeft(find.text(CatalogRows.forYouTitle)).dy;
    final catalog = tester
        .getTopLeft(
          find
              .text(
                CatalogsWithExtraState.fromJson(loadBoardFixture())
                    .rows
                    .first
                    .title,
              )
              .first,
        )
        .dy;
    expect(cw, lessThan(forYou));
    expect(forYou, lessThan(catalog));
  });

  testWidgets('hidden with nothing to show', (tester) async {
    await mount(tester, library: const []);
    expect(find.text(CatalogRows.forYouTitle), findsNothing);
    expect(fake.suggested, isEmpty);

    // Sources whose answers resolve to nothing are nothing too.
    await mount(tester, library: [libraryItemJson('tt-saved')]);
    expect(find.text(CatalogRows.forYouTitle), findsNothing);
    expect(fake.suggested, ['movie/tt-saved']);
  });

  testWidgets('a series watched through a season is a source, one watched '
      'part of the way is not', (tester) async {
    final show = [
      for (var s = 1; s <= 3; s++)
        for (var e = 1; e <= 4; e++) (id: 'tt9:$s:$e', season: s),
    ];
    fake
      ..shows['tt9'] = show
      ..shows['tt8'] = [
        for (final episode in show)
          (id: episode.id.replaceFirst('tt9', 'tt8'), season: episode.season),
      ]
      ..knows('Show Pick', 'tt300', type: 'series')
      ..knows('Other Pick', 'tt301', type: 'series')
      ..suggests('tt9', ['Show Pick'])
      ..suggests('tt8', ['Other Pick']);
    await mount(
      tester,
      library: [
        libraryItemJson(
          'tt9',
          type: 'series',
          name: 'Whole Season',
          temp: true,
          removed: true,
          watched: 'tt9:2:4:8:eJz7wAAAAeIA8Q==',
        ),
        libraryItemJson(
          'tt8',
          type: 'series',
          name: 'Part Season',
          temp: true,
          removed: true,
          watched: 'tt8:2:3:7:eJwrYAAAAOIAcQ==',
        ),
      ],
    );
    expect(tiles(tester), ['Show Pick. Because you watched Whole Season']);
    expect(fake.suggested, ['series/tt9']);
    expect(prefs.showEpisodes.of('tt9'), show, reason: 'kept per show');
  });

  testWidgets('a long press offers Not interested, which takes the title off '
      'and keeps it off', (tester) async {
    fake
      ..knows('Keep', 'tt400')
      ..knows('Drop', 'tt401')
      ..suggests('tt-saved', ['Drop', 'Keep']);
    await mount(tester, library: [libraryItemJson('tt-saved', name: 'S')]);
    expect(tiles(tester), [
      'Drop. Because you saved S',
      'Keep. Because you saved S',
    ]);

    await tester.longPress(find.bySemanticsLabel('Drop. Because you saved S'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tiles(tester), hasLength(2));

    await tester.longPress(find.bySemanticsLabel('Drop. Because you saved S'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(CatalogRows.notInterestedLabel));
    await tester.pumpAndSettle();
    expect(tiles(tester), ['Keep. Because you saved S']);
    expect(prefs.faces.of('tt401'), Face.dismissed);
  });

  testWidgets('the first run asks four at a time and shows the row as soon '
      'as the first answers are in', (tester) async {
    for (var i = 0; i < 10; i++) {
      fake
        ..knows('Pick $i', 'tt5$i')
        ..suggests('tt-s$i', ['Pick $i']);
    }
    fake.gate = Completer<void>();
    await mount(
      tester,
      library: [
        for (var i = 0; i < 10; i++)
          libraryItemJson(
            'tt-s$i',
            name: 'S$i',
            added: '2026-01-${(10 + i).toString().padLeft(2, '0')}T00:00:00Z',
          ),
      ],
      settle: false,
    );
    await tester.pump();
    await tester.pump();
    expect(fake.inFlight, ForYouController.concurrency);
    expect(find.text(CatalogRows.forYouTitle), findsNothing);

    // The first four answer; the row is up before the other six have.
    fake.gate!.complete();
    fake.gate = Completer<void>();
    for (
      var i = 0;
      i < 50 && find.text(CatalogRows.forYouTitle).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(find.text(CatalogRows.forYouTitle), findsOneWidget);
    expect(fake.inFlight, greaterThan(0), reason: 'the rest still out');
    expect(tiles(tester), isNotEmpty);
    expect(tiles(tester).length, lessThan(10));

    fake.gate!.complete();
    fake.gate = null;
    await tester.pumpAndSettle();
    expect(tiles(tester), hasLength(10));
    expect(fake.mostInFlight, ForYouController.concurrency);
  });

  testWidgets('a kept row is drawn at once and not worked out again the same '
      'day; a change of sources works it out again', (tester) async {
    fake
      ..knows('Pick', 'tt600')
      ..knows('New Pick', 'tt601')
      ..suggests('tt-saved', ['Pick'])
      ..suggests('tt-new', ['New Pick']);
    final library = [libraryItemJson('tt-saved', name: 'S')];
    await mount(tester, library: library);
    final kept = prefs.forYou;
    expect(kept, isNotNull);

    fake.suggested.clear();
    await mount(tester, library: library, stored: {AppPrefs.forYouKey: kept});
    expect(tiles(tester), ['Pick. Because you saved S']);
    expect(fake.suggested, isEmpty, reason: 'the same sources, the same day');

    core.setState(
      CoreField.libraryItems,
      libraryItemsState([
        ...library,
        libraryItemJson('tt-new', name: 'N', added: '2026-02-01T00:00:00Z'),
      ]),
    );
    await tester.pumpAndSettle();
    expect(fake.suggested, containsAll(['movie/tt-new']));
    expect(tiles(tester), [
      'New Pick. Because you saved N',
      'Pick. Because you saved S',
    ]);
  });

  testWidgets('on a television: the one poster size, a one-line caption, '
      'a plain heading, and the remote walks the row', (tester) async {
    fake
      ..knows('First', 'tt700')
      ..knows('Second', 'tt701')
      ..suggests('tt-saved', ['First'])
      ..suggests('tt-watched', ['Second']);
    await mount(
      tester,
      device: tv,
      library: [
        libraryItemJson('tt-saved', name: 'Saved'),
        libraryItemJson(
          'tt-watched',
          name: 'Watched',
          temp: true,
          removed: true,
          timesWatched: 1,
          lastWatched: '2026-05-01T00:00:00Z',
        ),
      ],
    );
    final first = find.bySemanticsLabel('Second. Because you watched Watched');
    expect(tester.getSize(first).width, PosterTile.tvImageWidth);
    // The caption is the name alone; the reason is not drawn under it.
    expect(find.text('Because you watched Watched'), findsNothing);
    await tester.pumpAndSettle();
    expect(focusedTileName(tester), 'Second');
    final heading = tester.widget<RichText>(
      find.textContaining(CatalogRows.forYouTitle, findRichText: true).first,
    );
    expect(heading.text.toPlainText(), CatalogRows.forYouTitle);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTileName(tester), 'First');
    expect(
      find.textContaining('Because you', findRichText: true),
      findsNothing,
    );
  });

  testWidgets('a film\'s sheet offers Mark as watched and a series\' does '
      'not', (tester) async {
    fake
      ..knows('A Film', 'tt800')
      ..knows('A Show', 'tt801', type: 'series')
      ..suggests('tt-saved', ['A Film', 'A Show']);
    await mount(tester, library: [libraryItemJson('tt-saved', name: 'S')]);
    await tester.longPress(
      find.bySemanticsLabel('A Film. Because you saved S'),
    );
    await tester.pumpAndSettle();
    expect(find.text(CatalogRows.markWatchedLabel), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.longPress(
      find.bySemanticsLabel('A Show. Because you saved S'),
    );
    await tester.pumpAndSettle();
    expect(find.text(CatalogRows.markWatchedLabel), findsNothing);
    expect(find.text(CatalogRows.notInterestedLabel), findsOneWidget);
  });

  testWidgets('Mark as watched marks the film in the engine, takes it off the '
      'row, and makes it a source', (tester) async {
    fake
      ..knows('Seen It', 'tt900')
      ..knows('Next', 'tt901')
      ..suggests('tt-saved', ['Seen It'])
      ..suggests('tt900', ['Next']);
    final library = [libraryItemJson('tt-saved', name: 'S')];
    await mount(tester, library: library);
    await tester.longPress(
      find.bySemanticsLabel('Seen It. Because you saved S'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(CatalogRows.markWatchedLabel));
    await tester.pumpAndSettle();

    final marked = core.dispatched.last.toJson();
    expect(marked['field'], 'ctx');
    expect(marked['action']['args']['action'], 'MetaItemMarkAsWatched');
    expect(marked['action']['args']['args']['meta_item']['id'], 'tt900');
    expect(marked['action']['args']['args']['is_watched'], true);
    expect(find.bySemanticsLabel(RegExp('^Seen It')), findsNothing);
    expect(prefs.faces.of('tt900'), isNull, reason: 'not a face');

    // What the engine then holds: a temporary item, watched once.
    core.setState(
      CoreField.libraryItems,
      libraryItemsState([
        ...library,
        libraryItemJson(
          'tt900',
          name: 'Seen It',
          temp: true,
          removed: true,
          timesWatched: 1,
          lastWatched: '2026-10-12T00:00:00Z',
        ),
      ]),
    );
    await tester.pumpAndSettle();
    expect(fake.suggested, contains('movie/tt900'));
    expect(tiles(tester), ['Next. Because you watched Seen It']);
  });

  /// Three sources of weights 2, 1 and 1 behind one title, "Shared".
  Future<void> mountThreeSources(
    WidgetTester tester, {
    DeviceProfile device = DeviceProfile.fallback,
  }) async {
    fake
      ..knows('Shared', 'tt100')
      ..suggests('tt-both', ['Shared'])
      ..suggests('tt-watched', ['Shared'])
      ..suggests('tt-saved', ['Shared']);
    await mount(
      tester,
      device: device,
      library: [
        libraryItemJson('tt-saved', name: 'Saved Film'),
        libraryItemJson(
          'tt-watched',
          name: 'Watched Film',
          temp: true,
          removed: true,
          timesWatched: 1,
          lastWatched: '2026-05-01T00:00:00Z',
        ),
        libraryItemJson('tt-both', name: 'Both Film', timesWatched: 1),
      ],
    );
  }

  /// The pushed details screen, if one is up.
  MetaDetailsScreen? details(WidgetTester tester) {
    final found = find.byType(MetaDetailsScreen, skipOffstage: false);
    return found.evaluate().isEmpty
        ? null
        : tester.widget<MetaDetailsScreen>(found);
  }

  testWidgets('each source line of the sheet opens that title\'s details, '
      'and the sheet is gone', (tester) async {
    await mountThreeSources(tester);
    await tester.longPress(find.bySemanticsLabel(RegExp(r'^Shared\.')));
    await tester.pumpAndSettle();
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp('Opens ')), findsNWidgets(3));
    expect(find.bySemanticsLabel(RegExp('Opens Watched Film')), findsOneWidget);
    semantics.dispose();

    await tester.tap(find.text('Watched: Watched Film'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(BottomSheet), findsNothing);
    final opened = details(tester)!;
    expect((opened.type, opened.id), ('movie', 'tt-watched'));
  });

  testWidgets('on a television the source lines are stops between the title '
      'and the choices, and select opens one', (tester) async {
    await mountThreeSources(tester, device: tv);
    await tester.pumpAndSettle();
    expect(focusedTileName(tester), 'Shared');
    await hold(tester, LogicalKeyboardKey.select, const Duration(seconds: 1));
    expect(find.byType(BottomSheet), findsOneWidget);

    String? focused() {
      final context = FocusManager.instance.primaryFocus?.context;
      final tile =
          context?.findAncestorWidgetOfExactType<ListTile>() ??
          (context?.widget is ListTile ? context!.widget as ListTile : null);
      final title = tile?.title;
      return title is Text ? title.data : null;
    }

    expect(focused(), 'Cancel', reason: 'the remote starts on Cancel');
    final upward = <String?>[];
    for (var i = 0; i < 6; i++) {
      await press(tester, LogicalKeyboardKey.arrowUp);
      upward.add(focused());
    }
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused(), 'Watched and saved: Both Film (×2)', reason: 'the top');
    expect(upward, [
      CatalogRows.notInterestedLabel,
      CatalogRows.markWatchedLabel,
      CatalogRows.addToLibraryLabel,
      'Saved: Saved Film',
      'Watched: Watched Film',
      'Watched and saved: Both Film (×2)',
    ]);
    final downward = <String?>[];
    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
      downward.add(focused());
    }
    expect(downward, [
      'Watched: Watched Film',
      'Saved: Saved Film',
      CatalogRows.addToLibraryLabel,
    ]);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused(), 'Saved: Saved Film');
    // Not `press`: the details screen it opens spins on a fake core, which
    // a settle would wait for forever.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(BottomSheet), findsNothing);
    final opened = details(tester)!;
    expect((opened.type, opened.id), ('movie', 'tt-saved'));
  });

  testWidgets('a single source is one line that opens it', (tester) async {
    fake
      ..knows('Pick', 'tt200')
      ..suggests('tt-saved', ['Pick']);
    await mount(tester, library: [libraryItemJson('tt-saved', name: 'S')]);
    await tester.longPress(find.bySemanticsLabel(RegExp(r'^Pick\.')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });

  testWidgets('a row kept by a build that stored less about its sources is '
      'worked out again once', (tester) async {
    fake
      ..knows('Pick', 'tt600')
      ..suggests('tt-saved', ['Pick']);
    final library = [libraryItemJson('tt-saved', name: 'S')];
    await mount(tester, library: library);
    final kept = Map<String, dynamic>.from(prefs.forYou!);
    final signature = kept['signature'] as String;
    expect(signature, startsWith('${ForYouController.keptShape},'));
    kept['signature'] = signature.substring(
      ForYouController.keptShape.length + 1,
    );
    fake.suggested.clear();
    await mount(tester, library: library, stored: {AppPrefs.forYouKey: kept});
    expect(fake.suggested, ['movie/tt-saved']);
  });

  for (final type in ['movie', 'series']) {
    testWidgets('Add to library is offered for a $type, saves it with the '
        'bookmark\'s action, takes it off the row and makes it a saved '
        'source', (tester) async {
      fake
        ..knows('Keep It', 'tt950', type: type)
        ..knows('After', 'tt951')
        ..suggests('tt-saved', ['Keep It'])
        ..suggests('tt950', ['After']);
      final library = [libraryItemJson('tt-saved', name: 'S')];
      await mount(tester, library: library);
      await tester.longPress(find.bySemanticsLabel(RegExp(r'^Keep It\.')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(CatalogRows.addToLibraryLabel));
      await tester.pumpAndSettle();

      final sent = core.dispatched.last.toJson();
      expect(sent['field'], 'ctx');
      expect(sent['action']['args']['action'], 'AddToLibrary');
      expect(sent['action']['args']['args']['id'], 'tt950');
      expect(sent['action']['args']['args']['type'], type);
      expect(find.bySemanticsLabel(RegExp(r'^Keep It\.')), findsNothing);

      // What the engine then holds: a saved title.
      core.setState(
        CoreField.libraryItems,
        libraryItemsState([
          ...library,
          libraryItemJson(
            'tt950',
            type: type,
            name: 'Keep It',
            added: '2026-10-12T00:00:00Z',
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(fake.suggested, contains('$type/tt950'));
      expect(tiles(tester), ['After. Because you saved Keep It']);
    });
  }

  group('the controller', () {
    test('works a kept row out again once it is a day old, and asks about '
        'the latest maxSources sources only', () async {
      final prefs = AppPrefs(client: FakePrefsClient());
      await prefs.load();
      var clock = DateTime.utc(2026, 10, 1, 12);
      final total = ForYouController.maxSources + 4;
      for (var i = 0; i < total; i++) {
        fake.suggests('tt-s$i', const []);
      }
      final controller = ForYouController(
        prefs: prefs,
        ask: fake.ask,
        now: () => clock,
      );
      addTearDown(controller.dispose);
      final library = [
        for (var i = 0; i < total; i++)
          LibraryItemView(
            libraryItemJson(
              'tt-s$i',
              added: DateTime.utc(
                2026,
                1,
                1,
              ).add(Duration(days: i)).toIso8601String(),
            ),
          ),
      ];
      controller.update(library: library, continueWatching: const {});
      await controller.settled;
      expect(fake.suggested, hasLength(ForYouController.maxSources));
      expect(fake.suggested, isNot(contains('movie/tt-s0')), reason: 'oldest');
      expect(fake.suggested, contains('movie/tt-s${total - 1}'));

      fake.suggested.clear();
      clock = clock.add(
        ForYouController.refreshEvery - const Duration(minutes: 1),
      );
      controller.update(library: library, continueWatching: const {});
      await controller.settled;
      expect(fake.suggested, isEmpty);

      clock = clock.add(const Duration(minutes: 2));
      controller.update(library: library, continueWatching: const {});
      await controller.settled;
      expect(fake.suggested, hasLength(ForYouController.maxSources));
    });

    test('at most max tasks run at once, and the rest in turn', () async {
      final limiter = TaskLimiter(2);
      final gates = [for (var i = 0; i < 5; i++) Completer<void>()];
      var most = 0;
      final done = <int>[];
      final all = [
        for (var i = 0; i < 5; i++)
          limiter.run(() async {
            if (limiter.running > most) most = limiter.running;
            await gates[i].future;
            done.add(i);
          }),
      ];
      await pumpEventQueue();
      expect(limiter.running, 2);
      for (final gate in gates) {
        gate.complete();
        await pumpEventQueue();
      }
      await Future.wait(all);
      expect(most, 2);
      expect(done, [0, 1, 2, 3, 4]);
    });
  });
}
