/// "Test this model": six calls, a few seconds, and three numbers that
/// say whether the model a viewer configured can do this job.
///
/// The row is one model call whose answer goes on screen as posters, and
/// the models differ enormously — `tool/recommendations/README.md` has six
/// of them measured, one of which was below chance on both axes and
/// invented twenty titles in seventy-one. A viewer who has pasted a key
/// and typed a model name has no way of knowing which of those they have.
/// This tells them, against the same keys the benchmark uses.
///
/// Three numbers and not one, because one number hides the failure that
/// matters:
///
///  1. **Judgement** ([ModelCheckReport.judgement]) — a sort. The model is
///     handed twelve films from a key and asked which *feel* most like the
///     target; the answer is scored pairwise against the key's `tone`. The
///     list is salted (see `check_keys.dart`) so that answering by how
///     *related* the films are scores below chance, which is what makes
///     the number worth having: it cannot be had by knowing what is
///     related, only by attending to what a film is like.
///  2. **Agreement** ([ModelCheckReport.agreement]) — one ordinary
///     recommendation call per target, the same question the row asks,
///     scored against the key's `grade`. A suggestion the key does not
///     rate counts as nothing, so the number is a floor and not a mark.
///  3. **Invented films** ([ModelCheckReport.invented]) — of the
///     suggestions the key does not rate, how many no catalogue has. This
///     is the veto. A model can sort sensibly and still fabricate one
///     title in six when asked to generate, and a fabricated title is not
///     a missing poster — it is a real poster for a film that does not
///     exist, because searching an invented title *succeeds*
///     (`similar_resolver.dart` is where that is explained).
///
/// And the slowest call, because five seconds is the budget the row lives
/// under ([similarBudget]) and the best recommender measured takes a
/// hundred and fifty-three.
///
/// **Nothing here ever sees the key.** The provider holds it; this asks
/// questions and counts answers, and a failure comes back as a
/// [SimilarTrouble], which is a handful of words with no URL and no
/// credential in it.
library;

import 'dart:async';

import '../../core/core.dart';
import 'check_keys.dart';
import 'similar_resolver.dart';
import 'similar_titles.dart';

/// Where the check's two questions go.
///
/// Two, because the sort and the recommendation are different questions
/// and the second catches what the first structurally cannot: every film
/// in a sort is already in the key, so a sort can never reveal an
/// invented one.
///
/// An interface for the reason [SimilarTitlesProvider] is one, and the
/// same seam: a test answers it without a network.
abstract interface class ModelCheckProvider {
  /// [films] ordered by how much each one feels like [target], most alike
  /// first. The answer is the same labels back — `Bug (2006)` — and a
  /// short answer is an answer, scored on what came back.
  Future<List<String>> order(String target, List<String> films);

  /// The row's own question, unchanged: what to watch after [subject].
  ///
  /// No kind, because every [subject] here is a key's target and every
  /// key's target is a film. The row asks a film and a series different
  /// questions ([askForSimilar]) and only the film one has a key to be
  /// scored against, so this is the film one.
  Future<List<SuggestedTitle>> suggest(String subject);
}

/// How many suggestions in every six may be invented before the model is
/// unusable whatever else it scored.
///
/// One. A row of ten with two films that do not exist is not a row that
/// is 80% right; it is a row a viewer cannot trust any of, because the
/// two that are wrong look exactly like the eight that are not.
const int inventedVeto = 6;

/// What the check found.
final class ModelCheckReport {
  const ModelCheckReport({
    required this.judgement,
    required this.agreement,
    required this.invented,
    required this.suggested,
    required this.slowest,
    required this.targets,
  });

  /// Pairwise tone accuracy over the three sorts, 0 to 1. [toneChance] is
  /// what a coin scores and is shown beside it.
  final double judgement;

  /// How much of what the model recommended the keys rate, 0 to 1, with
  /// everything outside the keys counted as nothing.
  final double agreement;

  /// Suggestions that are not in a key and that no catalogue has.
  final int invented;

  /// How many suggestions were made in all, across the three targets.
  final int suggested;

  /// The longest single call. The row is abandoned at [similarBudget].
  final Duration slowest;

  /// How many targets were actually asked about.
  final int targets;

  /// The model invents films at a rate the row cannot carry.
  bool get inventsFilms =>
      suggested > 0 && invented * inventedVeto >= suggested;

  /// No call came back inside the budget the row lives under, so there
  /// would be no row even if every number above were perfect.
  bool get tooSlow => slowest > similarBudget;

  /// Judging feel no better than a coin, which is what the row is for.
  bool get noBetterThanChance => judgement < toneChance;

  /// Nothing disqualifying: the row would appear, in time, with films
  /// that exist and an order worth having.
  bool get usable => !inventsFilms && !tooSlow && !noBetterThanChance;

  /// The one line at the top, in the order the failures disqualify.
  ///
  /// The veto first: it is the only one of these a good score cannot
  /// argue with.
  String get verdict {
    if (inventsFilms) return 'Not usable: it invents films.';
    if (tooSlow) return 'Too slow: the row would be abandoned.';
    if (noBetterThanChance) {
      return 'Weak: no better than chance at judging what a film is like.';
    }
    return 'Usable.';
  }
}

/// One run of the check.
///
/// Built per press and thrown away after, because both the key and the
/// model are preferences a viewer can change between one press and the
/// next.
final class ModelCheck {
  ModelCheck({
    required this.provider,
    this.search = cinemetaSearch,
    this.loadKeys = loadAnswerKeys,
    this.clock = DateTime.now,
    this.seed = 0,
  });

  final ModelCheckProvider provider;

  /// How a suggestion is checked against a catalogue — injected in the
  /// shape and for the reason `PlaybackScope.archiveSniff` is.
  final CatalogueSearch search;

  /// The shipped keys. A function so a test can hand over a small one.
  final Future<List<AnswerKey>> Function() loadKeys;

  /// Where the timing of a call comes from — a parameter, never
  /// [DateTime.now] called in the middle of the arithmetic, so a test can
  /// say what a call took.
  final DateTime Function() clock;

  /// Fixes the shuffle of each question's film list, so two runs ask the
  /// same thing and their scores can be compared.
  final int seed;

  bool _cancelled = false;

  /// The viewer left the screen. Nothing further is asked, and [run]
  /// answers null rather than a report over half the targets.
  ///
  /// It cannot abandon a call already in flight — the provider owns its
  /// own socket and its own budget — but it is what stops the next five.
  void cancel() => _cancelled = true;

  /// Asks, counts, and answers.
  ///
  /// Null means cancelled. A [SimilarTitlesFailure] means the model did
  /// not answer, and is thrown rather than folded into a low score: a
  /// model that cannot be reached has not been measured.
  Future<ModelCheckReport?> run() async {
    final keys = await loadKeys();
    if (_cancelled) return null;

    var judgement = 0.0;
    var agreement = 0.0;
    var scored = 0;
    var suggested = 0;
    var invented = 0;
    var slowest = Duration.zero;

    for (final key in keys) {
      final question = ToneQuestion.forKey(key);
      if (question == null) continue;

      final films = question.shuffled(seed);
      final (order, sortTook) = await _timed(
        () => provider.order(key.target, films),
      );
      if (order == null) return null;
      if (sortTook > slowest) slowest = sortTook;
      judgement += question.score(order);

      final (answer, askTook) = await _timed(
        () => provider.suggest(key.target),
      );
      if (answer == null) return null;
      if (askTook > slowest) slowest = askTook;

      var rated = 0.0;
      for (final suggestion in answer) {
        suggested++;
        final film = key.rating(suggestion.title, suggestion.year);
        if (film != null) {
          // 3 essential … 0 not a reasonable recommendation, as a
          // fraction of the best a suggestion could have been.
          rated += film.grade / 3;
          continue;
        }
        if (!await _exists(suggestion)) invented++;
        if (_cancelled) return null;
      }
      if (answer.isNotEmpty) agreement += rated / answer.length;
      scored++;
    }

    if (_cancelled) return null;
    return ModelCheckReport(
      judgement: scored == 0 ? 0 : judgement / scored,
      agreement: scored == 0 ? 0 : agreement / scored,
      invented: invented,
      suggested: suggested,
      slowest: slowest,
      targets: scored,
    );
  }

  /// One call, and what it took. A null answer is a cancelled run.
  Future<(T?, Duration)> _timed<T>(Future<T> Function() call) async {
    final started = clock();
    final answer = await call();
    final took = clock().difference(started);
    return _cancelled ? (null, took) : (answer, took);
  }

  /// Whether a catalogue has this film.
  ///
  /// Asked through [resolveSuggestions], which is the guard the row
  /// itself passes every suggestion through, so what counts as invented
  /// here is exactly what would fail to reach the screen there —
  /// including its rule that a year two apart is a different film rather
  /// than a release date.
  ///
  /// One suggestion at a time, because the guard collapses duplicates by
  /// id and a model that named the same film twice would otherwise look
  /// as though it had invented one. A subject id nothing can match, since
  /// the check has no title on screen to exclude.
  Future<bool> _exists(SuggestedTitle suggestion) async {
    final resolved = await resolveSuggestions(
      [suggestion],
      subjectId: '',
      search: search,
    );
    return resolved.isNotEmpty;
  }
}
