import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/board/board_screen.dart';
import 'package:xtremio/features/sharing/idle_sharing.dart';
import 'package:xtremio/features/sharing/sharing_activity.dart';
import 'package:xtremio/features/sharing/sharing_light.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/root_shell.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_sharing.dart';
import '../../support/fixtures.dart';

/// How a remote reaches the status light, and what it costs the walk that
/// was there before.
///
/// The light is drawn over the body in the top right corner, which on a
/// television is where a poster row ends -- so the thing to prove is that
/// directional traversal cannot land on it by accident, and that one
/// deliberate key can.
void main() {
  const tv = DeviceProfile(isTv: true, hasTouch: false);

  bool focusIn<T extends Widget>() =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<T>() !=
      null;

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  /// The shell on a television, with [uploading] deciding whether the
  /// server is giving anything to the swarm.
  Future<FakeSharingActivity> mount(
    WidgetTester tester, {
    required bool uploading,
  }) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The pulse never settles; the platform saying animations are off is
    // the same path the light takes on a television that says so.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    final server = FakeSharingActivity(
      answer: uploading ? traffic(up: true) : traffic(),
    );
    final monitor = SharingActivityMonitor(
      client: server,
      period: const Duration(milliseconds: 20),
    );
    addTearDown(monitor.dispose);
    final prefs = AppPrefs.inMemory();
    final policy = IdleSharingPolicy(
      prefs: prefs,
      server: RecordingServerSettings(),
    );
    addTearDown(policy.dispose);
    policy.start();

    await tester.pumpWidget(
      DeviceScope(
        profile: tv,
        child: CoreScope(
          client: FakeCoreClient(
            state: {
              CoreField.board: loadBoardFixture(),
              CoreField.continueWatchingPreview: loadContinueWatchingFixture(),
              CoreField.library: loadLibraryFixture(),
              CoreField.ctx: loadCtxLoggedOutFixture(),
            },
          ),
          child: PrefsScope(
            prefs: prefs,
            child: SharingScope(
              policy: policy,
              monitor: monitor,
              child: const MaterialApp(home: RootShell()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return server;
  }

  /// Focus onto the rail's first destination, from wherever it is.
  Future<void> focusRailTop(WidgetTester tester) async {
    while (!focusIn<NavigationRail>()) {
      await press(tester, LogicalKeyboardKey.arrowLeft);
    }
    for (var i = 0; i < 5; i++) {
      await press(tester, LogicalKeyboardKey.arrowUp);
      if (focusIn<SharingLight>()) {
        await press(tester, LogicalKeyboardKey.arrowDown);
        break;
      }
    }
    expect(focusIn<NavigationRail>(), isTrue);
  }

  testWidgets('up from the top of the rail reaches the light, and any '
      'direction hands the remote back', (tester) async {
    await mount(tester, uploading: true);
    expect(find.byKey(const Key('sharing-light')), findsOneWidget);

    // The rail is one left press from every tab's body, so this is the
    // whole of the path: left, up to the top, up once more.
    await focusRailTop(tester);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusIn<SharingLight>(), isTrue);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<SharingLight>(), isFalse);
    expect(focusIn<NavigationRail>(), isTrue);

    // And from the light there is nothing else a direction key can reach:
    // left is the same answer as down.
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusIn<SharingLight>(), isTrue);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusIn<NavigationRail>(), isTrue);
  });

  testWidgets('select on the light opens the popup', (tester) async {
    await mount(tester, uploading: true);

    await focusRailTop(tester);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusIn<SharingLight>(), isTrue);

    await press(tester, LogicalKeyboardKey.select);
    expect(find.byType(SharingStopDialog), findsOneWidget);
    expect(find.text(IdleSharing.pauseTitle), findsOneWidget);
    expect(find.text(IdleSharing.stopTitle), findsOneWidget);
  });

  testWidgets('with nothing going out the walk is exactly what it was', (
    tester,
  ) async {
    await mount(tester, uploading: false);
    expect(find.byKey(const Key('sharing-light')), findsNothing);

    await focusRailTop(tester);
    // The key that reaches the light is the one that used to do nothing,
    // and with no light it still does nothing.
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusIn<NavigationRail>(), isTrue);
  });

  testWidgets('the body cannot walk onto it', (tester) async {
    await mount(tester, uploading: true);
    expect(find.byKey(const Key('sharing-light')), findsOneWidget);

    // The light is drawn over the body's top right corner, which is where
    // a poster row ends. So the walk goes down into the catalog row and out
    // to its right-hand end -- under the light -- and presses up, which is
    // the press that means "the row above" and would find the light first
    // if the light were in the traversal at all.
    expect(focusIn<BoardScreen>(), isTrue);
    await press(tester, LogicalKeyboardKey.arrowDown);
    for (var i = 0; i < 8; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusIn<SharingLight>(), isFalse, reason: 'right $i');
    }
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusIn<SharingLight>(), isFalse);
    expect(focusIn<BoardScreen>(), isTrue);

    // Tab does not find it either, and neither loop is what keeps it out:
    // the light is skipped by traversal outright. Nothing observable here
    // distinguishes that from the layout's own luck -- Tab loops inside the
    // body's own scope, and directional traversal from the body's edge
    // happens to prefer the rail -- so the property is asserted where it is
    // set, because the protection must not rest on either accident.
    for (var i = 0; i < 60; i++) {
      await press(tester, LogicalKeyboardKey.tab);
      expect(focusIn<SharingLight>(), isFalse, reason: 'tab $i');
    }
    expect(
      tester
          .widget<Focus>(find.byKey(const Key('sharing-light')))
          .focusNode!
          .skipTraversal,
      isTrue,
    );
  });
}
