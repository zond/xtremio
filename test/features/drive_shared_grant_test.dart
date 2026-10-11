import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/drive/drive_match.dart';

import '../support/fake_drive_file_lister.dart';
import '../support/fake_drive_pairing_service.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_xervice.dart';

/// A Drive grant taken from the account's vault brings the files with it:
/// everything the grant reaches is listed into this device's list and
/// matched to titles, without the Library having been opened.
void main() {
  const key = 'stremio-session-key-abcdef0123456789';
  const shared = '1//0g-the-grant-another-device-paired';

  /// Cinemeta, answering The Matrix and nothing else.
  Future<List<Map<String, dynamic>>> search(String type, String query) async =>
      type == 'movie' && query == 'The Matrix'
      ? [
          {
            'id': 'tt0133093',
            'imdb_id': 'tt0133093',
            'name': 'The Matrix',
            'releaseInfo': '1999',
            'type': 'movie',
          },
        ]
      : const [];

  test('installed from the vault: the files are listed and matched', () async {
    final account = await driveAccount(prefsClient: FakePrefsClient());
    final vault = FakeDriveVaultStore()..byUser['user-a'] = shared;
    final service = FakeXervice(accounts: {key: 'user-a'})
      ..routes = (request, user) =>
          vault.routes(request, user) ?? const XerviceAnswer(404);
    final lister = FakeDriveFileLister(
      answers: [
        FakeDriveFileLister.listing({
          'file-matrix': 'The.Matrix.1999.1080p.BluRay.mkv',
          'file-unknown': 'ep6.avi',
        }),
      ],
    );
    final driveVault = DriveVault(
      identity: XerviceIdentity(http: service, authKey: () => key),
      account: account,
      adopted: () => fillSharedDrive(account, lister: lister, search: search),
    );

    await driveVault.reconcile();

    expect(account.refreshToken, shared);
    expect(lister.asked, [shared], reason: 'listed with the shared grant');
    expect(
      {for (final f in account.files.entries) f.fileId},
      {'file-matrix', 'file-unknown'},
    );
    expect(
      account.files.forFile('file-matrix')!.match?.cinemetaId,
      'tt0133093',
    );
    expect(account.files.forFile('file-unknown')!.match, isNull);
  });

  test('a listing that fails leaves the grant installed and the list empty '
      'for the next Reload', () async {
    final account = await driveAccount(prefsClient: FakePrefsClient());
    await account.link(refreshToken: shared, shared: true);
    await fillSharedDrive(
      account,
      lister: FakeDriveFileLister(),
      search: search,
    );
    expect(account.refreshToken, shared);
    expect(account.files.entries, isEmpty);
  });
}
