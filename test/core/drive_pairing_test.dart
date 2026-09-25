import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

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
      sessionStatus = HttpStatus.ok;
      sessionBody = {
        'sessionId': 'abc-123',
        'code': 'K7M2QX',
        'link': 'https://xtremio-drive.web.app/link?s=abc-123',
        'expiresAt': '2026-09-25T20:10:00.000Z',
      };
      collectStatus = HttpStatus.ok;
      collectBody = {'status': 'pending'};

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        seen.add('${request.method} ${request.uri}');
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
      final opening = await service().open();
      expect(seen, ['POST /session']);
      final session = (opening as DrivePairingOpened).session;
      expect(session.sessionId, 'abc-123');
      expect(session.code, 'K7M2QX');
      expect(session.link, 'https://xtremio-drive.web.app/link?s=abc-123');
      expect(session.expiresAt, DateTime.utc(2026, 9, 25, 20, 10));
    });

    test('a session it cannot draw is no session at all', () async {
      // The link is what the QR carries and the phone opens; a body without
      // one is not something to put on a television and wait beside.
      sessionBody = {'sessionId': 'abc-123', 'code': 'K7M2QX'};
      expect(
        (await service().open() as DrivePairingUnavailable).reason,
        XtremioDrivePairingService.notUnderstood,
      );
    });

    test('and the rate limit is its own sentence', () async {
      // Sixty an hour per address. Worth telling apart from a network
      // fault: one is waited out, the other is looked at.
      sessionStatus = HttpStatus.tooManyRequests;
      sessionBody = {'error': 'too many sessions'};
      expect(
        (await service().open() as DrivePairingUnavailable).reason,
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
        (await dead.open() as DrivePairingUnavailable).reason,
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

    test('a ready session hands over the grant and the file', () async {
      collectBody = {
        'status': 'ready',
        'refreshToken': fakeRefreshToken,
        // Read past, deliberately: an access token is good for an hour,
        // this device has nowhere safe for a second credential, and
        // DriveSource mints its own through POST /refresh.
        'accessToken': 'fake-access-token-for-tests-only',
        'accessExpiresAt': '2026-09-25T21:00:00.000Z',
        'file': {
          'fileId': 'drive-file-1',
          'name': 'Arrival (2016) 2160p.mkv',
          'mimeType': 'video/x-matroska',
        },
      };
      final answer = await service().collect('abc-123');
      final collected = answer as DrivePairingCollected;
      expect(collected.refreshToken, fakeRefreshToken);
      expect(collected.fileId, 'drive-file-1');
      expect(collected.name, 'Arrival (2016) 2160p.mkv');
      expect(collected.mimeType, 'video/x-matroska');
      // And it names the file and nothing else when something writes it
      // into a line.
      expect('$collected', 'DrivePairingCollected(drive-file-1)');
    });

    test('a ready session with nothing on it is not polled again', () async {
      // The session is deleted by the read either way, so there is nothing
      // left to wait for -- whichever half of the answer is missing.
      collectBody = {
        'status': 'ready',
        'file': {'fileId': 'drive-file-1'},
      };
      expect(await service().collect('abc-123'), isA<DrivePairingGone>());
      collectBody = {'status': 'ready', 'refreshToken': fakeRefreshToken};
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

    test('but a missing code is only a missing fallback', () {
      // The QR is the way in; the six characters under it are the spare.
      final session = DrivePairingSession.fromJson({
        'sessionId': 'abc',
        'link': 'https://example.com/link?s=abc',
        'expiresAt': '2026-09-25T20:10:00.000Z',
      });
      expect(session, isNotNull);
      expect(session!.code, isEmpty);
    });
  });
}
