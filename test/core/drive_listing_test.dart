import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/fake_drive_file_lister.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_secret_store.dart';

/// Nothing in this repository is a token. This string is a marker a test
/// can search for -- it is not a credential and not the shape of one
/// (`AGENTS.md`, "Never log auth material").
const String _token = 'fake-refresh-token-for-tests-only';

final DateTime _at = DateTime.utc(2026, 9, 25, 12);

const LinkedDriveMatch _arrival = LinkedDriveMatch(
  cinemetaId: 'tt2543164',
  type: 'movie',
  name: 'Arrival',
  year: 2016,
);

/// A linked account holding [files], most recently linked first.
Future<DriveAccount> _account(List<LinkedDriveFile> files) async {
  final prefs = AppPrefs(client: FakePrefsClient());
  await prefs.load();
  final account = DriveAccount(
    prefs: prefs,
    secrets: FakeSecretStore(),
    now: () => _at,
  );
  await account.load();
  addTearDown(() {
    account.dispose();
    prefs.dispose();
  });
  await account.link(refreshToken: _token, files: files);
  return account;
}

LinkedDriveFile _file(String id, String name, {LinkedDriveMatch? match}) =>
    LinkedDriveFile(
      fileId: id,
      name: name,
      mimeType: 'video/x-matroska',
      linkedAt: _at,
      match: match,
    );

/// Which files are stored, as id to name.
Map<String, String> _stored(DriveAccount account) => {
  for (final entry in account.files.entries) entry.fileId: entry.name,
};

void main() {
  group('reconciling a stored list against a complete listing', () {
    test('a renamed file takes the new name and loses its match, so the '
        'search runs again', () async {
      // The whole of what the note above the list promises: rename in
      // Drive, press Reload. A match made from a name that no longer
      // exists is the thing the rename was meant to be rid of.
      final account = await _account([
        _file('drive-file-1', 'Arrivel.2016.mkv', match: _arrival),
      ]);

      final outcome = await reloadLinkedDriveFiles(
        account: account,
        lister: FakeDriveFileLister(
          answers: [
            FakeDriveFileLister.listing({'drive-file-1': 'Arrival.2016.mkv'}),
          ],
        ),
      );

      expect(outcome, isA<DriveReloadDone>());
      expect((outcome as DriveReloadDone).renamed, 1);
      expect(outcome.removed, 0);
      final file = account.files.forFile('drive-file-1')!;
      expect(file.name, 'Arrival.2016.mkv');
      expect(
        file.match,
        isNull,
        reason:
            'a match from the old name is a claim about a name that is '
            'gone',
      );
    });

    test('a file absent from the listing loses its row', () async {
      final account = await _account([
        _file('drive-file-1', 'ep6.avi'),
        _file('drive-file-2', 'Arrival.2016.mkv', match: _arrival),
      ]);

      final outcome = await reloadLinkedDriveFiles(
        account: account,
        lister: FakeDriveFileLister(
          answers: [
            FakeDriveFileLister.listing({'drive-file-2': 'Arrival.2016.mkv'}),
          ],
        ),
      );

      expect((outcome as DriveReloadDone).removed, 1);
      expect(outcome.renamed, 0);
      expect(_stored(account), {'drive-file-2': 'Arrival.2016.mkv'});
    });

    test('an unchanged, matched file is left exactly as it was', () async {
      final account = await _account([
        _file('drive-file-1', 'Arrival.2016.mkv', match: _arrival),
      ]);
      final before = account.files;

      final outcome = await reloadLinkedDriveFiles(
        account: account,
        lister: FakeDriveFileLister(
          answers: [
            FakeDriveFileLister.listing({'drive-file-1': 'Arrival.2016.mkv'}),
          ],
        ),
      );

      expect((outcome as DriveReloadDone).changedNothing, isTrue);
      expect(account.files, before);
      expect(account.files.forFile('drive-file-1')!.match, _arrival);
    });

    test(
      'a file the listing names that was never stored here is not added',
      () async {
        // The listing reaches every file the account ever picked through this
        // client, including on somebody's other television. The stored list
        // is what was linked *here*.
        final account = await _account([_file('drive-file-1', 'ep6.avi')]);

        final outcome = await reloadLinkedDriveFiles(
          account: account,
          lister: FakeDriveFileLister(
            answers: [
              FakeDriveFileLister.listing({
                'drive-file-1': 'ep6.avi',
                'picked-somewhere-else': 'Dune.2021.mkv',
              }),
            ],
          ),
        );

        expect((outcome as DriveReloadDone).changedNothing, isTrue);
        expect(_stored(account), {'drive-file-1': 'ep6.avi'});
      },
    );

    test('a file Drive named with nothing this build can read keeps its '
        'stored name rather than being emptied', () async {
      final account = await _account([_file('drive-file-1', 'ep6.avi')]);

      await reloadLinkedDriveFiles(
        account: account,
        lister: FakeDriveFileLister(
          answers: [
            FakeDriveFileLister.listing({'drive-file-1': ''}),
          ],
        ),
      );

      expect(_stored(account), {'drive-file-1': 'ep6.avi'});
    });

    test(
      'a measurement that arrives on a later reload is written down',
      () async {
        // Drive fills `videoMediaMetadata` in once it has processed an
        // upload, so a file linked the minute it finished uploading has none
        // and has one later. Nothing draws these yet; what is under test is
        // that the reload that could have picked them up did.
        final account = await _account([_file('drive-file-1', 'ep6.avi')]);
        expect(account.files.forFile('drive-file-1')!.height, isNull);

        await reloadLinkedDriveFiles(
          account: account,
          lister: FakeDriveFileLister(
            answers: [
              FakeDriveFileLister.measured({
                'drive-file-1': (
                  name: 'ep6.avi',
                  height: 1080,
                  durationMillis: 2820000,
                ),
              }),
            ],
          ),
        );

        final file = account.files.forFile('drive-file-1')!;
        expect(file.height, 1080);
        expect(file.durationMillis, 2820000);
        expect(file.name, 'ep6.avi', reason: 'nothing else moved');
      },
    );

    test(
      'a listing that measures nothing leaves a measurement alone',
      () async {
        // Absent is Drive not having measured this file, which is the
        // ordinary answer -- not a measurement withdrawn. Wiping the stored
        // one would lose it on the first reload after any odd answer.
        final account = await _account([
          LinkedDriveFile(
            fileId: 'drive-file-1',
            name: 'ep6.avi',
            mimeType: 'video/x-matroska',
            linkedAt: _at,
            height: 2160,
            durationMillis: 5400000,
          ),
        ]);

        await reloadLinkedDriveFiles(
          account: account,
          lister: FakeDriveFileLister(
            answers: [
              FakeDriveFileLister.listing({'drive-file-1': 'ep6.avi'}),
            ],
          ),
        );

        final file = account.files.forFile('drive-file-1')!;
        expect(file.height, 2160);
        expect(file.durationMillis, 5400000);
      },
    );

    test('a renamed file keeps what Drive measured, because a rename is not '
        'a re-upload', () async {
      final account = await _account([
        LinkedDriveFile(
          fileId: 'drive-file-1',
          name: 'ep6.avi',
          mimeType: 'video/x-matroska',
          linkedAt: _at,
          height: 1080,
          match: _arrival,
        ),
      ]);

      await reloadLinkedDriveFiles(
        account: account,
        lister: FakeDriveFileLister(
          answers: [
            FakeDriveFileLister.listing({
              'drive-file-1': 'Breaking Bad S02E11.mkv',
            }),
          ],
        ),
      );

      final file = account.files.forFile('drive-file-1')!;
      expect(file.name, 'Breaking Bad S02E11.mkv');
      expect(file.match, isNull, reason: 'the name is the evidence');
      expect(file.height, 1080, reason: 'the pixels are not');
    });

    test('the listing is asked with the account\'s own credential', () async {
      final account = await _account([_file('drive-file-1', 'ep6.avi')]);
      final lister = FakeDriveFileLister(
        answers: [
          FakeDriveFileLister.listing({'drive-file-1': 'ep6.avi'}),
        ],
      );

      await reloadLinkedDriveFiles(account: account, lister: lister);

      expect(lister.asked, [_token]);
    });
  });

  group('a listing that did not arrive whole', () {
    test('reconciles nothing at all -- not one row, not one name', () async {
      // The property this whole file is arranged around. A television drops
      // off its wifi on the third page; read as the truth, that is "the
      // viewer deleted everything", and nothing can put those rows back.
      final account = await _account([
        _file('drive-file-1', 'ep6.avi'),
        LinkedDriveFile(
          fileId: 'drive-file-2',
          name: 'Arrival.2016.mkv',
          mimeType: 'video/x-matroska',
          linkedAt: _at,
          height: 1080,
          durationMillis: 6960000,
          match: _arrival,
        ),
      ]);
      final before = account.files;

      for (final reason in DriveListingFailure.values) {
        final outcome = await reloadLinkedDriveFiles(
          account: account,
          lister: FakeDriveFileLister(answers: [DriveListingFailed(reason)]),
        );

        expect(outcome, isA<DriveReloadRefused>(), reason: '$reason');
        expect(account.files, before, reason: '$reason');
      }
    });

    test('and says so, in one sentence per reason', () async {
      for (final reason in DriveListingFailure.values) {
        final said = driveReloadMessage(DriveReloadRefused(reason));
        expect(said, isNotEmpty);
        expect(said, endsWith('.'), reason: '$reason is a sentence');
      }
    });

    test('a revoked grant is written down on the way past, so every screen '
        'already knows', () async {
      final account = await _account([_file('drive-file-1', 'ep6.avi')]);

      final outcome = await reloadLinkedDriveFiles(
        account: account,
        lister: FakeDriveFileLister(
          answers: const [DriveListingFailed(DriveListingFailure.pairAgain)],
        ),
      );

      expect(outcome, isA<DriveReloadRefused>());
      expect(account.state, DriveLinkState.pairAgain);
      expect(account.refreshToken, isNull);
      expect(_stored(account), {
        'drive-file-1': 'ep6.avi',
      }, reason: 'those files are what a new pairing will reach');
    });

    test(
      'nothing is asked for at all with no credential to ask with',
      () async {
        final prefs = AppPrefs(client: FakePrefsClient());
        await prefs.load();
        final account = DriveAccount(prefs: prefs, secrets: FakeSecretStore());
        await account.load();
        addTearDown(() {
          account.dispose();
          prefs.dispose();
        });
        final lister = FakeDriveFileLister();

        final outcome = await reloadLinkedDriveFiles(
          account: account,
          lister: lister,
        );

        expect(
          outcome,
          isA<DriveReloadRefused>().having(
            (refused) => refused.reason,
            'reason',
            DriveListingFailure.notLinked,
          ),
        );
        expect(lister.asked, isEmpty);
      },
    );
  });

  group('reading one page of what Drive answered', () {
    test('the duration arrives as a string and the height as a number, and '
        'both are read', () {
      // Google's JSON mapping: a 32-bit field is a number and a 64-bit one
      // is a string. A build that read only numbers would drop every
      // duration and never say so.
      final page = parseDriveFilesPage({
        'files': [
          {
            'id': 'drive-file-1',
            'name': 'Arrival.2016.mkv',
            'mimeType': 'video/x-matroska',
            'videoMediaMetadata': {
              'width': 3840,
              'height': 2160,
              'durationMillis': '6960000',
            },
          },
        ],
      })!;

      expect(page.$1, {
        'drive-file-1': (
          name: 'Arrival.2016.mkv',
          height: 2160,
          durationMillis: 6960000,
        ),
      });
      expect(page.$2, isNull, reason: 'no token is the last page');
    });

    test(
      'a file Drive has not measured is measured by nobody, not by zero',
      () {
        final page = parseDriveFilesPage({
          'files': [
            {'id': 'drive-file-1', 'name': 'ep6.avi'},
            {
              'id': 'drive-file-2',
              'name': 'ep7.avi',
              'videoMediaMetadata': {'height': 0, 'durationMillis': 'soon'},
            },
          ],
        })!;

        expect(page.$1['drive-file-1'], (
          name: 'ep6.avi',
          height: null,
          durationMillis: null,
        ));
        expect(page.$1['drive-file-2'], (
          name: 'ep7.avi',
          height: null,
          durationMillis: null,
        ));
      },
    );

    test('a row with no id is skipped; a row with no name is kept, because '
        'left out means gone', () {
      final page = parseDriveFilesPage({
        'files': [
          {'name': 'nameless.mkv'},
          {'id': '  '},
          'not a row at all',
          {'id': 'drive-file-1'},
        ],
      })!;

      expect(page.$1.keys, ['drive-file-1']);
      expect(page.$1['drive-file-1']!.name, isEmpty);
    });

    test('a next page token is carried, and a body that is not a page at all '
        'is null', () {
      final page = parseDriveFilesPage({
        'files': <Object>[],
        'nextPageToken': 'page-2',
      })!;
      expect(page.$2, 'page-2');

      expect(parseDriveFilesPage({'files': 'one.mkv'}), isNull);
      expect(parseDriveFilesPage({'error': 'nope'}), isNull);
      expect(parseDriveFilesPage('files'), isNull);
      expect(parseDriveFilesPage(null), isNull);
    });
  });

  group('what a viewer is told', () {
    test('a reload that changed nothing still says something', () {
      expect(
        driveReloadMessage(const DriveReloadDone(renamed: 0, removed: 0)),
        'Nothing has changed in Drive since these files were linked.',
      );
    });

    test('one file and several read as one file and several', () {
      expect(
        driveReloadMessage(const DriveReloadDone(renamed: 1, removed: 0)),
        '1 file renamed in Drive.',
      );
      expect(
        driveReloadMessage(const DriveReloadDone(renamed: 0, removed: 2)),
        'Removed 2 files this device can no longer reach.',
      );
      expect(
        driveReloadMessage(const DriveReloadDone(renamed: 2, removed: 1)),
        '2 files renamed in Drive, and removed 1 file this device can no '
        'longer reach.',
      );
    });
  });
}
