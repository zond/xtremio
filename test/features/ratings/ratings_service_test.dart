import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/ratings/xtremio_ratings.dart';

import '../../support/fake_prefs_client.dart';
import '../../support/fake_ratings_provider.dart';
import '../../support/real_http.dart';

void main() {
  const jaws = TitleRatings(
    imdb: TitleScore(8.1, votes: 673852),
    tmdb: TitleScore(7.6, votes: 10114),
    tomatoes: TitleScore(97, votes: 102),
    popcorn: TitleScore(90),
  );

  group('XtremioRatings', () {
    late HttpServer server;
    late List<String> requests;
    late ({int status, String body}) reply;

    setUp(() async {
      useRealHttp();
      requests = [];
      reply = (status: 200, body: '{}');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests.add('${request.method} ${request.uri}');
        request.response.statusCode = reply.status;
        request.response.write(reply.body);
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    XtremioRatings provider() => XtremioRatings(
      base: Uri.parse('http://${server.address.address}:${server.port}'),
    );

    test('asks GET /ratings/{type}/{id}, nothing else, and reads the '
        'answer', () async {
      reply = (
        status: 200,
        body: jsonEncode({
          'imdb': {'score': 8.1, 'votes': 673852},
          'tmdb': {'score': 7.6, 'votes': 10114},
          'tomatoes': {'score': 97, 'votes': 102},
          'popcorn': {'score': 90},
          'fetchedAt': '2026-10-03T12:00:00.000Z',
        }),
      );
      expect(await provider().ratings(type: 'movie', id: 'tt0073195'), jaws);
      await provider().ratings(type: 'series', id: 'tt0903747');
      expect(requests, [
        'GET /ratings/movie/tt0073195',
        'GET /ratings/series/tt0903747',
      ]);
    });

    test('a status that is not 200, or a body that is not an answer, is a '
        'failure rather than no scores', () async {
      final failsWith = throwsA(isA<RatingsFailure>());
      reply = (status: 400, body: '{"error":"a Cinemeta movie or series id"}');
      await expectLater(
        provider().ratings(type: 'movie', id: 'tt1'),
        failsWith,
      );
      reply = (status: 200, body: '<html>');
      await expectLater(
        provider().ratings(type: 'movie', id: 'tt1'),
        failsWith,
      );
      reply = (status: 200, body: '[]');
      await expectLater(
        provider().ratings(type: 'movie', id: 'tt1'),
        failsWith,
      );
    });

    test('no server at all is a failure', () async {
      final gone = provider();
      await server.close(force: true);
      await expectLater(
        gone.ratings(type: 'movie', id: 'tt1'),
        throwsA(isA<RatingsFailure>()),
      );
    });
  });

  group('RatingsService', () {
    late AppPrefs prefs;
    late FakePrefsClient storage;
    late DateTime now;

    setUp(() async {
      storage = FakePrefsClient();
      prefs = AppPrefs(client: storage);
      await prefs.load();
      now = DateTime.utc(2026, 10, 3, 12);
    });

    tearDown(() => prefs.dispose());

    RatingsService service(FakeRatingsProvider provider) =>
        RatingsService(prefs: prefs, provider: provider, now: () => now);

    test('asks once, remembers it on disk, and does not ask again for a '
        'day', () async {
      final provider = FakeRatingsProvider(jaws);
      final ratings = service(provider);
      expect(ratings.remembered(type: 'movie', id: 'tt0073195'), isNull);

      expect(await ratings.refreshed(type: 'movie', id: 'tt0073195'), jaws);
      expect(ratings.remembered(type: 'movie', id: 'tt0073195'), jaws);
      expect(storage.stored, contains(AppPrefs.titleRatingsKey));

      now = now.add(const Duration(hours: 23));
      expect(await ratings.refreshed(type: 'movie', id: 'tt0073195'), isNull);
      expect(provider.asked, ['movie/tt0073195']);

      // A day on, asked again; the remembered scores stay on screen until
      // the answer is in.
      now = now.add(const Duration(hours: 2));
      provider.answer = const TitleRatings(imdb: TitleScore(8.2));
      expect(
        await ratings.refreshed(type: 'movie', id: 'tt0073195'),
        provider.answer,
      );
      expect(provider.asked, hasLength(2));
    });

    test('a failure or an empty answer is nothing new, and is not '
        'remembered', () async {
      final provider = FakeRatingsProvider(const RatingsFailure('503'));
      final ratings = service(provider);
      expect(await ratings.refreshed(type: 'movie', id: 'tt1'), isNull);
      provider.answer = StateError('anything else');
      expect(await ratings.refreshed(type: 'movie', id: 'tt1'), isNull);
      provider.answer = TitleRatings.none;
      expect(await ratings.refreshed(type: 'movie', id: 'tt1'), isNull);
      expect(prefs.titleRatings, TitleRatingsMemory.empty);
      expect(provider.asked, hasLength(3), reason: 'so the next open asks');

      // And a failure after a day keeps what was known.
      provider.answer = jaws;
      await ratings.refreshed(type: 'movie', id: 'tt1');
      now = now.add(const Duration(days: 2));
      provider.answer = const RatingsFailure('502');
      expect(await ratings.refreshed(type: 'movie', id: 'tt1'), isNull);
      expect(ratings.remembered(type: 'movie', id: 'tt1'), jaws);
    });

    test('asks only about a movie or a series by its IMDb id', () async {
      final provider = FakeRatingsProvider(jaws);
      final ratings = service(provider);
      for (final (type, id) in [
        ('channel', 'tt1'),
        ('tv', 'tt1'),
        ('movie', 'kitsu:1'),
        ('series', 'tt0903747:1:1'),
        ('movie', 'yt_id:UC1'),
      ]) {
        expect(await ratings.refreshed(type: type, id: id), isNull);
      }
      expect(provider.asked, isEmpty);
    });
  });
}
