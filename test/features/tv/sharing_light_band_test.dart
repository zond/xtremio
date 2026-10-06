import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/library/library_screen.dart';
import 'package:xtremio/features/search/search_screen.dart';
import 'package:xtremio/features/sharing/idle_sharing.dart';
import 'package:xtremio/features/sharing/sharing_activity.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/root_shell.dart';
import 'package:xtremio/shell/tv_density.dart';
import 'package:xtremio/widgets/focusable_tile.dart';
import 'package:xtremio/widgets/tv_text_field.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_sharing.dart';
import '../../support/fixtures.dart';
import '../../support/text_entry.dart';
import '../../support/tv.dart';

const Key lightKey = Key('sharing-light');

/// The shell on a Google TV (960x540 dp) with the light lit.
Future<FakeCoreClient> mount(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  // The pulse repeats while the light is drawn; a platform that says
  // animations are off is a path the light itself takes.
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  final monitor = SharingActivityMonitor(
    client: FakeSharingActivity(answer: traffic(up: true)),
    period: const Duration(milliseconds: 20),
  );
  addTearDown(monitor.dispose);
  final prefs = AppPrefs.inMemory();
  final policy = IdleSharingPolicy(
    prefs: prefs,
    server: RecordingServerSettings(),
    hold: RecordingSharingHold(),
  );
  addTearDown(policy.dispose);
  policy.start();
  final core = FakeCoreClient(
    state: {
      CoreField.ctx: loadCtxLoggedOutFixture(),
      CoreField.board: loadBoardFixture(),
      CoreField.continueWatchingPreview: loadContinueWatchingFixture(),
      CoreField.library: loadLibraryFixture(),
      CoreField.search: {
        'selected': null,
        'catalogs': <Object>[],
        'catalogLabels': <Object>[],
      },
    },
    initInfo: CoreInitInfo(
      serverBaseUrl: Uri.parse('http://127.0.0.1:11470/'),
      schemaVersion: 25,
    ),
  );
  await tester.pumpWidget(
    DeviceScope(
      profile: tv,
      child: CoreScope(
        client: core,
        initInfo: core.initInfo,
        child: PrefsScope(
          prefs: prefs,
          child: SharingScope(
            policy: policy,
            monitor: monitor,
            child: MaterialApp(
              theme: TvDensity.theme(ThemeData()),
              builder: TvMediaQuery.builder,
              home: const RootShell(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byKey(lightKey), findsOneWidget);
  return core;
}

/// What the light must stay off: every tile, every row heading.
void expectClearOfTheRows(WidgetTester tester, Rect light) {
  for (final element in find.byType(FocusableTile).evaluate()) {
    final tile = tester.getRect(find.byElementPredicate((e) => e == element));
    expect(tile.overlaps(light), isFalse, reason: 'a tile at $tile');
  }
  for (final element in find.byType(RichText).evaluate()) {
    final heading = tester.getRect(
      find.byElementPredicate((e) => e == element),
    );
    if (heading.top <= light.bottom + 200) {
      // Texts inside the light itself are its own.
      final own = find
          .descendant(
            of: find.byKey(lightKey),
            matching: find.byElementPredicate((e) => e == element),
          )
          .evaluate()
          .isNotEmpty;
      if (!own) {
        expect(heading.overlaps(light), isFalse, reason: 'text at $heading');
      }
    }
  }
}

void main() {
  testWidgets('on Discover the light is at the right end of the types\' '
      'band, clear of every tile and heading', (tester) async {
    await mount(tester);
    final light = tester.getRect(find.byKey(lightKey));
    final types = tester.getRect(find.byType(SegmentedButton<int>));

    expect(light.center.dy, closeTo(types.center.dy, 0.5));
    expect(light.top, greaterThanOrEqualTo(540 * 0.05), reason: 'safe area');
    expect(light.right, lessThanOrEqualTo(960 * 0.95), reason: 'safe area');
    expect(light.left, greaterThan(types.right), reason: 'beside the types');
    expectClearOfTheRows(tester, light);
  });

  testWidgets('on Search it is at the right end of the field\'s band, and '
      'the results keep clear of it too', (tester) async {
    final core = await mount(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('Search'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SearchScreen), findsOneWidget);
    final light = tester.getRect(find.byKey(lightKey));
    final field = tester.getRect(find.byType(TvTextField));
    expect(light.center.dy, closeTo(field.center.dy, 0.5));
    expect(light.left, greaterThan(field.right), reason: 'beside the field');

    // With results under it.
    answerTextEntry('night of the living dead');
    final search = tester.getCenter(find.byType(TvTextField));
    await tester.tapAt(search);
    await settleTextEntry(tester);
    core.setState(CoreField.search, loadSearchFixture());
    await tester.pumpAndSettle();
    expect(find.byType(FocusableTile), findsWidgets);
    expectClearOfTheRows(tester, tester.getRect(find.byKey(lightKey)));
  });

  testWidgets('on the Library it is at the right end of the band, past the '
      'bar\'s buttons, clear of every tile', (tester) async {
    await mount(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('Library'),
      ),
    );
    await tester.pumpAndSettle();
    final light = tester.getRect(find.byKey(lightKey));
    final types = tester.getRect(find.byType(SegmentedButton<int>));
    expect(light.center.dy, closeTo(types.center.dy, 0.5));
    expect(light.top, greaterThanOrEqualTo(540 * 0.05), reason: 'safe area');
    expect(light.right, lessThanOrEqualTo(960 * 0.95), reason: 'safe area');
    final buttons = find.descendant(
      of: find.byType(LibraryScreen),
      matching: find.byType(IconButton),
    );
    expect(buttons, findsWidgets);
    for (final element in buttons.evaluate()) {
      final button = tester.getRect(
        find.byElementPredicate((e) => e == element),
      );
      expect(button.overlaps(light), isFalse, reason: 'a button at $button');
    }
    expectClearOfTheRows(tester, light);
  });

  testWidgets('elsewhere it keeps its place a toolbar\'s height down', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('Settings'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(lightKey)).top,
      540 * 0.05 + kToolbarHeight,
    );
  });
}
