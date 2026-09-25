import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/diagnostics/diagnostics_report.dart';

import '../support/diagnostics_capture.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_secret_store.dart';

/// Nothing in this repository is a token. This string is a marker a test
/// can search the preferences file and the log for -- it is not a
/// credential, it is not the shape of one, and a real refresh token must
/// never be written into a fixture, a test or a comment here (`AGENTS.md`,
/// "Never log auth material").
const String _token = 'fake-refresh-token-for-tests-only';
const String _rotated = 'fake-rotated-refresh-token-for-tests-only';

final DateTime _at = DateTime.utc(2026, 9, 25, 12);

/// A [DriveAccount] over the two fakes, with the preferences loaded first
/// the way the app loads them.
Future<DriveAccount> _account({
  required FakePrefsClient prefsClient,
  required FakeSecretStore secrets,
}) async {
  final prefs = AppPrefs(client: prefsClient);
  await prefs.load();
  final account = DriveAccount(prefs: prefs, secrets: secrets, now: () => _at);
  await account.load();
  addTearDown(() {
    account.dispose();
    prefs.dispose();
  });
  return account;
}

void main() {
  group('a pairing', () {
    test('the token round-trips and is nowhere in the preferences', () async {
      final prefsClient = FakePrefsClient();
      final secrets = FakeSecretStore();
      final account = await _account(
        prefsClient: prefsClient,
        secrets: secrets,
      );

      final outcome = await account.linkFile(
        refreshToken: _token,
        fileId: 'drive-file-1',
        name: 'Arrival (2016) 2160p.mkv',
        mimeType: 'video/x-matroska',
      );

      expect(outcome, DriveLinkOutcome.stored);
      expect(account.state, DriveLinkState.linked);
      expect(account.refreshToken, _token);
      expect(secrets.stored[DriveAccount.refreshTokenKey], _token);
      // The whole preferences file, not just the keys this feature writes:
      // the point is that the credential is in neither half of it.
      expect(jsonEncode(prefsClient.stored), isNot(contains(_token)));
    });

    test('the file list is a preference and not a secret', () async {
      final prefsClient = FakePrefsClient();
      final secrets = FakeSecretStore();
      final account = await _account(
        prefsClient: prefsClient,
        secrets: secrets,
      );

      await account.linkFile(
        refreshToken: _token,
        fileId: 'drive-file-1',
        name: 'Arrival (2016) 2160p.mkv',
        mimeType: 'video/x-matroska',
      );

      expect(prefsClient.stored[AppPrefs.driveLinkedFilesKey], [
        {
          'id': 'drive-file-1',
          'name': 'Arrival (2016) 2160p.mkv',
          'mime': 'video/x-matroska',
          'linkedAt': _at.toIso8601String(),
        },
      ]);
      // One key in the secure store, and it is the token's.
      expect(secrets.stored.keys, [DriveAccount.refreshTokenKey]);
      expect(jsonEncode(secrets.stored), isNot(contains('drive-file-1')));
      expect(jsonEncode(secrets.stored), isNot(contains('Arrival')));
    });

    test('a restart reads both halves back', () async {
      final prefsClient = FakePrefsClient();
      final secrets = FakeSecretStore();
      final first = await _account(prefsClient: prefsClient, secrets: secrets);
      await first.linkFile(
        refreshToken: _token,
        fileId: 'drive-file-1',
        name: 'Arrival (2016) 2160p.mkv',
        mimeType: 'video/x-matroska',
      );

      // A fresh app start over the same preferences file and the same
      // keyring.
      final restarted = await _account(
        prefsClient: prefsClient,
        secrets: secrets,
      );

      expect(restarted.state, DriveLinkState.linked);
      expect(restarted.refreshToken, _token);
      expect(restarted.files.entries.single.fileId, 'drive-file-1');
      expect(restarted.files.entries.single.linkedAt, _at);
    });

    test('a second pairing replaces the token and adds the file', () async {
      final prefsClient = FakePrefsClient();
      final secrets = FakeSecretStore();
      final account = await _account(
        prefsClient: prefsClient,
        secrets: secrets,
      );

      await account.linkFile(
        refreshToken: _token,
        fileId: 'drive-file-1',
        name: 'one.mkv',
        mimeType: 'video/x-matroska',
      );
      await account.linkFile(
        refreshToken: _rotated,
        fileId: 'drive-file-2',
        name: 'two.mkv',
        mimeType: 'video/x-matroska',
      );

      expect(account.refreshToken, _rotated);
      expect(secrets.stored[DriveAccount.refreshTokenKey], _rotated);
      // One secret, replaced, never one per file.
      expect(secrets.stored.length, 1);
      // Most recently linked first, and the first file is still listed: the
      // new token reaches it too.
      expect(account.files.entries.map((file) => file.fileId), [
        'drive-file-2',
        'drive-file-1',
      ]);
    });

    test('a Cinemeta id can be written against a linked file', () async {
      final prefsClient = FakePrefsClient();
      final account = await _account(
        prefsClient: prefsClient,
        secrets: FakeSecretStore(),
      );
      await account.linkFile(
        refreshToken: _token,
        fileId: 'drive-file-1',
        name: 'Arrival (2016) 2160p.mkv',
        mimeType: 'video/x-matroska',
      );

      await account.noteCinemetaId(
        fileId: 'drive-file-1',
        cinemetaId: 'tt2543164',
      );
      var notified = 0;
      account.addListener(() => notified++);
      // And a file nobody linked is not quietly added -- and does not
      // notify, because a notify nothing changed is a screen rebuilt for
      // nothing.
      await account.noteCinemetaId(fileId: 'nothing', cinemetaId: 'tt0000000');

      expect(notified, 0);
      expect(account.files.entries.single.cinemetaId, 'tt2543164');
      expect(account.files.entries, hasLength(1));
    });
  });

  group('the three states', () {
    test('a device nobody has paired is unlinked', () async {
      final account = await _account(
        prefsClient: FakePrefsClient(),
        secrets: FakeSecretStore(),
      );

      expect(account.state, DriveLinkState.unlinked);
      expect(account.refreshToken, isNull);
      expect(account.files.isEmpty, isTrue);
      expect(account.loaded, isTrue);
    });

    test('a rejected token is not an absent one', () async {
      final prefsClient = FakePrefsClient();
      final secrets = FakeSecretStore();
      final account = await _account(
        prefsClient: prefsClient,
        secrets: secrets,
      );
      await account.linkFile(
        refreshToken: _token,
        fileId: 'drive-file-1',
        name: 'one.mkv',
        mimeType: 'video/x-matroska',
      );

      await account.notePairAgain();

      expect(account.state, DriveLinkState.pairAgain);
      // Distinguishable from unlinked in the one way that matters: the
      // state says so, whatever the store holds.
      expect(account.state, isNot(DriveLinkState.unlinked));
      expect(account.refreshToken, isNull, reason: 'a dead token is not lent');
      expect(secrets.stored, isEmpty, reason: 'it opens nothing; drop it');
      // The list survives: those files are what a new pairing will reach.
      expect(account.files.entries.single.fileId, 'drive-file-1');
      expect(prefsClient.stored[AppPrefs.driveTokenDeadKey], isTrue);
    });

    test('the flag rules: a rejected pairing lends nothing even with a '
        'token still in the store', () async {
      // A delete that did not happen: the store refused it, or a build
      // flagged the token without dropping it. The flag and not the
      // absence is what [state] reads, so this is still pairAgain.
      final account = await _account(
        prefsClient: FakePrefsClient({AppPrefs.driveTokenDeadKey: true}),
        secrets: FakeSecretStore({DriveAccount.refreshTokenKey: _token}),
      );

      expect(account.state, DriveLinkState.pairAgain);
      expect(account.refreshToken, isNull);
    });

    test('an empty stored value is no pairing', () async {
      final account = await _account(
        prefsClient: FakePrefsClient(),
        secrets: FakeSecretStore({DriveAccount.refreshTokenKey: ''}),
      );

      expect(account.state, DriveLinkState.unlinked);
      expect(account.refreshToken, isNull);
    });

    test('pairAgain survives a restart', () async {
      final prefsClient = FakePrefsClient();
      final secrets = FakeSecretStore();
      final account = await _account(
        prefsClient: prefsClient,
        secrets: secrets,
      );
      await account.linkFile(
        refreshToken: _token,
        fileId: 'drive-file-1',
        name: 'one.mkv',
        mimeType: 'video/x-matroska',
      );
      await account.notePairAgain();

      final restarted = await _account(
        prefsClient: prefsClient,
        secrets: secrets,
      );

      expect(restarted.state, DriveLinkState.pairAgain);
      expect(restarted.files.entries.single.fileId, 'drive-file-1');
    });

    test('a fresh pairing clears it', () async {
      final prefsClient = FakePrefsClient();
      final account = await _account(
        prefsClient: prefsClient,
        secrets: FakeSecretStore(),
      );
      await account.linkFile(
        refreshToken: _token,
        fileId: 'drive-file-1',
        name: 'one.mkv',
        mimeType: 'video/x-matroska',
      );
      await account.notePairAgain();

      await account.linkFile(
        refreshToken: _rotated,
        fileId: 'drive-file-1',
        name: 'one.mkv',
        mimeType: 'video/x-matroska',
      );

      expect(account.state, DriveLinkState.linked);
      expect(account.refreshToken, _rotated);
      expect(
        prefsClient.stored.containsKey(AppPrefs.driveTokenDeadKey),
        isFalse,
      );
    });

    test(
      'a pairing notifies, so a screen reading the state rebuilds',
      () async {
        final account = await _account(
          prefsClient: FakePrefsClient(),
          secrets: FakeSecretStore(),
        );
        var notified = 0;
        account.addListener(() => notified++);

        await account.linkFile(
          refreshToken: _token,
          fileId: 'drive-file-1',
          name: 'one.mkv',
          mimeType: 'video/x-matroska',
        );

        expect(notified, greaterThan(0));
      },
    );
  });

  group('unlinking', () {
    test('removes the secret, not just the list entry', () async {
      final prefsClient = FakePrefsClient();
      final secrets = FakeSecretStore();
      final account = await _account(
        prefsClient: prefsClient,
        secrets: secrets,
      );
      await account.linkFile(
        refreshToken: _token,
        fileId: 'drive-file-1',
        name: 'one.mkv',
        mimeType: 'video/x-matroska',
      );

      await account.unlink();

      expect(secrets.deletes, [DriveAccount.refreshTokenKey]);
      expect(secrets.stored, isEmpty);
      expect(account.refreshToken, isNull);
      expect(account.state, DriveLinkState.unlinked);
      expect(account.files.isEmpty, isTrue);
      // And nothing is left in the file for a restart to read back.
      expect(
        prefsClient.stored.containsKey(AppPrefs.driveLinkedFilesKey),
        isFalse,
      );
      final restarted = await _account(
        prefsClient: prefsClient,
        secrets: secrets,
      );
      expect(restarted.state, DriveLinkState.unlinked);
    });

    test('unlinking after pairAgain leaves nothing behind', () async {
      final prefsClient = FakePrefsClient();
      final secrets = FakeSecretStore();
      final account = await _account(
        prefsClient: prefsClient,
        secrets: secrets,
      );
      await account.linkFile(
        refreshToken: _token,
        fileId: 'drive-file-1',
        name: 'one.mkv',
        mimeType: 'video/x-matroska',
      );
      await account.notePairAgain();

      await account.unlink();

      expect(account.state, DriveLinkState.unlinked);
      expect(prefsClient.stored, isEmpty);
      expect(secrets.stored, isEmpty);
    });
  });

  group('a store that will not open', () {
    test('start-up survives it, as a device nobody has paired', () async {
      final account = await _account(
        prefsClient: FakePrefsClient(),
        secrets: FakeSecretStore.failing(),
      );

      expect(account.loaded, isTrue);
      expect(account.state, DriveLinkState.unlinked);
      expect(account.refreshToken, isNull);
    });

    test(
      'a pairing holds for the run and says that it will not last',
      () async {
        final prefsClient = FakePrefsClient();
        final secrets = FakeSecretStore.failing();
        final account = await _account(
          prefsClient: prefsClient,
          secrets: secrets,
        );

        final outcome = await account.linkFile(
          refreshToken: _token,
          fileId: 'drive-file-1',
          name: 'one.mkv',
          mimeType: 'video/x-matroska',
        );

        expect(outcome, DriveLinkOutcome.thisRunOnly);
        expect(account.thisRunOnly, isTrue);
        expect(account.state, DriveLinkState.linked);
        expect(account.refreshToken, _token);
        // In memory and nowhere else: not in the store that refused it, and
        // above all not in the preferences file instead.
        expect(secrets.stored, isEmpty);
        expect(jsonEncode(prefsClient.stored), isNot(contains(_token)));

        // A restart is an unpaired device again, and the list of files is
        // still there to say what was linked.
        final restarted = await _account(
          prefsClient: prefsClient,
          secrets: secrets,
        );
        expect(restarted.state, DriveLinkState.unlinked);
        expect(restarted.files.entries.single.fileId, 'drive-file-1');
      },
    );

    test('unlinking still works when the store cannot be reached', () async {
      final prefsClient = FakePrefsClient({
        AppPrefs.driveLinkedFilesKey: [
          {'id': 'drive-file-1', 'name': 'one.mkv', 'mime': 'video/mp4'},
        ],
      });
      final account = await _account(
        prefsClient: prefsClient,
        secrets: FakeSecretStore.failing(),
      );

      await account.unlink();

      expect(account.state, DriveLinkState.unlinked);
      expect(account.files.isEmpty, isTrue);
    });
  });

  group('nothing logs the token', () {
    test('the first lock: no line the app writes carries it', () async {
      final lines = captureDiagnostics();
      final prefsClient = FakePrefsClient();
      // The failing store is what makes this class write log lines at all,
      // so it is the run with the most chances to leak one.
      final account = await _account(
        prefsClient: prefsClient,
        secrets: FakeSecretStore.failing(),
      );
      await account.linkFile(
        refreshToken: _token,
        fileId: 'drive-file-1',
        name: 'one.mkv',
        mimeType: 'video/x-matroska',
      );
      await account.notePairAgain();
      await account.unlink();

      expect(lines, isNotEmpty, reason: 'the store failures were reported');
      for (final line in lines) {
        expect(line, isNot(contains(_token)));
      }
      // What a caught exception is allowed to contribute: its type. The
      // fake's message is not in the log either, because an exception's own
      // text is where a platform would put back what it was handed.
      expect(lines.join('\n'), contains('StateError'));
      expect(lines.join('\n'), isNot(contains('no keyring on this machine')));
    });

    test('the second lock: a report scrubs the key by name', () {
      // The first lock is about URLs and is deliberately not a place to
      // invent a redaction (`DiagnosticsLog`), so what protects a line
      // nobody here composed -- a stray `debugPrint`, a future caller's
      // mistake -- is the report's scrub. It has to know this key's name,
      // which is why the key is hyphenated.
      final line = '${DriveAccount.refreshTokenKey}: $_token';
      expect(redactSecrets(line), isNot(contains(_token)));
      expect(redactSecrets(line), contains(redactedMarker));

      // And through the report the Diagnostics screen actually copies.
      final report = formatDiagnostics(
        snapshot: DiagnosticsSnapshot(coreVersion: '0.1.0', logLines: [line]),
        platform: 'android',
        osVersion: 'Android 14',
        at: DateTime.utc(2026, 9, 25),
      );
      expect(report, isNot(contains(_token)));
    });
  });
}
