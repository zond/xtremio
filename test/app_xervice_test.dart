import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';

import 'support/empty_board.dart';
import 'support/fake_core_client.dart';
import 'support/fake_prefs_client.dart';
import 'support/fake_secret_store.dart';
import 'support/fake_sharing.dart';
import 'support/fake_xervice.dart';
import 'support/fixtures.dart';

/// The app keeps its copies on xtremio-xervice in step with the account:
/// at a signed-in start and at every sign-in, and never signed out.
void main() {
  late FakeXervice service;
  late FakeFacesStore store;
  late FakeDriveVaultStore vault;

  FakeCoreClient coreWith(Map<String, dynamic> ctx) => FakeCoreClient(
    state: {CoreField.ctx: ctx, CoreField.board: emptyBoard()},
  );

  String keyOf(Map<String, dynamic> ctx) => stremioAuthKeyOf(ctx)!;

  setUp(() {
    store = FakeFacesStore();
    vault = FakeDriveVaultStore();
    service = FakeXervice(accounts: {keyOf(loadCtxLoggedInFixture()): 'user-a'})
      ..routes = (request, user) =>
          store.routes(request, user) ??
          vault.routes(request, user) ??
          const XerviceAnswer(404);
  });

  Future<AppPrefs> prefsWithALike() async {
    final prefs = AppPrefs(client: FakePrefsClient());
    await prefs.load();
    await prefs.setFaces(
      Faces.empty.marking('tt1', Face.like, DateTime.utc(2026)),
    );
    return prefs;
  }

  testWidgets('a signed-in start syncs the faces', (tester) async {
    final prefs = await prefsWithALike();
    await tester.pumpWidget(
      XtremioApp(
        core: coreWith(loadCtxLoggedInFixture()),
        prefs: prefs,
        sharingActivity: FakeSharingActivity(),
        xervice: service,
      ),
    );
    await tester.pumpAndSettle();
    expect(store.byUser['user-a']!.of('tt1'), Face.like);
  });

  testWidgets('signed out asks nothing; a sign-in syncs', (tester) async {
    final prefs = await prefsWithALike();
    final core = coreWith(loadCtxLoggedOutFixture());
    await tester.pumpWidget(
      XtremioApp(
        core: core,
        prefs: prefs,
        sharingActivity: FakeSharingActivity(),
        xervice: service,
      ),
    );
    await tester.pumpAndSettle();
    expect(service.requests, isEmpty);

    core.setState(CoreField.ctx, loadCtxLoggedInFixture());
    await tester.pumpAndSettle();
    expect(store.byUser['user-a']!.of('tt1'), Face.like);
  });

  testWidgets('a signed-in start takes the vault\'s Drive grant only once '
      'the device\'s own has been read', (tester) async {
    vault.byUser['user-a'] = 'shared-grant';
    final prefs = AppPrefs(client: FakePrefsClient());
    await prefs.load();
    // A keystore slow to answer: the vault must wait for it.
    final store = _SlowSecretStore({DriveAccount.refreshTokenKey: 'own-grant'});
    final own = DriveAccount(prefs: prefs, secrets: store);
    await tester.pumpWidget(
      XtremioApp(
        core: coreWith(loadCtxLoggedInFixture()),
        prefs: prefs,
        drive: own,
        sharingActivity: FakeSharingActivity(),
        xervice: service,
      ),
    );
    await tester.pumpAndSettle();
    store.answer.complete();
    await tester.pumpAndSettle();
    expect(own.refreshToken, 'own-grant');
    expect(store.stored[DriveAccount.refreshTokenKey], 'own-grant');

    final prefs2 = AppPrefs(client: FakePrefsClient());
    await prefs2.load();
    final empty = DriveAccount(prefs: prefs2, secrets: FakeSecretStore());
    await tester.pumpWidget(
      XtremioApp(
        key: const ValueKey('second'),
        core: coreWith(loadCtxLoggedInFixture()),
        prefs: prefs2,
        drive: empty,
        sharingActivity: FakeSharingActivity(),
        xervice: service,
      ),
    );
    await tester.pumpAndSettle();
    expect(empty.refreshToken, 'shared-grant');

    // A pairing on this device goes to the vault.
    await empty.link(refreshToken: 'paired-here');
    expect(vault.byUser['user-a'], 'paired-here');
  });
}

/// A [FakeSecretStore] whose reads wait for [answer].
class _SlowSecretStore extends FakeSecretStore {
  _SlowSecretStore(super.stored);

  final Completer<void> answer = Completer<void>();

  @override
  Future<String?> read(String key) async {
    await answer.future;
    return super.read(key);
  }
}
