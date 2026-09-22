import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/fake_prefs_client.dart';

/// Where "More like this" keeps its three preferences: the viewer's API
/// key, which model is asked, and what has already been answered.
///
/// The key is the one preference in this file that is auth material. It is
/// never defaulted and never invented -- a fresh install has none, and a
/// box cleared back to empty has none again, because a stored `""` is the
/// same decision spelled in a way every reader of the file has to think
/// about.
void main() {
  group('the preferences', () {
    test('a fresh install has no key and the measured default model', () async {
      final prefs = AppPrefs(client: FakePrefsClient());
      await prefs.load();

      expect(prefs.similarApiKey, isNull);
      expect(prefs.similarModel, defaultSimilarModel);
      expect(prefs.similarSuggestions, SimilarMemory.empty);
    });

    test('a key is read back, and cleared by emptying the box', () async {
      final storage = FakePrefsClient();
      final prefs = AppPrefs(client: storage);
      await prefs.load();

      await prefs.setSimilarApiKey('  not-a-real-key  ');
      expect(prefs.similarApiKey, 'not-a-real-key');
      expect(storage.stored[AppPrefs.similarApiKeyKey], 'not-a-real-key');

      await prefs.setSimilarApiKey('');
      expect(prefs.similarApiKey, isNull);
      expect(
        storage.stored.containsKey(AppPrefs.similarApiKeyKey),
        isFalse,
        reason: 'no key is a missing key, not an empty one',
      );
    });

    test('a stored blank is not a key', () async {
      final prefs = AppPrefs(
        client: FakePrefsClient({AppPrefs.similarApiKeyKey: '   '}),
      );
      await prefs.load();

      expect(prefs.similarApiKey, isNull);
    });

    test('a model can be named, and emptied back to the default', () async {
      final storage = FakePrefsClient();
      final prefs = AppPrefs(client: storage);
      await prefs.load();

      // What a viewer does when their model answers "no longer available
      // to new users", which two of them began doing in one afternoon.
      await prefs.setSimilarModel('gemini-9.9-flash-latest');
      expect(prefs.similarModel, 'gemini-9.9-flash-latest');
      expect(
        storage.stored[AppPrefs.similarModelKey],
        'gemini-9.9-flash-latest',
      );

      await prefs.setSimilarModel(null);
      expect(prefs.similarModel, defaultSimilarModel);
      expect(storage.stored.containsKey(AppPrefs.similarModelKey), isFalse);
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
