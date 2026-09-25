import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

/// The two calls a reload makes, answered by a server on the loopback
/// rather than by a stub of the parsing.
///
/// `drive_listing_test.dart` has the reconciling and the reading of one
/// page. What is here is everything between them that only a real
/// request-and-answer proves: that the access token is minted first and
/// carried in a header, that the paging runs to the end and merges, that a
/// page which fails half way reconciles **nothing**, and which status means
/// which refusal.
///
/// Nothing in this repository is a token. Both strings below are markers a
/// test can search for; neither is a credential nor the shape of one
/// (`AGENTS.md`, "Never log auth material").
const String _refreshToken = 'fake-refresh-token-for-tests-only';
const String _accessToken = 'fake-access-token-for-tests-only';

void main() {
  group('a listing over the wire', () {
    late HttpServer server;
    HttpOverrides? overrides;

    /// Every request the server saw, as `METHOD <request-target>`.
    late List<String> seen;

    /// Every `Authorization` header it was sent.
    late List<String?> authorised;

    /// What `POST /refresh` answers.
    late int refreshStatus;
    late Object? refreshBody;

    /// What each `GET` of the files endpoint answers, in order; the last
    /// repeats.
    late List<(int, Object?)> pages;

    late XtremioDriveFileLister lister;

    setUp(() async {
      // The test binding answers every request with a 400 of its own; this
      // talks to a real server on the loopback.
      overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      seen = [];
      authorised = [];
      refreshStatus = HttpStatus.ok;
      refreshBody = {'accessToken': _accessToken, 'expiresIn': 3599};
      pages = [
        (
          HttpStatus.ok,
          {
            'files': [
              {'id': 'drive-file-1', 'name': 'ep6.avi'},
            ],
          },
        ),
      ];

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        seen.add('${request.method} ${request.uri}');
        authorised.add(request.headers.value(HttpHeaders.authorizationHeader));
        await utf8.decoder.bind(request).join();
        final response = request.response;
        final Object? body;
        if (request.method == 'POST') {
          response.statusCode = refreshStatus;
          body = refreshBody;
        } else {
          final page = pages.length == 1 ? pages.first : pages.removeAt(0);
          response.statusCode = page.$1;
          body = page.$2;
        }
        if (body != null) {
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode(body));
        }
        await response.close();
      });
      final origin = 'http://127.0.0.1:${server.port}';
      lister = XtremioDriveFileLister(
        origin: origin,
        filesEndpoint: Uri.parse('$origin/drive/v3/files'),
        timeout: const Duration(seconds: 5),
      );
    });

    tearDown(() async {
      await server.close(force: true);
      HttpOverrides.global = overrides;
    });

    test(
      'mints a token and carries it in a header, never in the URL',
      () async {
        final listing = await lister.listFiles(refreshToken: _refreshToken);

        expect(listing, isA<DriveFilesListed>());
        expect(seen.first, 'POST /refresh');
        expect(authorised.first, isNull, reason: 'the refresh is not bearer');
        expect(authorised.last, 'Bearer $_accessToken');
        expect(
          seen.last,
          isNot(contains(_accessToken)),
          reason: 'a URL reaches logs and proxies; a header does not',
        );
        expect(
          seen.join(' '),
          isNot(contains(_refreshToken)),
          reason: 'the grant goes in a body and nowhere else',
        );
      },
    );

    test('asks for the fields it reads, and skips the bin', () async {
      await lister.listFiles(refreshToken: _refreshToken);

      final asked = Uri.parse(seen.last.split(' ').last);
      // Written out rather than compared against the constant it is
      // pinning: a test that reads the mask off the code it is checking
      // passes at every value of it.
      expect(
        asked.queryParameters['fields'],
        'nextPageToken,files(id,name,mimeType,'
        'videoMediaMetadata(width,height,durationMillis))',
      );
      expect(asked.queryParameters['q'], 'trashed = false');
    });

    test('pages to the end, and answers one whole listing', () async {
      pages = [
        (
          HttpStatus.ok,
          {
            'files': [
              {'id': 'drive-file-1', 'name': 'ep6.avi'},
            ],
            'nextPageToken': 'page-2',
          },
        ),
        (
          HttpStatus.ok,
          {
            'files': [
              {
                'id': 'drive-file-2',
                'name': 'Arrival.2016.mkv',
                'videoMediaMetadata': {
                  'height': 2160,
                  'durationMillis': '6960000',
                },
              },
            ],
          },
        ),
      ];

      final listing = await lister.listFiles(
        refreshToken: _refreshToken,
      ) as DriveFilesListed;

      expect(listing.filesById.keys, ['drive-file-1', 'drive-file-2']);
      expect(listing.filesById['drive-file-2']!.height, 2160);
      expect(listing.filesById['drive-file-2']!.durationMillis, 6960000);
      expect(
        Uri.parse(seen.last.split(' ').last).queryParameters['pageToken'],
        'page-2',
        reason: 'the second page is asked for with the first page\'s token',
      );
      expect(
        Uri.parse(seen[1].split(' ').last).queryParameters
            .containsKey('pageToken'),
        isFalse,
      );
    });

    test('a page that fails half way answers a refusal and not the half it '
        'had', () async {
      // The property the whole feature is arranged around: this is a
      // television dropping off its wifi on the second page, and the one
      // thing that must not come back is a listing naming the first page's
      // file -- which reads as "the viewer deleted the other one".
      pages = [
        (
          HttpStatus.ok,
          {
            'files': [
              {'id': 'drive-file-1', 'name': 'ep6.avi'},
            ],
            'nextPageToken': 'page-2',
          },
        ),
        (HttpStatus.internalServerError, null),
      ];

      final listing = await lister.listFiles(refreshToken: _refreshToken);

      expect(listing, isA<DriveListingFailed>());
      expect(
        (listing as DriveListingFailed).reason,
        DriveListingFailure.unreachable,
      );
    });

    test(
      'a body that is not a page is a version skew, not a network',
      () async {
        pages = [
          (HttpStatus.ok, {'files': 'ep6.avi'}),
        ];

        final listing = await lister.listFiles(refreshToken: _refreshToken);

        expect(
          (listing as DriveListingFailed).reason,
          DriveListingFailure.notUnderstood,
        );
      },
    );

    test(
      'the service saying the grant is gone is the only terminal answer',
      () async {
        refreshStatus = HttpStatus.unauthorized;
        refreshBody = {'error': 'invalid_grant', 'pairAgain': true};

        final listing = await lister.listFiles(refreshToken: _refreshToken);

        expect(
          (listing as DriveListingFailed).reason,
          DriveListingFailure.pairAgain,
        );
        expect(seen, ['POST /refresh'], reason: 'nothing was listed');
      },
    );

    test('and a refusal that is not that one is worth trying again', () async {
      refreshStatus = HttpStatus.unauthorized;
      refreshBody = {'error': 'something else'};

      final listing = await lister.listFiles(refreshToken: _refreshToken);

      expect(
        (listing as DriveListingFailed).reason,
        DriveListingFailure.unreachable,
        reason: 'a wrong guess here deletes the credential',
      );
    });

    test('a 401 from Google itself is not read as a revoked grant', () async {
      pages = [(HttpStatus.unauthorized, null)];

      final listing = await lister.listFiles(refreshToken: _refreshToken);

      expect(
        (listing as DriveListingFailed).reason,
        DriveListingFailure.unreachable,
        reason: 'a token minted a moment ago is likelier a proxy or a clock',
      );
    });

    test('the rate limit has a sentence of its own', () async {
      refreshStatus = HttpStatus.tooManyRequests;
      refreshBody = {'error': 'too many refreshes'};

      final listing = await lister.listFiles(refreshToken: _refreshToken);

      expect(
        (listing as DriveListingFailed).reason,
        DriveListingFailure.tooOften,
      );
    });

    test('a refresh with no token on it is a skew and not a listing', () async {
      refreshBody = {'expiresIn': 3599};

      final listing = await lister.listFiles(refreshToken: _refreshToken);

      expect(
        (listing as DriveListingFailed).reason,
        DriveListingFailure.notUnderstood,
      );
      expect(seen, ['POST /refresh']);
    });

    test(
      'a redirect is not followed, so no header follows it anywhere',
      () async {
        // A followed redirect is how an `Authorization` header ends up at a
        // host nobody meant to send it to. It reads as a non-200 instead.
        pages = [(HttpStatus.found, null)];

        final listing = await lister.listFiles(refreshToken: _refreshToken);

        expect(
          (listing as DriveListingFailed).reason,
          DriveListingFailure.unreachable,
        );
        expect(seen.where((one) => one.startsWith('GET')), hasLength(1));
      },
    );

    test(
      'an answer too big to be a page is refused rather than read',
      () async {
        pages = [
          (HttpStatus.ok, {'filler': 'x' * (600 * 1024)}),
        ];

        final listing = await lister.listFiles(refreshToken: _refreshToken);

        expect(
          (listing as DriveListingFailed).reason,
          DriveListingFailure.notUnderstood,
        );
      },
    );

    test('a page token that never ends is refused, never trimmed', () async {
      // Past the cap the answer is a refusal and **nothing is written**: a
      // truncated listing is the partial answer this whole design keeps
      // away from the store.
      pages = [
        (
          HttpStatus.ok,
          {
            'files': [
              {'id': 'drive-file-1', 'name': 'ep6.avi'},
            ],
            'nextPageToken': 'and-another',
          },
        ),
      ];

      final listing = await lister.listFiles(refreshToken: _refreshToken);

      expect(
        (listing as DriveListingFailed).reason,
        DriveListingFailure.notUnderstood,
      );
      expect(
        seen.where((one) => one.startsWith('GET')),
        hasLength(XtremioDriveFileLister.maxPages),
      );
    });

    test(
      'a server that is not there at all is one refusal, not a throw',
      () async {
        await server.close(force: true);

        final listing = await lister.listFiles(refreshToken: _refreshToken);

        expect(
          (listing as DriveListingFailed).reason,
          DriveListingFailure.unreachable,
        );
      },
    );
  });
}
