/// Asking a model what a title is like: the question, and what answering
/// it can go wrong with.
///
/// The model is the cheap half of "More like this" and the half that is
/// wrong. What is measured about it lives in `tool/recommendations/` --
/// seven target titles, 568 rated titles, every model scored on
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
///
/// One thing in this file is **not** from that measurement, and says so
/// where it lives: the question is now two questions, one for a film and
/// one for a series, and only the film one has ever been measured. The
/// 528 researched titles are films, asked about films. (The keys hold
/// 568 now; the 40 added by pooling include series, but no *target* is
/// a series, which is the part that is unmeasured.)
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

/// The shape of the answer, the same in both questions.
///
/// `titles` and not `films`, because the key is one more place the model
/// is told what kind of thing is wanted, and it is told twice already.
/// `kind` is asked for outright rather than hoped for: the model knows
/// whether it meant the series or the film made of it, and a suggestion
/// that says so is one catalogue search instead of two
/// ([resolveSuggestions]).
const String _answerShape =
    'Answer JSON only: {"titles":[{"title":"","year":0,'
    '"kind":"film|series","why":"under 12 words"}]}.';

/// The question, for a title named [subject] -- `Avalon (2001)`, with the
/// year when one is known, because a title alone is ambiguous in exactly
/// the way the answers are -- and [about], which is what the viewer is
/// standing on.
///
/// **Both questions ask for both kinds.** A model told to name films names
/// films, which is what made a series page answer with ten of them; and a
/// model told to name films is also right to answer *Æon Flux* for *Wave
/// Twisters*, which is why neither question shuts the other kind out.
///
/// **The second sentence is the measured one**, and in the film question
/// it is the measured wording unchanged. The same model asked for films
/// that *feel* alike rather than films that are related scores 0.85
/// against 0.73 on tone; it is a third of the difference between the best
/// model measured and the worst usable one, bought for one sentence.
///
/// **The kind preference is a judgement, not a measurement.** Every number
/// in `tool/recommendations/` was taken with films as the subject and
/// films as the answers; nothing about series was measured at all. That a
/// viewer on a show page mostly wants another show is what we think a
/// viewer wants, and the series question's wording -- the same sentence
/// with the noun swapped -- inherits none of the film numbers' authority.
/// The benchmarks in `tool/recommendations/` still carry the old film-only
/// prompt, so the app and the measurement no longer ask the same thing;
/// the README says so.
///
/// Changing any of this wording means changing [similarQuestionVersion],
/// or the change is one nobody who has already opened a title will see.
String askForSimilar(
  String subject, {
  required SuggestedKind about,
  int count = similarSuggestionCount,
}) => switch (about) {
  SuggestedKind.film =>
    'Name $count films or television series to watch next for someone who '
        'loved $subject. '
        'Prefer films that *feel* like it -- the same register, pace and '
        'texture -- over films that merely share its premise. '
        '$_answerShape '
        'Real, released titles only; do not include the film itself.',
  SuggestedKind.series =>
    'Name $count television series or films to watch next for someone who '
        'loved $subject. '
        'Prefer series that *feel* like it -- the same register, pace and '
        'texture -- over series that merely share its premise; a film that '
        'genuinely fits belongs in the answer too. '
        '$_answerShape '
        'Real, released titles only; do not include the series itself.',
};

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
  /// What is like [subject] (`Avalon (2001)`), which is a film or a
  /// series ([about]) -- or a [SimilarTitlesFailure].
  ///
  /// [about] has no default. A film and a series are different questions
  /// ([askForSimilar]), and a default would be one of them asked quietly
  /// about the other, which is the bug this parameter exists to end.
  ///
  /// Throws rather than answering empty, because the two mean different
  /// things to everything upstream: empty is a model that answered and had
  /// nothing to say, and a failure is one that could not be asked. An
  /// empty answer is cached; a failure is not.
  Future<List<SuggestedTitle>> suggest(
    String subject, {
    required SuggestedKind about,
  });
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
