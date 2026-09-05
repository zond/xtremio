import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/addons/addon_details_screen.dart';
import 'package:xtremio/features/addons/addon_tile.dart';
import 'package:xtremio/features/addons/addons_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/external_link.dart';
import 'package:xtremio/widgets/focusable_tile.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_link_opener.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

/// The default installed list: Cinemeta, YouTube, WatchHub, Public Domain
/// Movies, OpenSubtitles v3 and Local Files.
FakeCoreClient fakeCore() => FakeCoreClient(
  state: {
    CoreField.installedAddons: loadInstalledAddonsFixture(),
    CoreField.remoteAddons: loadRemoteAddonsFixture(),
    CoreField.addonDetails: loadAddonDetailsFixture(),
    CoreField.ctx: loadCtxLoggedOutFixture(),
  },
);

Widget harness(FakeCoreClient core) => DeviceScope(
  profile: tv,
  child: CoreScope(
    client: core,
    child: ExternalLinkScope(
      opener: FakeLinkOpener(),
      child: const MaterialApp(home: AddonsScreen()),
    ),
  ),
);

/// Whether the tile showing [name] is drawing its focus ring.
bool ringOn(WidgetTester tester, String name) {
  final ring = find.descendant(
    of: find.ancestor(of: find.text(name), matching: find.byType(AddonTile)),
    matching: find.byType(FocusRing),
  );
  return tester.widget<FocusRing>(ring.first).focused;
}

/// How far the installed list has scrolled (the first Scrollable in the
/// tree is the TabBarView's, not this).
double listOffset(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    )
    .position
    .pixels;

void main() {
  testWidgets('the D-pad walks the addon list, with a ring on the tile it '
      'is on', (tester) async {
    useScreen(tester, tvSize);
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    // A pushed screen starts on its first tile, as Discover's does.
    expect(focusedTileName(tester), 'Cinemeta');
    expect(ringOn(tester, 'Cinemeta'), isTrue);
    expect(ringOn(tester, 'YouTube'), isFalse);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTileName(tester), 'YouTube');
    expect(ringOn(tester, 'YouTube'), isTrue);
    expect(ringOn(tester, 'Cinemeta'), isFalse);

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedTileName(tester), 'Cinemeta');
  });

  testWidgets('a tile the D-pad reaches scrolls itself into view', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();
    expect(listOffset(tester), 0);

    for (var i = 0; i < 5; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }

    expect(focusedTileName(tester), 'Local Files (without catalog support)');
    expect(
      listOffset(tester),
      greaterThan(0),
      reason: 'the last tile was below the fold',
    );
    expect(
      tester.getRect(find.text('Local Files (without catalog support)')).bottom,
      lessThanOrEqualTo(tvSize.height),
    );
  });

  testWidgets('the remote rests on the tile, not on a button inside it', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.arrowDown);

    // Every row draws a menu button inside the tile, and a button inside a
    // focusable thing is not a button: the tile takes select before it,
    // and the ring follows the whole tile, so focus stopping on the menu
    // looked exactly like focus on the tile while pressing did something
    // else. It was also in the way -- the walk went menu to menu down the
    // list, past anything drawn under a row.
    final tile = find.descendant(
      of: find.ancestor(
        of: find.text('YouTube'),
        matching: find.byType(AddonTile),
      ),
      matching: find.byType(FocusableTile),
    );
    expect(focusedTileName(tester), 'YouTube');
    expect(FocusManager.instance.primaryFocus?.rect, tester.getRect(tile));
  });

  testWidgets('the remote\'s select key opens the addon on the tile', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    await press(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(find.byType(AddonDetailsScreen), findsOneWidget);
  });

  testWidgets('off a television the tile is a plain ink well', (tester) async {
    await tester.pumpWidget(
      CoreScope(
        client: fakeCore(),
        child: ExternalLinkScope(
          opener: FakeLinkOpener(),
          child: const MaterialApp(home: AddonsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AddonTile), findsWidgets);
    expect(find.byType(FocusRing), findsNothing);
  });
}
