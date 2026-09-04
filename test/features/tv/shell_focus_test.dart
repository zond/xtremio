import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/board/board_screen.dart';
import 'package:xtremio/features/library/library_screen.dart';
import 'package:xtremio/features/search/search_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/root_shell.dart';
import 'package:xtremio/shell/tv_text_entry.dart';
import 'package:xtremio/widgets/focusable_tile.dart';
import 'package:xtremio/widgets/tv_text_field.dart';

import '../../support/fake_core_client.dart';
import '../../support/fixtures.dart';
import '../../support/text_entry.dart';

const tv = DeviceProfile(isTv: true, hasTouch: false);

/// A core with the Board, Library and Search tabs all able to settle.
FakeCoreClient fakeCore({Map<String, dynamic>? continueWatching}) =>
    FakeCoreClient(
      state: {
        CoreField.board: loadBoardFixture(),
        CoreField.continueWatchingPreview:
            continueWatching ?? loadContinueWatchingFixture(),
        CoreField.library: loadLibraryFixture(),
        CoreField.ctx: loadCtxLoggedOutFixture(),
        CoreField.search: {
          'selected': null,
          'catalogs': <Object>[],
          'catalogLabels': <Object>[],
        },
      },
    );

/// The shell as the app mounts it, on [device].
Widget harness(FakeCoreClient core, {DeviceProfile device = tv}) => DeviceScope(
  profile: device,
  child: CoreScope(
    client: core,
    child: const MaterialApp(home: RootShell()),
  ),
);

/// The widget with primary focus sits under a [T].
bool focusIn<T extends Widget>() =>
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<T>() !=
    null;

/// The name on the tile holding primary focus, null when focus is elsewhere.
String? focusedTileName(WidgetTester tester) {
  final context = FocusManager.instance.primaryFocus?.context;
  final tile = context?.findAncestorWidgetOfExactType<FocusableTile>();
  if (tile == null) return null;
  final texts = find.descendant(
    of: find.byWidget(tile),
    matching: find.byType(Text),
  );
  return tester.widget<Text>(texts.first).data;
}

/// The label of the rail destination holding primary focus, null when focus
/// is not on a destination.
String? focusedRailLabel(WidgetTester tester) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context?.findAncestorWidgetOfExactType<NavigationRail>() == null) {
    return null;
  }
  final texts = find.descendant(
    of: find.byWidget(context!.widget),
    matching: find.byType(Text),
  );
  return tester.widget<Text>(texts.first).data;
}

/// The Board's first catalog row (Cinemeta Popular movies), by name.
List<String> popularNames() => [
  for (final item in CatalogsWithExtraState.fromJson(
    loadBoardFixture(),
  ).rows.first.items)
    item.name,
];

/// Walks focus from wherever it is to the rail's first destination (Board).
Future<void> focusRailTop(WidgetTester tester) async {
  while (!focusIn<NavigationRail>()) {
    await press(tester, LogicalKeyboardKey.arrowLeft);
  }
  for (var i = 0; i < 5; i++) {
    await press(tester, LogicalKeyboardKey.arrowUp);
  }
  expect(focusIn<NavigationRail>(), isTrue);
}

/// Walks focus from wherever it is to the rail's Search destination.
Future<void> focusSearchDestination(WidgetTester tester) async {
  await focusRailTop(tester);
  await press(tester, LogicalKeyboardKey.arrowDown);
  await press(tester, LogicalKeyboardKey.arrowDown);
  expect(focusedRailLabel(tester), 'Search');
}

void useScreen(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a TV gets the rail whatever its width', (tester) async {
    useScreen(tester, const Size(400, 800));
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('a phone at the same width keeps the bottom bar', (tester) async {
    useScreen(tester, const Size(400, 800));
    await tester.pumpWidget(
      harness(fakeCore(), device: DeviceProfile.fallback),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
  });

  testWidgets('focus starts on the first tile of the Board', (tester) async {
    useScreen(tester, const Size(1280, 720));
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();

    // The continue-watching row is first; its one item is the movie.
    expect(focusIn<BoardScreen>(), isTrue);
    expect(focusedTileName(tester), 'Night of the Living Dead');
  });

  testWidgets('left from the body\'s first column reaches the rail, right '
      'from the rail enters the body', (tester) async {
    useScreen(tester, const Size(1280, 720));
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();
    expect(focusIn<BoardScreen>(), isTrue);

    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusIn<NavigationRail>(), isTrue);
    expect(focusIn<BoardScreen>(), isFalse);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusIn<BoardScreen>(), isTrue);
    expect(focusIn<NavigationRail>(), isFalse);

    // And back once more, from a tile further down.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTileName(tester), popularNames().first);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusIn<NavigationRail>(), isTrue);

    // Tab walks the rail as one group: from its last destination it moves
    // on to the body rather than to a tile in between.
    await focusRailTop(tester);
    for (var i = 0; i < 4; i++) {
      await press(tester, LogicalKeyboardKey.tab);
      expect(focusIn<NavigationRail>(), isTrue, reason: 'tab $i');
    }
    await press(tester, LogicalKeyboardKey.tab);
    expect(focusIn<BoardScreen>(), isTrue);
  });

  testWidgets('select on a rail destination switches the tab and right '
      'enters the new body', (tester) async {
    useScreen(tester, const Size(1280, 720));
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();

    await focusRailTop(tester);
    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    await press(tester, LogicalKeyboardKey.select);
    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(find.byType(BoardScreen), findsNothing);
    expect(focusIn<NavigationRail>(), isTrue);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusIn<LibraryScreen>(), isTrue);
    expect(focusIn<NavigationRail>(), isFalse);
  });

  testWidgets('tapping a destination while a tile is focused puts focus on '
      'that destination', (tester) async {
    useScreen(tester, const Size(1280, 720));
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();
    expect(focusIn<BoardScreen>(), isTrue);

    // A touch remote or mouse taps the rail without focusing it first; the
    // Library has nothing to restore, so focus must show on the rail, as it
    // does after a select there, rather than sit on the tab's bare scope.
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(focusedRailLabel(tester), 'Library');

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusIn<LibraryScreen>(), isTrue);
  });

  testWidgets('coming back to a tab restores the tile that was focused', (
    tester,
  ) async {
    useScreen(tester, const Size(1280, 720));
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();
    final popular = popularNames();

    // Down into the Popular row, right to its second tile.
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTileName(tester), popular[1]);

    // Switch tabs by tapping the rail so focus leaves the tile exactly where
    // it is (walking left with the D-pad would first retrace the arrow-right
    // step, as directional traversal does, and remember the first tile).
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(focusedTileName(tester), isNull);

    await tester.tap(find.text('Board'));
    await tester.pumpAndSettle();

    expect(find.byType(BoardScreen), findsOneWidget);
    expect(focusIn<BoardScreen>(), isTrue);
    expect(focusedTileName(tester), popular[1]);
  });

  testWidgets('with the D-pad the tile focus left from is the one restored', (
    tester,
  ) async {
    useScreen(tester, const Size(1280, 720));
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();
    final popular = popularNames();

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTileName(tester), popular[0]);
    await focusRailTop(tester);
    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    await press(tester, LogicalKeyboardKey.select);
    expect(find.byType(LibraryScreen), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.arrowUp);
    }
    await press(tester, LogicalKeyboardKey.select);

    expect(find.byType(BoardScreen), findsOneWidget);
    expect(focusedTileName(tester), popular[0]);
  });

  testWidgets('a row arriving while the rail is focused leaves focus on the '
      'rail', (tester) async {
    useScreen(tester, const Size(1280, 720));
    final core = fakeCore(continueWatching: {'items': <Object>[]});
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();
    final popular = popularNames();
    expect(focusedTileName(tester), popular[0]);

    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusIn<NavigationRail>(), isTrue);

    // The continue-watching row appears above the Popular row, so every row
    // moves down one slot and the widgets that showed row n now show row
    // n - 1, among them the tile the Board remembers. That is a rebuild,
    // not a key press, so focus must stay where the user put it.
    core.setState(
      CoreField.continueWatchingPreview,
      loadContinueWatchingFixture(),
    );
    await tester.pumpAndSettle();
    expect(find.text('Continue watching'), findsOneWidget);

    expect(focusIn<NavigationRail>(), isTrue);
    expect(focusedTileName(tester), isNull);

    // Right from the rail still enters the Board on the remembered tile.
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusIn<BoardScreen>(), isTrue);
  });

  testWidgets('select on Search keeps focus on the rail; right enters the '
      'field', (tester) async {
    useScreen(tester, const Size(1280, 720));
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();

    // The field autofocuses on a desktop or phone, where the keyboard is
    // right there; on a TV it would take focus off the rail the moment the
    // tab is selected, as no other tab does.
    await focusSearchDestination(tester);
    await press(tester, LogicalKeyboardKey.select);
    expect(find.byType(SearchScreen), findsOneWidget);
    expect(focusedRailLabel(tester), 'Search');
    expect(focusIn<TvTextField>(), isFalse);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusIn<TvTextField>(), isTrue);
  });

  testWidgets('the D-pad leaves the search field, full or empty', (
    tester,
  ) async {
    useScreen(tester, const Size(1280, 720));
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();
    await focusSearchDestination(tester);
    await press(tester, LogicalKeyboardKey.select);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusIn<TvTextField>(), isTrue);

    // Left is the way back to the rail (to whichever destination is
    // nearest, as directional traversal goes).
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusIn<NavigationRail>(), isTrue);

    // Select is what types on a television: it opens the platform's own
    // text-entry screen, which comes back with the whole query.
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusIn<TvTextField>(), isTrue);
    final calls = answerTextEntry('night of the living dead');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await settleTextEntry(tester);
    core.setState(CoreField.search, loadSearchFixture());
    await tester.pumpAndSettle();
    expect(calls.single.method, TvTextEntry.method);
    expect(find.byType(FocusableTile), findsWidgets);

    // And a field with text in it is no different: there is no caret for an
    // arrow key to walk, so nothing here can hold the D-pad.
    expect(focusIn<TvTextField>(), isTrue);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusIn<NavigationRail>(), isTrue);
  });

  testWidgets('down from the search field goes to the results', (tester) async {
    useScreen(tester, const Size(1280, 720));
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();
    await focusSearchDestination(tester);
    await press(tester, LogicalKeyboardKey.select);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusIn<TvTextField>(), isTrue);

    answerTextEntry('night of the living dead');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await settleTextEntry(tester);
    core.setState(CoreField.search, loadSearchFixture());
    await tester.pumpAndSettle();
    expect(find.byType(FocusableTile), findsWidgets);
    expect(focusIn<TvTextField>(), isTrue);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<TvTextField>(), isFalse);
    expect(focusIn<FocusableTile>(), isTrue);

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusIn<TvTextField>(), isTrue);
  });

  testWidgets('up from the first and down from the last destination stay on '
      'the rail', (tester) async {
    useScreen(tester, const Size(1280, 720));
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();

    // Directional traversal is geometric and knows nothing of the rail as
    // a unit: past either end of the menu it would find a Board tile that
    // happens to lie above or below, and a select there opens its details
    // when the user meant to keep walking the menu.
    await focusRailTop(tester);
    expect(focusedRailLabel(tester), 'Board');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedRailLabel(tester), 'Board');

    for (var i = 0; i < 4; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(focusedRailLabel(tester), 'Settings');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedRailLabel(tester), 'Settings');
    expect(focusIn<BoardScreen>(), isFalse);

    // Right still enters the body.
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusIn<BoardScreen>(), isTrue);
  });
}
