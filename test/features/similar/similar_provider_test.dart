import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/similar/similar_titles.dart';
import 'package:xtremio/features/similar/xtremio_similar_titles.dart';

/// Asking the xtremio-xervice server what a title is like, over a server on
/// the loopback that answers what `xtremio-xervice/functions/similar.js` does.
///
/// What is checked is the contract between the two: the path the request
/// goes to, the answer's shape, and every status the function can answer
/// with turned into a failure the log can name -- never into an empty
/// answer, because an empty answer is written down and a failure is not.
void main() {
  group('XtremioSimilarTitles', () {
    late HttpServer server;
    HttpOverrides? overrides;

    /// Every request the server was sent: its method and path.
    late List<String> requests;

    /// What the server answers.
    late ({int status, String body, Duration delay}) reply;

    void answer(int status, Object? body, {Duration delay = Duration.zero}) =>
        reply = (
          status: status,
          body: body is String ? body : jsonEncode(body),
          delay: delay,
        );

    setUp(() async {
      // The test binding answers every request with a 400 of its own;
      // this one talks to a real server on the loopback.
      overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      requests = [];
      answer(HttpStatus.ok, {'titles': const [], 'version': 1});
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests.add('${request.method} ${request.uri.path}');
        final current = reply;
        if (current.delay > Duration.zero) {
          await Future<void>.delayed(current.delay);
        }
        try {
          request.response.statusCode = current.status;
          request.response.headers.contentType = ContentType.json;
          request.response.write(current.body);
          await request.response.close();
        } on Object {
          // The client abandons a request past its budget; writing into
          // the socket it closed is that test working, not a failure.
        }
      });
    });

    tearDown(() async {
      await server.close(force: true);
      HttpOverrides.global = overrides;
    });

    XtremioSimilarTitles provider({
      Duration budget = const Duration(seconds: 5),
    }) => XtremioSimilarTitles(
      base: Uri.parse('http://${server.address.address}:${server.port}'),
      budget: budget,
    );

    Matcher failsWith(SimilarTrouble trouble) => throwsA(
      isA<SimilarTitlesFailure>().having((f) => f.trouble, 'trouble', trouble),
    );

    test('the request is a GET of /similar/{type}/{id}', () async {
      await provider().suggest(type: 'movie', id: 'tt0063350');
      await provider().suggest(type: 'series', id: 'tt0903747');

      expect(requests, [
        'GET /similar/movie/tt0063350',
        'GET /similar/series/tt0903747',
      ]);
    });

    test('parses the documented answer and skips what it cannot use', () async {
      answer(HttpStatus.ok, {
        'titles': [
          {
            'title': 'Carnival of Souls',
            'year': 1962,
            'kind': 'film',
            'why': 'dread',
          },
          {'title': 'Twin Peaks', 'year': 1990, 'kind': 'series', 'why': null},
          // What the server passes on when the model's row was missing a
          // part: a null year is a row the guard could not check, so it
          // is dropped; a null kind is a row looked for in both
          // catalogues.
          {'title': 'No Year', 'year': null, 'kind': 'film', 'why': 'x'},
          {'title': 'Some Kind', 'year': 1980, 'kind': null, 'why': 'y'},
          {'year': 1999, 'kind': 'film', 'why': 'no title'},
          'not a row',
        ],
        'version': 1,
      });

      final suggestions = await provider().suggest(
        type: 'movie',
        id: 'tt0063350',
      );

      expect(suggestions, const [
        SuggestedTitle(
          title: 'Carnival of Souls',
          year: 1962,
          why: 'dread',
          kind: SuggestedKind.film,
        ),
        SuggestedTitle(
          title: 'Twin Peaks',
          year: 1990,
          why: '',
          kind: SuggestedKind.series,
        ),
        SuggestedTitle(title: 'Some Kind', year: 1980, why: 'y'),
      ]);
    });

    test('an empty list is an answer, not a failure', () async {
      answer(HttpStatus.ok, {'titles': const [], 'version': 1});

      expect(await provider().suggest(type: 'movie', id: 'tt1'), isEmpty);
    });

    test('404 is a title the server does not know', () async {
      answer(HttpStatus.notFound, {'error': 'no such title'});

      await expectLater(
        provider().suggest(type: 'movie', id: 'tt0000000'),
        failsWith(SimilarTrouble.unknownTitle),
      );
    });

    test('503 is another request still asking about the title', () async {
      answer(HttpStatus.serviceUnavailable, {'error': 'asking'});

      await expectLater(
        provider().suggest(type: 'movie', id: 'tt1'),
        failsWith(SimilarTrouble.busy),
      );
    });

    test('502, 500 and 400 are a server that could not answer', () async {
      for (final status in [
        HttpStatus.badGateway,
        HttpStatus.internalServerError,
        HttpStatus.badRequest,
      ]) {
        answer(status, {'error': 'no'});
        await expectLater(
          provider().suggest(type: 'movie', id: 'tt1'),
          throwsA(
            isA<SimilarTitlesFailure>()
                .having((f) => f.trouble, 'trouble', SimilarTrouble.unavailable)
                .having((f) => f.detail, 'detail', '$status'),
          ),
        );
      }
    });

    test('a body that is not JSON is malformed, not empty', () async {
      answer(HttpStatus.ok, '<html>a captive portal</html>');

      await expectLater(
        provider().suggest(type: 'movie', id: 'tt1'),
        failsWith(SimilarTrouble.malformed),
      );
    });

    test('JSON without a list of titles is malformed too', () async {
      answer(HttpStatus.ok, {'films': const [], 'version': 1});

      await expectLater(
        provider().suggest(type: 'movie', id: 'tt1'),
        failsWith(SimilarTrouble.malformed),
      );
    });

    test('no network at all is a failure like any other', () async {
      // Nothing is listening here: what an aeroplane, a captive portal or
      // a dead DNS looks like from inside the budget.
      final nowhere = XtremioSimilarTitles(
        base: Uri.parse('http://127.0.0.1:1'),
        budget: const Duration(seconds: 2),
      );

      await expectLater(
        nowhere.suggest(type: 'movie', id: 'tt1'),
        throwsA(
          isA<SimilarTitlesFailure>()
              .having((f) => f.trouble, 'trouble', SimilarTrouble.unreachable)
              // What went wrong, never where: an exception's own message
              // quotes the address it was talking to, and the detail is
              // written to the log.
              .having((f) => f.detail, 'detail', isNot(contains('127.0.0.1'))),
        ),
      );
    });

    test('a request past the budget is abandoned', () async {
      answer(HttpStatus.ok, {
        'titles': const [],
        'version': 1,
      }, delay: const Duration(seconds: 5));

      final started = DateTime.now();
      await expectLater(
        provider(budget: const Duration(milliseconds: 150))
            .suggest(type: 'movie', id: 'tt1'),
        failsWith(SimilarTrouble.tooSlow),
      );
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 5)),
        reason: 'abandoning means not waiting for the answer',
      );
    });

    test('the default budget waits out a first ask of a title', () {
      // The first device to open a title waits while the server asks the
      // model; the row is late by design, so giving up early would only
      // fail every first ask.
      expect(similarBudget, const Duration(seconds: 20));
      expect(XtremioSimilarTitles().budget, similarBudget);
      expect(
        XtremioSimilarTitles().base,
        Uri.parse('https://xtremio-xervice.web.app'),
      );
    });
  });
}
