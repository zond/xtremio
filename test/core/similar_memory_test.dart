import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/fake_prefs_client.dart';

/// Where "More like this" keeps what the server has already answered, and
/// wipes the leftover `similarKey`/`similarModel` prefs an older build
/// stored locally.
///
/// The key is auth material: a preferences file that still holds one is a
/// credential on the device that nothing reads.
void main() {
  test('the version stamped on a kept answer is the one the server asks '
      'by', () {
    // The two are bumped by hand, in two languages; a bump of one alone
    // keeps every device on the answers the old question gave.
    final source = File('xtremio-xervice/functions/similar.js')
        .readAsStringSync();
    final declared = RegExp(
      r'^const QUESTION_VERSION = (\d+);$',
      multiLine: true,
    ).allMatches(source).toList();
    expect(declared, hasLength(1), reason: 'one declaration to read');
    expect(int.parse(declared.single.group(1)!), similarQuestionVersion);
  });

  group('the preferences', () {
    test('a fresh install remembers nothing and writes nothing', () async {
      final storage = FakePrefsClient();
      final prefs = AppPrefs(client: storage);
      await prefs.load();

      expect(prefs.similarSuggestions, SimilarMemory.empty);
      expect(storage.writes, isEmpty);
    });

    test('a key and a model an older build stored are removed on load, and '
        'nothing else is', () async {
      final storage = FakePrefsClient({
        'similarApiKey': 'not-a-real-key',
        'similarModel': 'gemini-9.9-flash-latest',
        AppPrefs.bufferAheadKey: BufferAhead.wholeFile.stored,
      });
      final prefs = AppPrefs(client: storage);
      await prefs.load();

      expect(storage.stored.containsKey('similarApiKey'), isFalse);
      expect(storage.stored.containsKey('similarModel'), isFalse);
      expect(
        storage.stored[AppPrefs.bufferAheadKey],
        BufferAhead.wholeFile.stored,
        reason: 'the purge touches the retired keys and only them',
      );
      expect(prefs.bufferAhead, BufferAhead.wholeFile);

      // Once: the next start finds nothing to remove and writes nothing.
      final restarted = AppPrefs(client: storage);
      storage.writes.clear();
      await restarted.load();
      expect(storage.writes, isEmpty);
    });

    test('either one alone is removed too', () async {
      final storage = FakePrefsClient({'similarModel': 'gemini-x'});
      await AppPrefs(client: storage).load();
      expect(storage.stored, isEmpty);
      expect(storage.writes, ['similarModel']);
    });

    test(
      'answers survive a restart, and a cleared memory removes the key',
      () async {
        final storage = FakePrefsClient();
        final prefs = AppPrefs(client: storage);
        await prefs.load();

        await prefs.setSimilarSuggestions(
          SimilarMemory.empty.remembering(
            type: 'movie',
            id: 'tt1',
            suggestions: const [
              SuggestedTitle(title: 'Avalon', year: 2001, why: 'grey'),
            ],
          ),
        );

        final restarted = AppPrefs(client: storage);
        await restarted.load();
        expect(
          restarted.similarSuggestions.forItem(type: 'movie', id: 'tt1'),
          const [SuggestedTitle(title: 'Avalon', year: 2001, why: 'grey')],
        );

        await restarted.setSimilarSuggestions(SimilarMemory.empty);
        expect(
          storage.stored.containsKey(AppPrefs.similarSuggestionsKey),
          isFalse,
        );
      },
    );
  });

  group('SimilarMemory', () {
    test('nothing answered and nothing found are different answers', () {
      final memory = SimilarMemory.empty.remembering(
        type: 'movie',
        id: 'tt1',
        suggestions: const [],
      );

      // Null is "never asked" and an empty list is "asked, nothing came
      // back" -- asking again would cost a call to be told the same thing.
      expect(memory.forItem(type: 'movie', id: 'tt1'), isEmpty);
      expect(memory.forItem(type: 'movie', id: 'tt2'), isNull);
      // The type is half the key: ids are only unique inside one.
      expect(memory.forItem(type: 'series', id: 'tt1'), isNull);
    });

    test('a title answered again replaces its row and moves to the front', () {
      var memory = SimilarMemory.empty
          .remembering(type: 'movie', id: 'tt1', suggestions: const [])
          .remembering(type: 'movie', id: 'tt2', suggestions: const []);
      memory = memory.remembering(
        type: 'movie',
        id: 'tt1',
        suggestions: const [
          SuggestedTitle(title: 'Avalon', year: 2001, why: 'grey'),
        ],
      );

      expect(memory.entries.map((e) => e.id), ['tt1', 'tt2']);
      expect(memory.forItem(type: 'movie', id: 'tt1'), hasLength(1));
    });

    test('the oldest title falls off the end', () {
      var memory = SimilarMemory.empty;
      for (var i = 0; i <= SimilarMemory.limit; i++) {
        memory = memory.remembering(
          type: 'movie',
          id: 'tt$i',
          suggestions: const [],
        );
      }

      expect(memory.entries, hasLength(SimilarMemory.limit));
      expect(memory.forItem(type: 'movie', id: 'tt0'), isNull);
      expect(
        memory.forItem(type: 'movie', id: 'tt${SimilarMemory.limit}'),
        isEmpty,
      );
    });

    test('an answer to another question is nothing remembered', () {
      const asked = [SuggestedTitle(title: 'Avalon', year: 2001, why: 'grey')];

      // No stamp at all: what every row written by the film-only question
      // looks like. A viewer standing on a series would otherwise keep
      // its ten films for the life of the install.
      final unstamped = SimilarMemory.fromJson([
        {
          'type': 'series',
          'id': 'tt1',
          'films': [
            {'title': 'Avalon', 'year': 2001, 'why': 'grey'},
          ],
        },
      ]);
      expect(unstamped.entries.single.askedAs, 0);
      expect(unstamped.forItem(type: 'series', id: 'tt1'), isNull);

      // A stamp from some other version of the wording is the same
      // answer, and so is one from a version this build has never heard
      // of: what is reused is an answer to *this* question.
      for (final version in [
        similarQuestionVersion - 1,
        similarQuestionVersion + 1,
      ]) {
        final other = SimilarMemory([
          SimilarAnswer(
            type: 'series',
            id: 'tt1',
            suggestions: asked,
            askedAs: version,
          ),
        ]);
        expect(other.forItem(type: 'series', id: 'tt1'), isNull);
      }

      // This version's answer is read back, and survives the file.
      final mine = SimilarMemory.empty.remembering(
        type: 'series',
        id: 'tt1',
        suggestions: asked,
      );
      expect(mine.entries.single.askedAs, similarQuestionVersion);
      expect(mine.forItem(type: 'series', id: 'tt1'), asked);
      expect(SimilarMemory.fromJson(mine.toJson()), mine);
    });

    test('a re-ask replaces the stale row rather than joining it', () {
      final stale = SimilarMemory.fromJson([
        {'type': 'series', 'id': 'tt1', 'films': []},
      ]);
      expect(stale.forItem(type: 'series', id: 'tt1'), isNull);

      final fresh = stale.remembering(
        type: 'series',
        id: 'tt1',
        suggestions: const [],
      );

      // One row, this version's, so the re-ask costs one call and then
      // stops costing anything.
      expect(fresh.entries, hasLength(1));
      expect(fresh.forItem(type: 'series', id: 'tt1'), isEmpty);

      // And the two are different memories, which is what gets the new
      // stamp to disk: `setSimilarSuggestions` writes nothing when the
      // value it is handed equals the one it holds, so a re-ask that came
      // back with the same titles would otherwise never be written down
      // and the viewer would be asked again on every restart.
      expect(fresh, isNot(stale));
    });

    test('a row this build cannot read is dropped, not a failed load', () {
      final memory = SimilarMemory.fromJson([
        {'id': 'tt1', 'films': []}, // no type: nothing to look it up by
        {
          'type': 'movie',
          'id': 'tt2',
          'asked': similarQuestionVersion,
          'films': [
            {'title': 'Avalon', 'year': 2001, 'why': 'grey', 'kind': 'film'},
            {'title': 'No year', 'why': 'nothing to check it by'},
            'not even a row',
          ],
        },
      ]);

      expect(memory.entries, hasLength(1));
      final films = memory.forItem(type: 'movie', id: 'tt2')!;
      expect(films.map((f) => f.title), ['Avalon']);
      expect(films.single.kind, SuggestedKind.film);
      expect(SimilarMemory.fromJson('nonsense'), SimilarMemory.empty);
    });

    test('a kind survives the file, and a model\'s own words for it', () {
      const suggestion = SuggestedTitle(
        title: 'Æon Flux',
        year: 1991,
        why: 'same airless future',
        kind: SuggestedKind.series,
      );

      expect(SuggestedTitle.fromJson(suggestion.toJson()), suggestion);
      // What a model writes when it volunteers a kind the schema did not
      // ask for.
      expect(SuggestedKind.parse('tv'), SuggestedKind.series);
      expect(SuggestedKind.parse('movie'), SuggestedKind.film);
      expect(SuggestedKind.parse('anime'), isNull);
      // Stremio's own vocabulary, which is not this enum's.
      expect(SuggestedKind.film.catalogType, 'movie');
      // A kind nobody stated is not written down as one.
      expect(
        const SuggestedTitle(title: 'Avalon', year: 2001, why: 'grey').toJson(),
        isNot(contains('kind')),
      );
    });
  });
}
