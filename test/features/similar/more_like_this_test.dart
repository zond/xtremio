import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/similar/more_like_this.dart';
import 'package:xtremio/features/similar/similar_resolver.dart';
import 'package:xtremio/features/similar/similar_titles.dart';

import '../../support/diagnostics_capture.dart';
import '../../support/fake_prefs_client.dart';

/// Everything behind the row, with nothing on the network.
///
/// The thing this file is here to hold is that **a title is asked about
/// once per install** -- the answer is written down and read back, because
/// the server's answer is everybody's and asking it again would only be
/// told the same -- and that a failure is never written down as an answer.
void main() {
  late FakePrefsClient storage;
  late AppPrefs prefs;
  late List<String> asked;

  /// What a provider answers, or throws.
  late Object Function(String type, String id) answering;

  Future<void> start([Map<String, dynamic>? stored]) async {
    storage = FakePrefsClient(stored);
    prefs = AppPrefs(client: storage);
    await prefs.load();
    asked = [];
  }

  MoreLikeThis feature({CatalogueSearch? search}) => MoreLikeThis(
    prefs: prefs,
    provider: _FakeProvider(asked, answering),
    search: search ?? _catalogue,
  );

  setUp(() async {
    answering = (_, _) => const [
      SuggestedTitle(title: 'Avalon', year: 2001, why: 'grey'),
    ];
    await start();
  });

  test('the type and the id are what the server is asked about', () async {
    await feature().forItem(type: 'movie', id: 'tt1');
    await feature().forItem(type: 'series', id: 'tt0903747');

    expect(asked, ['movie/tt1', 'series/tt0903747']);
  });

  test('a type the server does not answer for is not asked about, and '
      'nothing is remembered about it', () async {
    var searched = 0;
    Future<List<Map<String, dynamic>>> searching(
      String type,
      String query,
    ) async {
      searched++;
      return const [];
    }

    final row = await feature(search: searching)
        .forItem(type: 'channel', id: 'tt1');

    expect(row, isEmpty);
    expect(asked, isEmpty);
    expect(searched, 0);
    expect(storage.stored[AppPrefs.similarSuggestionsKey], isNull);
  });

  test('a title is asked about once, ever', () async {
    final first = await feature().forItem(type: 'movie', id: 'tt1');
    expect(first.single.item.id, 'tt0219653');

    // A fresh feature off the same preferences file: what a restart is.
    final again = await feature().forItem(type: 'movie', id: 'tt1');

    expect(again.single.item.id, 'tt0219653');
    expect(asked, hasLength(1), reason: 'the first answer is the answer');
    expect(storage.stored[AppPrefs.similarSuggestionsKey], isNotNull);
  });

  test('an answer to an older question is asked again', () async {
    // An answer stamped with an older question version is asked again;
    // without the stamp a stale row for the wrong question never refreshes.
    await start({
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

    await feature().forItem(type: 'series', id: 'tt0903747');

    expect(asked, ['series/tt0903747']);
    // And the new answer replaces the stale row rather than joining it,
    // so it is asked once and not once a visit.
    await feature().forItem(type: 'series', id: 'tt0903747');
    expect(asked, hasLength(1));
    expect(prefs.similarSuggestions.entries, hasLength(1));
    expect(
      prefs.similarSuggestions.entries.single.askedAs,
      similarQuestionVersion,
    );
  });

  test('an answer with nothing in it is still an answer', () async {
    answering = (_, _) => const <SuggestedTitle>[];

    expect(await feature().forItem(type: 'movie', id: 'tt1'), isEmpty);
    expect(await feature().forItem(type: 'movie', id: 'tt1'), isEmpty);

    expect(asked, hasLength(1), reason: 'asking again would be told the same');
  });

  test('a failure is an empty row, and a log line saying which', () async {
    final lines = captureDiagnostics();
    answering = (_, _) =>
        const SimilarTitlesFailure(SimilarTrouble.busy, '503');

    final row = await feature().forItem(type: 'movie', id: 'tt1');

    expect(row, isEmpty);
    expect(lines.single, contains(SimilarTrouble.busy.describe));
    expect(lines.single, contains('movie tt1'));
    // Nothing was written down, so another visit asks again -- a busy
    // server is one that will have the answer by then.
    expect(storage.stored[AppPrefs.similarSuggestionsKey], isNull);
    expect(await feature().forItem(type: 'movie', id: 'tt1'), isEmpty);
    expect(asked, hasLength(2));
  });

  test('a provider that throws something else is still an empty row', () async {
    captureDiagnostics();
    answering = (_, _) => StateError('a bug in a provider');

    expect(await feature().forItem(type: 'movie', id: 'tt1'), isEmpty);
    expect(storage.stored[AppPrefs.similarSuggestionsKey], isNull);
  });
}

/// A catalogue holding the two films the fake server names, and nothing
/// else -- so a suggestion of any other title is one the guard drops,
/// which is what an invented title does.
Future<List<Map<String, dynamic>>> _catalogue(String type, String query) async {
  const films = {
    'Avalon': ('tt0219653', '2001'),
    'Stalker': ('tt0079944', '1979'),
  };
  if (type != 'movie') return const [];
  final film = films[query];
  if (film == null) return const [];
  return [
    {
      'id': film.$1,
      'imdb_id': film.$1,
      'type': 'movie',
      'name': query,
      'releaseInfo': film.$2,
    },
  ];
}

final class _FakeProvider implements SimilarTitlesProvider {
  _FakeProvider(this.asked, this.answering);

  /// What was asked about: `movie/tt1`.
  final List<String> asked;

  /// A list to answer with, or an object to throw.
  final Object Function(String type, String id) answering;

  @override
  Future<List<SuggestedTitle>> suggest({
    required String type,
    required String id,
  }) async {
    asked.add('$type/$id');
    final answer = answering(type, id);
    if (answer is List<SuggestedTitle>) return answer;
    throw answer;
  }
}
