import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/shell/deep_link.dart';

import '../support/fake_drive_pairing_service.dart';

/// The television's two calls against the pairing service, answered by a
/// server on the loopback rather than by a stub of the parsing.
///
/// Every shape here is one `drive-link/functions/index.js` really answers
/// with: the session, the two waiting statuses, the `ready` that deletes
/// the session as it hands the tokens over, the `410` for a window that
/// closed, the `404` for a session that has been collected, and the `429`
/// the rate limit answers with. A stub of the JSON reading would have
/// proved the reading and not the statuses, and the statuses are where
/// three of the outcomes live.
void main() {
  group('the pairing service', () {
    late HttpServer server;
    HttpOverrides? overrides;

    /// Every request the server saw, as `METHOD <request-target>`.
    late List<String> seen;

    /// Every body it was sent, decoded.
    late List<Object?> sent;

    /// What `POST /session` answers.
    late int sessionStatus;
    late Object? sessionBody;

    /// What `GET /session/{id}` answers.
    late int collectStatus;
    late Object? collectBody;

    setUp(() async {
      // The test binding answers every request with a 400 of its own; this
      // talks to a real server on the loopback.
      overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      seen = [];
      sent = [];
      sessionStatus = HttpStatus.ok;
      sessionBody = {
        'sessionId': 'abc-123',
        'link': 'https://xtremio-drive.web.app/link?s=abc-123',
        'expiresAt': '2026-09-25T20:10:00.000Z',
      };
      collectStatus = HttpStatus.ok;
      collectBody = {'status': 'pending'};

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        seen.add('${request.method} ${request.uri}');
        final asked = await utf8.decoder.bind(request).join();
        if (asked.isNotEmpty) sent.add(jsonDecode(asked));
        final response = request.response;
        final Object? body;
        if (request.method == 'POST') {
          response.statusCode = sessionStatus;
          body = sessionBody;
        } else {
          response.statusCode = collectStatus;
          body = collectBody;
        }
        if (body != null) {
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode(body));
        }
        await response.close();
      });
    });

    tearDown(() async {
      HttpOverrides.global = overrides;
      await server.close(force: true);
    });

    XtremioDrivePairingService service() =>
        XtremioDrivePairingService(origin: 'http://127.0.0.1:${server.port}');

    test('opens a session and reads what there is to draw', () async {
      final opening = await service().open(shape: DrivePairingShape.television);
      expect(seen, ['POST /session']);
      final session = (opening as DrivePairingOpened).session;
      expect(session.sessionId, 'abc-123');
      expect(session.link, 'https://xtremio-drive.web.app/link?s=abc-123');
      expect(session.expiresAt, DateTime.utc(2026, 9, 25, 20, 10));
      // And nothing about the session goes into a line: the id is the whole
      // of what a pairing is collected with.
      expect('$session', 'DrivePairingSession()');
    });

    test('and says which shape asked, which is all the service is told about '
        'the three of them', () async {
      // A phone was handed to a browser by this app and wants the viewer
      // handed back; a desktop was too but has nowhere to be handed back to,
      // because the `stremio://` registration there is installed by hand or
      // not at all; a television's viewer is looking at the other screen and
      // is sent nowhere. Three cases and not two, because the page says
      // something different for each -- the desktop and the television were
      // one case while this was a boolean, and a desktop was told its files
      // were on the way to a television.
      for (final shape in DrivePairingShape.values) {
        await service().open(shape: shape);
      }
      expect(sent, [
        {'shape': 'tv'},
        {'shape': 'phone'},
        {'shape': 'desktop'},
      ]);
    });

    test('a session it cannot draw is no session at all', () async {
      // The link is what the QR carries and the phone opens; a body without
      // one is not something to put on a television and wait beside.
      sessionBody = {'sessionId': 'abc-123'};
      expect(
        (await service().open(
          shape: DrivePairingShape.television,
        ) as DrivePairingUnavailable).reason,
        XtremioDrivePairingService.notUnderstood,
      );
    });

    test('and the rate limit is its own sentence', () async {
      // Sixty an hour per address. Worth telling apart from a network
      // fault: one is waited out, the other is looked at.
      sessionStatus = HttpStatus.tooManyRequests;
      sessionBody = {'error': 'too many sessions'};
      expect(
        (await service().open(
          shape: DrivePairingShape.television,
        ) as DrivePairingUnavailable).reason,
        XtremioDrivePairingService.tooManyCodes,
      );
    });

    test('a service that is not there is one sentence, whatever the socket '
        'did', () async {
      // The port is taken while there is still a server on it: what is
      // being measured is a call to an address nothing answers on.
      final dead = service();
      await server.close(force: true);
      expect(
        (await dead.open(
          shape: DrivePairingShape.television,
        ) as DrivePairingUnavailable).reason,
        XtremioDrivePairingService.notReached,
      );
    });

    test('the two waiting statuses are told apart', () async {
      collectBody = {'status': 'pending'};
      expect(
        await service().collect('abc-123'),
        isA<DrivePairingWaiting>().having(
          (answer) => answer.signedIn,
          'signedIn',
          isFalse,
        ),
      );
      collectBody = {'status': 'signed-in'};
      expect(
        await service().collect('abc-123'),
        isA<DrivePairingWaiting>().having(
          (answer) => answer.signedIn,
          'signedIn',
          isTrue,
        ),
      );
      expect(seen, ['GET /session/abc-123', 'GET /session/abc-123']);
    });

    test(
      'a ready session hands over the grant and every file picked',
      () async {
        // One scan, a whole season: the Picker takes several files at once and
        // `files` is what the service answers with.
        collectBody = {
          'status': 'ready',
          'refreshToken': fakeRefreshToken,
          // Read past, deliberately: an access token is good for an hour,
          // this device has nowhere safe for a second credential, and
          // DriveSource mints its own through POST /refresh.
          'accessToken': 'fake-access-token-for-tests-only',
          'accessExpiresAt': '2026-09-25T21:00:00.000Z',
          'files': [
            {
              'fileId': 'drive-file-1',
              'name': 'Gilmore Girls S01E01.mkv',
              'mimeType': 'video/x-matroska',
            },
            {
              'fileId': 'drive-file-2',
              'name': 'Gilmore Girls S01E02.mkv',
              'mimeType': 'video/x-matroska',
            },
          ],
          // The first of them again, for a build that knows nothing of `files`.
          // This build reads the list and ignores it.
          'file': {
            'fileId': 'drive-file-1',
            'name': 'Gilmore Girls S01E01.mkv',
          },
        };
        final answer = await service().collect('abc-123');
        final collected = answer as DrivePairingCollected;
        expect(collected.refreshToken, fakeRefreshToken);
        expect(collected.files, [
          (
            fileId: 'drive-file-1',
            name: 'Gilmore Girls S01E01.mkv',
            mimeType: 'video/x-matroska',
          ),
          (
            fileId: 'drive-file-2',
            name: 'Gilmore Girls S01E02.mkv',
            mimeType: 'video/x-matroska',
          ),
        ]);
        // And it names the files and nothing else when something writes it
        // into a line.
        expect(
          '$collected',
          'DrivePairingCollected(drive-file-1, drive-file-2)',
        );
      },
    );

    test('and a session naming one file the old way still works', () async {
      // What a service from before several could be picked answers with:
      // `file` and no `files` at all. One file is a list of one, and nothing
      // past this point treats it as a special case.
      collectBody = {
        'status': 'ready',
        'refreshToken': fakeRefreshToken,
        'accessToken': 'fake-access-token-for-tests-only',
        'accessExpiresAt': '2026-09-25T21:00:00.000Z',
        'file': {
          'fileId': 'drive-file-1',
          'name': 'Arrival (2016) 2160p.mkv',
          'mimeType': 'video/x-matroska',
        },
      };
      final collected =
          await service().collect('abc-123') as DrivePairingCollected;
      expect(collected.files, [
        (
          fileId: 'drive-file-1',
          name: 'Arrival (2016) 2160p.mkv',
          mimeType: 'video/x-matroska',
        ),
      ]);
    });

    test('a row with no id is dropped, not the eleven beside it', () async {
      // The id is the only field a byte range is asked for; a name and a
      // mime type have answers for being missing. Losing the whole pairing
      // over one unreadable row would be losing a read that cannot be made
      // again.
      collectBody = {
        'status': 'ready',
        'refreshToken': fakeRefreshToken,
        'files': [
          {'name': 'no id at all'},
          {'fileId': '  '},
          {'fileId': ' drive-file-2 '},
          'nonsense',
        ],
      };
      final collected =
          await service().collect('abc-123') as DrivePairingCollected;
      expect(collected.files, [
        (fileId: 'drive-file-2', name: '', mimeType: ''),
      ]);
    });

    test('a ready session with nothing on it is not polled again', () async {
      // The session is deleted by the read either way, so there is nothing
      // left to wait for -- whichever half of the answer is missing.
      collectBody = {
        'status': 'ready',
        'files': [
          {'fileId': 'drive-file-1'},
        ],
      };
      expect(await service().collect('abc-123'), isA<DrivePairingGone>());
      collectBody = {'status': 'ready', 'refreshToken': fakeRefreshToken};
      expect(await service().collect('abc-123'), isA<DrivePairingGone>());
      // And a list with nothing readable in it is the same dead end: there
      // is no session left to ask again about.
      collectBody = {
        'status': 'ready',
        'refreshToken': fakeRefreshToken,
        'files': [
          {'name': 'no id'},
        ],
      };
      expect(await service().collect('abc-123'), isA<DrivePairingGone>());
    });

    test('410 is expired and 404 is gone, and they are not the same '
        'thing', () async {
      // One is "nobody finished in time", the other "this pairing was
      // already collected, or never existed" -- different sentences on the
      // screen, both terminal.
      collectStatus = HttpStatus.gone;
      collectBody = {'error': 'expired'};
      expect(await service().collect('abc-123'), isA<DrivePairingExpired>());

      collectStatus = HttpStatus.notFound;
      collectBody = {'error': 'no session'};
      expect(await service().collect('abc-123'), isA<DrivePairingGone>());
    });

    test('and anything else is worth asking again about', () async {
      // Not a verdict: a 500 from the platform, a body this build does not
      // know, a socket that died. The session's own window is the bound.
      collectStatus = HttpStatus.internalServerError;
      collectBody = {'error': 'boom'};
      expect(
        await service().collect('abc-123'),
        isA<DrivePairingUnreachable>(),
      );

      collectStatus = HttpStatus.ok;
      collectBody = {'status': 'something-this-build-has-never-heard-of'};
      expect(
        await service().collect('abc-123'),
        isA<DrivePairingUnreachable>(),
      );

      final dead = service();
      await server.close(force: true);
      expect(await dead.collect('abc-123'), isA<DrivePairingUnreachable>());
    });
  });

  group('a stored session', () {
    test('needs an id, a link and a time to be one', () {
      expect(DrivePairingSession.fromJson(null), isNull);
      expect(DrivePairingSession.fromJson('nonsense'), isNull);
      expect(
        DrivePairingSession.fromJson({
          'sessionId': ' ',
          'link': 'https://example.com/link?s=x',
          'expiresAt': '2026-09-25T20:10:00.000Z',
        }),
        isNull,
      );
      expect(
        DrivePairingSession.fromJson({
          'sessionId': 'abc',
          'link': 'https://example.com/link?s=abc',
          'expiresAt': 'not a time',
        }),
        isNull,
      );
    });

    test('and nothing else: a service still minting a typeable code is read '
        'past it', () {
      // The code is gone from the service's answer and from the screen -- no
      // route ever read it back, and a code a viewer cannot type anywhere is
      // worse than no code. A deployment that still sends one is a session
      // like any other.
      final session = DrivePairingSession.fromJson({
        'sessionId': 'abc',
        'code': 'K7M2QX',
        'link': 'https://example.com/link?s=abc',
        'expiresAt': '2026-09-25T20:10:00.000Z',
      });
      expect(session, isNotNull);
      expect(session!.sessionId, 'abc');
      expect('$session', isNot(contains('K7M2QX')));
    });
  });

  test('the hand-back link is one this app does nothing with', () {
    // The whole answer to what was written against `app_links` here: a
    // host-less `stremio://` link is already the shape the app drops, so the
    // hand-back adds no second meaning to the scheme and a launch link the
    // platform replays on a cold start days later is dropped then too. What
    // brings the app forward is the platform switching tasks.
    expect(deepLinkAddonManifestUrl(drivePairingHandBackLink), isNull);
    expect(Uri.parse(drivePairingHandBackLink).host, isEmpty);
  });
}
