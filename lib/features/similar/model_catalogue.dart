/// What models a key can actually see, asked of Google's own catalogue.
///
/// The model is a preference because the names rot — that is
/// [defaultSimilarModel]'s whole story — and a preference that has to be
/// typed is a preference nobody gets right. So the chooser is filled from
/// `GET {endpoint}/models?key={key}`, which is the account's own list: what
/// this key can see today, on the tier it is on.
///
/// Three things measured in `tool/recommendations/` are built into this
/// file rather than left to the caller:
///
///  * **A hard-coded list would be wrong within months.** In one afternoon
///    `gemini-2.5-flash` and `gemini-2.5-flash-lite` began answering *404,
///    no longer available to new users* and `gemini-3.6-flash` answered
///    *503, high demand*. Hence a live fetch and no shipped list.
///  * **Being listed is not being usable.** Probing every listed model
///    with a real request, 20 of 33 failed: gone, above the key's tier, or
///    answering only on a different API. Nothing here promises a listed
///    model works — that is what "Test this model" is for, and the screen
///    says so.
///  * **Some of what is listed is not a wrong answer but no answer.**
///    `models?key=` returns the image, video, speech and embedding models
///    too. [answersInWords] drops them, on the same list
///    `tool/recommendations/model_bench.py` skips by.
///
/// **The key goes into one query string and nowhere else** — not into a
/// log, not into a failure's `detail`, not into an error a screen shows.
/// A [SimilarTitlesFailure] from here carries a status code at most.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/core.dart';
import 'gemini_similar_titles.dart';
import 'similar_titles.dart';

/// Where a catalogue comes from, given the viewer's key: the names to
/// offer, in the order to offer them.
///
/// A typedef rather than a class because there is one call and no state,
/// and because a widget test has to answer it without a network.
typedef ModelCatalogue = Future<List<String>> Function(String apiKey);

/// How long the whole listing may take, pages included.
///
/// Shorter than the check's budget and longer than the row's: nobody is
/// watching a film while this runs, but it is one GET and a viewer is
/// sitting in front of the settings screen waiting for a menu to fill.
const Duration modelListBudget = Duration(seconds: 10);

/// What a name that is not a text model says.
///
/// `tool/recommendations/model_bench.py`'s own skip list. These are not
/// bad answers to a film question, they are not answers at all: an image
/// model handed "name ten films like Avalon" does not answer it badly, it
/// answers something else or nothing. Matched anywhere in the name and
/// case-insensitively, because the catalogue spells them
/// `models/gemini-2.5-flash-image-preview`.
const List<String> notInWords = [
  'tts',
  'image',
  'imagen',
  'veo',
  'lyria',
  'embedding',
  'transcribe',
  'robotics',
  'computer-use',
  'antigravity',
  'deep-research',
];

/// Whether a model could answer a question about films at all.
bool answersInWords(String model) {
  final name = model.toLowerCase();
  return !notInWords.any(name.contains);
}

/// The names in a `models[]` answer worth offering, in the order the
/// chooser offers them.
///
/// Takes the decoded list rather than the body so that the filtering and
/// the ordering — the two halves anybody would want to argue with — can be
/// tested without a socket.
List<String> usableModelNames(Object? models) {
  if (models is! List) return const [];
  final names = <String>{};
  for (final model in models) {
    if (model is! Map) continue;
    final name = model['name'];
    if (name is! String) continue;
    // A model that does not offer `generateContent` answers on a
    // different API — six of the 33 measured did — so it is not a model
    // this app can ask anything of, whatever its name says.
    final methods = model['supportedGenerationMethods'];
    if (methods is! List || !methods.contains('generateContent')) continue;
    final bare = name.split('/').last.trim();
    if (bare.isEmpty || !answersInWords(bare)) continue;
    names.add(bare);
  }
  return names.toList()..sort(compareModels);
}

/// The order the chooser offers models in: the measured default first,
/// then the flash-lites, then the flashes, then the rest, and inside each
/// of those the newest generation first.
///
/// Speed is what the ordering is about, because the row gives up at
/// [similarBudget] and the best recommender measured takes 153 seconds. A
/// flash-lite is the shape that answered in about two and a half, which is
/// also why the default is one.
int compareModels(String a, String b) {
  final byFamily = _family(a).compareTo(_family(b));
  if (byFamily != 0) return byFamily;
  // Newest first, and a name with no generation in it last: an alias like
  // `gemini-flash-latest` rots more slowly than a version does, but it
  // also says nothing about which generation it is pointing at today.
  final byGeneration = _generation(b).compareTo(_generation(a));
  if (byGeneration != 0) return byGeneration;
  return a.compareTo(b);
}

int _family(String model) {
  if (model == defaultSimilarModel) return 0;
  final name = model.toLowerCase();
  if (name.contains('flash-lite')) return 1;
  if (name.contains('flash')) return 2;
  return 3;
}

/// The generation in a name — 3.1 out of `gemini-3.1-flash-lite` — or -1
/// where there is none to read.
///
/// Between dashes and under a hundred, because `gemini-exp-1206` carries a
/// date in the same position and a date is not a generation: read as one
/// it would sort an experiment above everything that has ever shipped.
double _generation(String model) {
  final found = _version.firstMatch(model);
  if (found == null) return -1;
  final value = double.tryParse(found.group(1)!) ?? -1;
  return value < 100 ? value : -1;
}

final RegExp _version = RegExp(r'-(\d+(?:\.\d+)?)-');

/// How many pages of the catalogue are asked for before the answer is
/// taken as complete. Tens of models come back in one page at
/// [_pageSize]; the cap is there so that a `nextPageToken` that never
/// stops being returned cannot spend the whole budget.
const int _pageLimit = 5;
const int _pageSize = 200;

/// The models Google lists for [apiKey], filtered and ordered.
///
/// Throws a [SimilarTitlesFailure] rather than answering empty, because
/// the two mean different things to the chooser: empty is a key that can
/// see nothing, and a failure is a list that was never fetched — and only
/// the second one leaves the viewer needing somewhere to type a name.
Future<List<String>> listGeminiModels(
  String apiKey, {
  Uri? endpoint,
  Duration budget = modelListBudget,
}) async {
  final base = endpoint ?? googleGenerativeLanguage;
  final client = HttpClient()..connectionTimeout = budget;
  try {
    return await _list(client, base, apiKey).timeout(budget);
  } on TimeoutException {
    throw const SimilarTitlesFailure(SimilarTrouble.tooSlow);
  } on SimilarTitlesFailure {
    rethrow;
  } on Object catch (error) {
    // No HTTP at all. The type is worth keeping and the message is not:
    // it can carry the URL, and the URL carries the key.
    throw SimilarTitlesFailure(
      SimilarTrouble.unreachable,
      error.runtimeType.toString(),
    );
  } finally {
    client.close(force: true);
  }
}

Future<List<String>> _list(HttpClient client, Uri base, String apiKey) async {
  final models = <Object?>[];
  String? page;
  for (var asked = 0; asked < _pageLimit; asked++) {
    final answer = await _get(client, base, apiKey, page);
    final listed = answer['models'];
    if (listed is List) models.addAll(listed);
    final next = answer['nextPageToken'];
    page = next is String && next.isNotEmpty ? next : null;
    if (page == null) break;
  }
  return usableModelNames(models);
}

Future<Map<String, dynamic>> _get(
  HttpClient client,
  Uri base,
  String apiKey,
  String? page,
) async {
  final url = base.replace(
    pathSegments: [
      ...base.pathSegments.where((segment) => segment.isNotEmpty),
      'models',
    ],
    queryParameters: {
      'key': apiKey,
      'pageSize': '$_pageSize',
      'pageToken': ?page,
    },
  );
  final request = await client.getUrl(url);
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  if (response.statusCode != HttpStatus.ok) {
    throw SimilarTitlesFailure(
      _troubleFor(response.statusCode),
      '${response.statusCode}',
    );
  }
  final decoded = jsonDecode(text);
  if (decoded is! Map<String, dynamic>) {
    throw const SimilarTitlesFailure(SimilarTrouble.malformed);
  }
  return decoded;
}

/// What a status means *for a listing*, which is not what the same status
/// means for a request naming a model.
///
/// A 404 here is not a retired model, it is the wrong endpoint; a 403 is
/// not a tier, it is the key. Both are [SimilarTrouble.refused] — the
/// request was refused — and neither is a sentence this screen repeats,
/// which is why the split is coarser than [GeminiSimilarTitles]'s.
SimilarTrouble _troubleFor(int status) => switch (status) {
  HttpStatus.tooManyRequests => SimilarTrouble.quota,
  HttpStatus.serviceUnavailable => SimilarTrouble.busy,
  _ => SimilarTrouble.refused,
};
