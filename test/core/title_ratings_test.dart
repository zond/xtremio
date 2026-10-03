import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/fake_prefs_client.dart';

/// A title's scores as the server sends them and as this device keeps them.
void main() {
  const jaws = TitleRatings(
    imdb: TitleScore(8.1, votes: 673852),
    tmdb: TitleScore(7.6, votes: 10114),
    tomatoes: TitleScore(97, votes: 102),
    popcorn: TitleScore(90),
  );

  group('TitleRatings', () {
    test('reads the server\'s answer, null sources and all', () {
      expect(
        TitleRatings.fromJson({
          'imdb': {'score': 8.1, 'votes': 673852},
          'tmdb': {'score': 7.6, 'votes': 10114},
          'tomatoes': {'score': 97, 'votes': 102},
          'popcorn': {'score': 90},
          'fetchedAt': '2026-10-03T12:00:00.000Z',
        }),
        jaws,
      );
      expect(
        TitleRatings.fromJson({
          'imdb': null,
          'tmdb': {'score': 'high'},
          'tomatoes': {'score': 0},
          'popcorn': {'votes': 3},
          'fetchedAt': null,
        }),
        TitleRatings.none,
      );
      expect(TitleRatings.fromJson('nonsense').isEmpty, isTrue);
    });

    test('round-trips through its stored form', () {
      expect(TitleRatings.fromJson(jaws.toJson()), jaws);
    });
  });

  group('TitleRatingsMemory', () {
    final at = DateTime.utc(2026, 10, 3, 12);

    test('remembers per title, newest first, and forgets past the limit', () {
      var memory = TitleRatingsMemory.empty;
      for (var i = 0; i < TitleRatingsMemory.limit + 1; i++) {
        memory = memory.remembering(
          type: 'movie',
          id: 'tt$i',
          ratings: jaws,
          at: at,
        );
      }
      expect(memory.entries, hasLength(TitleRatingsMemory.limit));
      expect(memory.forItem(type: 'movie', id: 'tt0'), isNull);
      expect(memory.entries.first.id, 'tt${TitleRatingsMemory.limit}');

      // Asked again: replaced in place of a duplicate, and moved up.
      memory = memory.remembering(
        type: 'movie',
        id: 'tt5',
        ratings: TitleRatings.none,
        at: at,
      );
      expect(memory.entries, hasLength(TitleRatingsMemory.limit));
      expect(memory.entries.first.id, 'tt5');
      expect(
        memory.forItem(type: 'movie', id: 'tt5')!.ratings,
        TitleRatings.none,
      );
      expect(memory.forItem(type: 'series', id: 'tt6'), isNull);
    });

    test('is fresh for a day, and not before it was written', () {
      final entry = TitleRatingsEntry(
        type: 'movie',
        id: 'tt1',
        ratings: jaws,
        savedAt: at,
      );
      expect(entry.isFreshAt(at), isTrue);
      expect(
        entry.isFreshAt(
          at.add(TitleRatingsMemory.freshFor - const Duration(seconds: 1)),
        ),
        isTrue,
      );
      expect(entry.isFreshAt(at.add(TitleRatingsMemory.freshFor)), isFalse);
      expect(
        entry.isFreshAt(at.subtract(const Duration(minutes: 1))),
        isFalse,
        reason: 'a clock set back is not a week of fresh scores',
      );
    });

    test('survives a restart through the preferences file', () async {
      final storage = FakePrefsClient();
      final prefs = AppPrefs(client: storage);
      addTearDown(prefs.dispose);
      await prefs.load();
      expect(prefs.titleRatings, TitleRatingsMemory.empty);
      await prefs.setTitleRatings(
        prefs.titleRatings.remembering(
          type: 'movie',
          id: 'tt0073195',
          ratings: jaws,
          at: at,
        ),
      );

      final restarted = AppPrefs(client: storage);
      addTearDown(restarted.dispose);
      await restarted.load();
      final entry = restarted.titleRatings.forItem(
        type: 'movie',
        id: 'tt0073195',
      );
      expect(entry?.ratings, jaws);
      expect(entry?.savedAt, at);
    });

    test('drops a row it cannot read, never the whole memory', () {
      final memory = TitleRatingsMemory.fromJson([
        {'type': 'movie', 'id': 'tt1'},
        'junk',
        {
          'type': 'movie',
          'id': 'tt2',
          'at': at.millisecondsSinceEpoch,
          'ratings': jaws.toJson(),
        },
      ]);
      expect(memory.entries, hasLength(1));
      expect(memory.forItem(type: 'movie', id: 'tt2')?.ratings, jaws);
      expect(TitleRatingsMemory.fromJson({'no': 'list'}), isEmptyMemory);
    });
  });
}

final Matcher isEmptyMemory = equals(TitleRatingsMemory.empty);
