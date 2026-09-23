/// The answer keys as the app carries them, and the question built from
/// one.
///
/// `tool/recommendations/` holds 568 rated titles across seven targets,
/// each rated on two axes that are deliberately not averaged: `grade` for
/// how relevant the connection is (3 essential … 0 not a reasonable
/// recommendation) and `tone` for what the film is like *to sit through*
/// (2 feels like it, 1 partly, 0 a different register). Read that
/// directory's README before changing anything here; it is where the
/// numbers come from.
///
/// What ships is those two ratings, a title and a year, cut by
/// `tool/recommendations/ship_keys.py` — 30 KB against 900. The reasoning,
/// the citations and the `what` lines stay in the repository, because
/// nothing on a television reads them.
///
/// **The salting is the whole of it.** A question is four films per tone
/// tier, and which four is not arbitrary: for the films that feel most
/// like the target the *least* relevant are taken, and for the films that
/// feel nothing like it the *most* relevant. So the list is stocked with
/// the two shapes that pull hardest against each other — Watchmen for
/// *Glass*, which makes the same argument about comic books and has none
/// of the quiet, and Bug, which has the thinnest connection on the list
/// and is the closest thing to sitting through it. A model that sorts by
/// how related the films are puts the first group on top and **scores
/// below chance**: 0.27 against 0.50 on the three targets the app asks
/// about. That is the point of the test, and it is why [relatednessScore]
/// exists as a thing the tests can assert rather than a claim in a
/// comment.
///
/// This is `tool/recommendations/vibe_sort.py` in Dart, including its
/// title matching, and it is meant to stay that way: the numbers the
/// README reports were measured with that file.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// Where the cut-down keys live in the bundle.
const String answerKeysAsset = 'assets/recommendations/answer_keys.json';

/// The three targets the check asks about, and why these three.
///
/// One mainstream, two obscure, which is the split the README draws: four
/// of the seven targets are obscure on purpose and the other three are
/// controls that every model scores well on.
///
///  * **Glass** is a control, so failing it is a broken model rather than
///    a weak one — and it is the README's own worked example of the
///    salt, the key that holds both Watchmen and Bug.
///  * **Avalon** is the key the README works the grade/tone divergence
///    through by name: eXistenZ shares its premise and none of its
///    temperature, and Le Samouraï has the thinnest connection on the
///    list and is the closest thing to sitting through it.
///  * **Wave Twisters** is the sparsest key measured — 7 of its 59 films
///    share its texture, against 40 of 60 around The Seventh Continent —
///    and the target one measured model turned out to be no better than
///    chance on.
///
/// Three rather than seven because the check is two calls per target and
/// has to finish while somebody is looking at it.
const List<String> checkTargets = [
  'Glass (2019)',
  'Avalon (2001)',
  'Wave Twisters (2001)',
];

/// How many films from each tone tier go into a question. Four, as
/// `vibe_sort.py`'s `PER_TIER` is, which makes 12 films and 48 scored
/// pairs per target.
const int filmsPerTier = 4;

/// What a pairwise score of 0.50 means: the model placed the nearer film
/// first as often as a coin would. Printed beside every judgement,
/// because the number says nothing on its own.
const double toneChance = 0.50;

/// One film in a key: what it is called, when it came out, and the two
/// ratings that are never averaged.
final class KeyFilm {
  const KeyFilm({
    required this.title,
    required this.year,
    required this.grade,
    required this.tone,
  });

  final String title;
  final int year;

  /// 3 essential, 2 strong, 1 defensible, 0 not a reasonable
  /// recommendation — how relevant the connection is.
  final int grade;

  /// 2 feels like it, 1 partly, 0 a different register — what the film is
  /// like to sit through.
  final int tone;

  /// How the film is written into a question and read back out of an
  /// answer: `Bug (2006)`.
  String get label => '$title ($year)';

  /// One row of the shipped asset, or null when it is not one this build
  /// can use. A row that cannot be read is dropped rather than failing
  /// the load — a key short of a film is still a key.
  static KeyFilm? fromJson(Object? json) {
    if (json is! Map) return null;
    final title = json['title'];
    final year = json['year'];
    final grade = json['grade'];
    final tone = json['tone'];
    if (title is! String || title.trim().isEmpty) return null;
    if (year is! int || grade is! int || tone is! int) return null;
    return KeyFilm(title: title.trim(), year: year, grade: grade, tone: tone);
  }
}

/// One target's answer key.
final class AnswerKey {
  const AnswerKey({required this.target, required this.films});

  /// The title the films are rated against, as it is written to a model:
  /// `Glass (2019)`.
  final String target;

  final List<KeyFilm> films;

  /// The film in this key that [title] and [year] name, or null when the
  /// key does not rate it.
  ///
  /// Matched the way `similar_resolver.dart` matches a suggestion against
  /// a catalogue, and for the same reason: a loose title with a strict
  /// year keeps the near-misses and drops the inventions. The year is
  /// allowed to be off by one, because festival and territory dates
  /// genuinely differ by one.
  KeyFilm? rating(String title, int year) {
    final wanted = keyedTitle(title);
    for (final film in films) {
      if (keyedTitle(film.title) == wanted && (film.year - year).abs() <= 1) {
        return film;
      }
    }
    return null;
  }

  static AnswerKey? fromJson(Object? json) {
    if (json is! Map) return null;
    final target = json['target'];
    final films = json['films'];
    if (target is! String || target.trim().isEmpty || films is! List) {
      return null;
    }
    final rated = [for (final film in films) ?KeyFilm.fromJson(film)];
    return rated.isEmpty
        ? null
        : AnswerKey(target: target.trim(), films: rated);
  }
}

/// The shipped keys, in the order [targets] names them.
///
/// A missing target is left out rather than thrown over: a check over two
/// keys is worse than one over three and is still a check.
Future<List<AnswerKey>> loadAnswerKeys({
  AssetBundle? bundle,
  List<String> targets = checkTargets,
}) async {
  final json = await (bundle ?? rootBundle).loadString(answerKeysAsset);
  final all = parseAnswerKeys(json);
  return [
    for (final target in targets)
      ?all.where((key) => key.target == target).firstOrNull,
  ];
}

/// Every key in the shipped asset.
///
/// Throws [FormatException] on a bundle that is not the asset at all —
/// which is a build that shipped wrong, not a runtime condition, and is
/// worth failing loudly in the one test that reads the real file.
List<AnswerKey> parseAnswerKeys(String json) {
  final decoded = jsonDecode(json);
  final keys = decoded is Map ? decoded['keys'] : null;
  if (keys is! List) {
    throw const FormatException('answer keys: no "keys" list');
  }
  return [for (final key in keys) ?AnswerKey.fromJson(key)];
}

/// A title reduced to what two spellings of the same film share.
///
/// `vibe_sort.py`'s `split_title`, which lower-cases and drops everything
/// that is not a letter or a digit, and — unlike the resolver's own
/// normalisation — keeps a leading article, because the answer to this
/// question is a list handed back from a list and there is nothing for an
/// article to differ about.
String keyedTitle(String title) =>
    title.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

/// The title and year in `Bug (2006)`, as the scorer reads an answer
/// back: the last four-digit year in the string, and whatever is left
/// once it is taken out.
({String title, String? year}) splitLabel(String label) {
  final years = RegExp(r'1[89]\d\d|20\d\d').allMatches(label).toList();
  if (years.isEmpty) return (title: keyedTitle(label), year: null);
  final year = years.last.group(0)!;
  final stripped = label.replaceAll(
    RegExp(r'\(?\b(1[89]\d\d|20\d\d)\b\)?'),
    '',
  );
  return (title: keyedTitle(stripped), year: year);
}

/// One target's salted list, and the scoring of an answer to it.
final class ToneQuestion {
  ToneQuestion._(this.key, this.tiers);

  final AnswerKey key;

  /// Films by tone tier, nearest first: `tiers[0]` feels most like the
  /// target, `tiers[2]` least.
  final List<List<KeyFilm>> tiers;

  /// The question for [key], or null when the key has no film in one of
  /// the three tiers and so nothing to sort.
  ///
  /// Sorting each tier by how far it pulls *against* its tone is what
  /// salts the list: for the films that feel most like the target the
  /// least relevant are taken, and for the ones that feel nothing like it
  /// the most relevant. Tone 1 is ordered by the same rule as tone 0,
  /// arbitrarily but stably. This is `vibe_sort.py`'s `questions()`.
  static ToneQuestion? forKey(AnswerKey key, {int perTier = filmsPerTier}) {
    final tiers = <List<KeyFilm>>[];
    for (final tone in const [2, 1, 0]) {
      final pool = [
        for (final film in key.films)
          if (film.tone == tone) film,
      ];
      if (pool.isEmpty) return null;
      _stableSort(
        pool,
        (a, b) => tone == 2 ? a.grade - b.grade : b.grade - a.grade,
      );
      tiers.add(pool.take(perTier).toList());
    }
    return ToneQuestion._(key, tiers);
  }

  /// [List.sort] is not stable, and which of several films of the same
  /// grade is taken decides what the question contains. The order in the
  /// key is the tie-break, so the question is the one the benchmark
  /// measured rather than one of several the sort might have produced.
  static void _stableSort(
    List<KeyFilm> films,
    int Function(KeyFilm, KeyFilm) by,
  ) {
    final indexed =
        [for (var i = 0; i < films.length; i++) (film: films[i], at: i)]
          ..sort((a, b) {
            final ranked = by(a.film, b.film);
            return ranked != 0 ? ranked : a.at.compareTo(b.at);
          });
    films.setAll(0, [for (final entry in indexed) entry.film]);
  }

  /// Every film in the question, in tier order.
  List<KeyFilm> get films => [for (final tier in tiers) ...tier];

  /// The films as they are handed to the model, shuffled so the tiers are
  /// not the answer. [seed] fixes the order, so two runs of the check ask
  /// the same question and their scores can be compared.
  List<String> shuffled(int seed) =>
      [for (final film in films) film.label]..shuffle(Random(seed));

  /// Pairwise tone accuracy, weighted by how much of the list came back:
  /// over every pair of films from different tone tiers, how often the
  /// model placed the one that feels nearer first.
  ///
  /// The weighting is what stops a model scoring 1.00 by naming the two
  /// films it was surest of and dropping the rest.
  double score(List<String> order) {
    final want = <String, int>{};
    final byYear = <String, List<String>>{};
    for (var tier = 0; tier < tiers.length; tier++) {
      for (final film in tiers[tier]) {
        final split = splitLabel(film.label);
        final id = '${split.title}|${split.year}';
        want[id] = tier;
        (byYear[split.year ?? ''] ??= []).add(id);
      }
    }
    final place = <String, int>{};
    for (var i = 0; i < order.length; i++) {
      final answered = splitLabel(order[i]);
      final exact = '${answered.title}|${answered.year}';
      // The model wrote a title that is not one of ours character for
      // character: take a film of the same year whose title is a prefix
      // of what it wrote or the other way round, which is what catches a
      // subtitle dropped or added. Six characters, so that a short title
      // cannot swallow a long one.
      final id = want.containsKey(exact)
          ? exact
          : (byYear[answered.year ?? ''] ?? const <String>[]).where((
              candidate,
            ) {
              final title = candidate.split('|').first;
              return answered.title.length >= 6 &&
                  (title.startsWith(answered.title) ||
                      answered.title.startsWith(title));
            }).firstOrNull;
      if (id != null && !place.containsKey(id)) place[id] = i;
    }
    var right = 0;
    var total = 0;
    for (final near in want.entries) {
      for (final far in want.entries) {
        if (near.value >= far.value) continue;
        final a = place[near.key];
        final b = place[far.key];
        if (a == null || b == null) continue;
        total++;
        if (a < b) right++;
      }
    }
    final accuracy = total == 0 ? 0.0 : right / total;
    return accuracy * (place.length / want.length);
  }

  /// What answering by relatedness alone would score on this question —
  /// the trap, measured rather than asserted.
  ///
  /// It is below [toneChance] on the targets the app asks about, which is
  /// the one claim this whole file rests on, and the tests read it from
  /// here.
  double get relatednessScore {
    final ranked = films.toList();
    _stableSort(ranked, (a, b) => b.grade - a.grade);
    return score([for (final film in ranked) film.label]);
  }
}
