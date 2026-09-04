import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/fake_prefs_client.dart';

/// What the viewer fixed about a subtitle's timing, and the two keys it is
/// remembered under.
///
/// The asymmetry is the point: a speed is a property of where the file
/// came from, so it is keyed on the series and the subtitle group; a shift
/// is the video's pre-roll less the subtitle source's, so it is keyed on
/// the video release as well. Either way, a key part nobody can name means
/// the adjustment is not remembered -- guessing which files an adjustment
/// belongs to would apply it to files it was never made for.
void main() {
  const gilmore = 'tt0303461';

  SubtitleSyncMemory remembering(
    SubtitleSyncMemory memory, {
    String? series = gilmore,
    String? group = '6',
    String? release = 'gilmore.girls.s01e01.dvdrip-xor.avi',
    String? speed,
    int shiftSteps = 0,
  }) => memory.remembering(
    series: series,
    group: group,
    release: release,
    speed: speed,
    shiftSteps: shiftSteps,
  );

  group('SubtitleSyncMemory', () {
    test('a speed carries to another release of the same series', () {
      final memory = remembering(SubtitleSyncMemory.empty, speed: 'stretch');

      // Same show, same subtitle group, a different video release: the
      // speed still applies, because what a file was timed against is a
      // property of where the file came from.
      expect(memory.speedFor(series: gilmore, group: '6'), 'stretch');
      expect(
        memory.shiftStepsFor(
          series: gilmore,
          group: '6',
          release: 'gilmore.girls.s01e02.720p-ntb.mkv',
        ),
        0,
      );
    });

    test('a speed is forgotten when either part of its key differs', () {
      final memory = remembering(SubtitleSyncMemory.empty, speed: 'stretch');

      expect(memory.speedFor(series: 'tt0944947', group: '6'), isNull);
      expect(memory.speedFor(series: gilmore, group: '3'), isNull);
      expect(memory.speedFor(series: gilmore, group: null), isNull);
      expect(memory.speedFor(series: null, group: '6'), isNull);
    });

    test('a shift is forgotten when any part of its key differs', () {
      const release = 'gilmore.girls.s01e01.dvdrip-xor.avi';
      final memory = remembering(SubtitleSyncMemory.empty, shiftSteps: 12);
      int shift({String? series, String? group, String? release}) =>
          memory.shiftStepsFor(series: series, group: group, release: release);

      expect(shift(series: gilmore, group: '6', release: release), 12);
      // The offset is the video's pre-roll less the subtitle source's, so
      // it depends on both sides: change the release and the answer is no
      // longer known.
      expect(
        shift(series: gilmore, group: '6', release: 'another.release.mkv'),
        0,
      );
      expect(shift(series: gilmore, group: '3', release: release), 0);
      expect(shift(series: 'tt0944947', group: '6', release: release), 0);
      expect(shift(series: gilmore, group: '6', release: null), 0);
    });

    test('nothing is remembered without the key that caused it', () {
      // No `g` from the addon, and no series: neither adjustment has
      // anything to be keyed on, so neither is written down.
      expect(
        remembering(
          SubtitleSyncMemory.empty,
          group: null,
          speed: 'stretch',
          shiftSteps: 3,
        ).entries,
        isEmpty,
      );
      expect(
        remembering(
          SubtitleSyncMemory.empty,
          series: null,
          speed: 'stretch',
          shiftSteps: 3,
        ).entries,
        isEmpty,
      );
      // A release nobody has named: the speed still is, the shift is not.
      final unnamed = remembering(
        SubtitleSyncMemory.empty,
        release: null,
        speed: 'stretch',
        shiftSteps: 3,
      );
      expect(unnamed.speedFor(series: gilmore, group: '6'), 'stretch');
      expect(unnamed.entries, hasLength(1));
    });

    test('an unknown release leaves the shifts that are remembered', () {
      const release = 'gilmore.girls.s01e01.dvdrip-xor.avi';
      final made = remembering(SubtitleSyncMemory.empty, shiftSteps: 12);
      // Nothing has named the release this time, so there is no telling
      // which stored offset this would have replaced -- and dropping the
      // one that is there would forget an answer nobody asked to forget.
      final later = remembering(made, release: null, speed: 'compress');

      expect(
        later.shiftStepsFor(series: gilmore, group: '6', release: release),
        12,
      );
    });

    test('back to untouched is forgotten, not stored as a zero', () {
      final made = remembering(
        SubtitleSyncMemory.empty,
        speed: 'stretch',
        shiftSteps: 3,
      );
      expect(made.entries, hasLength(2));

      // Reset: the viewer has said this file needs nothing, and nothing
      // remembered is what nothing applied looks like next time.
      final reset = remembering(made);

      expect(reset.entries, isEmpty);
      expect(reset.speedFor(series: gilmore, group: '6'), isNull);
    });

    test('a fresh adjustment replaces the one it is keyed with', () {
      final first = remembering(SubtitleSyncMemory.empty, speed: 'stretch');
      final second = remembering(first, speed: 'compress', shiftSteps: -2);

      expect(second.speedFor(series: gilmore, group: '6'), 'compress');
      expect(second.entries, hasLength(2));
    });

    test('the store is bounded, and it is the oldest that falls off', () {
      var memory = SubtitleSyncMemory.empty;
      for (var i = 0; i <= SubtitleSyncMemory.limit; i++) {
        memory = remembering(memory, series: 'tt$i', speed: 'stretch');
      }

      expect(memory.entries, hasLength(SubtitleSyncMemory.limit));
      // The show fixed first is the one gone; the show fixed last is the
      // one kept.
      expect(memory.speedFor(series: 'tt0', group: '6'), isNull);
      expect(
        memory.speedFor(series: 'tt${SubtitleSyncMemory.limit}', group: '6'),
        'stretch',
      );
    });

    test('a memory that changed nothing is the same memory', () {
      final made = remembering(SubtitleSyncMemory.empty, speed: 'stretch');

      expect(identical(remembering(made, speed: 'stretch'), made), isTrue);
    });

    test('survives a round trip through the stored JSON', () {
      final made = remembering(
        remembering(SubtitleSyncMemory.empty, speed: 'stretch'),
        group: '3',
        shiftSteps: -4,
      );

      final read = SubtitleSyncMemory.fromJson(made.toJson());

      expect(read, made);
      expect(read.speedFor(series: gilmore, group: '6'), 'stretch');
      expect(
        read.shiftStepsFor(
          series: gilmore,
          group: '3',
          release: 'gilmore.girls.s01e01.dvdrip-xor.avi',
        ),
        -4,
      );
    });

    test('a row this build cannot read is dropped, never a failure', () {
      final read = SubtitleSyncMemory.fromJson([
        'not a row',
        <String, Object?>{'group': '6', 'speed': 'stretch'},
        <String, Object?>{'series': gilmore, 'speed': 'stretch'},
        // Names neither adjustment, so there is nothing to apply.
        <String, Object?>{'series': gilmore, 'group': '6'},
        // A shift of no steps is not an adjustment either.
        <String, Object?>{
          'series': gilmore,
          'group': '6',
          'release': 'r.mkv',
          'shift': 0,
        },
        <String, Object?>{
          'series': gilmore,
          'group': '6',
          'release': 'r.mkv',
          'shift': '3',
        },
        <String, Object?>{'series': gilmore, 'group': '6', 'speed': 'compress'},
      ]);

      expect(read.entries, hasLength(1));
      expect(read.speedFor(series: gilmore, group: '6'), 'compress');
      expect(SubtitleSyncMemory.fromJson(null), SubtitleSyncMemory.empty);
      expect(
        SubtitleSyncMemory.fromJson(<String, Object?>{}),
        SubtitleSyncMemory.empty,
      );
    });

    test('a stored list longer than the bound is cut on the way in', () {
      final read = SubtitleSyncMemory.fromJson([
        for (var i = 0; i < SubtitleSyncMemory.limit + 10; i++)
          <String, Object?>{'series': 'tt$i', 'group': '6', 'speed': 'stretch'},
      ]);

      expect(read.entries, hasLength(SubtitleSyncMemory.limit));
    });
  });

  group('AppPrefs.subtitleSync', () {
    test('starts empty and reads what was stored', () async {
      final prefs = AppPrefs(
        client: FakePrefsClient({
          'subtitleSync': [
            {'series': gilmore, 'group': '6', 'speed': 'stretch'},
          ],
        }),
      );
      expect(prefs.subtitleSync.entries, isEmpty);

      var notified = 0;
      prefs.addListener(() => notified++);
      await prefs.load();

      expect(
        prefs.subtitleSync.speedFor(series: gilmore, group: '6'),
        'stretch',
      );
      expect(notified, 1);
    });

    test(
      'a change is written through and read back by a fresh start',
      () async {
        final client = FakePrefsClient();
        final prefs = AppPrefs(client: client);

        await prefs.setSubtitleSync(
          remembering(SubtitleSyncMemory.empty, speed: 'compress'),
        );
        expect(client.writes, ['subtitleSync']);

        final restarted = AppPrefs(client: client);
        await restarted.load();

        expect(
          restarted.subtitleSync.speedFor(series: gilmore, group: '6'),
          'compress',
        );
      },
    );

    test(
      'forgetting the last adjustment takes the key out of the file',
      () async {
        final client = FakePrefsClient();
        final prefs = AppPrefs(client: client);
        final made = remembering(SubtitleSyncMemory.empty, speed: 'compress');

        await prefs.setSubtitleSync(made);
        await prefs.setSubtitleSync(remembering(made));

        expect(client.stored.containsKey('subtitleSync'), isFalse);
        expect(prefs.subtitleSync.entries, isEmpty);
      },
    );

    test('writing what is already stored writes nothing', () async {
      final client = FakePrefsClient();
      final prefs = AppPrefs(client: client);
      final made = remembering(SubtitleSyncMemory.empty, speed: 'compress');

      await prefs.setSubtitleSync(made);
      await prefs.setSubtitleSync(
        remembering(SubtitleSyncMemory.empty, speed: 'compress'),
      );

      expect(client.writes, ['subtitleSync']);
    });
  });
}
