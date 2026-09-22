/// The sort question over a server on the loopback that answers what
/// Google's does.
///
/// The recommendation half of the check is [GeminiSimilarTitles] and is
/// tested where that lives. What is here is the question the row never
/// asks: the ordering call, its answer shape, its one repair, and the
/// thing that matters more than any of them — **the key goes into the
/// query and nowhere else**, and no failure this can throw carries it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/similar/check_gemini.dart';
import 'package:xtremio/features/similar/similar_titles.dart';

/// A key of the shape a viewer would paste, and of no use to anybody.
const String pastedKey = 'AIza-not-a-real-key';

void main() {
  group('GeminiModelCheck.order', () {
    late HttpServer server;
    HttpOverrides? overrides;

    late List<Map<String, dynamic>> sent;
    late List<Uri> urls;
    late List<({int status, String body, Duration delay})> answers;

    void answer(int status, Object? body, {Duration delay = Duration.zero}) =>
        answers.add((
          status: status,
          body: body is String ? body : jsonEncode(body),
          delay: delay,
        ));

    /// A documented answer: the order, inside the JSON text of the first
    /// candidate's parts.
    Object ordered(List<String> titles) => {
      'candidates': [
        {
          'content': {
            'parts': [
              {
                'text': jsonEncode({'order': titles}),
              },
            ],
          },
        },
      ],
    };

    setUp(() async {
      // The test binding answers every request with a 400 of its own;
      // this one talks to a real server on the loopback.
      overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      sent = [];
      urls = [];
      answers = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        urls.add(request.uri);
        final body = await utf8.decoder.bind(request).join();
        sent.add(jsonDecode(body) as Map<String, dynamic>);
        final reply = answers.length > 1 ? answers.removeAt(0) : answers.first;
        if (reply.delay > Duration.zero) {
          await Future<void>.delayed(reply.delay);
        }
        try {
          request.response.statusCode = reply.status;
          request.response.write(reply.body);
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

    GeminiModelCheck provider({Duration budget = const Duration(seconds: 5)}) =>
        GeminiModelCheck(
          apiKey: pastedKey,
          endpoint: Uri.parse(
            'http://${server.address.address}:${server.port}/v1beta',
          ),
          budget: budget,
        );

    test(
      'asks for feel rather than relatedness, and reads the order',
      () async {
        answer(HttpStatus.ok, ordered(['Bug (2006)', 'Watchmen (2009)']));

        final order = await provider().order('Glass (2019)', [
          'Watchmen (2009)',
          'Bug (2006)',
        ]);

        expect(order, ['Bug (2006)', 'Watchmen (2009)']);
        final prompt =
            ((sent.single['contents'] as List).first
                    as Map<String, dynamic>)['parts']
                as List;
        final text = (prompt.first as Map<String, dynamic>)['text'] as String;
        // The sentence is worth +0.12 on tone and is not decoration; and the
        // salting only works against a question that asks for feel.
        expect(text, contains('*feels* like Glass (2019)'));
        expect(text, contains('rather than by how related they are'));
        expect(text, contains('Watchmen (2009); Bug (2006)'));
      },
    );

    test('the key rides in the query and nowhere else', () async {
      answer(HttpStatus.ok, ordered(const []));

      await provider().order('Glass (2019)', const ['Bug (2006)']);

      expect(urls.single.queryParameters['key'], pastedKey);
      expect(
        urls.single.path,
        '/v1beta/models/$defaultSimilarModel:generateContent',
      );
      // Not in the body, not in a header this file sets.
      expect(jsonEncode(sent.single), isNot(contains(pastedKey)));
    });

    test('a 400 naming temperature is worth exactly one more try', () async {
      answer(HttpStatus.badRequest, {
        'error': {'message': 'temperature is deprecated'},
      });
      answer(HttpStatus.ok, ordered(['Bug (2006)']));

      final order = await provider().order('Glass (2019)', ['Bug (2006)']);

      expect(order, ['Bug (2006)']);
      expect(sent, hasLength(2));
      expect(
        (sent.first['generationConfig'] as Map).containsKey('temperature'),
        isTrue,
      );
      expect(
        (sent.last['generationConfig'] as Map).containsKey('temperature'),
        isFalse,
      );
    });

    test('a second refusal is the answer, not a third request', () async {
      answer(HttpStatus.badRequest, {
        'error': {'message': 'temperature is deprecated'},
      });

      await expectLater(
        provider().order('Glass (2019)', ['Bug (2006)']),
        throwsA(
          isA<SimilarTitlesFailure>().having(
            (failure) => failure.trouble,
            'trouble',
            SimilarTrouble.refused,
          ),
        ),
      );
      expect(sent, hasLength(2));
    });

    test('every status is the failure a log can be read back in', () async {
      for (final (status, trouble) in [
        (HttpStatus.notFound, SimilarTrouble.gone),
        (HttpStatus.forbidden, SimilarTrouble.notInTier),
        (HttpStatus.tooManyRequests, SimilarTrouble.quota),
        (HttpStatus.serviceUnavailable, SimilarTrouble.busy),
      ]) {
        answers = [];
        answer(status, {'error': 'no'});

        await expectLater(
          provider().order('Glass (2019)', ['Bug (2006)']),
          throwsA(
            isA<SimilarTitlesFailure>()
                .having((failure) => failure.trouble, 'trouble', trouble)
                // Whatever it says, it never says the key.
                .having(
                  (failure) => failure.toString(),
                  'toString',
                  isNot(contains(pastedKey)),
                ),
          ),
        );
      }
    });

    test(
      'an answer that is not the documented shape is not an empty sort',
      () async {
        // Zero films back and "I could not read that" are different things:
        // one is scored, the other is a model that cannot be measured.
        answer(HttpStatus.ok, {'candidates': []});

        await expectLater(
          provider().order('Glass (2019)', ['Bug (2006)']),
          throwsA(
            isA<SimilarTitlesFailure>().having(
              (failure) => failure.trouble,
              'trouble',
              SimilarTrouble.malformed,
            ),
          ),
        );
      },
    );

    test('a model that does not answer in time is abandoned', () async {
      answer(
        HttpStatus.ok,
        ordered(['Bug (2006)']),
        delay: const Duration(milliseconds: 400),
      );

      await expectLater(
        provider(budget: const Duration(milliseconds: 50))
            .order('Glass (2019)', ['Bug (2006)']),
        throwsA(
          isA<SimilarTitlesFailure>().having(
            (failure) => failure.trouble,
            'trouble',
            SimilarTrouble.tooSlow,
          ),
        ),
      );
    });
  });
}
