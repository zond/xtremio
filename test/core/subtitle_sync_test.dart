import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/fake_prefs_client.dart';

/// What the viewer fixed about a subtitle's timing, and the two keys it is
/// remembered under.
///
/// The asymmetry is the point: a speed is a property of where the file
/// came from, so it is keyed on the series and the group that cut the
/// release (`releaseGroup`, lower-cased -- never the addon's per-answer
/// `g`); a shift is the video's pre-roll less the subtitle source's, so it
/// is keyed on the video release as well. Either way, a key part nobody can name means
/// the adjustment is not remembered -- guessing which files an adjustment
/// belongs to would apply it to files it was never made for.
void main() {
  const gilmore = 'tt0303461';

  /// Two multipliers a viewer can arrive at: the PAL ratio and its
  /// reciprocal. Nothing here reads them -- the file stores whatever
  /// number was on the player -- but they are what the two ends of the
  /// range look like.
  const stretch = 25 / 23.976;
  const compress = 23.976 / 25;

  SubtitleSyncMemory remembering(
    SubtitleSyncMemory memory, {
    String? series = gilmore,
    String? releaseGroup = 'fgt',
    String? release = 'gilmore.girls.s01e01.dvdrip-xor.avi',
    double? speed,
    double shiftSeconds = 0,
  }) => memory.remembering(
    series: series,
    releaseGroup: releaseGroup,
    release: release,
    speed: speed,
    shiftSeconds: shiftSeconds,
  );

  group('SubtitleSyncMemory', () {
    test('a speed carries to another release of the same series', () {
      final memory = remembering(SubtitleSyncMemory.empty, speed: stretch);

      // Same show, same release group, a different video release: the
      // speed still applies, because what a file was timed against is a
      // property of where the file came from.
      expect(memory.speedFor(series: gilmore, releaseGroup: 'fgt'), stretch);
      expect(
        memory.shiftSecondsFor(
          series: gilmore,
          releaseGroup: 'fgt',
          release: 'gilmore.girls.s01e02.720p-ntb.mkv',
        ),
        0,
      );
    });

    test('a speed is forgotten when either part of its key differs', () {
      final memory = remembering(SubtitleSyncMemory.empty, speed: stretch);

      expect(memory.speedFor(series: 'tt0944947', releaseGroup: 'fgt'), isNull);
      expect(memory.speedFor(series: gilmore, releaseGroup: 'fov'), isNull);
      expect(memory.speedFor(series: gilmore, releaseGroup: null), isNull);
      expect(memory.speedFor(series: null, releaseGroup: 'fgt'), isNull);
    });

    test('a shift is forgotten when any part of its key differs', () {
      const release = 'gilmore.girls.s01e01.dvdrip-xor.avi';
      final memory = remembering(SubtitleSyncMemory.empty, shiftSeconds: 1.2);
      double shift({String? series, String? releaseGroup, String? release}) =>
          memory.shiftSecondsFor(
            series: series,
            releaseGroup: releaseGroup,
            release: release,
          );

      expect(
        shift(series: gilmore, releaseGroup: 'fgt', release: release),
        1.2,
      );
      // The offset is the video's pre-roll less the subtitle source's, so
      // it depends on both sides: change the release and the answer is no
      // longer known.
      expect(
        shift(
          series: gilmore,
          releaseGroup: 'fgt',
          release: 'another.release.mkv',
        ),
        0,
      );
      expect(shift(series: gilmore, releaseGroup: 'fov', release: release), 0);
      expect(
        shift(series: 'tt0944947', releaseGroup: 'fgt', release: release),
        0,
      );
      expect(shift(series: gilmore, releaseGroup: 'fgt', release: null), 0);
    });

    test('nothing is remembered without the key that caused it', () {
      // No release group from the addon, and no series: neither
      // adjustment has anything to be keyed on, so neither is written
      // down.
      expect(
        remembering(
          SubtitleSyncMemory.empty,
          releaseGroup: null,
          speed: stretch,
          shiftSeconds: 0.3,
        ).entries,
        isEmpty,
      );
      expect(
        remembering(
          SubtitleSyncMemory.empty,
          series: null,
          speed: stretch,
          shiftSeconds: 0.3,
        ).entries,
        isEmpty,
      );
      // A release nobody has named: the speed still is, the shift is not.
      final unnamed = remembering(
        SubtitleSyncMemory.empty,
        release: null,
        speed: stretch,
        shiftSeconds: 0.3,
      );
      expect(unnamed.speedFor(series: gilmore, releaseGroup: 'fgt'), stretch);
      expect(unnamed.entries, hasLength(1));
    });

    test('an unknown release leaves the shifts that are remembered', () {
      const release = 'gilmore.girls.s01e01.dvdrip-xor.avi';
      final made = remembering(SubtitleSyncMemory.empty, shiftSeconds: 1.2);
      // Nothing has named the release this time, so there is no telling
      // which stored offset this would have replaced -- and dropping the
      // one that is there would forget an answer nobody asked to forget.
      final later = remembering(made, release: null, speed: compress);

      expect(
        later.shiftSecondsFor(
          series: gilmore,
          releaseGroup: 'fgt',
          release: release,
        ),
        1.2,
      );
    });

    test('back to untouched is forgotten, not stored as a zero', () {
      final made = remembering(
        SubtitleSyncMemory.empty,
        speed: stretch,
        shiftSeconds: 0.3,
      );
      expect(made.entries, hasLength(2));

      // Reset: the viewer has said this file needs nothing, and nothing
      // remembered is what nothing applied looks like next time.
      final reset = remembering(made);

      expect(reset.entries, isEmpty);
      expect(reset.speedFor(series: gilmore, releaseGroup: 'fgt'), isNull);
    });

    test('a fresh adjustment replaces the one it is keyed with', () {
      final first = remembering(SubtitleSyncMemory.empty, speed: stretch);
      final second = remembering(first, speed: compress, shiftSeconds: -0.2);

      expect(second.speedFor(series: gilmore, releaseGroup: 'fgt'), compress);
      expect(second.entries, hasLength(2));
    });

    test('the store is bounded, and it is the oldest that falls off', () {
      var memory = SubtitleSyncMemory.empty;
      for (var i = 0; i <= SubtitleSyncMemory.limit; i++) {
        memory = remembering(memory, series: 'tt$i', speed: stretch);
      }

      expect(memory.entries, hasLength(SubtitleSyncMemory.limit));
      // The show fixed first is the one gone; the show fixed last is the
      // one kept.
      expect(memory.speedFor(series: 'tt0', releaseGroup: 'fgt'), isNull);
      expect(
        memory.speedFor(
          series: 'tt${SubtitleSyncMemory.limit}',
          releaseGroup: 'fgt',
        ),
        stretch,
      );
    });

    test('a memory that changed nothing is the same memory', () {
      final made = remembering(SubtitleSyncMemory.empty, speed: stretch);

      expect(identical(remembering(made, speed: stretch), made), isTrue);
    });

    test('survives a round trip through the stored JSON', () {
      final made = remembering(
        remembering(SubtitleSyncMemory.empty, speed: stretch),
        releaseGroup: 'fov',
        shiftSeconds: -0.4,
      );

      final read = SubtitleSyncMemory.fromJson(made.toJson());

      expect(read, made);
      expect(read.speedFor(series: gilmore, releaseGroup: 'fgt'), stretch);
      expect(
        read.shiftSecondsFor(
          series: gilmore,
          releaseGroup: 'fov',
          release: 'gilmore.girls.s01e01.dvdrip-xor.avi',
        ),
        -0.4,
      );
    });

    test('a row this build cannot read is dropped, never a failure', () {
      final read = SubtitleSyncMemory.fromJson([
        'not a row',
        <String, Object?>{'releaseGroup': 'fgt', 'speed': 1.25},
        <String, Object?>{'series': gilmore, 'speed': 1.25},
        // Names neither adjustment, so there is nothing to apply.
        <String, Object?>{'series': gilmore, 'releaseGroup': 'fgt'},
        // An offset of no seconds is not an adjustment either.
        <String, Object?>{
          'series': gilmore,
          'releaseGroup': 'fgt',
          'release': 'r.mkv',
          'shiftSeconds': 0,
        },
        <String, Object?>{
          'series': gilmore,
          'releaseGroup': 'fgt',
          'release': 'r.mkv',
          'shiftSeconds': '3',
        },
        // Neither is a number no player can be given.
        <String, Object?>{
          'series': gilmore,
          'releaseGroup': 'fgt',
          'release': 'r.mkv',
          'shiftSeconds': double.nan,
        },
        // A row an older build wrote, keyed on the addon's per-answer
        // bucket: `g` never named the same release family twice, and the
        // group's name is not in the row to migrate it with, so it
        // lapses.
        <String, Object?>{'series': gilmore, 'group': '6', 'speed': stretch},
        <String, Object?>{
          'series': gilmore,
          'releaseGroup': 'fgt',
          'speed': compress,
        },
      ]);

      expect(read.entries, hasLength(1));
      expect(read.speedFor(series: gilmore, releaseGroup: 'fgt'), compress);
      expect(SubtitleSyncMemory.fromJson(null), SubtitleSyncMemory.empty);
      expect(
        SubtitleSyncMemory.fromJson(<String, Object?>{}),
        SubtitleSyncMemory.empty,
      );
    });

    test('a stored list longer than the bound is cut on the way in', () {
      final read = SubtitleSyncMemory.fromJson([
        for (var i = 0; i < SubtitleSyncMemory.limit + 10; i++)
          <String, Object?>{
            'series': 'tt$i',
            'releaseGroup': 'fgt',
            'speed': stretch,
          },
      ]);

      expect(read.entries, hasLength(SubtitleSyncMemory.limit));
    });
  });

  group('AppPrefs.subtitleSync', () {
    test('starts empty and reads what was stored', () async {
      final prefs = AppPrefs(
        client: FakePrefsClient({
          'subtitleSync': [
            {'series': gilmore, 'releaseGroup': 'fgt', 'speed': stretch},
          ],
        }),
      );
      expect(prefs.subtitleSync.entries, isEmpty);

      var notified = 0;
      prefs.addListener(() => notified++);
      await prefs.load();

      expect(
        prefs.subtitleSync.speedFor(series: gilmore, releaseGroup: 'fgt'),
        stretch,
      );
      expect(notified, 1);
    });

    test(
      'a change is written through and read back by a fresh start',
      () async {
        final client = FakePrefsClient();
        final prefs = AppPrefs(client: client);

        await prefs.setSubtitleSync(
          remembering(SubtitleSyncMemory.empty, speed: compress),
        );
        expect(client.writes, ['subtitleSync']);

        final restarted = AppPrefs(client: client);
        await restarted.load();

        expect(
          restarted.subtitleSync.speedFor(series: gilmore, releaseGroup: 'fgt'),
          compress,
        );
      },
    );

    test(
      'forgetting the last adjustment takes the key out of the file',
      () async {
        final client = FakePrefsClient();
        final prefs = AppPrefs(client: client);
        final made = remembering(SubtitleSyncMemory.empty, speed: compress);

        await prefs.setSubtitleSync(made);
        await prefs.setSubtitleSync(remembering(made));

        expect(client.stored.containsKey('subtitleSync'), isFalse);
        expect(prefs.subtitleSync.entries, isEmpty);
      },
    );

    test('writing what is already stored writes nothing', () async {
      final client = FakePrefsClient();
      final prefs = AppPrefs(client: client);
      final made = remembering(SubtitleSyncMemory.empty, speed: compress);

      await prefs.setSubtitleSync(made);
      await prefs.setSubtitleSync(
        remembering(SubtitleSyncMemory.empty, speed: compress),
      );

      expect(client.writes, ['subtitleSync']);
    });
  });
}
