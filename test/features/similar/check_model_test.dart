/// "Test this model", with nothing on the network.
///
/// Everything here runs against the answer keys that actually ship and a
/// model that answers out of a function, so what is measured is the real
/// arithmetic over the real file.
///
/// Three of these matter more than the rest. **A model that sorts by
/// relatedness scores below chance** — that is the salting working, and
/// without it the judgement number would be measuring what every model
/// already knows. **An invented film is counted as invented**, because
/// that is the one failure a sort can never reveal and the one that
/// reaches the screen as a real poster for a film that does not exist.
/// And **a provider that fails reports the failure**, because a model
/// that could not be asked has not been measured and must not be given a
/// low score as though it had been.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/similar/check_keys.dart';
import 'package:xtremio/features/similar/check_model.dart';
import 'package:xtremio/features/similar/similar_titles.dart';

import '../../support/fake_model_check.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<AnswerKey> keys;

  /// Every title a catalogue was asked for, so a test can say that the
  /// check asked about nothing it already knew.
  late List<String> searched;

  /// A catalogue that has every film in the keys and nothing else, which
  /// is what makes a suggestion outside them an invention.
  Future<List<Map<String, dynamic>>> catalogue(
    String type,
    String query,
  ) async {
    searched.add(query);
    if (type != 'movie') return const [];
    for (final key in keys) {
      for (final film in key.films) {
        if (film.title.toLowerCase() == query.toLowerCase()) {
          return [
            {
              'id': 'tt-${film.title.hashCode}',
              'imdb_id': 'tt-${film.title.hashCode}',
              'type': 'movie',
              'name': film.title,
              'releaseInfo': '${film.year}',
            },
          ];
        }
      }
    }
    return const [];
  }

  ModelCheck checking(
    ModelCheckProvider provider, {
    FakeCheckClock? clock,
    int seed = 0,
  }) => ModelCheck(
    provider: provider,
    search: catalogue,
    loadKeys: loadAnswerKeys,
    clock: clock == null ? DateTime.now : clock.now,
    seed: seed,
  );

  setUpAll(() async {
    keys = await loadAnswerKeys();
  });

  setUp(() => searched = []);

  test('a model that answers well scores well', () async {
    final report = (await checking(FakeCheckModel.attentive(keys)).run())!;

    expect(report.targets, 3);
    expect(report.judgement, 1);
    expect(report.agreement, 1);
    expect(report.invented, 0);
    expect(report.usable, isTrue);
    expect(report.verdict, 'Usable.');
    // Everything it named was in a key, so no catalogue was troubled: the
    // check only asks about what it cannot already vouch for.
    expect(searched, isEmpty);
  });

  test('a model that answers randomly scores near chance', () async {
    final scores = <double>[];
    for (var seed = 0; seed < 40; seed++) {
      final report = (await checking(FakeCheckModel.guessing(seed)).run())!;
      scores.add(report.judgement);
    }
    final mean = scores.reduce((a, b) => a + b) / scores.length;

    // One run of 144 pairs is noisy -- a standard deviation of about 0.08
    // -- so the claim is about the average of forty, which sits within
    // 0.03 of chance.
    expect(mean, closeTo(toneChance, 0.06));
  });

  test('a model that sorts by relatedness scores below chance', () async {
    final report = (await checking(FakeCheckModel.relating(keys)).run())!;

    // The whole reason the sort is worth running. Answering with what is
    // *related* -- the thing every model knows and the thing the
    // recommendation call already measures -- is punished rather than
    // rewarded, because the list is stocked with films that are closely
    // related and feel nothing alike and with films barely related that
    // feel identical.
    expect(report.judgement, lessThan(toneChance));
    expect(report.noBetterThanChance, isTrue);
    expect(report.verdict, startsWith('Weak:'));
    // And it is not merely a hair under: the trap bites.
    expect(report.judgement, lessThan(0.40));
  });

  test('an invented film is counted as invented', () async {
    final report = (await checking(
      FakeCheckModel.attentive(
        keys,
        suggesting: (target) => [
          // Five the key rates, and one that does not exist. An invented
          // title is not a gap in the row: searching it succeeds often
          // enough to put a real poster under a made-up name.
          for (final film in _fiveFrom(keys, target))
            SuggestedTitle(title: film.title, year: film.year, why: 'real'),
          const SuggestedTitle(
            title: 'Heat and Bone',
            year: 2019,
            why: 'a model made this up',
          ),
        ],
      ),
    ).run())!;

    expect(report.invented, 3, reason: 'one per target, three targets');
    expect(report.suggested, 18);
    // One in six is the veto, and it does not matter what else it scored.
    expect(report.inventsFilms, isTrue);
    expect(report.usable, isFalse);
    expect(report.verdict, 'Not usable: it invents films.');
    expect(report.judgement, 1, reason: 'it sorted perfectly and is still out');
    expect(searched, contains('Heat and Bone'));
  });

  test('a film outside the keys that exists is not an invention', () async {
    // The number is conservative on purpose about *agreement* -- a film
    // nobody researched scores nothing -- but not about honesty. A real
    // film the keys do not rate is a real film.
    final real = keys.last.films.first;
    final report = (await checking(
      FakeCheckModel.attentive(
        keys,
        suggesting: (target) => [
          SuggestedTitle(title: real.title, year: real.year, why: 'real'),
        ],
      ),
    ).run())!;

    expect(report.invented, lessThan(3));
    expect(searched, contains(real.title));
  });

  test('a film named twice is not an invention the second time', () async {
    // The guard collapses duplicates by id -- two suggestions can resolve
    // to one item where a model names a film and its re-release -- so
    // asking it about a whole answer at once would count the second
    // naming as a title no catalogue has. It is asked one at a time.
    final real = keys.last.films.first;
    final twice = SuggestedTitle(
      title: real.title,
      year: real.year,
      why: 'named twice',
    );
    final report = (await checking(
      FakeCheckModel.attentive(keys, suggesting: (target) => [twice, twice]),
    ).run())!;

    expect(report.invented, 0);
    expect(report.suggested, 6);
  });

  test(
    'a provider that fails reports the failure rather than a number',
    () async {
      final check = checking(
        FakeCheckModel(
          ordering: (target, films) =>
              throw const SimilarTitlesFailure(SimilarTrouble.gone, '404'),
        ),
      );

      await expectLater(
        check.run(),
        throwsA(
          isA<SimilarTitlesFailure>().having(
            (failure) => failure.trouble,
            'trouble',
            SimilarTrouble.gone,
          ),
        ),
      );
    },
  );

  test('the slowest call is what is reported, not the total', () async {
    final clock = FakeCheckClock();
    final report = (await checking(
      FakeCheckModel.attentive(
        keys,
        clock: clock,
        orderTakes: const Duration(milliseconds: 1200),
        suggestTakes: const Duration(milliseconds: 6500),
      ),
      clock: clock,
    ).run())!;

    expect(report.slowest, const Duration(milliseconds: 6500));
    // Past the budget the row lives under, so there would be no row
    // however well it judged.
    expect(report.tooSlow, isTrue);
    expect(report.usable, isFalse);
    expect(report.verdict, 'Too slow: the row would be abandoned.');
  });

  test('a model inside the budget is not called slow', () async {
    final clock = FakeCheckClock();
    final report = (await checking(
      FakeCheckModel.attentive(
        keys,
        clock: clock,
        orderTakes: const Duration(milliseconds: 2400),
        suggestTakes: const Duration(milliseconds: 2400),
      ),
      clock: clock,
    ).run())!;

    expect(report.slowest, lessThan(similarBudget));
    expect(report.tooSlow, isFalse);
  });

  test('cancelling stops the calls that have not been made', () async {
    final model = FakeCheckModel.attentive(keys)..holding = Completer<void>();
    final check = checking(model);

    final running = check.run();
    await pumpEventQueue();
    expect(model.ordered, hasLength(1), reason: 'the first call is away');
    check.cancel();
    model.holding!.complete();

    expect(await running, isNull, reason: 'half a check is not a report');
    expect(model.ordered, hasLength(1));
    expect(model.asked, isEmpty, reason: 'the other five were never made');
  });

  test('the veto is what a report says, whatever else is wrong', () async {
    // A model can be slow *and* inventing, and it is the inventions that
    // are said: waiting is a thing a viewer can decide about, and a row
    // of films that do not exist is not.
    const both = ModelCheckReport(
      judgement: 0.9,
      agreement: 0.9,
      invented: 3,
      suggested: 18,
      slowest: Duration(seconds: 40),
      targets: 3,
    );

    expect(both.inventsFilms, isTrue);
    expect(both.tooSlow, isTrue);
    expect(both.verdict, 'Not usable: it invents films.');
  });

  test('the check asks two calls per target and no more', () async {
    final model = FakeCheckModel.attentive(keys);

    await checking(model).run();

    expect(model.ordered, checkTargets);
    expect(model.asked, checkTargets);
  });
}

/// Five films a key rates, to pad a suggestion list out to six.
List<KeyFilm> _fiveFrom(List<AnswerKey> keys, String target) {
  final key = keys.where((key) => key.target == target).first;
  return key.films.take(5).toList();
}
