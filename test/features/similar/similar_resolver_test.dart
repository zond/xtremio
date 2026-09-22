import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/similar/similar_resolver.dart';

/// The guard: what a model said, checked against a catalogue before any of
/// it reaches a poster.
///
/// The failure this exists for is not a model that comes up short. It is
/// that **searching an invented title succeeds** -- `The Otherside (2022)`
/// does not exist and the catalogue answers that query with a 2008 film
/// and a 2013 one, either of which would appear on screen as a real
/// recommendation. So the year has to agree as well as the title, and the
/// tests below are mostly about the ways it can fail to.
void main() {
  SuggestedTitle said(String title, int year, {SuggestedKind? kind}) =>
      SuggestedTitle(title: title, year: year, why: 'because', kind: kind);

  Map<String, dynamic> meta(
    String id,
    String name,
    String releaseInfo, {
    String type = 'movie',
  }) => {
    'id': id,
    'imdb_id': id,
    'type': type,
    'name': name,
    'releaseInfo': releaseInfo,
    'poster': 'https://example.invalid/$id.jpg',
  };

  /// A catalogue that answers from a table, keyed `type/query`, and
  /// records what it was asked.
  ({CatalogueSearch search, List<String> asked}) catalogue(
    Map<String, List<Map<String, dynamic>>> table, {
    Set<String> failing = const {},
  }) {
    final asked = <String>[];
    Future<List<Map<String, dynamic>>> search(String type, String query) async {
      asked.add('$type/$query');
      if (failing.contains('$type/$query')) {
        throw const SocketException('nothing answered');
      }
      return table['$type/$query'] ?? const [];
    }

    return (search: search, asked: asked);
  }

  group('resolveSuggestions', () {
    test(
      'an invented title that searches to another year is dropped',
      () async {
        // The measured case, exactly: a model invented `The Otherside
        // (2022)` and the search answered with real films of 2008 and 2013.
        final table = catalogue({
          'movie/The Otherside': [
            meta('tt1', 'The Otherside', '2008'),
            meta('tt2', 'The Otherside', '2013'),
          ],
          'series/The Otherside': const [],
        });

        final resolved = await resolveSuggestions(
          [said('The Otherside', 2022)],
          subjectId: 'tt0000',
          search: table.search,
        );

        expect(resolved, isEmpty);
        // And it did look -- this is a title that was checked and dropped,
        // not one that was never searched for.
        expect(table.asked, ['movie/The Otherside', 'series/The Otherside']);
      },
    );

    test('a year out by one is a hit, by two is not', () async {
      final table = catalogue({
        'movie/Avalon': [meta('tt1', 'Avalon', '2001')],
        'movie/Stalker': [meta('tt2', 'Stalker', '1979')],
      });

      final resolved = await resolveSuggestions(
        [said('Avalon', 2000), said('Stalker', 1981)],
        subjectId: 'tt0000',
        search: table.search,
      );

      expect(resolved.map((r) => r.item.id), ['tt1']);
    });

    test('a series suggestion resolves against the series catalogue', () async {
      // Asked what is like *Wave Twisters*, a model answered *Æon Flux*,
      // which is television and a good answer -- the app plays series.
      final table = catalogue({
        'movie/Æon Flux': [meta('tt3', 'Æon Flux', '2005')],
        'series/Æon Flux': [
          meta('tt4', 'Æon Flux', '1991-1995', type: 'series'),
        ],
      });

      final resolved = await resolveSuggestions(
        [said('Æon Flux', 1991)],
        subjectId: 'tt0000',
        search: table.search,
      );

      expect(resolved.single.item.id, 'tt4');
      expect(resolved.single.item.type, 'series');
      // The year is what told the series from the film made of it: the
      // film catalogue was asked first and had an answer of the same name.
      expect(table.asked, ['movie/Æon Flux', 'series/Æon Flux']);
    });

    test('a stated kind is the only catalogue asked', () async {
      final table = catalogue({
        'series/Æon Flux': [
          meta('tt4', 'Æon Flux', '1991-1995', type: 'series'),
        ],
      });

      final resolved = await resolveSuggestions(
        [said('Æon Flux', 1991, kind: SuggestedKind.series)],
        subjectId: 'tt0000',
        search: table.search,
      );

      expect(resolved.single.item.id, 'tt4');
      expect(table.asked, ['series/Æon Flux']);
    });

    test('the subject suggested back is dropped', () async {
      final table = catalogue({
        'movie/Heat': [meta('tt0113277', 'Heat', '1995')],
        'movie/Thief': [meta('tt0084787', 'Thief', '1981')],
      });

      final resolved = await resolveSuggestions(
        [said('Heat', 1995), said('Thief', 1981)],
        subjectId: 'tt0113277',
        search: table.search,
      );

      expect(resolved.map((r) => r.item.id), ['tt0084787']);
    });

    test('two suggestions of one film collapse, first reason kept', () async {
      final table = catalogue({
        'movie/Avalon': [meta('tt1', 'Avalon', '2001')],
        'movie/avalon.': [meta('tt1', 'Avalon', '2001')],
      });

      final resolved = await resolveSuggestions(
        [
          const SuggestedTitle(
            title: 'Avalon',
            year: 2001,
            why: 'the first reason',
          ),
          const SuggestedTitle(title: 'avalon.', year: 2002, why: 'the second'),
        ],
        subjectId: 'tt0000',
        search: table.search,
      );

      expect(resolved, hasLength(1));
      expect(resolved.single.why, 'the first reason');
    });

    test(
      'a search that fails drops one suggestion and keeps the rest',
      () async {
        final table = catalogue(
          {
            'movie/Avalon': [meta('tt1', 'Avalon', '2001')],
            'movie/Stalker': [meta('tt2', 'Stalker', '1979')],
          },
          failing: {'movie/Stalker', 'series/Stalker'},
        );

        final resolved = await resolveSuggestions(
          [said('Stalker', 1979), said('Avalon', 2001)],
          subjectId: 'tt0000',
          search: table.search,
        );

        expect(resolved.map((r) => r.item.id), ['tt1']);
      },
    );

    test('a search that never answers drops one suggestion', () async {
      Future<List<Map<String, dynamic>>> search(
        String type,
        String query,
      ) async {
        if (query == 'Stalker') {
          throw TimeoutException('no answer', const Duration(seconds: 5));
        }
        return [meta('tt1', 'Avalon', '2001')];
      }

      final resolved = await resolveSuggestions(
        [said('Stalker', 1979), said('Avalon', 2001)],
        subjectId: 'tt0000',
        search: search,
      );

      expect(resolved.map((r) => r.item.id), ['tt1']);
    });

    test('nothing matching is an empty answer, not a failure', () async {
      final table = catalogue(const {});

      final resolved = await resolveSuggestions(
        [said('Heat and Bone', 2019)],
        subjectId: 'tt0000',
        search: table.search,
      );

      expect(resolved, isEmpty);
    });

    test('a title spelled another way still matches', () async {
      // Case, punctuation and a leading article are not what a model gets
      // wrong; the year is. So the title is compared loosely and the year
      // strictly, which is the trade the whole guard rests on.
      final table = catalogue({
        'movie/the american astronaut!': [
          meta('tt1', 'The American Astronaut', '2001'),
        ],
        'movie/Wall-E': [meta('tt2', 'WALL\u00b7E', '2008')],
      });

      final resolved = await resolveSuggestions(
        [said('the american astronaut!', 2001), said('Wall-E', 2008)],
        subjectId: 'tt0000',
        search: table.search,
      );

      expect(resolved.map((r) => r.item.id), ['tt1', 'tt2']);
    });

    test('the same title twice is searched once', () async {
      final table = catalogue({
        'movie/Avalon': [meta('tt1', 'Avalon', '2001')],
      });

      await resolveSuggestions(
        [said('Avalon', 2001), said('Avalon', 2001)],
        subjectId: 'tt0000',
        search: table.search,
      );

      expect(table.asked, ['movie/Avalon']);
    });

    test('the imdb id is the id, and the query names the type', () async {
      // Cinemeta answers both and they agree; an addon that keys its own
      // way does not, and the imdb id is the one the rest of the app is
      // keyed on. A meta that names no type at all is of the type the
      // question was asked about.
      final table = catalogue({
        'series/Twin Peaks': [
          {
            'id': 'cinemeta:7',
            'imdb_id': 'tt0098936',
            'name': 'Twin Peaks',
            'releaseInfo': '1990-1991',
          },
        ],
      });

      final resolved = await resolveSuggestions(
        [said('Twin Peaks', 1990, kind: SuggestedKind.series)],
        subjectId: 'tt0000',
        search: table.search,
      );

      expect(resolved.single.item.id, 'tt0098936');
      expect(resolved.single.item.type, 'series');
    });

    test('a meta with no year of its own is dropped', () async {
      // Nothing to check the suggestion against is the same answer as a
      // year that disagrees: there is no evidence this is the film.
      final table = catalogue({
        'movie/Avalon': [
          {'id': 'tt1', 'type': 'movie', 'name': 'Avalon'},
        ],
      });

      final resolved = await resolveSuggestions(
        [said('Avalon', 2001)],
        subjectId: 'tt0000',
        search: table.search,
      );

      expect(resolved, isEmpty);
    });

    test('case, punctuation and a leading article are not a mismatch', () {
      expect(similarTitleKey('The American Astronaut'), 'americanastronaut');
      expect(similarTitleKey('american astronaut!'), 'americanastronaut');
      expect(similarTitleKey('WALL·E'), 'walle');
      expect(yearIn('2008-2013'), 2008);
      expect(yearIn('2008-'), 2008);
      expect(yearIn('not a year'), isNull);
    });
  });

  group('cinemetaSearch', () {
    late HttpServer server;
    HttpOverrides? overrides;
    late List<String> seen;
    late int status;
    late String body;

    setUp(() async {
      overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      seen = [];
      status = HttpStatus.ok;
      body = jsonEncode({
        'metas': [
          {'id': 'tt1', 'imdb_id': 'tt1', 'name': 'Avalon'},
        ],
      });
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        seen.add('${request.method} ${request.uri}');
        request.response.statusCode = status;
        request.response.write(body);
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      HttpOverrides.global = overrides;
    });

    Uri base() => Uri.parse('http://${server.address.address}:${server.port}');

    test('asks the documented route, with the title as one segment', () async {
      final metas = await cinemetaSearch('series', 'Æon Flux', base: base());

      expect(
        seen.single,
        'GET /catalog/series/top/search=%C3%86on%20Flux.json',
      );
      expect(metas.single['id'], 'tt1');
    });

    test('a title with a slash in it stays one segment', () async {
      // A model naming *Face/Off* must not ask for a catalogue called
      // `Face` -- and a title with a `?` or a `#` in it must not become a
      // query or a fragment.
      await cinemetaSearch('movie', 'Face/Off?', base: base());

      expect(seen.single, 'GET /catalog/movie/top/search=Face%2FOff%3F.json');
    });

    test('a status that is not 200 throws, for the resolver to drop', () async {
      status = HttpStatus.internalServerError;

      await expectLater(
        cinemetaSearch('movie', 'Avalon', base: base()),
        throwsA(isA<HttpException>()),
      );
    });

    test('malformed JSON throws, for the resolver to drop', () async {
      body = '<html>down for maintenance</html>';

      await expectLater(
        cinemetaSearch('movie', 'Avalon', base: base()),
        throwsA(isA<FormatException>()),
      );
    });

    test('a body with no metas is an empty answer', () async {
      body = jsonEncode({'err': 'nothing'});

      expect(await cinemetaSearch('movie', 'Avalon', base: base()), isEmpty);
    });
  });
}
