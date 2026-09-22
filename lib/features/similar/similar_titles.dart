/// Asking a model what a title is like: the question, and what answering
/// it can go wrong with.
///
/// The model is the cheap half of "More like this" and the half that is
/// wrong. What is measured about it lives in `tool/recommendations/` --
/// seven target titles, 528 researched films, every model scored on
/// relevance, on *tone*, on how many of its answers are films that exist,
/// and on how much its own repeated runs agree. Three findings from that
/// measurement are built into this file rather than left to taste:
///
///  * **The wording is part of the answer.** Asking for films that *feel*
///    like the target rather than films related to it is worth +0.12 on
///    the tone score and invents fewer titles while it is at it. That
///    sentence is in [askForSimilar] and is not decoration.
///  * **Five seconds is the budget.** The best recommender measured leads
///    both tests and takes 153 seconds. A row nobody waits for is not a
///    row, so a request past [similarBudget] is abandoned, and slowness
///    is a failure like any other ([SimilarTrouble.tooSlow]).
///  * **The model is a setting, not a constant.** In one afternoon of
///    measuring, two models began answering *404, no longer available to
///    new users*, one answered *503, high demand*, and one began
///    rejecting a parameter it had taken the day before. A build that
///    names one model in its source is a build that stops working without
///    anything about it changing, so [defaultSimilarModel] is a default
///    for a preference and every failure is classified
///    ([SimilarTrouble]) so that the log can say which of those happened.
library;

import '../../core/core.dart';

/// How long the whole ask is allowed to take, retry included.
///
/// Measured: the models worth using answer in about two and a half
/// seconds, and the ones that do not answer in five do not answer in
/// thirty either. Abandoning is not an error path that needs explaining to
/// the viewer -- it is the row not appearing.
const Duration similarBudget = Duration(seconds: 5);

/// How many titles are asked for. Ten is what the benchmark asks for, so
/// it is the number every measurement in `tool/recommendations` was taken
/// at; the guard drops some of them, which is what the coverage column is
/// about.
const int similarSuggestionCount = 10;

/// What the model is told it is doing. Kept apart from [askForSimilar]
/// because the providers that take a system instruction take it as its own
/// field, and one that does not can prepend it.
const String similarSystemInstruction =
    'You recommend films and television. Real, released titles only. '
    'JSON only.';

/// The question, for a title named [subject] -- `Avalon (2001)`, with the
/// year when one is known, because a title alone is ambiguous in exactly
/// the way the answers are.
///
/// The second sentence is the measured one. The same model asked for films
/// that *feel* alike rather than films that are related scores 0.85
/// against 0.73 on tone; it is a third of the difference between the best
/// model measured and the worst usable one, bought for one sentence.
String askForSimilar(String subject, {int count = similarSuggestionCount}) =>
    'Name $count films to watch next for someone who loved $subject. '
    'Prefer films that *feel* like it -- the same register, pace and '
    'texture -- over films that merely share its premise. '
    'Answer JSON only: {"films":[{"title":"","year":0,'
    '"why":"under 12 words"}]}. '
    'Real, released films only; do not include the film itself.';

/// Where suggestions come from.
///
/// An interface with one implementation ([GeminiSimilarTitles]) for two
/// reasons, and only one of them is testing. The other is that the models
/// move: a provider that retires the model this app defaults to is a
/// provider the app has to be able to be pointed away from, and the seam
/// for that is here rather than inside one vendor's request shape.
///
/// Nothing here promises the titles exist. That is [resolveSuggestions]'s
/// job, and it is not optional.
abstract interface class SimilarTitlesProvider {
  /// What is like [subject] (`Avalon (2001)`), or a [SimilarTitlesFailure].
  ///
  /// Throws rather than answering empty, because the two mean different
  /// things to everything upstream: empty is a model that answered and had
  /// nothing to say, and a failure is one that could not be asked. An
  /// empty answer is cached; a failure is not.
  Future<List<SuggestedTitle>> suggest(String subject);
}

/// The kinds of not-answering, told apart so a log line can say which.
///
/// This is the list `tool/recommendations/model_bench.py` reports a model's
/// failure as, because it is the list that turned out to matter when six
/// models were measured in an afternoon and four of them failed in four
/// different ways. A fallback to another model is only explicable
/// afterwards if the log says which of these happened.
enum SimilarTrouble {
  /// 404: the model is gone, or was never a name. Both of the models this
  /// app might have defaulted to a version earlier answer this now.
  gone('model gone'),

  /// 402 or 403: real, and not for this key. A paid tier, or a region.
  notInTier('model not in this tier'),

  /// 429: the key is over its quota. Ordinary on a free tier and the one
  /// failure here that fixes itself by waiting.
  quota('quota exhausted'),

  /// 503: the model is busy. Also fixes itself, sooner.
  busy('model busy'),

  /// The budget passed with no answer ([similarBudget]).
  tooSlow('no answer in time'),

  /// A 400 the request could not be repaired into: a parameter was named
  /// and stripped and it was still refused, or nothing was named.
  refused('request refused'),

  /// An answer arrived and was not the documented shape, or was not JSON.
  malformed('answer not understood'),

  /// No HTTP at all: no network, DNS, TLS, a host that is not there.
  unreachable('provider unreachable');

  const SimilarTrouble(this.describe);

  /// A few words for the log. Never carries the key, the model name or a
  /// URL -- the caller puts the model name beside it, and the key is
  /// written down nowhere.
  final String describe;
}

/// Why nothing was suggested. Carries [trouble] so that the caller can log
/// which of the failures it was without parsing a sentence.
final class SimilarTitlesFailure implements Exception {
  const SimilarTitlesFailure(this.trouble, [this.detail]);

  final SimilarTrouble trouble;

  /// What the provider said, when it said anything worth keeping -- a
  /// status code, the name of a parameter it refused. **Never a body that
  /// could carry the request back**, because this is written to the log.
  final String? detail;

  @override
  String toString() => detail == null
      ? 'SimilarTitlesFailure(${trouble.describe})'
      : 'SimilarTitlesFailure(${trouble.describe}: $detail)';
}
