import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/addons/addon_health.dart';
import 'package:xtremio/features/addons/addon_health_client.dart';
import 'package:xtremio/features/addons/addon_health_view.dart';
import 'package:xtremio/features/addons/addon_tile.dart';
import 'package:xtremio/features/addons/addons_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/external_link.dart';
import 'package:xtremio/widgets/focusable_tile.dart';

import '../../support/fake_addon_health_client.dart';
import '../../support/fake_core_client.dart';
import '../../support/fake_link_opener.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

/// The verdict chip is the one control the installed list draws that opens
/// something of its own, and until it was lifted out of the tile it was
/// unreachable from a sofa: the tile takes focus as a whole and its
/// `RemotePress` takes select, so a chip inside it was drawn and dead.
void main() {
  const cinemeta = 'https://v3-cinemeta.strem.io/manifest.json';
  const youtube = 'https://v3-channels.strem.io/manifest.json';
  const watchhub = 'https://watchhub.strem.io/manifest.json';

  final now = DateTime.now().toUtc();

  /// YouTube working, WatchHub unreachable, Cinemeta protected (and so
  /// never labelled, whatever its record says).
  Map<String, Map<AddonResourceKind, AddonHealthRecord>> records() => {
    addonHealthKey(youtube): {
      AddonResourceKind.catalog: AddonHealthRecord(
        ok: 20,
        empty: 10,
        fail: 0,
        lastOk: now.subtract(const Duration(days: 3)),
        updated: now,
      ),
    },
    addonHealthKey(watchhub): {
      AddonResourceKind.stream: AddonHealthRecord(
        ok: 0,
        empty: 0,
        fail: 12,
        lastOk: null,
        updated: now,
      ),
    },
    addonHealthKey(cinemeta): {
      AddonResourceKind.catalog: AddonHealthRecord(
        ok: 0,
        empty: 0,
        fail: 30,
        lastOk: null,
        updated: now,
      ),
    },
  };

  FakeCoreClient fakeCore() => FakeCoreClient(
    state: {
      CoreField.installedAddons: loadInstalledAddonsFixture(),
      CoreField.remoteAddons: loadRemoteAddonsFixture(),
      CoreField.addonDetails: loadAddonDetailsFixture(),
      CoreField.ctx: loadCtxLoggedOutFixture(),
    },
  );

  Widget harness(AddonHealthClient health, {DeviceProfile device = tv}) =>
      DeviceScope(
        profile: device,
        child: CoreScope(
          client: fakeCore(),
          child: ExternalLinkScope(
            opener: FakeLinkOpener(),
            child: AddonHealthScope(
              client: health,
              child: const MaterialApp(home: AddonsScreen()),
            ),
          ),
        ),
      );

  Future<void> pumpScreen(
    WidgetTester tester, {
    DeviceProfile device = tv,
  }) async {
    useScreen(tester, tvSize);
    await tester.pumpWidget(
      harness(FakeAddonHealthClient(addons: records()), device: device),
    );
    await tester.pumpAndSettle();
  }

  /// The verdict chip on the tile named [name].
  Finder chipOf(String name) => find.descendant(
    of: find.ancestor(of: find.text(name), matching: find.byType(AddonTile)),
    matching: find.byType(AddonHealthChip),
  );

  /// Whether the chip on [name] is drawing the app's own focus ring --
  /// which it has to have at all, or a remote that can reach it still
  /// leaves nobody able to find it.
  bool ringOn(WidgetTester tester, String name) {
    final ring = find.descendant(
      of: chipOf(name),
      matching: find.byType(FocusRing),
    );
    expect(ring, findsWidgets, reason: 'the verdict wears no focus ring');
    return tester.widget<FocusRing>(ring.first).focused;
  }

  testWidgets('the remote reaches a verdict, with a ring on it', (
    tester,
  ) async {
    await pumpScreen(tester);

    // Cinemeta is first and protected, so it carries no verdict at all;
    // the first chip the D-pad meets is YouTube's, one press below its
    // tile.
    expect(focusedTileName(tester), 'Cinemeta');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTileName(tester), 'YouTube');
    expect(ringOn(tester, 'YouTube'), isFalse);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<AddonHealthChip>(), isTrue);
    expect(focusedLabel(tester), 'Working · catalogs 67%');
    expect(ringOn(tester, 'YouTube'), isTrue);

    // And it is a stop on the way down, not a trap: the next press goes on
    // to the addon below.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTileName(tester), 'WatchHub');
    expect(ringOn(tester, 'YouTube'), isFalse);
  });

  testWidgets("the remote's select key opens the evidence", (tester) async {
    await pumpScreen(tester);

    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<AddonHealthChip>(), isTrue);

    await press(tester, LogicalKeyboardKey.select);
    expect(find.byType(AddonHealthEvidence), findsOneWidget);
    expect(find.text('Last worked 3 days ago'), findsOneWidget);
  });

  testWidgets('a verdict arriving leaves the remote where it was', (
    tester,
  ) async {
    // The record is read once on mount, so every row is built without a
    // verdict and then again with one -- and by then the viewer has had a
    // second to press down. A tile whose root widget changed type there
    // would be a different element: the ring the remote was on is disposed
    // and whatever autofocuses answers the next press instead.
    useScreen(tester, tvSize);
    final health = FakeAddonHealthClient(addons: records())..holdReads();
    await tester.pumpWidget(harness(health));
    await tester.pumpAndSettle();
    expect(find.byType(AddonHealthChip), findsNothing);

    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTileName(tester), 'WatchHub');

    health.releaseReads();
    await tester.pumpAndSettle();
    expect(find.byType(AddonHealthChip), findsWidgets);
    expect(focusedTileName(tester), 'WatchHub');
  });

  testWidgets('a verdict is drawn beside the tile, never inside it', (
    tester,
  ) async {
    await pumpScreen(tester);

    // Inside the tile it would be within the tile's own RemotePress, which
    // takes select before anything below it: reachable, apparently
    // pressable, and dead.
    expect(find.byType(AddonHealthChip), findsWidgets);
    expect(
      find.descendant(
        of: find.byType(FocusableTile),
        matching: find.byType(AddonHealthChip),
      ),
      findsNothing,
    );
  });

  testWidgets('off a television the chip is where it always was', (
    tester,
  ) async {
    await pumpScreen(tester, device: DeviceProfile.fallback);

    // Under the type labels, inside the tile, with no ring: focus there
    // follows a pointer, and nothing about the phone layout moves.
    expect(
      find.descendant(
        of: find.byType(FocusableTile),
        matching: find.byType(AddonHealthChip),
      ),
      findsWidgets,
    );
    expect(find.byType(FocusRing), findsNothing);
    expect(
      find.descendant(
        of: find.byType(AddonHealthChip),
        matching: find.byIcon(AddonHealthChip.affordance),
      ),
      findsWidgets,
    );
  });
}
