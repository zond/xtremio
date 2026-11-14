import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/decode_keep_up.dart';
import 'package:xtremio/features/player/playback_stats.dart';

/// When the player checks that software decoding keeps up, and what it
/// calls behind ([DecodeKeepUp], [decodingFallsBehind]).
void main() {
  group('the check', () {
    List<KeepUpStep> run(DecodeKeepUp check, int ticks, {bool? buffering}) => [
      for (var i = 0; i < ticks; i++)
        check.tick(playing: true, buffering: buffering ?? false),
    ];

    test('takes a baseline on the first tick of playback and a sample '
        'eight seconds of playback later', () {
      final check = DecodeKeepUp();
      final steps = run(check, 9);
      expect(steps.first, KeepUpStep.baseline);
      expect(steps.sublist(1, 8), everyElement(KeepUpStep.wait));
      expect(steps.last, KeepUpStep.sample);
      expect(check.played, DecodeKeepUp.measured);
      expect(check.done, isTrue);
    });

    test('counts nothing while the film is paused or buffering', () {
      final check = DecodeKeepUp();
      expect(check.tick(playing: false, buffering: false), KeepUpStep.wait);
      expect(check.tick(playing: true, buffering: true), KeepUpStep.wait);
      expect(check.tick(playing: true, buffering: false), KeepUpStep.baseline);
      for (var i = 0; i < 20; i++) {
        expect(check.tick(playing: false, buffering: false), KeepUpStep.wait);
        expect(check.tick(playing: true, buffering: true), KeepUpStep.wait);
      }
      expect(check.played, Duration.zero);
      expect(run(check, 8).last, KeepUpStep.sample);
    });

    test('runs once per film', () {
      final check = DecodeKeepUp();
      run(check, 9);
      expect(run(check, 30), everyElement(KeepUpStep.wait));
    });
  });

  group('decoding is behind', () {
    const played = Duration(seconds: 8);
    const start = PlaybackStats(droppedFrames: 3, decoderDroppedFrames: 1);

    test('when it shows clearly fewer frames than the film has', () {
      const sample = PlaybackStats(
        outputFps: 14,
        containerFps: 23.976,
        droppedFrames: 3,
        decoderDroppedFrames: 1,
      );
      expect(
        decodingFallsBehind(baseline: start, sample: sample, played: played),
        isTrue,
      );
    });

    test('when it drops frames fast', () {
      // 24 fps for 8 s is 192 frames; 60 dropped is nearly a third.
      const sample = PlaybackStats(
        outputFps: 23.9,
        containerFps: 24,
        droppedFrames: 53,
        decoderDroppedFrames: 11,
      );
      expect(
        decodingFallsBehind(baseline: start, sample: sample, played: played),
        isTrue,
      );
    });

    test('and not when it keeps up, a few drops or the ones before the '
        'baseline aside', () {
      const sample = PlaybackStats(
        outputFps: 23.5,
        containerFps: 23.976,
        droppedFrames: 9,
        decoderDroppedFrames: 1,
      );
      expect(
        decodingFallsBehind(baseline: start, sample: sample, played: played),
        isFalse,
      );
      const before = PlaybackStats(droppedFrames: 500);
      const after = PlaybackStats(
        outputFps: 24,
        containerFps: 24,
        droppedFrames: 510,
      );
      expect(
        decodingFallsBehind(baseline: before, sample: after, played: played),
        isFalse,
      );
    });

    test('and nothing is decided for a film with no declared rate', () {
      const sample = PlaybackStats(outputFps: 3, droppedFrames: 900);
      expect(
        decodingFallsBehind(baseline: start, sample: sample, played: played),
        isFalse,
      );
    });
  });
}
