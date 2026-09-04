import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/board/board_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/focusable_tile.dart';
import 'package:xtremio/widgets/poster_tile.dart';

import '../../support/fake_core_client.dart';
import '../../support/fixtures.dart';

const tv = DeviceProfile(isTv: true, hasTouch: false);

FakeCoreClient fakeCore() => FakeCoreClient(
  state: {
    CoreField.board: loadBoardFixture(),
    CoreField.continueWatchingPreview: loadContinueWatchingFixture(),
  },
);

Widget harness(FakeCoreClient core) => DeviceScope(
  profile: tv,
  child: CoreScope(
    client: core,
    child: const MaterialApp(home: BoardScreen()),
  ),
);

/// The tile (poster or library item) holding primary focus, by its name.
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

/// The names in catalog row [index] of the board fixture.
List<String> rowNames(int index) => [
  for (final item in CatalogsWithExtraState.fromJson(
    loadBoardFixture(),
  ).rows[index].items)
    item.name,
];

/// Whether the [FocusableTile] around [name] draws its ring.
bool ringOf(WidgetTester tester, String name) => tester
    .widget<FocusRing>(
      find.ancestor(of: find.text(name), matching: find.byType(FocusRing)),
    )
    .focused;

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
  testWidgets('the focused poster shows the ring, and only that one', (
    tester,
  ) async {
    useScreen(tester, const Size(1280, 720));
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();
    final popular = CatalogsWithExtraState.fromJson(loadBoardFixture())
        .rows
        .first
        .items;

    // Focus starts on the first tile: the continue-watching movie.
    expect(focusedTileName(tester), 'Night of the Living Dead');
    expect(ringOf(tester, 'Night of the Living Dead'), isTrue);
    expect(ringOf(tester, popular.first.name), isFalse);

    // Every poster tile carries a ring, lit only on the focused one.
    final rings = tester.widgetList<FocusRing>(
      find.descendant(
        of: find.byType(PosterTile),
        matching: find.byType(FocusRing),
      ),
    );
    expect(rings, isNotEmpty);
    expect(rings.where((r) => r.focused), isEmpty);
  });

  testWidgets('the focus zoom fits inside the row it grows in', (tester) async {
    // The owner's television: 1920x1080 at density 320, so 960x540 of
    // logical pixels.
    useScreen(tester, const Size(960, 540));
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();
    final name = focusedTileName(tester);
    expect(name, 'Night of the Living Dead');

    // A row with more tiles than fit scrolls, and a scrolling viewport
    // paints behind a clip of exactly its own bounds. Laid out to the full
    // height of that viewport, a focused tile's zoom is not a lift but a
    // crop: a slice off the top of the poster and off the caption below
    // it, and no shadow at all.
    final tile = find.text(name!);
    final grown = tester.getRect(
      find.ancestor(of: tile, matching: find.byType(FocusRing)).first,
    );
    final strip = tester.getRect(
      find.ancestor(of: tile, matching: find.byType(Viewport)).first,
    );
    expect(grown.top, greaterThan(strip.top));
    expect(grown.bottom, lessThan(strip.bottom));
  });

  testWidgets('up and down move between rows, left and right within one', (
    tester,
  ) async {
    useScreen(tester, const Size(1280, 720));
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();
    final movies = rowNames(0);
    final series = rowNames(1);
    expect(focusedTileName(tester), 'Night of the Living Dead');

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTileName(tester), movies[0]);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTileName(tester), movies[1]);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTileName(tester), movies[2]);

    // Down keeps the column; up from the first row's second column lands on
    // the only tile the continue-watching row has.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTileName(tester), series[2]);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedTileName(tester), series[1]);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedTileName(tester), movies[1]);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedTileName(tester), 'Night of the Living Dead');
  });

  testWidgets('right walks a row past the tiles that were built at first', (
    tester,
  ) async {
    useScreen(tester, const Size(1280, 720));
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();
    final movies = rowNames(0);
    expect(movies.length, greaterThan(12));

    await press(tester, LogicalKeyboardKey.arrowDown);
    // Twelve 130 px tiles are past the 1280 px viewport plus its cache:
    // each step's centring must build the next before it is asked for.
    for (var i = 1; i <= 12; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedTileName(tester), movies[i], reason: 'step $i');
    }
    final focused = tester.getRect(find.text(movies[12]));
    expect(focused.left, greaterThan(0));
    expect(focused.right, lessThan(1280));
    // The strip scrolled: the row's first tile is off screen now.
    expect(find.text(movies[0]), findsNothing);
  });
}
