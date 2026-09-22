/// What the chooser is filled from: which of an account's models could
/// answer a question about films at all, and in what order they are put.
///
/// Over the decoded `models[]` rather than over a socket, because these
/// are the two halves anybody would want to argue with and neither of them
/// is about HTTP.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/similar/model_catalogue.dart';
import 'package:xtremio/features/similar/similar_titles.dart';

/// A key of the shape a viewer would paste, and of no use to anybody.
const String pastedKey = 'AIza-not-a-real-key';

/// One entry as the catalogue returns it: the name under `models/`, and
/// the methods it answers on.
Map<String, dynamic> listed(
  String name, {
  List<String> methods = const ['generateContent', 'countTokens'],
}) => {
  'name': 'models/$name',
  'displayName': name,
  'description': 'A model.',
  'supportedGenerationMethods': methods,
};

void main() {
  test('what does not answer in words is not offered', () {
    final names = usableModelNames([
      listed('gemini-3.1-flash-lite'),
      listed('gemini-2.5-flash-image-preview'),
      listed('imagen-4.0-generate-001'),
      listed('veo-3.1-generate-preview'),
      listed('lyria-realtime-exp'),
      listed('gemini-2.5-flash-preview-tts'),
      listed('gemini-embedding-001'),
      listed('gemini-2.5-flash-transcribe'),
      listed('gemini-robotics-er-1.5-preview'),
      listed('gemini-2.5-computer-use-preview'),
      listed('antigravity-1.0'),
      listed('gemini-3.0-deep-research'),
    ]);

    // A picture is not a wrong answer to a film question, it is not an
    // answer; and a chooser full of them is one nobody can read.
    expect(names, [defaultSimilarModel]);
  });

  test('a model that answers on another API is not offered', () {
    // Six of the 33 measured were listed and answered only elsewhere.
    final names = usableModelNames([
      listed('gemini-3.6-flash'),
      listed('gemini-live-2.5-flash', methods: const ['bidiGenerateContent']),
      listed('gemini-2.5-flash-native-audio', methods: const []),
      {'name': 'models/gemini-3.0-pro'},
    ]);

    expect(names, ['gemini-3.6-flash']);
  });

  test('the measured default first, then the lites, then the flashes', () {
    final names = usableModelNames([
      listed('gemini-3.0-pro'),
      listed('gemini-3.6-flash'),
      listed('gemini-3.1-flash'),
      listed('gemini-3.6-flash-lite'),
      listed(defaultSimilarModel),
      listed('gemini-4.0-pro'),
    ]);

    // Speed is what the order is about: the row gives up at five seconds,
    // and the flash-lites are the shape that answered in two and a half.
    // Newest first inside each of those.
    expect(names, [
      defaultSimilarModel,
      'gemini-3.6-flash-lite',
      'gemini-3.6-flash',
      'gemini-3.1-flash',
      'gemini-4.0-pro',
      'gemini-3.0-pro',
    ]);
  });

  test('a date in a name is not read as a generation', () {
    final names = usableModelNames([
      listed('gemini-exp-1206-preview'),
      listed('gemini-exp-1206'),
      listed('gemini-3.1-pro'),
      listed('gemini-flash-latest'),
      listed('gemini-3.6-flash'),
    ]);

    // `gemini-exp-1206-preview` carries a date where a version goes; read
    // as one it would sort an experiment above everything that ever
    // shipped. An alias has no generation at all and goes last among its
    // own kind, which is where a name with nothing to read goes too.
    expect(names, [
      'gemini-3.6-flash',
      'gemini-flash-latest',
      'gemini-3.1-pro',
      'gemini-exp-1206',
      'gemini-exp-1206-preview',
    ]);
  });

  test('a name listed twice is offered once', () {
    final names = usableModelNames([
      listed(defaultSimilarModel),
      listed(defaultSimilarModel),
    ]);

    expect(names, [defaultSimilarModel]);
  });

  test('an answer that is not the documented shape is no models', () {
    // Empty and unreadable are the same answer *here* -- the caller tells
    // "the key can see nothing" from "the list never arrived" by whether
    // this threw, which is `listGeminiModels`'s business, not this one's.
    expect(usableModelNames(null), isEmpty);
    expect(usableModelNames('models'), isEmpty);
    expect(usableModelNames([1, 'gemini', null, <String, Object>{}]), isEmpty);
  });

  group('listGeminiModels, against a server on the loopback', () {
    late HttpServer server;
    HttpOverrides? overrides;

    late List<Uri> urls;
    late List<({int status, String body})> answers;

    void answer(int status, Object? body) =>
        answers.add((status: status, body: jsonEncode(body)));

    setUp(() async {
      // The test binding answers every request with a 400 of its own;
      // this one talks to a real server on the loopback.
      overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      urls = [];
      answers = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        urls.add(request.uri);
        final reply = answers.length > 1 ? answers.removeAt(0) : answers.first;
        request.response.statusCode = reply.status;
        request.response.write(reply.body);
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      HttpOverrides.global = overrides;
    });

    Future<List<String>> ask() => listGeminiModels(
      pastedKey,
      endpoint: Uri.parse(
        'http://${server.address.address}:${server.port}/v1beta',
      ),
      budget: const Duration(seconds: 5),
    );

    test('the key rides in the query and nowhere else', () async {
      answer(HttpStatus.ok, {
        'models': [listed(defaultSimilarModel)],
      });

      expect(await ask(), [defaultSimilarModel]);
      expect(urls.single.path, '/v1beta/models');
      expect(urls.single.queryParameters['key'], pastedKey);
    });

    test('a catalogue that arrives in pages arrives whole', () async {
      answer(HttpStatus.ok, {
        'models': [listed('gemini-3.6-flash')],
        'nextPageToken': 'second',
      });
      answer(HttpStatus.ok, {
        'models': [listed(defaultSimilarModel)],
      });

      // A page that was never asked for is a model the chooser does not
      // have and the viewer cannot pick.
      expect(await ask(), [defaultSimilarModel, 'gemini-3.6-flash']);
      expect(urls.last.queryParameters['pageToken'], 'second');
    });

    test('a refusal is a failure and not an empty list', () async {
      answer(HttpStatus.forbidden, {
        'error': {'message': 'API key not valid'},
      });

      // Empty would put an empty menu on the screen and say the key can
      // see nothing. This is a list that never arrived, which is the case
      // the by-hand box exists for.
      await expectLater(
        ask(),
        throwsA(
          isA<SimilarTitlesFailure>().having(
            (failure) => failure.trouble,
            'trouble',
            SimilarTrouble.refused,
          ),
        ),
      );
    });

    test('nothing a failure carries is the key', () async {
      answer(HttpStatus.tooManyRequests, {
        'error': {'message': 'quota exceeded for key $pastedKey'},
      });

      // The provider quotes the request back in its own message. This
      // repository is public and its APKs are handed around.
      try {
        await ask();
        fail('a 429 is not an answer');
      } on SimilarTitlesFailure catch (failure) {
        expect(failure.trouble, SimilarTrouble.quota);
        expect(failure.toString(), isNot(contains(pastedKey)));
        expect(failure.detail, '429');
      }
    });
  });
}
