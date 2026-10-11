import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/diagnostics_capture.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_secret_store.dart';
import '../support/fake_xervice.dart';

const String _key = 'stremio-session-key-abcdef0123456789';
const String _paired = '1//0g-this-devices-own-grant';
const String _shared = '1//0g-the-grant-another-device-paired';

void main() {
  late String? signedIn;
  late FakeXervice service;
  late FakeDriveVaultStore vault;
  late List<String?> handedToRust;
  late FakeSecretStore secrets;
  late DriveAccount account;
  late DriveVault driveVault;

  Future<void> boot({Map<String, String>? stored}) async {
    final prefs = AppPrefs(client: FakePrefsClient());
    await prefs.load();
    secrets = FakeSecretStore(stored);
    account = DriveAccount(
      prefs: prefs,
      secrets: secrets,
      grantSink: (token) async => handedToRust.add(token),
    );
    addTearDown(account.dispose);
    await account.load();
    driveVault = DriveVault(
      identity: XerviceIdentity(http: service, authKey: () => signedIn),
      account: account,
    );
    account.pairedSink = driveVault.store;
    handedToRust.clear();
  }

  setUp(() {
    signedIn = _key;
    handedToRust = [];
    vault = FakeDriveVaultStore();
    service = FakeXervice(accounts: {_key: 'user-a'})
      ..routes = (request, user) =>
          vault.routes(request, user) ?? const XerviceAnswer(404);
  });

  test('a pairing puts its grant in the vault', () async {
    await boot();
    await account.link(refreshToken: _paired);
    expect(vault.byUser['user-a'], _paired);
  });

  test('a device with no grant takes the vault\'s, the way a pairing '
      'installs one, and does not send it back', () async {
    vault.byUser['user-a'] = _shared;
    await boot();
    await driveVault.reconcile();
    expect(account.state, DriveLinkState.linked);
    expect(account.refreshToken, _shared);
    expect(secrets.stored[DriveAccount.refreshTokenKey], _shared);
    expect(handedToRust, [_shared]);
    expect(
      service.requests.where((request) => request.method == 'PUT'),
      isEmpty,
    );
  });

  test('a device with a grant of its own never takes the vault\'s', () async {
    vault.byUser['user-a'] = _shared;
    await boot(stored: {DriveAccount.refreshTokenKey: _paired});
    await driveVault.reconcile();
    expect(account.refreshToken, _paired);
    expect(service.requests, isEmpty, reason: 'nothing to ask');
  });

  test('a pairing that lands while the vault is being read wins', () async {
    vault.byUser['user-a'] = _shared;
    await boot();
    final release = Completer<void>();
    service.holdRoutes = release.future;
    final reading = driveVault.reconcile();
    await pumpEventQueue();
    expect(service.requests.last.path, '/vault/drive', reason: 'held');
    final pairing = account.link(refreshToken: _paired);
    await pumpEventQueue();
    release.complete();
    await reading;
    await pairing;
    expect(account.refreshToken, _paired);
    expect(secrets.stored[DriveAccount.refreshTokenKey], _paired);
    expect(vault.byUser['user-a'], _paired, reason: 'the pairing was shared');
  });

  test('a refused grant is not replaced by the vault\'s either', () async {
    vault.byUser['user-a'] = _shared;
    await boot(stored: {DriveAccount.refreshTokenKey: _paired});
    await account.notePairAgain();
    await driveVault.reconcile();
    expect(account.state, DriveLinkState.pairAgain);
    expect(service.requests, isEmpty);
  });

  test('an empty vault, signed out, or offline changes nothing', () async {
    await boot();
    await driveVault.reconcile();
    expect(account.state, DriveLinkState.unlinked);
    signedIn = null;
    vault.byUser['user-a'] = _shared;
    await driveVault.reconcile();
    expect(account.state, DriveLinkState.unlinked);
    signedIn = _key;
    service.offline = true;
    await driveVault.reconcile();
    expect(account.state, DriveLinkState.unlinked);
  });

  test(
    'forgetting deletes the vault\'s grant and leaves the device\'s',
    () async {
      vault.byUser['user-a'] = _shared;
      await boot(stored: {DriveAccount.refreshTokenKey: _paired});
      expect(await driveVault.forgetEverywhere(), isTrue);
      expect(vault.byUser, isEmpty);
      expect(account.refreshToken, _paired);
      service.offline = true;
      expect(await driveVault.forgetEverywhere(), isFalse);
    },
  );

  test('no log line of a whole round trip carries a grant', () async {
    final lines = captureDiagnostics();
    vault.byUser['user-a'] = _shared;
    await boot();
    await driveVault.reconcile();
    await account.unlink();
    await account.link(refreshToken: _paired);
    vault.byUser.clear();
    service.routes = (request, user) => const XerviceAnswer(500);
    await account.link(refreshToken: _paired);
    service.offline = true;
    await driveVault.reconcile();
    await driveVault.forgetEverywhere();
    expect(lines, isNotEmpty);
    for (final line in lines) {
      expect(line, isNot(contains(_shared)));
      expect(line, isNot(contains(_paired)));
      expect(line, isNot(contains(_key)));
    }
  });
}
