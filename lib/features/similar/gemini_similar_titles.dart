/// [SimilarTitlesProvider] over Google's Generative Language API.
///
/// One `POST` to
/// `{endpoint}/models/{model}:generateContent?key={key}`, carrying a
/// `system_instruction`, the question, and a `generationConfig` that pins
/// the answer to JSON of a stated shape (`responseMimeType` and
/// `responseSchema`). The schema is what makes the answer parseable
/// without hoping -- without it the same models wrap their JSON in prose
/// about half the time.
///
/// Two things here look defensive and are not:
///
///  * **The retry.** A model that takes a parameter today refuses it
///    tomorrow: one measured provider began answering 400 naming
///    `temperature` as deprecated, mid-afternoon, with nothing about the
///    request having changed. A 400 whose message names a parameter this
///    request sent is therefore worth exactly one more attempt without
///    that parameter -- which costs a round trip out of the budget and
///    turns a dead feature into a working one.
///  * **The classification.** Every failure comes back as a
///    [SimilarTrouble] rather than an exception to print, so that a log
///    read a week later can say *the model is gone* rather than *it did
///    not work*, and so that a fallback to another model has grounds.
///
/// **The key is written down nowhere.** It reaches this class from
/// `AppPrefs`, goes into the query of one request, and is never logged,
/// never put in a failure's `detail`, and never returned. The repository
/// is public: a key in a default or a fixture ships in every APK.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/core.dart';
import 'similar_titles.dart';

/// Where Google's Generative Language API lives. A parameter on the
/// provider rather than a constant in the request, so a test answers it
/// from the loopback and nothing in this file knows the difference.
final Uri googleGenerativeLanguage = Uri.parse(
  'https://generativelanguage.googleapis.com/v1beta',
);

/// The parameters this request sends that it can do without, in the order
/// they are given up.
///
/// A 400 naming one of these is answered by sending the request again
/// without it. The order is what the answer can most afford to lose:
/// `temperature` changes nothing about whether the answer parses,
/// `thinkingConfig` is not sent at all but is named here because a model
/// that starts rejecting it would otherwise be unusable, and the two
/// response fields are given up last -- without them the answer is prose
/// with JSON somewhere in it, which [_filmsIn] can still often read.
///
/// Both spellings of each are matched, because the API's own error
/// messages use the snake-cased names of its proto fields while the body
/// takes the camel-cased ones.
const List<String> _strippable = [
  'temperature',
  'thinkingConfig',
  'responseSchema',
  'responseMimeType',
  'system_instruction',
];

final class GeminiSimilarTitles implements SimilarTitlesProvider {
  GeminiSimilarTitles({
    required this.apiKey,
    this.model = defaultSimilarModel,
    Uri? endpoint,
    this.budget = similarBudget,
    this.count = similarSuggestionCount,
  }) : endpoint = endpoint ?? googleGenerativeLanguage;

  /// The viewer's own API key (`AppPrefs.similarApiKey`). Goes into one
  /// query string and nowhere else.
  final String apiKey;

  /// Which model is asked. A string because the names rot -- see
  /// [defaultSimilarModel].
  final String model;

  /// The API's base, up to and including the version segment.
  final Uri endpoint;

  /// The whole ask, retry included. Past it the request is abandoned and
  /// the socket closed under it.
  final Duration budget;

  /// How many titles to ask for.
  final int count;

  @override
  Future<List<SuggestedTitle>> suggest(String subject) async {
    final client = HttpClient()..connectionTimeout = budget;
    try {
      return await _ask(client, subject).timeout(budget);
    } on TimeoutException {
      throw const SimilarTitlesFailure(SimilarTrouble.tooSlow);
    } on SimilarTitlesFailure {
      rethrow;
    } on Object catch (error) {
      // No HTTP at all: no network, no DNS, a TLS refusal. The type is
      // worth keeping and the message is not -- it can carry the URL.
      throw SimilarTitlesFailure(
        SimilarTrouble.unreachable,
        error.runtimeType.toString(),
      );
    } finally {
      // Force, because [budget] may have passed while a response was
      // still arriving: closing the client is what actually abandons it.
      client.close(force: true);
    }
  }

  Future<List<SuggestedTitle>> _ask(HttpClient client, String subject) async {
    final body = _body(subject);
    try {
      return _filmsIn(await _send(client, body));
    } on _Refused catch (refusal) {
      final parameter = _named(refusal.message);
      if (parameter == null) {
        throw SimilarTitlesFailure(SimilarTrouble.refused, refusal.status);
      }
      // One more attempt, without what was named. A second refusal is the
      // answer: the alternative is a loop that strips the request down to
      // nothing while the viewer waits.
      try {
        return _filmsIn(await _send(client, _without(body, parameter)));
      } on _Refused catch (again) {
        throw SimilarTitlesFailure(
          SimilarTrouble.refused,
          '${again.status}, after dropping $parameter',
        );
      }
    }
  }

  /// The request, exactly as measured: a system instruction, the question,
  /// and a `generationConfig` pinning JSON of a stated shape.
  ///
  /// The schema asks for a title, a year and a reason, and nothing else --
  /// that shape is the one every measurement in `tool/recommendations` was
  /// taken against. A model that volunteers a `kind` beside them is read
  /// ([SuggestedTitle.fromJson]); one that does not leaves the kind
  /// unstated, which [resolveSuggestions] handles by looking in both
  /// catalogues.
  Map<String, Object?> _body(String subject) => {
    'system_instruction': {
      'parts': [
        {'text': similarSystemInstruction},
      ],
    },
    'contents': [
      {
        'parts': [
          {'text': askForSimilar(subject, count: count)},
        ],
      },
    ],
    'generationConfig': {
      'temperature': 0.7,
      'responseMimeType': 'application/json',
      'responseSchema': {
        'type': 'OBJECT',
        'properties': {
          'films': {
            'type': 'ARRAY',
            'items': {
              'type': 'OBJECT',
              'properties': {
                'title': {'type': 'STRING'},
                'year': {'type': 'INTEGER'},
                'why': {'type': 'STRING'},
              },
              'required': ['title', 'year', 'why'],
            },
          },
        },
        'required': ['films'],
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
      throw _Refused('${response.statusCode}', _messageIn(text));
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

  /// What a status code means, in the words a log can be read back in.
  /// The same split `tool/recommendations/model_bench.py` reports, which
  /// is the one six models in an afternoon justified.
  static SimilarTrouble _troubleFor(int status) => switch (status) {
    HttpStatus.notFound => SimilarTrouble.gone,
    HttpStatus.paymentRequired ||
    HttpStatus.forbidden => SimilarTrouble.notInTier,
    HttpStatus.tooManyRequests => SimilarTrouble.quota,
    HttpStatus.serviceUnavailable => SimilarTrouble.busy,
    _ => SimilarTrouble.unreachable,
  };

  /// `error.message` out of a refusal body, or the body's first line when
  /// it is not the documented error shape. Only ever matched against
  /// [_strippable]; it is not logged.
  static String _messageIn(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is Map) {
        final message = (decoded['error'] as Map)['message'];
        if (message is String) return message;
      }
    } on FormatException {
      // A 400 that is not JSON is a 400 that names no parameter.
    }
    return body;
  }

  /// Which of [_strippable] a refusal named, or null.
  static String? _named(String message) {
    final lowered = message.toLowerCase();
    for (final parameter in _strippable) {
      if (lowered.contains(parameter.toLowerCase()) ||
          lowered.contains(_snake(parameter))) {
        return parameter;
      }
    }
    return null;
  }

  /// `responseMimeType` as the API's own messages spell it,
  /// `response_mime_type`.
  static String _snake(String name) => name
      .replaceAllMapped(
        RegExp('[A-Z]'),
        (match) => '_${match.group(0)!.toLowerCase()}',
      )
      .toLowerCase();

  /// [body] without [parameter], wherever in it that parameter lives:
  /// inside `generationConfig` for the generation settings, at the top for
  /// `system_instruction`.
  static Map<String, Object?> _without(
    Map<String, Object?> body,
    String parameter,
  ) {
    final copy = {...body};
    copy.remove(parameter);
    final config = copy['generationConfig'];
    if (config is Map) {
      copy['generationConfig'] = {...config}..remove(parameter);
    }
    return copy;
  }

  /// The films in a documented answer.
  ///
  /// `candidates[0].content.parts[].text` joined -- the parts are a list
  /// because the API may split one answer across several -- then the
  /// outermost braces of that, which is what survives a model that wrapped
  /// its JSON in a sentence after the schema was stripped.
  ///
  /// Anything that is not that shape is [SimilarTrouble.malformed] rather
  /// than an empty answer: an answer that was not understood must not be
  /// cached as "this film is like nothing".
  static List<SuggestedTitle> _filmsIn(Map<String, dynamic> answer) {
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
    final films = decoded is Map ? decoded['films'] : null;
    if (films is! List) {
      throw const SimilarTitlesFailure(SimilarTrouble.malformed, 'films');
    }
    // A row that cannot be read is one suggestion lost, not an answer
    // lost: a model that names nine films and a fragment has named nine
    // films.
    return [for (final film in films) ?SuggestedTitle.fromJson(film)];
  }
}

/// A 400, kept apart from the other failures because it is the one that is
/// worth another try. Private: nothing outside this file distinguishes a
/// refusal that was repaired from one that was never refused.
final class _Refused implements Exception {
  const _Refused(this.status, this.message);

  final String status;

  /// The provider's own words, matched against [_strippable] and then
  /// dropped. Not logged: an error message can quote the request.
  final String message;
}
