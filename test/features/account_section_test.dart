import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/settings/account_section.dart';
import 'package:xtremio/features/settings/settings_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/tv_text_field.dart';

import '../support/fake_core_client.dart';
import '../support/fixtures.dart';
import '../support/text_entry.dart';

/// The Settings screen (the Account section sits at its top) on a tall
/// viewport, so the whole registration form stays tappable.
Future<void> pumpSettings(
  WidgetTester tester,
  FakeCoreClient core, {
  DeviceProfile device = DeviceProfile.fallback,
}) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    DeviceScope(
      profile: device,
      child: CoreScope(
        client: core,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

FakeCoreClient loggedOutCore() =>
    FakeCoreClient(state: {CoreField.ctx: loadCtxLoggedOutFixture()});

FakeCoreClient loggedInCore({bool addonsLocked = false}) {
  final ctx = loadCtxLoggedInFixture();
  (ctx['profile'] as Map<String, dynamic>)['addonsLocked'] = addonsLocked;
  return FakeCoreClient(state: {CoreField.ctx: ctx});
}

List<CoreAction> ctxActions(FakeCoreClient core) => [
  for (final action in core.dispatched)
    if (action.field == CoreField.ctx) action,
];

const authError = RuntimeCoreEvent({
  'event': 'Error',
  'args': {
    'error': {'type': 'API', 'message': 'Wrong email or password', 'code': 3},
    'source': {
      'event': 'UserAuthenticated',
      'args': {
        'auth_request': {
          'type': 'Login',
          'email': 'user@example.com',
          'password': 'secret',
          'facebook': false,
        },
      },
    },
  },
});

const userAuthenticated = RuntimeCoreEvent({
  'event': 'UserAuthenticated',
  'args': {
    'auth_request': {
      'type': 'Login',
      'email': 'user@example.com',
      'password': 'secret',
      'facebook': false,
    },
  },
});

/// Emits [event] and renders its effect. The fake's stream delivers
/// asynchronously; on a static screen (no frame scheduled) the first pump
/// only flushes that delivery, the second draws the result.
Future<void> deliver(
  WidgetTester tester,
  FakeCoreClient core,
  CoreEvent event,
) async {
  core.emit(event);
  await tester.pump();
  await tester.pump();
}

Future<void> fillCredentials(
  WidgetTester tester, {
  String email = 'user@example.com',
  String password = 'secret',
}) async {
  await tester.enterText(find.byKey(AccountSection.emailFieldKey), email);
  await tester.enterText(find.byKey(AccountSection.passwordFieldKey), password);
}

void main() {
  group('signed out', () {
    testWidgets('shows the sign-in form at the top and dispatches nothing', (
      tester,
    ) async {
      final core = loggedOutCore();
      await pumpSettings(tester, core);

      expect(find.text('Account'), findsOneWidget);
      expect(find.byKey(AccountSection.emailFieldKey), findsOneWidget);
      expect(find.byKey(AccountSection.passwordFieldKey), findsOneWidget);
      expect(find.byKey(AccountSection.confirmPasswordFieldKey), findsNothing);
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Create an account'), findsOneWidget);
      expect(find.text(AccountSection.libraryNote), findsOneWidget);
      expect(find.text('Log out'), findsNothing);
      expect(core.dispatched, isEmpty);

      // The Account section comes before the Addons one.
      final accountY = tester.getTopLeft(find.text('Account')).dy;
      final addonsY = tester
          .getTopLeft(find.widgetWithText(ListTile, 'Addons'))
          .dy;
      expect(accountY, lessThan(addonsY));
    });

    testWidgets('an empty ctx (nothing pulled yet) counts as anonymous', (
      tester,
    ) async {
      final core = FakeCoreClient();
      await pumpSettings(tester, core);
      expect(find.byKey(AccountSection.emailFieldKey), findsOneWidget);
      expect(find.text('Log out'), findsNothing);
    });

    testWidgets('Sign in dispatches Login on ctx and spins until the '
        'outcome', (tester) async {
      final core = loggedOutCore();
      await pumpSettings(tester, core);
      await fillCredentials(tester);
      await tester.tap(find.byKey(AccountSection.submitButtonKey));
      await tester.pump();

      expect(ctxActions(core), hasLength(1));
      expect(
        ctxActions(core).single.toJson(),
        CoreActions.login(
          email: 'user@example.com',
          password: 'secret',
        ).toJson(),
      );
      expect(ctxActions(core).single.field, CoreField.ctx);
      expect(find.byKey(AccountSection.submitButtonKey), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<TvTextField>(find.byKey(AccountSection.emailFieldKey))
            .enabled,
        isFalse,
      );

      // An error from elsewhere leaves the spinner alone.
      await deliver(
        tester,
        core,
        const RuntimeCoreEvent({
          'event': 'Error',
          'args': {
            'error': {'type': 'Other', 'code': 2, 'message': 'x'},
            'source': {'event': 'LibraryItemRemoved', 'args': {}},
          },
        }),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('x'), findsNothing);

      await deliver(tester, core, authError);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Wrong email or password'), findsOneWidget);
      expect(find.byKey(AccountSection.submitButtonKey), findsOneWidget);
      // The typed password is kept for a retry.
      expect(
        tester
            .widget<TvTextField>(find.byKey(AccountSection.passwordFieldKey))
            .controller
            .text,
        'secret',
      );
    });

    testWidgets('trims the email and does not submit an invalid form', (
      tester,
    ) async {
      final core = loggedOutCore();
      await pumpSettings(tester, core);

      await tester.tap(find.byKey(AccountSection.submitButtonKey));
      await tester.pump();
      expect(find.text('Enter a valid email address'), findsOneWidget);
      expect(core.dispatched, isEmpty);

      await fillCredentials(tester, email: ' user@example.com ', password: '');
      await tester.tap(find.byKey(AccountSection.submitButtonKey));
      await tester.pump();
      expect(find.text('Enter a password'), findsOneWidget);
      expect(find.text('Enter a valid email address'), findsNothing);
      expect(core.dispatched, isEmpty);

      await fillCredentials(tester, email: ' user@example.com ');
      await tester.tap(find.byKey(AccountSection.submitButtonKey));
      await tester.pump();
      expect(find.text('Enter a password'), findsNothing);
      expect(
        ctxActions(core).single.action,
        CoreActions.login(email: 'user@example.com', password: 'secret').action,
      );
    });

    testWidgets('UserAuthenticated and the new ctx switch to the account', (
      tester,
    ) async {
      final core = loggedOutCore();
      await pumpSettings(tester, core);
      await fillCredentials(tester);
      await tester.tap(find.byKey(AccountSection.submitButtonKey));
      await tester.pump();

      // The engine publishes the new state before the event.
      core.setState(CoreField.ctx, loadCtxLoggedInFixture());
      core.emit(userAuthenticated);
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('user@example.com'), findsOneWidget);
      expect(find.text('Log out'), findsOneWidget);
      expect(find.text('Sync now'), findsOneWidget);
      expect(find.byKey(AccountSection.emailFieldKey), findsNothing);
      expect(find.byKey(AccountSection.addonsLockedBannerKey), findsNothing);
      expect(find.byKey(AccountSection.libraryMissingBannerKey), findsNothing);
    });

    group('Create account', () {
      Future<void> switchToRegister(WidgetTester tester) async {
        await tester.tap(find.text('Create an account'));
        await tester.pumpAndSettle();
      }

      testWidgets('adds the confirmation and the consent boxes', (
        tester,
      ) async {
        final core = loggedOutCore();
        await pumpSettings(tester, core);
        await switchToRegister(tester);

        expect(
          find.byKey(AccountSection.confirmPasswordFieldKey),
          findsOneWidget,
        );
        expect(find.byKey(AccountSection.tosCheckboxKey), findsOneWidget);
        expect(find.byKey(AccountSection.privacyCheckboxKey), findsOneWidget);
        expect(find.byKey(AccountSection.marketingCheckboxKey), findsOneWidget);
        expect(find.text('Create account'), findsOneWidget);
        expect(find.text('Sign in'), findsNothing);
        expect(find.text('I already have an account'), findsOneWidget);

        await tester.tap(find.text('I already have an account'));
        await tester.pumpAndSettle();
        expect(find.byKey(AccountSection.tosCheckboxKey), findsNothing);
        expect(find.text('Sign in'), findsOneWidget);
      });

      testWidgets('requires matching passwords and both consents', (
        tester,
      ) async {
        final core = loggedOutCore();
        await pumpSettings(tester, core);
        await switchToRegister(tester);
        await fillCredentials(tester);

        await tester.enterText(
          find.byKey(AccountSection.confirmPasswordFieldKey),
          'other',
        );
        await tester.tap(find.byKey(AccountSection.submitButtonKey));
        await tester.pump();
        expect(find.text('The passwords do not match'), findsOneWidget);
        expect(core.dispatched, isEmpty);

        await tester.enterText(
          find.byKey(AccountSection.confirmPasswordFieldKey),
          'secret',
        );
        await tester.tap(find.byKey(AccountSection.tosCheckboxKey));
        await tester.tap(find.byKey(AccountSection.submitButtonKey));
        await tester.pump();
        expect(
          find.textContaining('Accept the Terms of Service'),
          findsOneWidget,
        );
        expect(core.dispatched, isEmpty);

        await tester.tap(find.byKey(AccountSection.privacyCheckboxKey));
        await tester.tap(find.byKey(AccountSection.submitButtonKey));
        await tester.pump();
        expect(find.textContaining('Accept the Terms'), findsNothing);
        expect(ctxActions(core), hasLength(1));
        expect(ctxActions(core).single.toJson(), {
          'field': 'ctx',
          'action': {
            'action': 'Ctx',
            'args': {
              'action': 'Authenticate',
              'args': {
                'type': 'Register',
                'email': 'user@example.com',
                'password': 'secret',
                'gdpr_consent': {
                  'tos': true,
                  'privacy': true,
                  'marketing': false,
                  'from': 'xtremio',
                },
              },
            },
          },
        });
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      });

      testWidgets('marketing consent is optional and carried when ticked', (
        tester,
      ) async {
        final core = loggedOutCore();
        await pumpSettings(tester, core);
        await switchToRegister(tester);
        await fillCredentials(tester);
        await tester.enterText(
          find.byKey(AccountSection.confirmPasswordFieldKey),
          'secret',
        );
        await tester.tap(find.byKey(AccountSection.tosCheckboxKey));
        await tester.tap(find.byKey(AccountSection.privacyCheckboxKey));
        await tester.tap(find.byKey(AccountSection.marketingCheckboxKey));
        await tester.tap(find.byKey(AccountSection.submitButtonKey));
        await tester.pump();

        expect(
          ctxActions(core).single.action,
          CoreActions.register(
            email: 'user@example.com',
            password: 'secret',
            consent: const GdprConsent(
              tos: true,
              privacy: true,
              marketing: true,
              from: 'xtremio',
            ),
          ).action,
        );

        // A failed registration shows the API's message.
        await deliver(
          tester,
          core,
          const RuntimeCoreEvent({
            'event': 'Error',
            'args': {
              'error': {
                'type': 'API',
                'message': 'This email is already registered',
                'code': 1,
              },
              'source': {
                'event': 'UserAuthenticated',
                'args': {'auth_request': {}},
              },
            },
          }),
        );
        expect(find.text('This email is already registered'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      });
    });
  });

  group('signed in', () {
    testWidgets('shows the email, Log out dispatches Logout', (tester) async {
      final core = loggedInCore();
      await pumpSettings(tester, core);

      expect(find.text('user@example.com'), findsOneWidget);
      expect(find.byKey(AccountSection.emailFieldKey), findsNothing);
      expect(find.text(AccountSection.libraryNote), findsNothing);
      expect(core.dispatched, isEmpty);

      await tester.tap(find.text('Log out'));
      await tester.pump();
      expect(ctxActions(core), hasLength(1));
      expect(ctxActions(core).single.toJson(), CoreActions.logout().toJson());

      // The engine resets the profile and says so.
      core.setState(CoreField.ctx, loadCtxLoggedOutFixture());
      core.emit(const RuntimeCoreEvent({'event': 'UserLoggedOut', 'args': {}}));
      await tester.pumpAndSettle();
      expect(find.byKey(AccountSection.emailFieldKey), findsOneWidget);
      expect(find.text('Log out'), findsNothing);
    });

    testWidgets('Sync now pulls library, addons and notifications', (
      tester,
    ) async {
      final core = loggedInCore();
      await pumpSettings(tester, core);

      await tester.tap(find.text('Sync now'));
      await tester.pump();
      expect(
        [for (final action in ctxActions(core)) action.action],
        [
          CoreActions.syncLibraryWithAPI().action,
          CoreActions.pullAddonsFromAPI().action,
          CoreActions.pullNotifications().action,
        ],
      );
      expect(find.text('Sync now'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await deliver(
        tester,
        core,
        const RuntimeCoreEvent({
          'event': 'LibrarySyncWithAPIPlanned',
          'args': {
            'uid': 'fake_user_id',
            'plan': [[], []],
          },
        }),
      );
      expect(find.text('Sync now'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('the addons-locked banner offers a retry', (tester) async {
      final core = loggedInCore(addonsLocked: true);
      await pumpSettings(tester, core);

      expect(find.byKey(AccountSection.addonsLockedBannerKey), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(
        ctxActions(core).single.toJson(),
        CoreActions.pullAddonsFromAPI().toJson(),
      );

      core.setState(CoreField.ctx, loadCtxLoggedInFixture());
      await tester.pumpAndSettle();
      expect(find.byKey(AccountSection.addonsLockedBannerKey), findsNothing);
    });

    testWidgets('the library-missing banner follows the events', (
      tester,
    ) async {
      final core = loggedInCore();
      await pumpSettings(tester, core);
      expect(find.byKey(AccountSection.libraryMissingBannerKey), findsNothing);

      // What the login path emits when the library fetch failed.
      await deliver(
        tester,
        core,
        const RuntimeCoreEvent({
          'event': 'Error',
          'args': {
            'error': {
              'type': 'Other',
              'code': 8,
              'message': 'User library is missing',
            },
            'source': {
              'event': 'UserLibraryMissing',
              'args': {'library_missing': true},
            },
          },
        }),
      );
      expect(
        find.byKey(AccountSection.libraryMissingBannerKey),
        findsOneWidget,
      );

      // A later sync pulled the library.
      await deliver(
        tester,
        core,
        const RuntimeCoreEvent({
          'event': 'UserLibraryMissing',
          'args': {'library_missing': false},
        }),
      );
      expect(find.byKey(AccountSection.libraryMissingBannerKey), findsNothing);
    });

    testWidgets('logging out clears the library-missing banner', (
      tester,
    ) async {
      final core = loggedInCore();
      await pumpSettings(tester, core);
      await deliver(
        tester,
        core,
        const RuntimeCoreEvent({
          'event': 'UserLibraryMissing',
          'args': {'library_missing': true},
        }),
      );
      expect(
        find.byKey(AccountSection.libraryMissingBannerKey),
        findsOneWidget,
      );

      core.setState(CoreField.ctx, loadCtxLoggedOutFixture());
      core.emit(const RuntimeCoreEvent({'event': 'UserLoggedOut', 'args': {}}));
      await tester.pumpAndSettle();
      core.setState(CoreField.ctx, loadCtxLoggedInFixture());
      await tester.pumpAndSettle();
      expect(find.byKey(AccountSection.libraryMissingBannerKey), findsNothing);
    });
  });

  group('event helpers', () {
    test('read only the source name, the message and the flag', () {
      expect(AccountSection.errorSourceOf(authError), 'UserAuthenticated');
      expect(
        AccountSection.errorMessageOf(authError),
        'Wrong email or password',
      );
      expect(AccountSection.errorSourceOf(userAuthenticated), isNull);
      expect(AccountSection.libraryMissingOf(userAuthenticated), isNull);
      expect(AccountSection.libraryMissingOf(authError), isNull);
      expect(
        AccountSection.libraryMissingOf(
          const RuntimeCoreEvent({
            'event': 'UserLibraryMissing',
            'args': {'library_missing': false},
          }),
        ),
        isFalse,
      );
      expect(
        AccountSection.libraryMissingOf(
          const RuntimeCoreEvent({
            'event': 'Error',
            'args': {
              'error': {'type': 'Other', 'code': 8, 'message': 'm'},
              'source': {
                'event': 'UserLibraryMissing',
                'args': {'library_missing': true},
              },
            },
          }),
        ),
        isTrue,
      );
    });
  });

  // The device the form exists for. On Android TV the app window keeps
  // input focus while the on-screen keyboard is up, so the keyboard cannot
  // move its own selection and neither field can be typed into; the fields
  // here host no IME at all and hand the string to the platform's screen.
  group('on a television', () {
    const tv = DeviceProfile(isTv: true, hasTouch: false);

    testWidgets('the remote types both credentials and signs in', (
      tester,
    ) async {
      final core = loggedOutCore();
      await pumpSettings(tester, core, device: tv);
      expect(find.byType(EditableText), findsNothing);

      var calls = answerTextEntry('user@example.com');
      await tester.tap(find.byKey(AccountSection.emailFieldKey));
      await tester.pumpAndSettle();
      expect(calls.single.arguments, {
        'label': 'Email',
        'value': '',
        'kind': 'email',
      });
      expect(find.text('user@example.com'), findsOneWidget);
      expect(core.dispatched, isEmpty, reason: 'the email is not a submit');

      // The password screen is asked for masking, and confirming there is
      // the remote's Done: it signs in without a trip to the button.
      calls = answerTextEntry('secret');
      await tester.tap(find.byKey(AccountSection.passwordFieldKey));
      await settleTextEntry(tester);
      expect((calls.single.arguments as Map)['kind'], 'password');
      expect(find.text('secret'), findsNothing);
      expect(
        ctxActions(core).single.toJson(),
        CoreActions.login(
          email: 'user@example.com',
          password: 'secret',
        ).toJson(),
      );
    });

    testWidgets('a cancelled screen leaves the field as it was', (
      tester,
    ) async {
      final core = loggedOutCore();
      await pumpSettings(tester, core, device: tv);

      answerTextEntry('user@example.com');
      await tester.tap(find.byKey(AccountSection.emailFieldKey));
      await tester.pumpAndSettle();

      answerTextEntry(null);
      await tester.tap(find.byKey(AccountSection.emailFieldKey));
      await tester.pumpAndSettle();

      expect(find.text('user@example.com'), findsOneWidget);
      expect(core.dispatched, isEmpty);
    });
  });
}
