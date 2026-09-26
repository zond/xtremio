import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/fake_secret_store.dart';

/// The grant reaches the Rust side exactly when the account's answer
/// changes, and as exactly that answer: the token while the device is
/// linked, `null` when it is not -- so what Rust holds for the Drive
/// downloads it pins on its own is never a token this account has
/// dropped, and never missing while there is one.
void main() {
  Future<(DriveAccount, AppPrefs)> account(
    FakeSecretStore store,
    List<String?> handed,
  ) async {
    final prefs = AppPrefs.inMemory();
    await prefs.load();
    final drive = DriveAccount(
      prefs: prefs,
      secrets: store,
      grantSink: (token) async => handed.add(token),
    );
    addTearDown(() {
      drive.dispose();
      prefs.dispose();
    });
    return (drive, prefs);
  }

  test('a pairing hands the token down; unlinking takes it back', () async {
    final store = FakeSecretStore();
    final handed = <String?>[];
    final (drive, _) = await account(store, handed);
    await drive.load();
    expect(handed, isEmpty, reason: 'nothing stored, nothing to say');

    await drive.linkFile(
      refreshToken: 'refresh-tok-1',
      fileId: 'file-1',
      name: 'A Film.mkv',
      mimeType: 'video/x-matroska',
    );
    expect(handed, ['refresh-tok-1']);

    await drive.unlink();
    expect(handed, ['refresh-tok-1', null]);
  });

  test('a stored pairing is handed down on load', () async {
    final store = FakeSecretStore({DriveAccount.refreshTokenKey: 'stored-tok'});
    final handed = <String?>[];
    final (drive, _) = await account(store, handed);
    await drive.load();
    expect(handed, ['stored-tok']);
    expect(drive.state, DriveLinkState.linked);
  });

  test('a dead pairing takes the token back, and a new one hands the new '
      'token down', () async {
    final store = FakeSecretStore({DriveAccount.refreshTokenKey: 'old-tok'});
    final handed = <String?>[];
    final (drive, _) = await account(store, handed);
    await drive.load();
    await drive.notePairAgain();
    expect(handed, ['old-tok', null]);
    expect(drive.state, DriveLinkState.pairAgain);

    await drive.link(refreshToken: 'new-tok');
    expect(handed, ['old-tok', null, 'new-tok']);
    expect(drive.state, DriveLinkState.linked);
  });

  test(
    'a sink that throws is a line in the log, not a broken account',
    () async {
      final store = FakeSecretStore();
      final prefs = AppPrefs.inMemory();
      await prefs.load();
      final drive = DriveAccount(
        prefs: prefs,
        secrets: store,
        grantSink: (_) async => throw StateError('no core under this test'),
      );
      addTearDown(() {
        drive.dispose();
        prefs.dispose();
      });
      await drive.link(refreshToken: 'refresh-tok');
      expect(drive.state, DriveLinkState.linked);
      expect(drive.refreshToken, 'refresh-tok');
    },
  );
}
