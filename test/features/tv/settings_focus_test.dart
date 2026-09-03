import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/addons/addons_screen.dart';
import 'package:xtremio/features/settings/account_section.dart';
import 'package:xtremio/features/settings/core_settings.dart';
import 'package:xtremio/features/settings/settings_screen.dart';
import 'package:xtremio/shell/device_profile.dart';

import '../../support/fake_core_client.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

/// An anonymous profile with default settings, plus what Addons needs.
///
/// [embeddedUrl] is what `init` reported as the embedded stream server, so
/// that the streaming-server section offers both of its choices.
FakeCoreClient fakeCore({Uri? embeddedUrl}) => FakeCoreClient(
  state: {
    CoreField.ctx: loadCtxLoggedOutFixture(),
    CoreField.installedAddons: loadInstalledAddonsFixture(),
    CoreField.remoteAddons: loadRemoteAddonsFixture(),
  },
  initInfo: CoreInitInfo(serverBaseUrl: embeddedUrl, schemaVersion: 25),
);

Widget harness(FakeCoreClient core) => DeviceScope(
  profile: tv,
  child: CoreScope(
    client: core,
    initInfo: core.initInfo,
    child: const MaterialApp(home: SettingsScreen()),
  ),
);

/// The settings map of the last `UpdateSettings` dispatched.
Map<String, dynamic> lastSettings(FakeCoreClient core) {
  final action = core.dispatched.lastWhere(
    (a) => a.action['args']?['action'] == 'UpdateSettings',
  );
  return (action.action['args'] as Map<String, dynamic>)['args']
      as Map<String, dynamic>;
}

/// Presses down until the focused control reads [label], at most [limit]
/// times.
Future<void> downTo(WidgetTester tester, String label, {int limit = 40}) async {
  for (var i = 0; i < limit && focusedLabel(tester) != label; i++) {
    await press(tester, LogicalKeyboardKey.arrowDown);
  }
  expect(focusedLabel(tester), label);
}

void main() {
  testWidgets('down leaves the sign-in fields and walks on to the tiles', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();
    expect(focusedLabel(tester), isNull);

    // The account form comes first: two text fields, which must not keep
    // the D-pad (a field claims every arrow key while focused).
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<TextField>(), isTrue);
    final email = FocusManager.instance.primaryFocus!;
    expect(
      tester
          .getRect(find.byKey(AccountSection.emailFieldKey))
          .contains(email.rect.center),
      isTrue,
    );
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<TextField>(), isTrue);
    expect(FocusManager.instance.primaryFocus, isNot(email));
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<TextField>(), isFalse);
    expect(focusedLabel(tester), 'Sign in');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), 'Create an account');

    // Up goes back into the field, left and right walk out of an empty one.
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusIn<TextField>(), isTrue);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(FocusManager.instance.primaryFocus, email);

    await downTo(tester, 'Addons');
    await press(tester, LogicalKeyboardKey.select);
    expect(find.byType(AddonsScreen), findsOneWidget);
  });

  testWidgets('the D-pad walks the streaming-server choices and off them', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    final core = fakeCore(embeddedUrl: Uri.parse('http://127.0.0.1:11470'));
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    await press(tester, LogicalKeyboardKey.arrowDown);
    await downTo(tester, 'Embedded server');
    expect(core.dispatched, isEmpty, reason: 'walking onto one picks nothing');

    // Flutter's RadioGroup takes all four arrow keys to move the
    // *selection*, and wraps around at the ends: on a television that shut
    // the remote inside the pair for good, rewriting the setting on every
    // press. Down walks the choices and then leaves them.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedLabel(tester), 'Remote server');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedLabel(tester), isNot('Embedded server'));
    expect(focusedLabel(tester), isNot('Remote server'));

    // And up walks back in, and out of the top.
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedLabel(tester), 'Remote server');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedLabel(tester), 'Embedded server');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedLabel(tester), isNot('Embedded server'));
    expect(focusedLabel(tester), isNot('Remote server'));
    expect(core.dispatched, isEmpty, reason: 'nothing was chosen yet');

    // Select is what picks one: the remote choice opens its URL field.
    await downTo(tester, 'Remote server');
    await press(tester, LogicalKeyboardKey.select);
    expect(
      find.byKey(StreamingServerSection.remoteUrlFieldKey),
      findsOneWidget,
    );
  });

  testWidgets('select flips a switch and picks from a choice menu', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();
    final defaults = ProfileState.fromCtx(loadCtxLoggedOutFixture()).settings;

    await press(tester, LogicalKeyboardKey.arrowDown);
    await downTo(tester, 'Binge watching');
    expect(focusIn<SwitchListTile>(), isTrue);
    await press(tester, LogicalKeyboardKey.select);
    expect(
      lastSettings(core)['bingeWatching'],
      !(defaults.json['bingeWatching'] as bool),
    );

    // The next tile's control is its dropdown, reading the current value.
    final countdown = defaults.json['nextVideoNotificationDuration'] as int;
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<DropdownButton<int>>(), isTrue);
    expect(focusedLabel(tester), '${countdown ~/ 1000} s');

    await press(tester, LogicalKeyboardKey.select);
    // The menu is a route listing every option, the current one focused.
    expect(find.text('Disabled'), findsOneWidget);
    expect(focusedLabel(tester), '${countdown ~/ 1000} s');
    await press(tester, LogicalKeyboardKey.arrowUp);
    final picked = focusedLabel(tester);
    expect(picked, isNot('${countdown ~/ 1000} s'));
    await press(tester, LogicalKeyboardKey.select);
    expect(find.text('Disabled'), findsNothing, reason: 'menu closed');
    final chosen = lastSettings(core)['nextVideoNotificationDuration'] as int;
    expect(chosen, isNot(countdown));
    expect(picked, chosen == 0 ? 'Disabled' : '${chosen ~/ 1000} s');
    expect(focusIn<DropdownButton<int>>(), isTrue, reason: 'focus returns');
  });
}
