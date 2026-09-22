import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/similar/gemini_similar_titles.dart';
import 'package:xtremio/features/similar/similar_titles.dart';

/// Asking a model what a title is like, over a server on the loopback that
/// answers what Google's does.
///
/// Everything measured about the real one is in `tool/recommendations`;
/// what is checked here is the half that is not about taste. The request
/// is the shape that was verified working -- a system instruction, the
/// question, and a `generationConfig` pinning the answer's JSON -- and the
/// failures are the four that happened in one afternoon of measuring: a
/// model that went away, one that was busy, one not in the tier, and one
/// that began refusing a parameter it had taken an hour earlier.
void main() {
  group('GeminiSimilarTitles', () {
    late HttpServer server;
    HttpOverrides? overrides;

    /// Every request body the server was sent, decoded, and the query of
    /// each -- the key rides in the query, so a test can see it went where
    /// it was meant to and nowhere else.
    late List<Map<String, dynamic>> sent;
    late List<Uri> urls;

    /// What the server answers, in order; the last one is repeated once
    /// the list runs out, so a test that expects one request states one
    /// answer.
    late List<({int status, String body, Duration delay})> answers;

    void answer(int status, Object? body, {Duration delay = Duration.zero}) =>
        answers.add((
          status: status,
          body: body is String ? body : jsonEncode(body),
          delay: delay,
        ));

    /// A documented answer: the films, inside the JSON text of the first
    /// candidate's parts.
    Object films(List<Map<String, Object>> rows) => {
      'candidates': [
        {
          'content': {
            'parts': [
              {
                'text': jsonEncode({'films': rows}),
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

    GeminiSimilarTitles provider({
      String model = defaultSimilarModel,
      Duration budget = const Duration(seconds: 5),
    }) => GeminiSimilarTitles(
      apiKey: 'not-a-real-key',
      model: model,
      endpoint: Uri.parse(
        'http://${server.address.address}:${server.port}/v1beta',
      ),
      budget: budget,
    );

    test('parses the documented answer shape', () async {
      answer(
        HttpStatus.ok,
        films([
          {'title': 'Avalon', 'year': 2001, 'why': 'same grey war dream'},
          {'title': 'Æon Flux', 'year': 1991, 'why': 'same airless future'},
        ]),
      );

      final suggestions = await provider().suggest('Wave Twisters (2001)');

      expect(suggestions, hasLength(2));
      expect(suggestions.first.title, 'Avalon');
      expect(suggestions.first.year, 2001);
      expect(suggestions.first.why, 'same grey war dream');
      // Nothing in the documented shape says which catalogue to look in.
      expect(suggestions.first.kind, isNull);
    });

    test('asks for feel, in JSON, of the model it was given', () async {
      answer(HttpStatus.ok, films(const []));

      await provider(model: 'gemini-4.0-flash-latest').suggest('Avalon (2001)');

      expect(
        urls.single.path,
        '/v1beta/models/gemini-4.0-flash-latest:generateContent',
      );
      expect(urls.single.queryParameters['key'], 'not-a-real-key');
      final body = sent.single;
      final prompt =
          ((body['contents'] as List).first as Map)['parts'][0]['text']
              as String;
      // The sentence is worth +0.12 on the benchmark's tone score. It is
      // not decoration, so it is asserted.
      expect(prompt, contains('feel'));
      expect(prompt, contains('Avalon (2001)'));
      expect(body['system_instruction'], isNotNull);
      final config = body['generationConfig'] as Map<String, dynamic>;
      expect(config['responseMimeType'], 'application/json');
      final schema = config['responseSchema'] as Map<String, dynamic>;
      final film =
          ((schema['properties'] as Map)['films'] as Map)['items'] as Map;
      expect(film['required'], ['title', 'year', 'why']);
    });

    test('drops a row it cannot read and keeps the rest', () async {
      answer(
        HttpStatus.ok,
        films([
          {'title': 'Avalon', 'year': 2001, 'why': 'grey'},
          {'title': 'Nothing', 'why': 'no year, so nothing to check it by'},
        ]),
      );

      final suggestions = await provider().suggest('Wave Twisters (2001)');

      expect(suggestions.map((s) => s.title), ['Avalon']);
    });

    test('a model that is gone is classified, not thrown', () async {
      answer(HttpStatus.notFound, {
        'error': {'message': 'model no longer available to new users'},
      });

      await expectLater(
        provider().suggest('Avalon (2001)'),
        throwsA(
          isA<SimilarTitlesFailure>().having(
            (f) => f.trouble,
            'trouble',
            SimilarTrouble.gone,
          ),
        ),
      );
    });

    test('a busy model is classified, not thrown', () async {
      answer(HttpStatus.serviceUnavailable, {
        'error': {'message': 'The model is overloaded. Please try again.'},
      });

      await expectLater(
        provider().suggest('Avalon (2001)'),
        throwsA(
          isA<SimilarTitlesFailure>().having(
            (f) => f.trouble,
            'trouble',
            SimilarTrouble.busy,
          ),
        ),
      );
    });

    test('a tier and a quota are told apart', () async {
      Future<SimilarTrouble?> troubleOf(GeminiSimilarTitles asked) async {
        try {
          await asked.suggest('Avalon (2001)');
          return null;
        } on SimilarTitlesFailure catch (failure) {
          return failure.trouble;
        }
      }

      answer(HttpStatus.forbidden, {
        'error': {'message': 'not available on the free tier'},
      });
      expect(await troubleOf(provider()), SimilarTrouble.notInTier);

      answers.clear();
      answer(HttpStatus.tooManyRequests, {
        'error': {'message': 'quota exceeded'},
      });
      expect(await troubleOf(provider()), SimilarTrouble.quota);
    });

    test('a 400 naming a parameter is retried once without it', () async {
      // What one provider's model began answering mid-afternoon, about a
      // parameter it had taken an hour earlier.
      answer(HttpStatus.badRequest, {
        'error': {
          'message': 'temperature is deprecated for this model',
          'code': 400,
        },
      });
      answer(
        HttpStatus.ok,
        films([
          {'title': 'Avalon', 'year': 2001, 'why': 'grey'},
        ]),
      );

      final suggestions = await provider().suggest('Wave Twisters (2001)');

      expect(suggestions.map((s) => s.title), ['Avalon']);
      expect(sent, hasLength(2));
      expect(
        (sent.first['generationConfig'] as Map).containsKey('temperature'),
        isTrue,
      );
      expect(
        (sent.last['generationConfig'] as Map).containsKey('temperature'),
        isFalse,
        reason: 'the named parameter is what the retry drops',
      );
      // Everything else the request needs survives the repair.
      expect(
        (sent.last['generationConfig'] as Map)['responseSchema'],
        isNotNull,
      );
    });

    test('a parameter named the API\'s own way is still found', () async {
      // The body takes the camel-cased names and the error messages use
      // the snake-cased proto fields, so both spellings have to match.
      answer(HttpStatus.badRequest, {
        'error': {'message': 'response_schema is not supported', 'code': 400},
      });
      answer(
        HttpStatus.ok,
        films([
          {'title': 'Avalon', 'year': 2001, 'why': 'grey'},
        ]),
      );

      final suggestions = await provider().suggest('Wave Twisters (2001)');

      expect(suggestions.map((s) => s.title), ['Avalon']);
      expect(
        (sent.last['generationConfig'] as Map).containsKey('responseSchema'),
        isFalse,
      );
    });

    test('no network at all is a failure like any other', () async {
      // Nothing is listening here: what an aeroplane, a captive portal or
      // a dead DNS looks like from inside the five seconds.
      final nowhere = GeminiSimilarTitles(
        apiKey: 'not-a-real-key',
        endpoint: Uri.parse('http://127.0.0.1:1/v1beta'),
        budget: const Duration(seconds: 2),
      );

      await expectLater(
        nowhere.suggest('Avalon (2001)'),
        throwsA(
          isA<SimilarTitlesFailure>()
              .having((f) => f.trouble, 'trouble', SimilarTrouble.unreachable)
              // What went wrong, never what was sent: an exception's own
              // message quotes the address it was talking to, and the URL
              // it was talking to carries the key. The detail is written
              // to the log, so it is the failure's *type* and nothing
              // else.
              .having(
                (f) => f.detail,
                'detail',
                allOf(
                  isNot(contains('127.0.0.1')),
                  isNot(contains('not-a-real-key')),
                ),
              ),
        ),
      );
    });

    test('a 400 naming nothing is refused once and not retried', () async {
      answer(HttpStatus.badRequest, {
        'error': {'message': 'API key not valid'},
      });

      await expectLater(
        provider().suggest('Avalon (2001)'),
        throwsA(
          isA<SimilarTitlesFailure>().having(
            (f) => f.trouble,
            'trouble',
            SimilarTrouble.refused,
          ),
        ),
      );
      expect(sent, hasLength(1));
    });

    test('an answer that is not the documented shape is malformed', () async {
      answer(HttpStatus.ok, {'candidates': []});

      await expectLater(
        provider().suggest('Avalon (2001)'),
        throwsA(
          isA<SimilarTitlesFailure>().having(
            (f) => f.trouble,
            'trouble',
            SimilarTrouble.malformed,
          ),
        ),
      );
    });

    test('prose around the JSON is still read', () async {
      // What a model does once the schema has been stripped by the retry.
      answer(HttpStatus.ok, {
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': 'Sure! Here you go:\n'},
                {
                  'text':
                      '{"films":[{"title":"Avalon","year":2001,"why":"grey"}]}'
                      '\nHope that helps.',
                },
              ],
            },
          },
        ],
      });

      final suggestions = await provider().suggest('Wave Twisters (2001)');

      expect(suggestions.map((s) => s.title), ['Avalon']);
    });

    test('a request past the budget is abandoned', () async {
      answer(
        HttpStatus.ok,
        films(const []),
        delay: const Duration(seconds: 30),
      );

      final started = DateTime.now();
      await expectLater(
        provider(budget: const Duration(milliseconds: 150)).suggest('Avalon'),
        throwsA(
          isA<SimilarTitlesFailure>().having(
            (f) => f.trouble,
            'trouble',
            SimilarTrouble.tooSlow,
          ),
        ),
      );
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 5)),
        reason: 'abandoning means not waiting for the answer',
      );
    });

    test('five seconds is the budget nothing has to be told', () {
      // A row nobody waits for is not a row: the models worth using answer
      // in about two and a half seconds, and the ones that do not answer
      // in five do not answer in thirty either.
      expect(similarBudget, const Duration(seconds: 5));
      expect(
        GeminiSimilarTitles(apiKey: 'not-a-real-key').budget,
        similarBudget,
      );
      // Measured, not chosen -- see `tool/recommendations/README.md`.
      expect(defaultSimilarModel, 'gemini-3.1-flash-lite');
    });
  });
}
