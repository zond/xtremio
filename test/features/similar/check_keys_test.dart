/// The shipped answer keys, and the one claim the check rests on.
///
/// **The salt is the test.** If a model could score well on the sort by
/// knowing which films are related to the target — which every model
/// knows, and which the recommendation call already measures — then the
/// judgement number would be telling a viewer nothing they could not have
/// guessed. The keys are stocked so that answering that way scores
/// *below* chance, and that is measured here against the file that
/// actually ships rather than asserted in a comment.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/similar/check_keys.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<AnswerKey> shipped;

  setUpAll(() async {
    shipped = parseAnswerKeys(await rootBundle.loadString(answerKeysAsset));
  });

  test('the shipped asset parses and carries every field the check needs', () {
    // 568 titles across seven targets, as `tool/recommendations/README.md`
    // says. A key short of its films would not fail anything loudly; it
    // would quietly make the check easier.
    expect(shipped, hasLength(7));
    expect(shipped.fold<int>(0, (all, key) => all + key.films.length), 568);
    for (final key in shipped) {
      expect(key.target, matches(RegExp(r'^.+ \((1[89]|20)\d\d\)$')));
      for (final film in key.films) {
        expect(film.title, isNotEmpty);
        expect(film.year, greaterThan(1890));
        expect(film.grade, inInclusiveRange(0, 3));
        expect(film.tone, inInclusiveRange(0, 2));
      }
    }
  });

  test('the three targets the check asks about are all in the asset', () async {
    final keys = await loadAnswerKeys();

    expect([for (final key in keys) key.target], checkTargets);
    // One mainstream control and two of the four obscure targets, which
    // is where the models separate.
    expect(checkTargets, contains('Glass (2019)'));
    expect(checkTargets, contains('Avalon (2001)'));
    expect(checkTargets, contains('Wave Twisters (2001)'));
  });

  test('answering by relatedness scores below chance on all three', () async {
    final keys = await loadAnswerKeys();
    final scores = [
      for (final key in keys) ToneQuestion.forKey(key)!.relatednessScore,
    ];

    // Every one of them below chance, not merely the average: a target
    // where relatedness pays would let a model bank a good number on one
    // key and guess the others.
    for (final score in scores) {
      expect(score, lessThan(toneChance));
    }
    // 0.27 as measured when these three were picked. Loose enough that a
    // re-rated film does not fail the suite, tight enough that a key
    // whose salt has been folded away does.
    final mean = scores.reduce((a, b) => a + b) / scores.length;
    expect(mean, lessThan(0.35));
  });

  test(
    'a question is four films from each tone tier, the awkward ones',
    () async {
      final glass = (await loadAnswerKeys(targets: ['Glass (2019)'])).single;
      final question = ToneQuestion.forKey(glass)!;

      expect(question.tiers, hasLength(3));
      expect(question.films, hasLength(filmsPerTier * 3));
      // The films that feel most like Glass are the *least* relevant of the
      // ones that do, and the films that feel nothing like it are the most
      // relevant of those -- which is the salt, and which is why Watchmen
      // and Bug are both in the list. See `tool/recommendations/README.md`.
      expect([
        for (final film in question.tiers.first) film.title,
      ], contains('Bug'));
      expect([
        for (final film in question.tiers.last) film.title,
      ], contains('Watchmen'));
      for (final film in question.tiers.first) {
        expect(film.tone, 2);
        expect(film.grade, lessThanOrEqualTo(1));
      }
      for (final film in question.tiers.last) {
        expect(film.tone, 0);
        expect(film.grade, greaterThanOrEqualTo(2));
      }
    },
  );

  test('the question is the one vibe_sort.py builds, film for film', () async {
    final glass = (await loadAnswerKeys(targets: ['Glass (2019)'])).single;
    final question = ToneQuestion.forKey(glass)!;

    // Pinned against the Python that measured the table in the README,
    // run over the same key. Five of Glass's nineteen tonally-identical
    // films share the lowest grade and four of them are taken, so which
    // four is a question about the sort and not only about the rule.
    expect(
      [for (final film in question.films) film.label],
      [
        'Lady in the Water (2006)',
        'The Happening (2008)',
        'The Three Faces of Eve (1957)',
        'Bug (2006)',
        'Chronicle (2012)',
        'Shutter Island (2010)',
        'The Visit (2015)',
        'Old (2021)',
        'Super (2010)',
        'Birdman or (The Unexpected Virtue of Ignorance) (2014)',
        'Watchmen (2009)',
        'Joker (2019)',
      ],
    );
  });

  test('a year one out is the same film, two out is another', () async {
    final glass = (await loadAnswerKeys(targets: ['Glass (2019)'])).single;

    // Festival and territory dates genuinely differ by one, which is why
    // a suggestion a year out is rated rather than counted a miss -- and
    // why two years out is not: that is a different film.
    expect(glass.rating('Watchmen', 2009)?.grade, 3);
    expect(glass.rating('Watchmen', 2008)?.grade, 3);
    expect(glass.rating('Watchmen', 2010)?.grade, 3);
    expect(glass.rating('Watchmen', 2011), isNull);
    expect(glass.rating('A film nobody wrote', 2009), isNull);
  });

  test('the tone order scores 1.00 and reversing it scores 0.00', () async {
    final keys = await loadAnswerKeys();
    for (final key in keys) {
      final question = ToneQuestion.forKey(key)!;
      final perfect = [for (final film in question.films) film.label];

      expect(question.score(perfect), 1);
      expect(question.score(perfect.reversed.toList()), 0);
    }
  });

  test(
    'an answer that drops half the list is scored on half the list',
    () async {
      final glass = (await loadAnswerKeys(targets: ['Glass (2019)'])).single;
      final question = ToneQuestion.forKey(glass)!;
      final perfect = [for (final film in question.films) film.label];

      // Right about everything it said, and it said half. A model cannot
      // score 1.00 by naming the two films it was surest of.
      expect(question.score(perfect.take(6).toList()), closeTo(0.5, 0.001));
    },
  );

  test('the shuffle is fixed, so two runs ask the same question', () async {
    final glass = (await loadAnswerKeys(targets: ['Glass (2019)'])).single;
    final question = ToneQuestion.forKey(glass)!;

    expect(question.shuffled(0), question.shuffled(0));
    expect(question.shuffled(0), isNot(question.shuffled(1)));
    // Every film once, whatever the seed.
    expect(question.shuffled(0).toSet(), hasLength(filmsPerTier * 3));
  });

  test('a title spelled a little differently still counts', () async {
    final glass = (await loadAnswerKeys(targets: ['Glass (2019)'])).single;
    final question = ToneQuestion.forKey(glass)!;
    final loose = [
      for (final film in question.films)
        film.title == 'Birdman or (The Unexpected Virtue of Ignorance)'
            ? 'Birdman (2014)'
            : film.label,
    ];

    expect(question.score(loose), 1);
  });
}
