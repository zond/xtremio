import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/similar/more_like_this.dart';
import 'package:xtremio/features/similar/similar_resolver.dart';
import 'package:xtremio/features/similar/similar_titles.dart';

import '../../support/diagnostics_capture.dart';
import '../../support/fake_prefs_client.dart';

/// Everything behind the row, with nothing on the network.
///
/// The two things this file is here to hold are the ones that cost money
/// or leak something: **with no key configured no provider is built at
/// all**, and **a title is asked about once** -- the answer is written
/// down and read back, because the same model asked twice agrees with
/// itself about half the time.
void main() {
  late FakePrefsClient storage;
  late AppPrefs prefs;
  late List<String> built;
  late List<String> asked;

  /// What a provider answers, or throws.
  late Object Function(String subject) answering;

  Future<void> start({String? apiKey, String? model}) async {
    storage = FakePrefsClient({
      AppPrefs.similarApiKeyKey: ?apiKey,
      AppPrefs.similarModelKey: ?model,
    });
    prefs = AppPrefs(client: storage);
    await prefs.load();
    built = [];
    asked = [];
  }

  MoreLikeThis feature({CatalogueSearch? search}) => MoreLikeThis(
    prefs: prefs,
    providerFor: ({required String apiKey, required String model}) {
      built.add('$model with $apiKey');
      return _FakeProvider(asked, answering);
    },
    search: search ?? _catalogue,
  );

  setUp(() async {
    answering = (_) => const [
      SuggestedTitle(title: 'Avalon', year: 2001, why: 'grey'),
    ];
    await start(apiKey: 'not-a-real-key');
  });

  test('with no key configured nothing is asked of anybody', () async {
    await start();
    var searched = 0;
    Future<List<Map<String, dynamic>>> searching(
      String type,
      String query,
    ) async {
      searched++;
      return const [];
    }

    final row = await feature(search: searching).forItem(
      type: 'movie',
      id: 'tt0293429',
      name: 'Wave Twisters',
      year: 2001,
    );

    expect(row, isEmpty);
    expect(
      built,
      isEmpty,
      reason: 'no key means no provider, not a failed call',
    );
    expect(asked, isEmpty);
    expect(searched, 0);
  });

  test('the title and its year are what the model is asked about', () async {
    await feature().forItem(
      type: 'movie',
      id: 'tt1',
      name: 'Wave Twisters',
      year: 2001,
    );

    expect(asked, ['Wave Twisters (2001) as film']);
    expect(built, ['$defaultSimilarModel with not-a-real-key']);
  });

  test('a series is asked about as a series', () async {
    // The screen's own `type` is what decides which question is asked, so
    // a show page does not get a row of ten films.
    await feature().forItem(
      type: 'series',
      id: 'tt0903747',
      name: 'Breaking Bad',
      year: 2008,
    );

    expect(asked, ['Breaking Bad (2008) as series']);
  });

  test('the model named in preferences is the one asked', () async {
    await start(apiKey: 'not-a-real-key', model: 'gemini-9.9-flash-latest');

    await feature().forItem(type: 'movie', id: 'tt1', name: 'Avalon');

    expect(built, ['gemini-9.9-flash-latest with not-a-real-key']);
    // No year known is no year claimed.
    expect(asked, ['Avalon as film']);
  });

  test('a title is asked about once, ever', () async {
    final first = await feature().forItem(
      type: 'movie',
      id: 'tt1',
      name: 'Wave Twisters',
      year: 2001,
    );
    expect(first.single.item.id, 'tt0219653');

    // A fresh feature off the same preferences file: what a restart is.
    final again = await feature().forItem(
      type: 'movie',
      id: 'tt1',
      name: 'Wave Twisters',
      year: 2001,
    );

    expect(again.single.item.id, 'tt0219653');
    expect(asked, hasLength(1), reason: 'the first answer is the answer');
    expect(storage.stored[AppPrefs.similarSuggestionsKey], isNotNull);
  });

  test('an answer to an older question is asked again', () async {
    // What an install that has already opened this series holds: ten
    // titles written down by the film-only question, with no stamp on
    // them at all. Without the stamp that viewer keeps a row of films
    // under a television series for the life of the install, and this
    // change would be one only a fresh install ever saw.
    storage = FakePrefsClient({
      AppPrefs.similarApiKeyKey: 'not-a-real-key',
      AppPrefs.similarSuggestionsKey: [
        {
          'type': 'series',
          'id': 'tt0903747',
          'films': [
            {'title': 'Sicario', 'year': 2015, 'why': 'a film, on a show'},
          ],
        },
      ],
    });
    prefs = AppPrefs(client: storage);
    await prefs.load();
    built = [];
    asked = [];

    await feature().forItem(
      type: 'series',
      id: 'tt0903747',
      name: 'Breaking Bad',
    );

    expect(asked, ['Breaking Bad as series']);
    // And the new answer replaces the stale row rather than joining it,
    // so it is asked once and not once a visit.
    await feature().forItem(
      type: 'series',
      id: 'tt0903747',
      name: 'Breaking Bad',
    );
    expect(asked, hasLength(1));
  });

  test('an answer with nothing in it is still an answer', () async {
    answering = (_) => const <SuggestedTitle>[];

    expect(
      await feature().forItem(type: 'movie', id: 'tt1', name: 'A'),
      isEmpty,
    );
    expect(
      await feature().forItem(type: 'movie', id: 'tt1', name: 'A'),
      isEmpty,
    );

    expect(asked, hasLength(1), reason: 'asking again would be told the same');
  });

  test('a failure is an empty row, and a log line saying which', () async {
    final lines = captureDiagnostics();
    answering = (_) => const SimilarTitlesFailure(SimilarTrouble.gone, '404');

    final row = await feature().forItem(type: 'movie', id: 'tt1', name: 'A');

    expect(row, isEmpty);
    expect(lines.single, contains(SimilarTrouble.gone.describe));
    expect(lines.single, contains(defaultSimilarModel));
    // The key is the one thing that must never reach a log: this
    // repository is public and the ring is copied into bug reports.
    expect(lines.single, isNot(contains('not-a-real-key')));
    // Nothing was written down, so another visit may find the model back.
    expect(storage.stored[AppPrefs.similarSuggestionsKey], isNull);
    expect(
      await feature().forItem(type: 'movie', id: 'tt1', name: 'A'),
      isEmpty,
    );
    expect(asked, hasLength(2));
  });

  test('a provider that throws something else is still an empty row', () async {
    answering = (_) => StateError('a bug in a provider');

    expect(
      await feature().forItem(type: 'movie', id: 'tt1', name: 'A'),
      isEmpty,
    );
  });

  test('a title already resolved this run is not searched again', () async {
    var searched = 0;
    Future<List<Map<String, dynamic>>> searching(
      String type,
      String query,
    ) async {
      searched++;
      return _catalogue(type, query);
    }

    final feature1 = feature(search: searching);
    await feature1.forItem(type: 'movie', id: 'tt1', name: 'A');
    final searches = searched;
    await feature1.forItem(type: 'movie', id: 'tt1', name: 'A');

    expect(searched, searches);
  });
}

/// A catalogue holding one film, under the one name the fake model uses.
Future<List<Map<String, dynamic>>> _catalogue(String type, String query) async {
  if (type != 'movie' || query != 'Avalon') return const [];
  return [
    {
      'id': 'tt0219653',
      'imdb_id': 'tt0219653',
      'type': 'movie',
      'name': 'Avalon',
      'releaseInfo': '2001',
    },
  ];
}

final class _FakeProvider implements SimilarTitlesProvider {
  _FakeProvider(this.asked, this.answering);

  /// What was asked about, and as what: `Avalon (2001) as film`. The kind
  /// is in the string because it is half the question.
  final List<String> asked;

  /// A list to answer with, or an object to throw.
  final Object Function(String subject) answering;

  @override
  Future<List<SuggestedTitle>> suggest(
    String subject, {
    required SuggestedKind about,
  }) async {
    asked.add('$subject as ${about.stored}');
    final answer = answering(subject);
    if (answer is List<SuggestedTitle>) return answer;
    throw answer;
  }
}
