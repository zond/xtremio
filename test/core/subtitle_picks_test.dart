import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/fake_prefs_client.dart';

/// What the viewer picks, and the two questions it answers.
///
/// One row per show says what that programme was last watched with, down
/// to the release group of the very file when the addon named one; a
/// count per language says which two the menu should lift to the top of
/// forty rows. A key nobody can name is not remembered -- the same rule
/// `SubtitleSyncMemory` keeps -- so a file with no release group is
/// remembered as a language and nothing more.
void main() {
  const gilmore = 'tt0303461';
  const breakingBad = 'tt0903747';

  SubtitlePickMemory picked(
    SubtitlePickMemory memory, {
    String series = gilmore,
    String language = 'Swedish',
    String? releaseGroup,
    bool embedded = false,
  }) => memory.remembering(
    SubtitleShowPick(
      series: series,
      language: language,
      releaseGroup: releaseGroup,
      embedded: embedded,
    ),
  );

  group('SubtitleShowPick', () {
    test('a show is remembered with the group of the file that was picked', () {
      final memory = picked(SubtitlePickMemory.empty, releaseGroup: 'fgt');

      final pick = memory.forSeries(gilmore)!;
      expect(pick.enabled, isTrue);
      expect(pick.language, 'Swedish');
      expect(pick.releaseGroup, 'fgt');
      // The count is what the pins read, and it is per language rather
      // than per show: a viewer's languages are theirs, not a
      // programme's.
      expect(memory.languages, {'Swedish': 1});
    });

    test('a file the addon named no group for is remembered as a language', () {
      // Six files in ten carry no `releaseGroup`, and for those the
      // memory says the language and stops. That is the honest answer
      // rather than a shortfall: the next episode takes the head of the
      // language, exactly as it would with nothing remembered.
      final pick = picked(SubtitlePickMemory.empty).forSeries(gilmore)!;

      expect(pick.language, 'Swedish');
      expect(pick.releaseGroup, isNull);
    });

    test('off is a value, not the absence of one', () {
      final memory = picked(
        SubtitlePickMemory.empty,
        releaseGroup: 'fgt',
      ).remembering(const SubtitleShowPick.off(series: gilmore));

      final pick = memory.forSeries(gilmore)!;
      expect(pick.enabled, isFalse);
      expect(pick.language, isNull);
      // Turning subtitles off says nothing about a language, so it
      // counts towards none -- but the language picked before it still
      // counts, because it was picked.
      expect(memory.languages, {'Swedish': 1});
    });

    test('a show nobody has watched is remembered as nothing', () {
      final memory = picked(SubtitlePickMemory.empty);

      expect(memory.forSeries(breakingBad), isNull);
      expect(memory.forSeries(null), isNull);
    });

    test('the newest pick for a show replaces the one before it', () {
      final memory = picked(
        picked(SubtitlePickMemory.empty, releaseGroup: 'fov'),
        language: 'English',
        releaseGroup: 'fgt',
      );

      expect(memory.forSeries(gilmore)!.language, 'English');
      expect(memory.shows, hasLength(1));
      // Both picks count, because both were made.
      expect(memory.languages, {'Swedish': 1, 'English': 1});
    });

    test('the store is bounded, and it is the oldest show that falls off', () {
      var memory = SubtitlePickMemory.empty;
      for (var i = 0; i <= SubtitlePickMemory.showLimit; i++) {
        memory = picked(memory, series: 'tt$i');
      }

      expect(memory.shows, hasLength(SubtitlePickMemory.showLimit));
      expect(memory.forSeries('tt0'), isNull);
      expect(memory.forSeries('tt${SubtitlePickMemory.showLimit}'), isNotNull);
    });

    test('a memory that changed nothing is the same memory', () {
      final off = SubtitlePickMemory.empty.remembering(
        const SubtitleShowPick.off(series: gilmore),
      );

      // Off again on the same show moves neither the row nor a count, so
      // there is nothing to notify a listener about or write to a file.
      expect(
        identical(
          off.remembering(const SubtitleShowPick.off(series: gilmore)),
          off,
        ),
        isTrue,
      );
      // A language picked again *is* a change, because the count is what
      // the pins read and it has moved.
      final made = picked(SubtitlePickMemory.empty, releaseGroup: 'fgt');
      expect(identical(picked(made, releaseGroup: 'fgt'), made), isFalse);
    });
  });

  group('SubtitlePickMemory.pinned', () {
    SubtitlePickMemory counting(Map<String, int> counts) =>
        SubtitlePickMemory(shows: const [], languages: counts);

    test('the two most picked, most picked first', () {
      final memory = counting({'English': 41, 'Swedish': 12, 'Finnish': 4});

      expect(memory.pinned(['English', 'Finnish', 'Swedish']), [
        'English',
        'Swedish',
      ]);
    });

    test('a tie comes out in the order the menu already had it', () {
      // Which is the alphabet, because that is what the list is sorted
      // on before it gets here -- and it has to be the same answer every
      // time the menu is built, or the rows would swap under the viewer.
      final memory = counting({'Danish': 7, 'Swedish': 7, 'English': 7});

      expect(memory.pinned(['Danish', 'English', 'Swedish']), [
        'Danish',
        'English',
      ]);
    });

    test('one curious pick does not earn a permanent row', () {
      final memory = counting({
        'English': SubtitlePickMemory.pinThreshold,
        'Thai': SubtitlePickMemory.pinThreshold - 1,
      });

      expect(memory.pinned(['English', 'Thai']), ['English']);
    });

    test('a language offered twice takes one slot', () {
      // The menu hands over everything the sheet offers, so a language
      // the video carries a track for *and* an addon answered with
      // arrives twice. Two slots spent on one language would lift one
      // row and leave the viewer's second language down in the alphabet.
      final memory = counting({'English': 41, 'Swedish': 12});

      expect(memory.pinned(['English', 'Swedish', 'English']), [
        'English',
        'Swedish',
      ]);
    });

    test('a language this episode does not offer is not pinned', () {
      // A pin is a row moved, never a row invented: the addons answered
      // with no Swedish here, and nothing about the memory may put a
      // Swedish row in front of the viewer.
      final memory = counting({'English': 20, 'Swedish': 18});

      expect(memory.pinned(['English', 'French']), ['English']);
      expect(SubtitlePickMemory.empty.pinned(['English']), isEmpty);
    });
  });

  group('SubtitlePickMemory counts', () {
    test('the counts halve when they pass the ceiling, and zeroes go', () {
      // Decay on picks, not on days: a language a viewer speaks does not
      // go stale while the app is closed, so nothing here reads a clock.
      // What makes an old preference weak is newer ones.
      var memory = SubtitlePickMemory(
        shows: const [],
        languages: {
          'English': SubtitlePickMemory.countCeiling - 4,
          'Swedish': 3,
          'Thai': 1,
        },
      );

      memory = picked(memory, language: 'English');

      expect(memory.languages, {
        'English': (SubtitlePickMemory.countCeiling - 3) ~/ 2,
        'Swedish': 1,
      });
      // Which is what lets a taste that changes be followed: Thai was
      // tried once, a long time ago in picks, and is gone.
      expect(memory.languages.containsKey('Thai'), isFalse);
    });

    test('a total under the ceiling is left exactly as it is', () {
      final memory = picked(
        SubtitlePickMemory(shows: const [], languages: {'English': 5}),
        language: 'English',
      );

      expect(memory.languages, {'English': 6});
    });
  });

  group('the stored value', () {
    test('survives a round trip', () {
      final made = picked(
        picked(
          SubtitlePickMemory.empty,
          series: breakingBad,
          language: 'English',
          embedded: true,
        ),
        releaseGroup: 'fgt',
      ).remembering(const SubtitleShowPick.off(series: 'tt1234567'));

      final read = SubtitlePickMemory.fromJson(made.toJson());

      expect(read, made);
      expect(read.forSeries(breakingBad)!.embedded, isTrue);
      expect(read.forSeries(gilmore)!.releaseGroup, 'fgt');
      expect(read.forSeries('tt1234567')!.enabled, isFalse);
    });

    test('a row this build cannot read is dropped, never a failure', () {
      final read = SubtitlePickMemory.fromJson({
        'shows': [
          'not a row',
          // No series to key it on.
          {'language': 'Swedish'},
          // Neither an off nor a language: nothing to apply.
          {'series': gilmore},
          // A group is stored lower-cased whatever the file said.
          {'series': gilmore, 'language': 'Swedish', 'releaseGroup': 'FGT'},
          // The same show twice: the second row could never be reached.
          {'series': gilmore, 'language': 'English'},
        ],
        'languages': {
          'Swedish': 4,
          // Not counts: a name with nothing in it, a number that is not
          // one, a count of none.
          '': 9,
          'English': 'lots',
          'Thai': 0,
        },
      });

      expect(read.shows, hasLength(1));
      expect(read.forSeries(gilmore)!.releaseGroup, 'fgt');
      expect(read.languages, {'Swedish': 4});
      expect(SubtitlePickMemory.fromJson(null), SubtitlePickMemory.empty);
      expect(SubtitlePickMemory.fromJson('nope'), SubtitlePickMemory.empty);
      // Every half of the value is read the same way, because reading a
      // preferences file must not be able to fail: a start-up that
      // throws on a hand-edited file is worse than every preference in
      // it being lost.
      expect(
        SubtitlePickMemory.fromJson({
          'shows': {'series': gilmore},
          'languages': ['English'],
        }),
        SubtitlePickMemory.empty,
      );
    });

    test('a stored list longer than the bound is cut on the way in', () {
      final read = SubtitlePickMemory.fromJson({
        'shows': [
          for (var i = 0; i < SubtitlePickMemory.showLimit + 10; i++)
            {'series': 'tt$i', 'language': 'English'},
        ],
      });

      expect(read.shows, hasLength(SubtitlePickMemory.showLimit));
    });
  });

  group('AppPrefs.subtitlePicks', () {
    test('starts empty and reads what was stored', () async {
      final prefs = AppPrefs(
        client: FakePrefsClient({
          'subtitlePicks': {
            'shows': [
              {'series': gilmore, 'language': 'Swedish', 'releaseGroup': 'fgt'},
            ],
            'languages': {'Swedish': 3},
          },
        }),
      );
      expect(prefs.subtitlePicks, SubtitlePickMemory.empty);

      var notified = 0;
      prefs.addListener(() => notified++);
      await prefs.load();

      expect(prefs.subtitlePicks.forSeries(gilmore)!.releaseGroup, 'fgt');
      expect(prefs.subtitlePicks.pinned(['Swedish']), ['Swedish']);
      expect(notified, 1);
    });

    test(
      'a change is written through and read back by a fresh start',
      () async {
        final client = FakePrefsClient();
        final prefs = AppPrefs(client: client);

        await prefs.setSubtitlePicks(
          picked(SubtitlePickMemory.empty, releaseGroup: 'fgt'),
        );
        expect(client.writes, ['subtitlePicks']);

        final restarted = AppPrefs(client: client);
        await restarted.load();

        expect(restarted.subtitlePicks.forSeries(gilmore)!.language, 'Swedish');
      },
    );

    test('writing what is already stored writes nothing', () async {
      final client = FakePrefsClient();
      final prefs = AppPrefs(client: client);
      final made = picked(SubtitlePickMemory.empty, releaseGroup: 'fgt');

      await prefs.setSubtitlePicks(made);
      await prefs.setSubtitlePicks(
        picked(SubtitlePickMemory.empty, releaseGroup: 'fgt'),
      );

      expect(client.writes, ['subtitlePicks']);
    });
  });
}
