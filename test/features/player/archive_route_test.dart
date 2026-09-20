import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/archive_route.dart';
import 'package:xtremio/features/player/archive_sniff.dart';

/// Sending a container to the streaming server instead of giving up on it.
///
/// The server reads an archive or a disc image as ranges of itself
/// (`docs/translated-sources.md` in the stream-server tree), so a film
/// inside one plays as cheaply as a plain file -- and one that is *packed*
/// rather than wrapped is refused with a sentence. Both halves are the
/// route's contract, and this is a fake of it: every shape the real routes
/// answer with (`server/src/routes/archive.rs`), answered here.
void main() {
  group('routeArchive', () {
    late HttpServer server;
    HttpOverrides? overrides;

    /// Every request the server saw, as `METHOD <request-target>` with the
    /// target exactly as it arrived -- which is the point for a torrent
    /// key, whose own `/` has to reach the route escaped.
    late List<String> seen;

    /// The bodies of the `POST /{fmt}/create` calls, decoded.
    late List<Map<String, dynamic>> created;

    /// What `/{fmt}/create` answers.
    late int createStatus;
    late Object? createBody;

    /// What `GET /{fmt}/stream/{key}` answers.
    late int streamStatus;
    late String? streamLocation;
    late Object? streamBody;

    /// What `GET /{fmt}/stream?key=...` answers -- the query form, which
    /// is the one that indexes a torrent-backed container.
    late int queryStatus;
    late Object? queryBody;

    setUp(() async {
      // The test binding answers every request with a 400 of its own;
      // these talk to a real server on the loopback.
      overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      seen = [];
      created = [];
      createStatus = HttpStatus.ok;
      createBody = {'key': 'session-key'};
      streamStatus = HttpStatus.temporaryRedirect;
      streamLocation = './session-key/Some%20Film.mkv';
      streamBody = null;
      queryStatus = HttpStatus.notFound;
      queryBody = null;

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        seen.add('${request.method} ${request.uri}');
        final path = request.uri.path;
        final response = request.response;
        Object? body;
        if (path.endsWith('/create')) {
          created.add(
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>,
          );
          response.statusCode = createStatus;
          body = createBody;
        } else if (path.endsWith('/stream')) {
          response.statusCode = queryStatus;
          body = queryBody;
        } else {
          response.statusCode = streamStatus;
          body = streamBody;
          final location = streamLocation;
          if (location != null) {
            response.headers.set(HttpHeaders.locationHeader, location);
          }
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

    Uri base() => Uri.parse('http://127.0.0.1:${server.port}');

    ArchiveRouteRequest link({ArchiveKind kind = ArchiveKind.zip}) =>
        ArchiveRouteRequest.link(
          serverBase: base(),
          kind: kind,
          played: Uri.parse(
            'http://127.0.0.1:${server.port}/proxy/d=https%3A%2F%2Fdebrid'
            '.example&p=player-1/dl/token/Release.zip',
          ),
        );

    ArchiveRouteRequest inTorrent({ArchiveKind kind = ArchiveKind.rar}) =>
        ArchiveRouteRequest.inTorrent(
          serverBase: base(),
          kind: kind,
          infoHash: 'dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c',
          pathInTorrent: 'Release/film.part1.rar',
        );

    test('a link is created, and what plays is the member', () async {
      final routed = await routeArchive(link());

      // The create names the format's own prefix and carries the URL the
      // player would have fetched -- the `/proxy` one, credentials and
      // all -- as the one-entry volume list.
      expect(created, [
        {
          'urls': [
            'http://127.0.0.1:${server.port}/proxy/d=https%3A%2F%2Fdebrid'
                '.example&p=player-1/dl/token/Release.zip',
          ],
        },
      ]);
      expect(seen, ['POST /zip/create', 'GET /zip/stream/session-key']);
      // The redirect is resolved here rather than left to mpv, so what the
      // engine is handed ends in the film's own name.
      expect(
        routed,
        isA<ArchiveMember>().having(
          (member) => member.url.toString(),
          'url',
          'http://127.0.0.1:${server.port}/zip/stream/session-key/'
              'Some%20Film.mkv',
        ),
      );
    });

    test('a torrent names itself: no create call at all', () async {
      final routed = await routeArchive(inTorrent());

      expect(created, isEmpty);
      // `torrent:<hash>/<path in the torrent>` is **one** path segment, so
      // its own separator reaches the route escaped; the route decodes the
      // segment and splits on the first `/`.
      expect(seen, [
        'GET /rar/stream/torrent%3Add8255ecdc7ca55fb0bbf81323d87062db1f6d1c'
            '%2FRelease%2Ffilm.part1.rar',
      ]);
      expect(
        routed,
        isA<ArchiveMember>().having(
          (member) => member.url.pathSegments.last,
          'member',
          'Some Film.mkv',
        ),
      );
    });

    test('every refusal the routes answer with is carried whole', () async {
      // 415: a member this server will not serve by range. The kind is the
      // server's own word and part of the contract; the message is the
      // sentence it wrote for a player to show.
      for (final (kind, message) in const [
        ('compressed', 'this file is compressed inside the zip (deflate)'),
        ('encrypted', 'this file is encrypted inside the archive'),
        ('solid', 'this file shares a solid block with the others'),
        ('noRandomAccess', 'a tar.gz is one compressed stream'),
        ('unsupported', 'this UDF image uses a type 2 partition map'),
      ]) {
        createStatus = HttpStatus.unsupportedMediaType;
        createBody = {'refused': kind, 'message': message};
        expect(
          await routeArchive(link()),
          isA<ArchiveRefused>()
              .having((r) => r.kind, 'kind', kind)
              .having((r) => r.message, 'message', message),
        );
      }

      // 422: the container contradicts itself.
      createStatus = HttpStatus.unprocessableEntity;
      createBody = {
        'refused': 'malformed',
        'message': 'this archive could not be read: volume 2 is missing',
      };
      expect(
        await routeArchive(link()),
        isA<ArchiveRefused>().having((r) => r.kind, 'kind', 'malformed'),
      );

      // 501: this server declining to do the work. The route says `error`
      // and names no kind there, so the word is ours and the sentence is
      // still the server's.
      createStatus = HttpStatus.notImplemented;
      createBody = {
        'error':
            'this link\'s host does not serve byte ranges, so a file '
            'inside it could only be played by downloading the whole thing',
      };
      expect(
        await routeArchive(link()),
        isA<ArchiveRefused>()
            .having((r) => r.kind, 'kind', ArchiveRefused.unavailable)
            .having((r) => r.message, 'message', startsWith('this link\'s')),
      );
    });

    test('a refusal on the stream route is carried too', () async {
      // Nothing says a container has to be refused at the create: the
      // member request is where a `torrent:` session is indexed, and it is
      // where the refusal for one arrives.
      streamStatus = HttpStatus.unsupportedMediaType;
      streamLocation = null;
      streamBody = {'refused': 'solid', 'message': 'one solid block'};

      expect(
        await routeArchive(link()),
        isA<ArchiveRefused>().having((r) => r.kind, 'kind', 'solid'),
      );
    });

    test('a torrent the redirect route cannot select in is indexed by the '
        'query form, which is where its refusal is', () async {
      // As the server stands (master 52d25dc) `GET /{fmt}/stream/{key}`
      // only *looks up* a session, so a `torrent:` key it has never seen
      // is a 404 and no member is selected. The query form does create the
      // session, which is what turns a Blu-ray image's metadata partition
      // from "can't be played" into the sentence that says why.
      streamStatus = HttpStatus.notFound;
      streamLocation = null;
      queryStatus = HttpStatus.unsupportedMediaType;
      queryBody = {
        'refused': 'unsupported',
        'message':
            'this UDF image uses a type 2 partition map (metadata), '
            'which remaps logical blocks; that is not supported yet',
      };

      final routed = await routeArchive(inTorrent(kind: ArchiveKind.iso));
      expect(
        routed,
        isA<ArchiveRefused>().having((r) => r.kind, 'kind', 'unsupported'),
      );
      expect(seen, hasLength(2));
      expect(seen.last, startsWith('GET /iso/stream?key=torrent%3A'));
    });

    test('a link the server cannot answer for is nobody\'s message to '
        'replace', () async {
      // Every failure that is not the server saying no is null, and the
      // viewer keeps the message they would have had.
      createStatus = HttpStatus.badGateway;
      createBody = {'error': 'the origin is gone'};
      expect(await routeArchive(link()), isNull);

      createStatus = HttpStatus.ok;
      createBody = {'not': 'a key'};
      expect(await routeArchive(link()), isNull);

      createBody = {'key': 'session-key'};
      streamStatus = HttpStatus.notFound;
      streamLocation = null;
      expect(await routeArchive(link()), isNull);

      // A refusal whose body is not the shape the route documents is not a
      // refusal: a message invented here would be worse than mpv's.
      createStatus = HttpStatus.unsupportedMediaType;
      createBody = {'refused': 'compressed'};
      expect(await routeArchive(link()), isNull);
    });

    test('a server that is not there is null, not a throw', () async {
      final port = server.port;
      await server.close(force: true);
      expect(
        await routeArchive(
          ArchiveRouteRequest.link(
            serverBase: Uri.parse('http://127.0.0.1:$port'),
            kind: ArchiveKind.sevenZip,
            played: Uri.parse('https://example.org/release.7z'),
          ),
          timeout: const Duration(seconds: 2),
        ),
        isNull,
      );
    });
  });

  group('archiveRefusal', () {
    /// The sentence a viewer reads, after "Playback failed: ".
    String said(String kind, {String message = 'the server said so'}) =>
        archiveRefusal(
          ArchiveKind.rar,
          ArchiveRefused(kind: kind, message: message),
        );

    test('says what is the matter in the viewer\'s terms', () {
      expect(
        said('compressed'),
        'this RAR archive has the film packed inside it rather than just '
        'wrapped, so playing it would mean unpacking the whole archive '
        'first. Try another source.',
      );
      expect(said('solid'), contains('one solid block'));
      expect(said('solid'), endsWith('Try another source.'));
      expect(said('encrypted'), contains('password-protected'));
      expect(said('noRandomAccess'), contains('no way in at the middle'));
      // None of the four falls back to what the server said: each is this
      // app's own sentence, in the viewer's terms.
      for (final kind in const [
        'compressed',
        'solid',
        'encrypted',
        'noRandomAccess',
      ]) {
        expect(said(kind), isNot(contains('the server said so')));
        expect(said(kind), contains('RAR archive'));
      }
    });

    test('keeps the server\'s sentence where it knows more', () {
      // `malformed` and `unsupported` each name one concrete thing -- the
      // volume that is missing, the UDF structure -- that no message
      // written in this app could know.
      expect(
        said('malformed', message: 'this archive could not be read: volume 2'),
        'this archive could not be read: volume 2. Try another source.',
      );
      expect(
        said('unsupported', message: 'this UDF image uses a metadata map'),
        startsWith('this UDF image uses a metadata map'),
      );
      expect(
        said(ArchiveRefused.unavailable, message: 'this link\'s host will not'),
        'this link\'s host will not. Try another source.',
      );
      // A kind this app has never heard of is still the server's sentence
      // and never a blank.
      expect(said('somethingNew'), 'the server said so. Try another source.');
    });
  });
}
