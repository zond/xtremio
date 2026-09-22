import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/addons/addons_screen.dart';
import 'package:xtremio/features/settings/account_section.dart';
import 'package:xtremio/features/settings/core_settings.dart';
import 'package:xtremio/features/settings/recommendations_section.dart';
import 'package:xtremio/features/settings/settings_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/readout.dart';
import 'package:xtremio/widgets/tv_text_field.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_prefs_client.dart';
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

Widget harness(FakeCoreClient core, {AppPrefs? prefs}) {
  const screen = MaterialApp(home: SettingsScreen());
  return DeviceScope(
    profile: tv,
    child: CoreScope(
      client: core,
      initInfo: core.initInfo,
      child: prefs == null ? screen : PrefsScope(prefs: prefs, child: screen),
    ),
  );
}

/// What the engine says when the API refused a sign-in, which is what puts
/// a line of red under the form.
const authRefused = RuntimeCoreEvent({
  'event': 'Error',
  'args': {
    'error': {'type': 'API', 'message': 'Wrong email or password', 'code': 3},
    'source': {'event': 'UserAuthenticated'},
  },
});

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

    // The account form comes first: two fields, which on a television are
    // controls that open the platform's text-entry screen rather than
    // EditableTexts, so nothing there claims an arrow key.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<TvTextField>(), isTrue);
    final email = FocusManager.instance.primaryFocus!;
    expect(
      tester
          .getRect(find.byKey(AccountSection.emailFieldKey))
          .contains(email.rect.center),
      isTrue,
    );
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<TvTextField>(), isTrue);
    expect(FocusManager.instance.primaryFocus, isNot(email));
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<TvTextField>(), isFalse);
    expect(focusedLabel(tester), 'Sign in');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), 'Create an account');

    // Up goes back into the fields, one at a time.
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusIn<TvTextField>(), isTrue);
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

  testWidgets('the remote reaches Buffer ahead and picks a choice', (
    tester,
  ) async {
    // It is the app's own preference rather than a `profile.settings`
    // field, but on a television that changes nothing: it has to be walked
    // to and chosen with the same four keys as its neighbours.
    useScreen(tester, tvSize);
    final prefs = AppPrefs(client: FakePrefsClient());
    final core = fakeCore();
    await tester.pumpWidget(harness(core, prefs: prefs));
    await tester.pumpAndSettle();

    await press(tester, LogicalKeyboardKey.arrowDown);
    await downTo(tester, BufferAhead.normal.label);
    expect(focusIn<DropdownButton<BufferAhead>>(), isTrue);

    await press(tester, LogicalKeyboardKey.select);
    expect(find.text(BufferAhead.wholeFile.label), findsWidgets);
    await press(tester, LogicalKeyboardKey.arrowDown);
    final picked = focusedLabel(tester);
    expect(picked, isNot(BufferAhead.normal.label));
    await press(tester, LogicalKeyboardKey.select);

    expect(prefs.bufferAhead.label, picked);
    expect(core.dispatched, isEmpty, reason: 'it is not a core setting');
    expect(
      focusIn<DropdownButton<BufferAhead>>(),
      isTrue,
      reason: 'focus returns',
    );
  });

  testWidgets('the remote reaches the model chooser and opens it', (
    tester,
  ) async {
    // The model used to be a box, and a box on a television is the
    // text-entry screen and a remote spelling out `gemini-3.1-flash-lite`
    // one letter at a time. It is a menu now, which is the shape every
    // other choice on this screen already takes: walk to it, press
    // select, walk the options, press select.
    useScreen(tester, tvSize);
    final prefs = AppPrefs(client: FakePrefsClient());
    await tester.pumpWidget(harness(fakeCore(), prefs: prefs));
    await tester.pumpAndSettle();

    // No key, so nothing was asked of anybody and what is offered is the
    // measured default.
    final measured = RecommendationsSection.label(defaultSimilarModel);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await downTo(tester, measured);
    expect(focusIn<DropdownButton<String>>(), isTrue);

    await press(tester, LogicalKeyboardKey.select);
    // The menu is a route listing every option, the current one focused.
    expect(find.text(measured), findsWidgets);
    expect(focusedLabel(tester), measured);
    await press(tester, LogicalKeyboardKey.select);

    expect(prefs.similarModel, defaultSimilarModel);
    expect(focusIn<DropdownButton<String>>(), isTrue, reason: 'focus returns');
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
    final none = PlayerSettingsSection.upNextLabel(0);
    expect(find.text(none), findsOneWidget);
    expect(focusedLabel(tester), '${countdown ~/ 1000} s');
    await press(tester, LogicalKeyboardKey.arrowUp);
    final picked = focusedLabel(tester);
    expect(picked, isNot('${countdown ~/ 1000} s'));
    await press(tester, LogicalKeyboardKey.select);
    expect(find.text(none), findsNothing, reason: 'menu closed');
    final chosen = lastSettings(core)['nextVideoNotificationDuration'] as int;
    expect(chosen, isNot(countdown));
    expect(picked, PlayerSettingsSection.upNextLabel(chosen));
    expect(focusIn<DropdownButton<int>>(), isTrue, reason: 'focus returns');
  });

  testWidgets('the remote reaches the line saying why a URL was refused', (
    tester,
  ) async {
    // A read-only block that is only ever on screen when something has
    // gone wrong, which is the worst kind to be unreachable: it appears
    // under the Save that was just pressed, and on a television a block
    // that takes no focus is one the page cannot be scrolled to.
    useScreen(tester, tvSize);
    final core = fakeCore(embeddedUrl: Uri.parse('http://127.0.0.1:11470'));
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    await press(tester, LogicalKeyboardKey.arrowDown);
    await downTo(tester, 'Remote server');
    await press(tester, LogicalKeyboardKey.select);
    // An empty box is not a URL, which is what the line under it says.
    // The Save is beside the box rather than under it, so this is a right
    // press and not another down.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<TvTextField>(), isTrue);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), 'Save');
    await press(tester, LogicalKeyboardKey.select);
    expect(find.text(StreamingServerSection.invalidUrlMessage), findsOneWidget);

    await downTo(tester, StreamingServerSection.invalidUrlMessage);
    expect(focusIn<Readout>(), isTrue);
    expect(focusMarks(), {FocusMark.ring});
  });

  testWidgets('and the account row, which is words rather than a control', (
    tester,
  ) async {
    // Signed in, the first thing on the screen is which account this is --
    // an email address a viewer reads and presses nothing on.
    useScreen(tester, tvSize);
    // With the addon collection locked, so the banner under the account
    // row is drawn as well: it is the other read-only block here, and the
    // only one with a button of its own inside it.
    final ctx = loadCtxLoggedInFixture();
    (ctx['profile'] as Map<String, dynamic>)['addonsLocked'] = true;
    final core = FakeCoreClient(
      state: {
        CoreField.ctx: ctx,
        CoreField.installedAddons: loadInstalledAddonsFixture(),
        CoreField.remoteAddons: loadRemoteAddonsFixture(),
      },
    );
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();
    final email = ProfileState.fromCtx(ctx).user!.email;

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedLabel(tester), email);
    expect(focusIn<Readout>(), isTrue);
    expect(focusMarks(), {FocusMark.ring});

    // And the banner under it, which is a whole paragraph of what went
    // wrong -- reachable itself, with its Retry a stop of its own after
    // it rather than a ring drawn round both.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<Readout>(), isTrue);
    expect(
      focusedLabel(tester),
      startsWith('Your addon collection could not be fetched'),
    );
    expect(focusMarks(), {FocusMark.ring});
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedLabel(tester), 'Retry');
    expect(focusIn<Readout>(), isFalse);
  });

  testWidgets('and the line saying why a sign-in was refused', (tester) async {
    // The error appears under the button that was just pressed, and it is
    // words rather than a control: on a television that is a block the
    // page cannot scroll to unless it takes focus.
    useScreen(tester, tvSize);
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    core.emit(authRefused);
    await tester.pumpAndSettle();
    expect(find.text('Wrong email or password'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.arrowDown);
    await downTo(tester, 'Wrong email or password');
    expect(focusIn<Readout>(), isTrue);
    expect(focusMarks(), {FocusMark.ring});
  });
}
