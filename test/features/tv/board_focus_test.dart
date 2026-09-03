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
}
