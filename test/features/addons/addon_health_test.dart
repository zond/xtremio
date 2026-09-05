import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/addons/addon_health.dart';

void main() {
  final now = DateTime.utc(2026, 9, 4, 12);

  /// A record whose counts were last aged [ago] before [now], so a case can
  /// choose between "these are the counts" and "these are the counts, and
  /// they are old".
  AddonHealthRecord record({
    double ok = 0,
    double empty = 0,
    double fail = 0,
    Duration? workedAgo,
    Duration ago = Duration.zero,
  }) => AddonHealthRecord(
    ok: ok,
    empty: empty,
    fail: fail,
    lastOk: workedAgo == null ? null : now.subtract(workedAgo),
    updated: now.subtract(ago),
  );

  AddonHealth health(
    Map<AddonResourceKind, AddonHealthRecord> records, {
    Set<AddonResourceKind>? declared,
  }) =>
      AddonHealth(declared: declared ?? records.keys.toSet(), records: records);

  group('the verdict', () {
    /// Every case the rule is allowed to have an opinion about, and the
    /// opinion. Ordered as the rule evaluates: too little evidence, broken,
    /// useless, useful.
    final cases = <String, (AddonHealth, AddonHealthVerdict)>{
      'nothing has been asked at all': (
        health(const {}),
        AddonHealthVerdict.notEnoughEvidence,
      ),
      'four failures is not yet an accusation': (
        health({AddonResourceKind.catalog: record(fail: 4)}),
        AddonHealthVerdict.notEnoughEvidence,
      ),
      'a record old enough to have decayed below the threshold': (
        health({
          AddonResourceKind.catalog: record(
            fail: 6,
            ago: const Duration(days: 60),
          ),
        }),
        AddonHealthVerdict.notEnoughEvidence,
      ),
      'five failures and nothing else, ever': (
        health({AddonResourceKind.catalog: record(fail: 5)}),
        AddonHealthVerdict.neverAnswered,
      ),
      'it answered once, a month ago, and has failed ever since': (
        health({
          AddonResourceKind.catalog: record(
            ok: 1,
            fail: 12,
            workedAgo: const Duration(days: 30),
          ),
        }),
        AddonHealthVerdict.broken,
      ),
      'an addon that has answered with nothing has answered': (
        // Twenty empties and five failures: it is reachable and has had
        // nothing, which is the difference the three buckets exist for.
        health({
          AddonResourceKind.catalog: record(empty: 20),
          AddonResourceKind.stream: record(fail: 5),
        }),
        AddonHealthVerdict.broken,
      ),
      'four failures on something installed yesterday is not a dead addon': (
        health({AddonResourceKind.catalog: record(fail: 4)}),
        AddonHealthVerdict.notEnoughEvidence,
      ),
      'failures spread too thin to accuse any one resource': (
        // Six failures in total and never an answer, but no single kind has
        // been asked five times -- the same guard that keeps `broken` off.
        health({
          AddonResourceKind.catalog: record(fail: 3),
          AddonResourceKind.stream: record(fail: 3),
        }),
        AddonHealthVerdict.notEnoughEvidence,
      ),
      'half of them failed and it has not worked in a month': (
        health({
          AddonResourceKind.stream: record(
            ok: 5,
            fail: 5,
            workedAgo: const Duration(days: 30),
          ),
        }),
        AddonHealthVerdict.broken,
      ),
      'one dead resource while nothing else has worked either': (
        health({
          AddonResourceKind.catalog: record(fail: 9, ok: 1),
          AddonResourceKind.stream: record(empty: 30),
        }),
        AddonHealthVerdict.broken,
      ),
      // Both halves of broken are required, and each of the next two cases
      // has only one of them.
      'failing right now, but it answered an hour ago': (
        health({
          AddonResourceKind.catalog: record(
            fail: 8,
            ok: 2,
            workedAgo: const Duration(hours: 1),
          ),
        }),
        AddonHealthVerdict.useful,
      ),
      'silent for a fortnight, but it has never failed': (
        health({
          AddonResourceKind.catalog: record(
            ok: 8,
            empty: 2,
            workedAgo: const Duration(days: 14),
          ),
        }),
        AddonHealthVerdict.useful,
      ),
      'a dead catalog on an addon whose streams still work': (
        health({
          AddonResourceKind.catalog: record(fail: 20),
          AddonResourceKind.stream: record(
            ok: 40,
            workedAgo: const Duration(hours: 2),
          ),
        }),
        AddonHealthVerdict.useful,
      ),
      'every declared kind asked plenty and almost never answering': (
        health({
          AddonResourceKind.catalog: record(empty: 40),
          AddonResourceKind.stream: record(
            ok: 1,
            empty: 39,
            workedAgo: const Duration(days: 1),
          ),
        }),
        AddonHealthVerdict.useless,
      ),
      'answering nothing at all, which is still not a failure': (
        health({AddonResourceKind.catalog: record(empty: 100)}),
        AddonHealthVerdict.useless,
      ),
      'a specialist that answers one title in twenty': (
        health({
          AddonResourceKind.stream: record(
            ok: 1,
            empty: 19,
            workedAgo: const Duration(days: 1),
          ),
        }),
        AddonHealthVerdict.useful,
      ),
      'one live resource rescues an addon whose other one is silent': (
        health({
          AddonResourceKind.catalog: record(empty: 40),
          AddonResourceKind.stream: record(
            ok: 20,
            empty: 20,
            workedAgo: const Duration(days: 1),
          ),
        }),
        AddonHealthVerdict.useful,
      ),
      'a declared kind nothing has asked for yet': (
        health(
          {AddonResourceKind.catalog: record(empty: 40)},
          declared: {AddonResourceKind.catalog, AddonResourceKind.stream},
        ),
        AddonHealthVerdict.useful,
      ),
      'an addon that declares nothing a record is kept for': (
        health({
          AddonResourceKind.catalog: record(empty: 40),
        }, declared: const {}),
        AddonHealthVerdict.useful,
      ),
      'both unreachable and empty-handed reads as unreachable': (
        health({AddonResourceKind.catalog: record(fail: 30, empty: 30)}),
        AddonHealthVerdict.broken,
      ),
      'a record old enough to have decayed still remembers the answer': (
        // Counts halve; `lastOk` does not, which is what keeps an addon
        // that worked in the spring out of the never-answered bucket
        // however small its `ok` has become.
        health({
          AddonResourceKind.catalog: record(
            ok: 1,
            fail: 40,
            workedAgo: const Duration(days: 120),
            ago: const Duration(days: 28),
          ),
        }),
        AddonHealthVerdict.broken,
      ),
    };

    cases.forEach((description, expected) {
      test(description, () {
        expect(expected.$1.verdict(now), expected.$2);
      });
    });

    test('the thresholds are boundaries, not approximations', () {
      // Exactly the minimum evidence, exactly half of it failing: broken is
      // "at least half", and "not enough evidence" is strictly below five.
      expect(
        health({AddonResourceKind.catalog: record(ok: 2, fail: 3)})
            .verdict(now),
        AddonHealthVerdict.broken,
      );
      expect(
        health({AddonResourceKind.catalog: record(ok: 2.5, fail: 2.5)})
            .verdict(now),
        AddonHealthVerdict.broken,
      );
      expect(
        health({AddonResourceKind.catalog: record(ok: 3, fail: 2)})
            .verdict(now),
        AddonHealthVerdict.useful,
      );
      // Exactly twenty observations and exactly five percent of them
      // answered: useless is strictly under five percent, so this addon is
      // working as intended.
      expect(
        health({
          AddonResourceKind.catalog: record(
            ok: 1,
            empty: 19,
            workedAgo: const Duration(days: 1),
          ),
        }).verdict(now),
        AddonHealthVerdict.useful,
      );
      expect(
        health({AddonResourceKind.catalog: record(empty: 20)}).verdict(now),
        AddonHealthVerdict.useless,
      );
      expect(
        health({AddonResourceKind.catalog: record(empty: 19)}).verdict(now),
        AddonHealthVerdict.useful,
      );
      // Silence is longer than a week, not a week.
      expect(
        health({
          AddonResourceKind.catalog: record(
            fail: 5,
            workedAgo: const Duration(days: 7),
          ),
        }).verdict(now),
        AddonHealthVerdict.useful,
      );
      expect(
        health({
          AddonResourceKind.catalog: record(
            fail: 5,
            workedAgo: const Duration(days: 7, seconds: 1),
          ),
        }).verdict(now),
        AddonHealthVerdict.broken,
      );
    });

    test('never answered is broken, plus more, and never less', () {
      // The evidence floor is structural rather than a second threshold:
      // the verdict is decided inside broken's own branch, so every record
      // that earns it is one this rule would otherwise have called
      // unreachable. Walk a record up from nothing and it can only be said
      // once broken could have been.
      for (
        var failures = 0;
        failures < AddonHealth.minimumObservations;
        failures++
      ) {
        expect(
          health({AddonResourceKind.catalog: record(fail: failures.toDouble())})
              .verdict(now),
          AddonHealthVerdict.notEnoughEvidence,
          reason: '$failures failures',
        );
      }
      expect(
        health({
          AddonResourceKind.catalog: record(
            fail: AddonHealth.minimumObservations.toDouble(),
          ),
        }).verdict(now),
        AddonHealthVerdict.neverAnswered,
      );
    });

    test('the silence half is satisfied by there being no answer at all', () {
      // `lastOk` is null, so the addon has been silent for as long as it
      // has existed -- there is no fresh-failure case to exclude here, the
      // way an addon that worked an hour ago is excluded from broken.
      final dead = health({
        AddonResourceKind.stream: record(fail: 9, ago: Duration.zero),
      });
      expect(dead.hasNeverAnswered, isTrue);
      expect(dead.lastOk, isNull);
      expect(dead.verdict(now), AddonHealthVerdict.neverAnswered);
    });

    test('an empty answer is never counted as a failure', () {
      // The whole reason the record has three buckets: a public-domain
      // catalog with nothing for this year's blockbuster answers, every
      // time, with nothing.
      final specialist = health({AddonResourceKind.catalog: record(empty: 50)});
      expect(specialist.verdict(now), isNot(AddonHealthVerdict.broken));
      // And it has answered, fifty times, which is why the strongest
      // verdict is off it as well.
      expect(specialist.hasNeverAnswered, isFalse);
      expect(
        health({AddonResourceKind.catalog: record(fail: 50)}).verdict(now),
        AddonHealthVerdict.neverAnswered,
      );
    });
  });

  group('decay', () {
    test('a count halves every fortnight', () {
      final aged = record(ok: 8).decayedTo(now.add(const Duration(days: 14)));
      expect(aged.ok, closeTo(4, 1e-9));
      expect(
        aged.decayedTo(now.add(const Duration(days: 28))).ok,
        closeTo(2, 1e-9),
      );
    });

    test('applying it twice ages a count exactly as far as once', () {
      final once = record(ok: 8).decayedTo(now.add(const Duration(days: 14)));
      final twice = record(ok: 8)
          .decayedTo(now.add(const Duration(days: 7)))
          .decayedTo(now.add(const Duration(days: 14)));
      expect(twice.ok, closeTo(once.ok, 1e-9));
    });

    test('a clock that went backwards ages nothing', () {
      final aged = record(ok: 8)
          .decayedTo(now.subtract(const Duration(days: 30)));
      expect(aged.ok, 8);
      expect(aged.updated, now);
    });

    test('the timestamps do not decay', () {
      final aged = record(
        ok: 8,
        workedAgo: const Duration(days: 1),
      ).decayedTo(now.add(const Duration(days: 90)));
      expect(aged.lastOk, now.subtract(const Duration(days: 1)));
    });
  });

  group('the record key', () {
    test('is the digest the Rust side computes', () {
      // Pinned against `the_key_is_the_digest_the_app_computes` in
      // `rust/src/addon_health.rs`: if these two ever disagree the whole
      // record silently reads as "not used yet".
      expect(
        addonHealthKey('https://addons.example.com/manifest.json'),
        'addons.example.com#810b3d5448bc',
      );
      expect(
        addonHealthKey('http://127.0.0.1:11470/manifest.json'),
        startsWith('127.0.0.1:11470#'),
      );
    });

    test('never carries the URL or its query', () {
      const withToken =
          'https://addons.example.com/manifest.json?apikey=SUPERSECRET';
      final key = addonHealthKey(withToken);
      expect(key, isNot(contains('SUPERSECRET')));
      expect(key, isNot(contains('apikey')));
      expect(key, isNot(contains('manifest.json')));
      expect(key, startsWith('addons.example.com#'));
    });

    test('tells two configurations of one addon apart', () {
      expect(
        addonHealthKey('https://addon.example.com/aaa/manifest.json'),
        isNot(addonHealthKey('https://addon.example.com/bbb/manifest.json')),
      );
    });

    test('leaves a scheme default port out of the readable half', () {
      expect(
        addonHealthKey('https://addon.example.com:443/manifest.json'),
        startsWith('addon.example.com#'),
      );
      expect(
        addonHealthKey('http://addon.example.com:8080/manifest.json'),
        startsWith('addon.example.com:8080#'),
      );
    });

    test('a URL with no host still gets a key', () {
      expect(addonHealthKey('not a url at all'), startsWith('unknown#'));
    });
  });

  group('the report', () {
    Map<String, dynamic> reportJson({bool everyAnswerFailed = false}) => {
      'addons': {
        'addon.example.com#0123456789ab': {
          'catalog': {
            'ok': 3.0,
            'empty': 1.0,
            'fail': 2.0,
            'lastOk': '2026-09-01T00:00:00Z',
            'lastFail': '2026-09-03T00:00:00Z',
            'updated': '2026-09-03T00:00:00Z',
          },
          'addon_catalog': {'ok': 9.0, 'updated': '2026-09-03T00:00:00Z'},
          'stream': 'not a record',
        },
      },
      'everyAnswerFailed': everyAnswerFailed,
    };

    test('reads the counts and skips what it does not understand', () {
      final report = AddonHealthReport.fromJson(reportJson());
      final records = report.addons['addon.example.com#0123456789ab']!;
      expect(records.keys, [AddonResourceKind.catalog]);
      final catalog = records[AddonResourceKind.catalog]!;
      expect((catalog.ok, catalog.empty, catalog.fail), (3.0, 1.0, 2.0));
      expect(catalog.lastOk, DateTime.utc(2026, 9, 1));
      expect(report.everyAnswerFailed, isFalse);
    });

    test('carries the connection signal', () {
      expect(
        AddonHealthReport.fromJson(reportJson(everyAnswerFailed: true))
            .everyAnswerFailed,
        isTrue,
      );
      expect(AddonHealthReport.fromJson('nonsense').addons, isEmpty);
      expect(AddonHealthReport.empty.everyAnswerFailed, isFalse);
    });

    test('never labels a protected addon', () {
      AddonDescriptor descriptor({required bool protected}) => AddonDescriptor({
        'transportUrl': 'https://addon.example.com/manifest.json',
        'manifest': {
          'id': 'x',
          'version': '1.0.0',
          'name': 'x',
          'resources': ['catalog'],
        },
        'flags': {'official': true, 'protected': protected},
      });
      const report = AddonHealthReport(addons: {}, everyAnswerFailed: false);
      expect(report.healthOf(descriptor(protected: true)), isNull);
      expect(report.healthOf(descriptor(protected: false)), isNotNull);
    });

    test('finds an addon by the key its transport URL hashes to', () {
      const url = 'https://addon.example.com/manifest.json';
      final report = AddonHealthReport(
        addons: {
          addonHealthKey(url): {
            AddonResourceKind.stream: record(ok: 12, empty: 140, fail: 3),
          },
        },
        everyAnswerFailed: false,
      );
      final addon = AddonDescriptor({
        'transportUrl': url,
        'manifest': {
          'id': 'x',
          'version': '1.0.0',
          'name': 'x',
          'resources': [
            'stream',
            {'name': 'catalog', 'types': [], 'idPrefixes': []},
            'addon_catalog',
          ],
        },
        'flags': {'official': false, 'protected': false},
      });
      final health = report.healthOf(addon)!;
      expect(health.declared, {
        AddonResourceKind.catalog,
        AddonResourceKind.stream,
      });
      expect(health.records[AddonResourceKind.stream]?.ok, 12);
      expect(health.busiestKind(now), AddonResourceKind.stream);
      expect(health.lastOk, isNull);
    });
  });
}
