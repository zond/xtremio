/// A model that answers the check's two questions without a network, and
/// a clock it winds on as it does.
///
/// The three named models are the three the check has to tell apart, and
/// the middle one is why the check exists: a model that sorts by how
/// *related* the films are must score **below** chance, not above it, or
/// the answer keys are not salted and the number is decoration.
library;

import 'dart:async';
import 'dart:math';

import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/similar/check_keys.dart';
import 'package:xtremio/features/similar/check_model.dart';

/// Time as the fake model spends it: no waiting, and a `slowest` a test
/// can assert.
final class FakeCheckClock {
  DateTime _now = DateTime.utc(2026, 9, 22);

  DateTime now() => _now;

  void advance(Duration by) => _now = _now.add(by);
}

/// How a sort is answered: the films back, in some order.
typedef FakeOrdering = List<String> Function(String target, List<String> films);

/// How the recommendation question is answered.
typedef FakeSuggesting = List<SuggestedTitle> Function(String target);

final class FakeCheckModel implements ModelCheckProvider {
  FakeCheckModel({
    required this.ordering,
    this.suggesting = _nothing,
    this.clock,
    this.orderTakes = Duration.zero,
    this.suggestTakes = Duration.zero,
  });

  /// A model that attends to what a film is like: the key's own tone
  /// order, which is a perfect answer.
  factory FakeCheckModel.attentive(
    List<AnswerKey> keys, {
    FakeSuggesting? suggesting,
    FakeCheckClock? clock,
    Duration orderTakes = Duration.zero,
    Duration suggestTakes = Duration.zero,
  }) => FakeCheckModel(
    ordering: _sortedBy(keys, (film) => film.tone),
    suggesting: suggesting ?? _essentials(keys),
    clock: clock,
    orderTakes: orderTakes,
    suggestTakes: suggestTakes,
  );

  /// The trap: a model that sorts by how related the films are, which is
  /// the thing that is easy to know and not the thing that was asked.
  factory FakeCheckModel.relating(
    List<AnswerKey> keys, {
    FakeSuggesting? suggesting,
    FakeCheckClock? clock,
  }) => FakeCheckModel(
    ordering: _sortedBy(keys, (film) => film.grade),
    suggesting: suggesting ?? _essentials(keys),
    clock: clock,
  );

  /// A model that is not answering the question at all.
  factory FakeCheckModel.guessing(
    int seed, {
    FakeSuggesting? suggesting,
    FakeCheckClock? clock,
  }) => FakeCheckModel(
    ordering: (target, films) => films.toList()..shuffle(Random(seed)),
    suggesting: suggesting ?? _nothing,
    clock: clock,
  );

  final FakeOrdering ordering;
  final FakeSuggesting suggesting;
  final FakeCheckClock? clock;
  final Duration orderTakes;
  final Duration suggestTakes;

  /// Every target asked to sort, in order.
  final List<String> ordered = [];

  /// Every subject asked to recommend for, in order.
  final List<String> asked = [];

  /// Held open until a test completes it, for the question that has to be
  /// in flight when the viewer leaves the screen.
  Completer<void>? holding;

  @override
  Future<List<String>> order(String target, List<String> films) async {
    ordered.add(target);
    if (holding != null) await holding!.future;
    clock?.advance(orderTakes);
    return ordering(target, films);
  }

  @override
  Future<List<SuggestedTitle>> suggest(String subject) async {
    asked.add(subject);
    clock?.advance(suggestTakes);
    return suggesting(subject);
  }

  static List<SuggestedTitle> _nothing(String target) => const [];

  /// Everything a key calls essential, as a model would name it: a
  /// perfect answer to the recommendation question.
  static FakeSuggesting _essentials(List<AnswerKey> keys) => (target) {
    final key = keys.where((key) => key.target == target).firstOrNull;
    if (key == null) return const [];
    return [
      for (final film in key.films)
        if (film.grade == 3)
          SuggestedTitle(title: film.title, year: film.year, why: 'measured'),
    ].take(10).toList();
  };

  /// Orders a question's films by one of the key's two ratings, highest
  /// first, stably — so that ordering by `tone` is a perfect answer and
  /// ordering by `grade` is the trap.
  static FakeOrdering _sortedBy(
    List<AnswerKey> keys,
    int Function(KeyFilm) rating,
  ) => (target, films) {
    final key = keys.where((key) => key.target == target).firstOrNull;
    if (key == null) return films;
    final rated = {for (final film in key.films) film.label: rating(film)};
    final indexed =
        [
          for (var i = 0; i < films.length; i++) (label: films[i], at: i),
        ]..sort((a, b) {
          final ranked = (rated[b.label] ?? -1).compareTo(rated[a.label] ?? -1);
          return ranked != 0 ? ranked : a.at.compareTo(b.at);
        });
    return [for (final entry in indexed) entry.label];
  };
}
