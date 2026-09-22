/// Turning what a model said into catalogue items, and dropping what it
/// made up.
///
/// **This is where the correctness of "More like this" lives.** A model
/// answers with text, and some of that text names films that do not
/// exist: one measured model invented `Heat and Bone (2019)`, another
/// invented twenty titles out of seventy-one. The failure is not that a
/// row comes up short -- it is that searching an invented title *succeeds*.
/// `The Otherside (2022)` does not exist, and the catalogue answers that
/// query happily with a 2008 film and a 2013 one. Show either and the
/// viewer is looking at a real poster for a film nothing recommended.
///
/// So every suggestion is resolved against a catalogue and kept only when
/// the answer matches on **both** the title and the year, within a year
/// either way. A year is allowed to be off by one because festival and
/// territory dates genuinely differ by one; two years apart is not a
/// release date, it is a different film.
///
/// The other half is which catalogue. A model asked what is like *Wave
/// Twisters* answered *Æon Flux*, which is a television series, and was
/// right -- the app plays series. Asked for the film catalogue only, that
/// suggestion would either vanish or, worse, land on the 2005 film of the
/// same name. So a suggestion that names its kind is looked for in that
/// kind's catalogue, and one that names none is looked for in both: the
/// year is what tells the 1991 series from the 2005 film.
///
/// Nothing here throws. A search that fails, times out or answers
/// something that is not JSON drops that one suggestion and leaves the
/// rest; an empty result is an ordinary outcome -- a model that named ten
/// films none of which exist -- and not an error for anything upstream to
/// report.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/core.dart';

/// How a catalogue is asked. `type` is stremio's own (`movie`, `series`),
/// `query` the title as the model wrote it.
///
/// A function rather than a client interface for the reason
/// `PlaybackScope.archiveSniff` is one: it is the only question this
/// feature asks over the network apart from the model, a test answers it
/// with a list, and there is nothing else about a catalogue this wants to
/// know. Failures are the function's own business -- it may throw, and
/// [resolveSuggestions] turns that into one dropped suggestion.
typedef CatalogueSearch = Future<List<Map<String, dynamic>>> Function(
  String type,
  String query,
);

/// Where [cinemetaSearch] asks. Cinemeta is stremio's own metadata addon
/// and is installed for everybody, which is why it can be asked directly.
final Uri cinemeta = Uri.parse('https://v3-cinemeta.strem.io');

/// One suggestion that survived: the catalogue's item, and the model's
/// sentence about why it is here.
final class SimilarTitle {
  const SimilarTitle({required this.item, required this.why});

  /// What the catalogue answered with -- a real item, with a real id and a
  /// real poster, which is the only kind of thing that reaches a row.
  final MetaItemPreview item;

  /// The model's reason, in its own words. Empty when it gave none.
  final String why;

  @override
  String toString() => 'SimilarTitle(${item.type}/${item.id})';
}

/// Asks Cinemeta's search catalogue for [query] of [type].
///
/// `GET /catalog/{type}/top/search={query}.json`, answering `metas[]` with
/// `name`, `releaseInfo` and `imdb_id` on each -- which is exactly the
/// three things the guard above needs.
///
/// **Deliberately provisional.** The addon-aware version of this question
/// asks the viewer's own installed meta addons rather than one addon this
/// file names, and the app cannot ask it yet: the way into the core's
/// addon search is its shared search field, and driving that from a row on
/// a details screen would write every model's suggestion into the viewer's
/// search history. Until there is a search that is not the viewer's own,
/// this asks the addon everybody has.
Future<List<Map<String, dynamic>>> cinemetaSearch(
  String type,
  String query, {
  Uri? base,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    return await _search(
      client,
      base ?? cinemeta,
      type,
      query,
    ).timeout(timeout);
  } finally {
    client.close(force: true);
  }
}

Future<List<Map<String, dynamic>>> _search(
  HttpClient client,
  Uri base,
  String type,
  String query,
) async {
  // The title is one path *segment* with `search=` in front of it and
  // `.json` after it, encoded here rather than by [Uri]: a title with a
  // slash, an ampersand or a question mark in it must not become a path of
  // its own or a query string. An escape already in the path is left as it
  // is, which is why the path is written out rather than built from
  // segments -- that would encode these escapes a second time.
  final url = base.replace(
    path:
        '${base.path}/catalog/$type/top/'
        'search=${Uri.encodeComponent(query)}.json',
  );
  final response = await client.getUrl(url).then((r) => r.close());
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode != HttpStatus.ok) {
    throw HttpException('${response.statusCode}', uri: url);
  }
  final decoded = jsonDecode(body);
  final metas = decoded is Map ? decoded['metas'] : null;
  if (metas is! List) return const [];
  return [
    for (final meta in metas)
      if (meta is Map<String, dynamic>) meta,
  ];
}

/// [suggestions], in the order they were suggested, reduced to the ones a
/// catalogue agrees exist.
///
/// [subjectId] is the item the suggestions are *about*: a model asked what
/// is like a film routinely names that film, and a row whose first poster
/// is the title already on screen looks like a bug. Matching is by id,
/// which is the one thing about the subject that cannot be spelled two
/// ways.
///
/// Duplicates collapse by id -- two suggestions can resolve to one item
/// where a model names a film and its re-release -- and the first of them
/// keeps its reason, since that is the one the model thought of first.
Future<List<SimilarTitle>> resolveSuggestions(
  List<SuggestedTitle> suggestions, {
  required String subjectId,
  CatalogueSearch search = cinemetaSearch,
}) async {
  final resolved = <SimilarTitle>[];
  final seen = <String>{subjectId};
  // One query is one answer for the length of this call: a model that
  // names the same title twice, or two titles that search the same, costs
  // one search.
  final asked = <String, List<Map<String, dynamic>>>{};

  Future<List<Map<String, dynamic>>> ask(String type, String query) async {
    final key = '$type/$query';
    if (asked[key] case final answer?) return answer;
    List<Map<String, dynamic>> answer;
    try {
      answer = await search(type, query);
    } on Object {
      // A search that failed, timed out, or answered something that is not
      // JSON: this one suggestion is lost and the rest of the row is not.
      answer = const [];
    }
    return asked[key] = answer;
  }

  for (final suggestion in suggestions) {
    // The kind the model stated, or both in a fixed order when it stated
    // none. Both is the honest default: the schema asks for a title, a
    // year and a reason, so most answers say nothing about kind, and the
    // year is what keeps a series from resolving to the film that was
    // made of it.
    final types = switch (suggestion.kind) {
      final kind? => [kind.catalogType],
      null => const ['movie', 'series'],
    };
    for (final type in types) {
      final match = _matchIn(
        await ask(type, suggestion.title),
        suggestion,
        type,
      );
      if (match == null) continue;
      final item = MetaItemPreview(match);
      if (!seen.add(item.id)) break;
      resolved.add(SimilarTitle(item: item, why: suggestion.why));
      break;
    }
  }
  return resolved;
}

/// The first meta in [metas] that is this suggestion, or null.
///
/// Both halves must agree. The title comparison is loose -- case,
/// punctuation and a leading article are not what a model gets wrong --
/// and the year comparison is what carries the weight.
Map<String, dynamic>? _matchIn(
  List<Map<String, dynamic>> metas,
  SuggestedTitle suggestion,
  String type,
) {
  final wanted = similarTitleKey(suggestion.title);
  for (final meta in metas) {
    final name = meta['name'];
    if (name is! String || similarTitleKey(name) != wanted) continue;
    final year = yearIn(meta['releaseInfo']);
    if (year == null || (year - suggestion.year).abs() > 1) continue;
    final id = meta['imdb_id'] ?? meta['id'];
    if (id is! String || id.isEmpty) continue;
    final named = meta['type'];
    return {
      ...meta,
      // `imdb_id` in preference to `id`: they are the same string on
      // Cinemeta, and where they are not, the imdb id is the one every
      // other addon in the app is keyed on.
      'id': id,
      // Cinemeta names the type on every meta; a catalogue that does not
      // was asked for one type at a time anyway, so the query's own type
      // is the answer rather than a guess.
      'type': named is String && named.isNotEmpty ? named : type,
    };
  }
  return null;
}

/// A title reduced to what two spellings of the same film share: lower
/// case, no punctuation, no leading article.
///
/// The same normalisation the benchmark scores with
/// (`tool/recommendations/recommend_bench.py`), so that a title counted as
/// found there is one that resolves here. Dropping the article makes *The
/// Heat* and *Heat* one key, which the year then separates -- 2013 against
/// 1995 -- and which is the trade this whole file is built on: a loose
/// title with a strict year keeps the near-misses and drops the
/// inventions, where the reverse keeps the inventions.
String similarTitleKey(String title) {
  var key = title.toLowerCase().trim();
  key = key.replaceFirst(RegExp(r'^(the|a|an)\b'), '');
  return key.replaceAll(RegExp('[^a-z0-9]'), '');
}

/// The year a `releaseInfo` starts with, or null.
///
/// A film's is `1995`; a series' is a range -- `2008-2013`, or `2008-` for
/// one still running -- and the year a suggestion means is the year it
/// started.
int? yearIn(Object? releaseInfo) {
  if (releaseInfo is int) return releaseInfo;
  if (releaseInfo is! String) return null;
  final match = RegExp(r'(1[89]\d\d|20\d\d)').firstMatch(releaseInfo);
  return match == null ? null : int.parse(match.group(1)!);
}
