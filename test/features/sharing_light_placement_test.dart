import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/sharing/idle_sharing.dart';
import 'package:xtremio/features/sharing/sharing_activity.dart';
import 'package:xtremio/features/sharing/sharing_light.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/root_shell.dart';
import 'package:xtremio/shell/tv_density.dart';

import '../support/fake_core_client.dart';
import '../support/fake_sharing.dart';
import '../support/fixtures.dart';

/// What the status light in the shell's corner is allowed to cover.
///
/// It is drawn over whatever screen is showing, and the shell does not
/// know what a screen puts in its top right corner -- so the rule it keeps
/// is not "the corner is empty", which no fixed position over somebody
/// else's screen can promise, but that the light never takes a press meant
/// for something else. Two things say that, and both are checked on all
/// five shell screens:
///
/// - **Nothing an app bar draws is touched.** That is what the toolbar's
///   height of offset buys: an app bar's trailing action is the one control
///   a screen is likely to have put in this corner, and it is small enough
///   that clipping its edge is clipping the button.
/// - **No control's middle is under the light.** A press is aimed at the
///   middle of what it is for, and `WidgetTester.tap` lands there too, so a
///   control whose centre is clear still takes the press it is given.
///
/// What that admits, and what it is worth writing down: the light does clip
/// things. On the Library, whose filter row starts immediately under the
/// app bar, it covers 15 x 40 px of the "Downloaded" chip at 1280x720 on a
/// television, and at 400 wide off one, where the row's `Wrap` breaks its
/// line with a chip ending under the light. At the two phone widths the
/// sweep runs at, 360 and 320, the break falls elsewhere and nothing is
/// clipped; the other four screens draw nothing there on either layout.
void main() {
  const lightKey = Key('sharing-light');
  const tv = DeviceProfile(isTv: true, hasTouch: false);

  /// The five tabs, in the order the shell lists them.
  const tabs = ['Board', 'Discover', 'Search', 'Library', 'Settings'];

  /// The shell with the light lit, on [profile] at [size].
  ///
  /// The core answers for every tab, since this walks all five.
  Future<FakeCoreClient> mount(
    WidgetTester tester, {
    required DeviceProfile profile,
    required Size size,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The pulse repeats for as long as the light is drawn and
    // `pumpAndSettle` would wait for a frame that never comes; a platform
    // that says animations are off is a path the light itself takes.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    final server = FakeSharingActivity(answer: traffic(up: true));
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
    final core = FakeCoreClient(
      state: {
        CoreField.ctx: loadCtxLoggedInFixture(),
        CoreField.board: loadBoardFixture(),
        CoreField.continueWatchingPreview: loadContinueWatchingFixture(),
        CoreField.discover: loadDiscoverFixture(),
        CoreField.search: loadSearchFixture(),
        CoreField.library: loadLibraryFixture(),
        CoreField.installedAddons: loadInstalledAddonsFixture(),
        CoreField.remoteAddons: loadRemoteAddonsFixture(),
      },
      initInfo: CoreInitInfo(
        serverBaseUrl: Uri.parse('http://127.0.0.1:11470/'),
        schemaVersion: 25,
      ),
    );
    await tester.pumpWidget(
      DeviceScope(
        profile: profile,
        child: CoreScope(
          client: core,
          initInfo: core.initInfo,
          child: PrefsScope(
            prefs: prefs,
            child: SharingScope(
              policy: policy,
              monitor: monitor,
              child: MaterialApp(
                // The overscan band the shell keeps out of, as the app
                // gives it to a television: the light sits inside it, so
                // without this it is measured in the wrong place.
                builder: profile.isTv ? TvMediaQuery.builder : null,
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

  /// Shows [tab], by pressing its destination in the rail or the bar.
  Future<void> show(WidgetTester tester, String tab) async {
    final nav = find.byType(NavigationRail).evaluate().isEmpty
        ? find.byType(NavigationBar)
        : find.byType(NavigationRail);
    await tester.tap(find.descendant(of: nav, matching: find.text(tab)));
    await tester.pumpAndSettle();
  }

  /// Every control a pointer can press, with the light's own left out.
  List<Rect> controls(WidgetTester tester) {
    final light = find.byKey(lightKey).evaluate().single;
    final found = find.byWidgetPredicate(
      (w) => w is InkResponse && (w.onTap != null || w.onLongPress != null),
    );
    return [
      for (final element in found.evaluate())
        if (!_under(element, light))
          tester.getRect(find.byElementPredicate((e) => e == element)),
    ];
  }

  /// The two rules, on whatever screen is showing.
  void checkCorner(WidgetTester tester, String where) {
    final light = tester.getRect(find.byKey(lightKey));
    final bars = find.byType(AppBar).evaluate();
    final bar = bars.isEmpty
        ? null
        : tester.getRect(find.byElementPredicate((e) => e == bars.single));
    for (final control in controls(tester)) {
      if (bar != null && bar.overlaps(control)) {
        expect(
          control.overlaps(light),
          isFalse,
          reason:
              'on $where the light is over $control, which the app bar '
              'draws: an app bar action is small enough that clipping its '
              'edge is clipping the button',
        );
      }
      expect(
        light.contains(control.center),
        isFalse,
        reason:
            'on $where the light covers the middle of $control, which is '
            'where a press is aimed -- the press opens the light instead',
      );
    }
  }

  testWidgets('on a television the light takes no press meant for a '
      'control, on any of the five screens', (tester) async {
    await mount(tester, profile: tv, size: const Size(1280, 720));
    checkCorner(tester, 'the television Board');
    for (final tab in tabs.skip(1)) {
      await show(tester, tab);
      checkCorner(tester, 'the television $tab');
    }
  });

  // The width most phones have, and the narrowest any does. Every screen
  // lays out at both -- Settings, which used to throw below about 480, is
  // measured at 320 and 360 by `settings_narrow_test.dart` since its menus
  // left the tile's trailing slot -- so the sweep runs where the light will
  // be seen.
  for (final width in [360, 320]) {
    testWidgets('and on a phone $width wide, where the light is the button', (
      tester,
    ) async {
      await mount(
        tester,
        profile: DeviceProfile.fallback,
        size: Size(width.toDouble(), 800),
      );
      checkCorner(tester, 'the $width-wide phone Board');
      for (final tab in tabs.skip(1)) {
        await show(tester, tab);
        checkCorner(tester, 'the $width-wide phone $tab');
      }
    });
  }

  testWidgets('a control the light clips still takes the tap', (tester) async {
    // 400 wide, and not one of the sweep's widths: the Library's filter row
    // is a `Wrap`, and 400 is where its line break leaves a chip ending
    // under the light -- at 360 and 320 the break falls elsewhere and no
    // chip is clipped, so the sweeps never meet this case. The second rule
    // is only worth anything if the chip it leaves half-covered is still
    // pressed by pressing it, and this is the one width that checks it.
    final core = await mount(
      tester,
      profile: DeviceProfile.fallback,
      size: const Size(400, 800),
    );
    await show(tester, 'Library');
    final light = tester.getRect(find.byKey(lightKey));
    final clipped = [
      for (final control in controls(tester))
        if (control.overlaps(light)) control,
    ];
    expect(
      clipped,
      isNotEmpty,
      reason: 'the row this is about no longer reaches the light',
    );

    final dispatched = core.dispatched.length;
    await tester.tapAt(clipped.single.center);
    await tester.pumpAndSettle();

    // The press went to the chip -- which asks the engine for a filtered
    // library -- and not to the light, whose popup is what a press in the
    // covered corner opens.
    expect(core.dispatched.length, greaterThan(dispatched));
    expect(find.byKey(SharingStopDialog.notNowKey), findsNothing);
  });
}

/// [element] is [ancestor] or is drawn inside it.
bool _under(Element element, Element ancestor) {
  if (element == ancestor) return true;
  var found = false;
  element.visitAncestorElements((e) {
    if (e == ancestor) found = true;
    return !found;
  });
  return found;
}
