import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/fake_drive_file_opener.dart';
import '../support/fake_drive_pairing_service.dart';
import '../support/fake_prefs_client.dart';

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
  final account = await driveAccount(
    prefsClient: prefsClient ?? FakePrefsClient(),
    now: () => _at,
  );
  if (linked) {
    await account.linkFiles(
      refreshToken: _token,
      files: [
        (fileId: _file.fileId, name: _file.name, mimeType: _file.mimeType),
      ],
    );
  }
  return account;
}

void main() {
  group('opening a linked file', () {
    test('a linked file is played by its own source URL, and the grant goes '
        'only to the server', () async {
      final account = await _account();
      final opener = FakeDriveFileOpener();

      final opened = await openLinkedDriveFile(
        account: account,
        file: account.files.entries.single,
        opener: opener,
      );

      final playable = opened as DriveFilePlayable;
      // What the player registers as a Drive media id, and what a Drive
      // download's row keeps: the file, and nothing about the account.
      expect(playable.url, Uri.parse(driveSourceUrl(_file)));
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

      // Nor anywhere in what the player is given.
      final stream = driveStreamJson(file: _file, playable: opened);
      expect(jsonEncode(stream), isNot(contains(_token)));
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

    test('a refusal of a grant a new pairing replaced meanwhile deletes '
        'nothing', () async {
      final account = await _account();
      final answer = Completer<void>();
      final opener = FakeDriveFileOpener(
        answers: const [DriveFileRefused(DriveOpenFailure.pairAgain)],
      )..pending = answer.future;

      final opening = openLinkedDriveFile(
        account: account,
        file: account.files.entries.single,
        opener: opener,
      );
      await pumpEventQueue();
      // A pairing lands while the server is still being asked.
      await account.link(refreshToken: '$_token-new');
      answer.complete();
      await opening;

      expect(
        account.refreshToken,
        '$_token-new',
        reason: 'the refusal was about the old grant',
      );
      expect(account.state, isNot(DriveLinkState.pairAgain));
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
      await account.linkFiles(
        refreshToken: '',
        files: [
          (fileId: _file.fileId, name: _file.name, mimeType: _file.mimeType),
        ],
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
    test('a success is a URL and the name of the file', () {
      final opened = parseDriveOpenAnswer(
        jsonEncode({
          'ok': true,
          'url': 'xtremio-drive:a-file-id',
          'name': 'A Film.mkv',
        }),
      );
      final playable = opened as DriveFilePlayable;
      expect(playable.url.toString(), 'xtremio-drive:a-file-id');
      expect(playable.name, 'A Film.mkv');
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
      // The URL is what makes it a `StreamKind.url`, which the core passes
      // through for the player to register.
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
      // `xtremio-drive:<fileId>` has no extension, so the cast check has
      // nothing to read a container off but this.
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

  group('the request a Drive play is tracked under', () {
    /// The URL stremio-core's HTTP transport fetches for [request]: the
    /// manifest's `/manifest.json` swapped for `/{resource}/{type}/{id}.json`,
    /// the id percent-encoded as a URI component.
    String fetchedUrl(ResourceRequest request) => request.base.replaceFirst(
      RegExp(r'/manifest\.json$'),
      '/${request.path.resource}/${request.path.type}/'
      '${Uri.encodeComponent(request.path.id)}.json',
    );

    test('an episode lands on the service, under its own id', () {
      final request = driveStreamRequest(
        type: 'series',
        videoId: 'tt0903747:1:2',
      );
      expect(request.toJson(), {
        'base': 'https://xtremio-xervice.web.app/manifest.json',
        'path': {
          'resource': 'stream',
          'type': 'series',
          'id': 'tt0903747:1:2',
          'extra': <Object>[],
        },
      });
      expect(
        fetchedUrl(request),
        'https://xtremio-xervice.web.app/stream/series/tt0903747%3A1%3A2.json',
        reason: 'what the Hosting rewrite of /stream/** answers',
      );
      expect(
        fetchedUrl(driveStreamRequest(type: 'movie', videoId: 'tt0063350')),
        'https://xtremio-xervice.web.app/stream/movie/tt0063350.json',
      );
    });

    test('the manifest it names is the one the service publishes', () {
      final manifest = jsonDecode(
        File('xtremio-xervice/public/manifest.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(manifest['resources'], ['stream']);
      expect(manifest['types'], containsAll(['movie', 'series']));
      expect(manifest['idPrefixes'], ['tt']);
      expect(manifest['catalogs'], isEmpty);
      expect(
        jsonDecode(
          File('xtremio-xervice/public/no-streams.json').readAsStringSync(),
        ),
        {'streams': <Object>[]},
      );
    });

    test('a matched file plays under its title, an unmatched one under '
        'nothing', () {
      LinkedDriveFile linked(LinkedDriveMatch? match) => LinkedDriveFile(
        fileId: 'f',
        name: 'f.mkv',
        mimeType: 'video/x-matroska',
        linkedAt: _at,
        match: match,
      );

      final film = driveMatchRequests(
        linked(
          const LinkedDriveMatch(
            cinemetaId: 'tt2543164',
            type: 'movie',
            name: 'Arrival',
          ),
        ),
      )!;
      expect(film.meta.base, kCinemetaManifestUrl);
      expect(
        film.meta.path,
        const ResourcePath(resource: 'meta', type: 'movie', id: 'tt2543164'),
      );
      expect(
        film.stream,
        driveStreamRequest(type: 'movie', videoId: 'tt2543164'),
      );

      final episode = driveMatchRequests(
        linked(
          const LinkedDriveMatch(
            cinemetaId: 'tt0903747',
            type: 'series',
            name: 'Breaking Bad',
            season: 2,
            episode: 11,
          ),
        ),
      )!;
      expect(
        episode.meta.path,
        const ResourcePath(resource: 'meta', type: 'series', id: 'tt0903747'),
      );
      expect(
        episode.stream,
        driveStreamRequest(type: 'series', videoId: 'tt0903747:2:11'),
      );

      expect(driveMatchRequests(linked(null)), isNull);
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
