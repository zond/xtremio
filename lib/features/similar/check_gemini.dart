/// The check's two questions over Google's Generative Language API.
///
/// The recommendation half is [GeminiSimilarTitles] itself — the check
/// must ask the row's own question, in the row's own request, or it is
/// measuring something the viewer will never see. The sort half is here
/// because it is a different question with a different answer shape, and
/// the row has no use for it.
///
/// The request is `vibe_sort.py`'s: the same sentence, `temperature` 0.3,
/// and a response schema pinning the answer to `{"order":[…]}`. The
/// numbers in `tool/recommendations/README.md` were measured with that
/// request, and a check that asked differently would be reporting against
/// a table it no longer belongs to. The one repair is the row's one
/// repair, for the reason given there: a provider began answering 400
/// naming `temperature` as deprecated, mid-afternoon, with nothing about
/// the request having changed.
///
/// **The key goes into one query string and nowhere else** — not into a
/// log, not into a failure's `detail`, not into an error a screen shows.
/// This repository is public and its APKs are handed around.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/core.dart';
import 'check_model.dart';
import 'gemini_similar_titles.dart';
import 'similar_titles.dart';

/// How long one call of the check may take.
///
/// Six times the row's own [similarBudget], deliberately. The check
/// *reports* the slowest call so a viewer can see that a model is too
/// slow for the row; abandoning at five seconds would leave it with no
/// number to report and a failure instead, which is a worse answer to
/// "is this model any good" than "it is good and it takes forty seconds".
const Duration modelCheckBudget = Duration(seconds: 30);

/// The sort question, for a [target] and the films to order.
///
/// `vibe_sort.py`'s prompt, word for word: the salting only works if the
/// model is asked for *feel* rather than for relatedness, and the second
/// clause is what asks for it.
String askForOrder(String target, List<String> films) =>
    'Order these films by how much each one *feels* like $target -- the '
    'same register, pace, palette and texture, what it is like to sit '
    'through -- rather than by how related they are in subject, director '
    'or genre. Most alike in feel first: ${films.join('; ')}. '
    'Answer JSON only: {"order":["Title (Year)", ...]} with every film once.';

final class GeminiModelCheck implements ModelCheckProvider {
  GeminiModelCheck({
    required this.apiKey,
    this.model = defaultSimilarModel,
    Uri? endpoint,
    this.budget = modelCheckBudget,
  }) : endpoint = endpoint ?? googleGenerativeLanguage;

  /// The viewer's own key (`AppPrefs.similarApiKey`).
  final String apiKey;

  final String model;
  final Uri endpoint;
  final Duration budget;

  /// The row's own question in the row's own request, so that what the
  /// check measures is what the viewer would get.
  ///
  /// Asked as a film, because every target in the shipped keys is one and
  /// the keys are what the answer is scored against -- see
  /// `tool/recommendations/README.md`, where nothing about series was
  /// measured. A viewer standing on a series gets the series question
  /// ([askForSimilar]); this check has no opinion about that question
  /// because there is no key to have one with.
  @override
  Future<List<SuggestedTitle>> suggest(String subject) => GeminiSimilarTitles(
    apiKey: apiKey,
    model: model,
    endpoint: endpoint,
    budget: budget,
  ).suggest(subject, about: SuggestedKind.film);

  @override
  Future<List<String>> order(String target, List<String> films) async {
    final client = HttpClient()..connectionTimeout = budget;
    try {
      return await _order(client, target, films).timeout(budget);
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

  Future<List<String>> _order(
    HttpClient client,
    String target,
    List<String> films,
  ) async {
    final body = _body(target, films);
    try {
      return _orderIn(await _send(client, body));
    } on _Deprecated {
      // One more attempt without the parameter that was named. A second
      // refusal is the answer.
      final without = {...body};
      final config = without['generationConfig'];
      if (config is Map) {
        without['generationConfig'] = {...config}..remove('temperature');
      }
      try {
        return _orderIn(await _send(client, without));
      } on _Deprecated {
        throw const SimilarTitlesFailure(
          SimilarTrouble.refused,
          '400, after dropping temperature',
        );
      }
    }
  }

  Map<String, Object?> _body(String target, List<String> films) => {
    'contents': [
      {
        'parts': [
          {'text': askForOrder(target, films)},
        ],
      },
    ],
    'generationConfig': {
      'temperature': 0.3,
      'responseMimeType': 'application/json',
      'responseSchema': {
        'type': 'OBJECT',
        'properties': {
          'order': {
            'type': 'ARRAY',
            'items': {'type': 'STRING'},
          },
        },
        'required': ['order'],
      },
    },
  };

  Future<Map<String, dynamic>> _send(
    HttpClient client,
    Map<String, Object?> body,
  ) async {
    final url = endpoint.replace(
      pathSegments: [
        ...endpoint.pathSegments.where((segment) => segment.isNotEmpty),
        'models',
        '$model:generateContent',
      ],
      queryParameters: {'key': apiKey},
    );
    final request = await client.postUrl(url);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode == HttpStatus.badRequest) {
      if (text.toLowerCase().contains('temperature')) throw const _Deprecated();
      throw const SimilarTitlesFailure(SimilarTrouble.refused, '400');
    }
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

  /// The same split `tool/recommendations/model_bench.py` reports a
  /// failure as, which is the one six models in an afternoon justified.
  static SimilarTrouble _troubleFor(int status) => switch (status) {
    HttpStatus.notFound => SimilarTrouble.gone,
    HttpStatus.paymentRequired ||
    HttpStatus.forbidden => SimilarTrouble.notInTier,
    HttpStatus.tooManyRequests => SimilarTrouble.quota,
    HttpStatus.serviceUnavailable => SimilarTrouble.busy,
    _ => SimilarTrouble.unreachable,
  };

  /// The titles in a documented answer, in the order the model put them.
  ///
  /// A short list is an answer and is scored as one — the sort is
  /// weighted by how much of the list came back — but a body that is not
  /// the documented shape is [SimilarTrouble.malformed], because a score
  /// of zero and an answer nobody could read are different things.
  static List<String> _orderIn(Map<String, dynamic> answer) {
    final candidates = answer['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      throw const SimilarTitlesFailure(SimilarTrouble.malformed, 'candidates');
    }
    final first = candidates.first;
    final content = first is Map ? first['content'] : null;
    final parts = content is Map ? content['parts'] : null;
    if (parts is! List) {
      throw const SimilarTitlesFailure(SimilarTrouble.malformed, 'parts');
    }
    final text = [
      for (final part in parts)
        if (part is Map && part['text'] is String) part['text'] as String,
    ].join();
    final open = text.indexOf('{');
    final close = text.lastIndexOf('}');
    if (open < 0 || close <= open) {
      throw const SimilarTitlesFailure(SimilarTrouble.malformed, 'not JSON');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text.substring(open, close + 1));
    } on FormatException {
      throw const SimilarTitlesFailure(SimilarTrouble.malformed, 'not JSON');
    }
    final order = decoded is Map ? decoded['order'] : null;
    if (order is! List) {
      throw const SimilarTitlesFailure(SimilarTrouble.malformed, 'order');
    }
    return [
      for (final title in order)
        if (title is String) title,
    ];
  }
}

/// A 400 naming a parameter this request could do without. Private:
/// nothing outside this file distinguishes a request that was repaired
/// from one that was never refused.
final class _Deprecated implements Exception {
  const _Deprecated();
}
