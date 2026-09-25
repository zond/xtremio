import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/fake_drive_file_opener.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_secret_store.dart';

/// Not a token. A marker a test can search a URL, a stream JSON and the log
/// for; a real refresh token must never be written into a fixture, a test
/// or a comment (`AGENTS.md`, "Never log auth material").
const String _token = 'fake-refresh-token-for-tests-only';

final DateTime _at = DateTime.utc(2026, 9, 25, 12);

final LinkedDriveFile _file = LinkedDriveFile(
  fileId: 'drive-file-1',
  name: 'Arrival (2016) 2160p.mkv',
  mimeType: 'video/x-matroska',
  linkedAt: _at,
);

Future<DriveAccount> _account({
  FakePrefsClient? prefsClient,
  bool linked = true,
}) async {
  final prefs = AppPrefs(client: prefsClient ?? FakePrefsClient());
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
  if (linked) {
    await account.linkFile(
      refreshToken: _token,
      fileId: _file.fileId,
      name: _file.name,
      mimeType: _file.mimeType,
    );
  }
  return account;
}

void main() {
  group('opening a linked file', () {
    test('a linked file produces a URL, and the grant goes only to the '
        'server', () async {
      final account = await _account();
      final opener = FakeDriveFileOpener();

      final opened = await openLinkedDriveFile(
        account: account,
        file: account.files.entries.single,
        opener: opener,
      );

      final playable = opened as DriveFilePlayable;
      expect(playable.url.host, '127.0.0.1');
      expect(playable.url.path, startsWith('/drive/stream/'));
      // The one call the grant reaches, with the file it was asked for.
      expect(opener.asked, hasLength(1));
      expect(opener.asked.single.fileId, _file.fileId);
      expect(opener.asked.single.refreshToken, _token);
      // The account is untouched by a successful open: it was already
      // linked and still is.
      expect(account.state, DriveLinkState.linked);
    });

    test('the token is in no part of the URL handed to the player', () async {
      final account = await _account();
      final opener = FakeDriveFileOpener();

      final opened = await openLinkedDriveFile(
        account: account,
        file: account.files.entries.single,
        opener: opener,
      ) as DriveFilePlayable;

      // The whole URL, not its query: a credential in a path segment is the
      // shape this feature exists to avoid (`/proxy`'s `h=` rides in the
      // path, which is why it was not reused).
      expect(opened.url.toString(), isNot(contains(_token)));
      // And not the file id either, so nothing about the account is
      // recoverable from a line in a log.
      expect(opened.url.toString(), isNot(contains(_file.fileId)));

      // Nor anywhere in what the player is given.
      final stream = driveStreamJson(file: _file, playable: opened);
      expect(jsonEncode(stream), isNot(contains(_token)));
      expect(jsonEncode(stream), isNot(contains(_file.fileId)));
    });

    test('a dead pairing surfaces as pairAgain and the account records '
        'it', () async {
      final account = await _account();
      final opener = FakeDriveFileOpener(
        answers: const [DriveFileRefused(DriveOpenFailure.pairAgain)],
      );

      final opened = await openLinkedDriveFile(
        account: account,
        file: account.files.entries.single,
        opener: opener,
      );

      expect(
        (opened as DriveFileRefused).reason,
        DriveOpenFailure.pairAgain,
        reason: 'the UI has to be able to send the viewer back to a QR',
      );
      // Written down once, here, so that no second caller has to remember:
      // the state every screen reads is already `pairAgain`, and the
      // credential is gone.
      expect(account.state, DriveLinkState.pairAgain);
      expect(account.refreshToken, isNull);
      // And the list survives, because those files are what a new token
      // will reach.
      expect(account.files.entries, hasLength(1));
    });

    test('nothing is asked with no credential to ask with', () async {
      final account = await _account(linked: false);
      final opener = FakeDriveFileOpener();

      final opened = await openLinkedDriveFile(
        account: account,
        file: _file,
        opener: opener,
      );

      expect((opened as DriveFileRefused).reason, DriveOpenFailure.notLinked);
      expect(opener.asked, isEmpty, reason: 'there was nothing to send');
    });

    test('nor with an empty one, which is not a credential either', () async {
      // A pairing service that answered with an empty string would leave
      // the account "linked" with nothing in it, and sending that to the
      // server is a refresh the viewer would be told to pair again over.
      final account = await _account(linked: false);
      await account.linkFile(
        refreshToken: '',
        fileId: _file.fileId,
        name: _file.name,
        mimeType: _file.mimeType,
      );
      final opener = FakeDriveFileOpener();

      final opened = await openLinkedDriveFile(
        account: account,
        file: account.files.entries.single,
        opener: opener,
      );

      expect((opened as DriveFileRefused).reason, DriveOpenFailure.notLinked);
      expect(opener.asked, isEmpty);
    });
  });

  group('the server answer', () {
    test('a success is a URL and the three facts about the file', () {
      final opened = parseDriveOpenAnswer(
        jsonEncode({
          'ok': true,
          'url': 'http://127.0.0.1:1234/drive/stream/k',
          'name': 'A Film.mkv',
          'contentType': 'video/mp4',
          'length': 4096,
        }),
      );
      final playable = opened as DriveFilePlayable;
      expect(playable.url.toString(), 'http://127.0.0.1:1234/drive/stream/k');
      expect(playable.name, 'A Film.mkv');
      expect(playable.contentType, 'video/mp4');
      expect(playable.length, 4096);
    });

    test('each refusal keeps its own kind, so nothing matches English', () {
      for (final (word, reason) in const [
        ('pairAgain', DriveOpenFailure.pairAgain),
        ('noPairingService', DriveOpenFailure.noPairingService),
        ('unreachable', DriveOpenFailure.unreachable),
        ('unavailable', DriveOpenFailure.unavailable),
      ]) {
        final opened = parseDriveOpenAnswer(
          jsonEncode({'ok': false, 'reason': word}),
        );
        expect((opened as DriveFileRefused).reason, reason, reason: word);
      }
    });

    test('an answer this build cannot read is said so and never thrown', () {
      for (final answer in [
        'not json at all',
        '[]',
        jsonEncode({'ok': false, 'reason': 'somethingNewer'}),
        // A success with no URL is not one; it would otherwise reach a
        // player as a null.
        jsonEncode({'ok': true}),
        jsonEncode({'ok': true, 'url': 42}),
      ]) {
        final opened = parseDriveOpenAnswer(answer);
        expect(
          (opened as DriveFileRefused).reason,
          DriveOpenFailure.notUnderstood,
          reason: answer,
        );
      }
    });
  });

  group('what the player is given', () {
    test('the title is the file\'s own name, and the source is beside '
        'it', () {
      final stream = driveStreamJson(
        file: _file,
        playable: fakeDrivePlayable(name: _file.name),
      );
      // With no meta item, `PlayerState.title` falls through to the
      // stream's `name` -- so the name is the film, not the service, or
      // five linked files draw identically.
      expect(stream['name'], _file.name);
      expect(stream['description'], driveSourceLabel);
      // The URL is what makes it a `StreamKind.url` the engine plays
      // directly, and it is the server's own, so nothing proxies it again.
      expect(StreamInfo(stream).kind, StreamKind.url);
      expect(StreamInfo(stream).isPlayable, isTrue);
      // And the title the overlay draws really is the file's name.
      expect(StreamInfo(stream).title, _file.name);
    });

    test('the filename travels, because the URL has no extension on '
        'it', () {
      final stream = driveStreamJson(
        file: _file,
        playable: fakeDrivePlayable(name: _file.name),
      );
      // `/drive/stream/{key}` ends in a uuid, so the cast check has nothing
      // to read a container off but this.
      expect((stream['behaviorHints'] as Map)['filename'], _file.name);
    });

    test('a file the server named is named that, and one nothing names '
        'still draws', () {
      // Drive's own current name wins: a file can be renamed since it was
      // linked.
      final renamed = driveStreamJson(
        file: _file,
        playable: fakeDrivePlayable(name: 'Arrival.2016.remux.mkv'),
      );
      expect(renamed['name'], 'Arrival.2016.remux.mkv');

      final nameless = driveStreamJson(
        file: LinkedDriveFile(
          fileId: 'drive-file-2',
          name: '',
          mimeType: '',
          linkedAt: _at,
        ),
        playable: fakeDrivePlayable(),
      );
      expect(nameless['name'], driveSourceLabel);
      expect(
        nameless.containsKey('behaviorHints'),
        isFalse,
        reason: 'an empty filename is worse than none: it claims a container',
      );
    });
  });

  group('every failure has a sentence', () {
    test('and none of them is empty', () {
      for (final reason in DriveOpenFailure.values) {
        expect(driveFailureMessage(reason), isNotEmpty, reason: '$reason');
      }
    });
  });
}
