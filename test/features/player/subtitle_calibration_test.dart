import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/subtitle_calibration.dart';
import 'package:xtremio/features/player/subtitle_timing.dart';

/// The viewer marking the picture right: what one mark is worth, what two
/// are, and the span below which two are still only one.
void main() {
  /// Where mpv puts the cue whose own start is [cueStart]: the
  /// timestamps multiplied by `sub-speed`, then `sub-delay` added. Every
  /// claim below that a mark is "exact" is this landing on it.
  double shown(SubtitleTiming timing, double cueStart) =>
      timing.speed * cueStart + timing.delay;

  /// The owner's Swedish Gilmore Girls file: a ratio of 1.0440 where the
  /// PAL constant is 1.04271, and half a second of pre-roll on top. The
  /// 0.12 % between those two is three seconds across an episode, which
  /// is the whole reason a measurement exists.
  const rate = 1.0440;
  const offset = -0.5;
  SubtitleMark markAt(double cueStart, {double error = 0}) => SubtitleMark(
    cueStart: cueStart,
    videoPosition: rate * cueStart + offset + error,
  );

  group('one mark', () {
    test('sets an offset and says so', () {
      final result = SubtitleCalibration.none.marking(
        markAt(30),
        inForce: const SubtitleTiming(),
      );

      // One point is one point: it says where this cue belongs and
      // nothing about how fast the file runs, so the speed it was
      // watched at stands.
      expect(result.outcome, SubtitleCalibrationOutcome.offset);
      expect(result.timing.speed, 1);
      expect(shown(result.timing, 30), closeTo(rate * 30 + offset, 1e-9));
    });

    test('is a correspondence, so the shift it was made under is in it', () {
      // The mark says "this line belongs here", which stays true whatever
      // the transform was at the time. Recording the shift in force
      // instead would have to be unwound every time something else
      // touched the timing.
      const inForce = SubtitleTiming(shiftSteps: 12, calibratedSpeed: 1.044);
      final result = SubtitleCalibration.none.marking(
        markAt(300),
        inForce: inForce,
      );

      expect(result.timing.shiftSteps, 0);
      expect(result.timing.speed, inForce.speed);
      expect(shown(result.timing, 300), closeTo(rate * 300 + offset, 1e-9));
    });

    test('the panel can still nudge it and come back to it exactly', () {
      final calibrated = SubtitleCalibration.none
          .marking(markAt(30), inForce: const SubtitleTiming())
          .timing;

      expect(
        calibrated.shiftedBy(1).delay,
        closeTo(calibrated.delay + 0.1, 1e-9),
      );
      // Presses are counted on top of the measured offset rather than
      // folded into it, so seven forward and seven back is the measured
      // number again and not a double that has been round the houses.
      var nudged = calibrated;
      for (var i = 0; i < 7; i++) {
        nudged = nudged.shiftedBy(1);
      }
      for (var i = 0; i < 7; i++) {
        nudged = nudged.shiftedBy(-1);
      }
      expect(nudged.delay, calibrated.delay);
    });
  });

  group('two marks', () {
    test('far enough apart set a rate as well, and say so', () {
      // Twenty-four minutes of lever arm: both marks exact by
      // construction, and the ratio is the file's own rather than the
      // family it came from.
      final result = SubtitleCalibration.none
          .marking(markAt(30), inForce: const SubtitleTiming())
          .calibration
          .marking(markAt(1500), inForce: const SubtitleTiming());

      expect(result.outcome, SubtitleCalibrationOutcome.rate);
      expect(result.timing.speed, closeTo(rate, 1e-9));
      expect(shown(result.timing, 30), closeTo(rate * 30 + offset, 1e-9));
      expect(shown(result.timing, 1500), closeTo(rate * 1500 + offset, 1e-9));
      // The measurement is what is believed, not the constant it is
      // near: PAL would leave 1.7 seconds on the second mark.
      expect(result.timing.speed, isNot(closeTo(25 / 23.976, 1e-4)));
    });

    test('close together do not, and say that instead', () {
      // A hundred seconds is under the span, so this is still one
      // observation's worth of information about the rate -- and a tenth
      // of a second of judgement error over it would be a 0.1 % rate
      // error applied to the whole episode.
      final result = SubtitleCalibration.none
          .marking(markAt(30), inForce: const SubtitleTiming())
          .calibration
          .marking(markAt(130), inForce: const SubtitleTiming());

      expect(result.calibration.marks, hasLength(2));
      expect(result.outcome, SubtitleCalibrationOutcome.offset);
      expect(result.timing.speed, 1);
      // The offset is the newest mark's: an offset cannot reconcile two
      // observations, and the one in front of the viewer is the
      // judgement they just made.
      expect(shown(result.timing, 130), closeTo(rate * 130 + offset, 1e-9));
    });

    test(
      'that disagree by more than a rate can explain only set an offset',
      () {
        // 0.86 is not a rate any pair of files has; it is a cue read off
        // the wrong line. An offset is the honest answer, and it keeps
        // `sub-speed` inside the range mpv would otherwise refuse in
        // silence.
        final result = SubtitleCalibration.none
            .marking(
              const SubtitleMark(cueStart: 30, videoPosition: 30),
              inForce: const SubtitleTiming(),
            )
            .calibration
            .marking(
              const SubtitleMark(cueStart: 1500, videoPosition: 1300),
              inForce: const SubtitleTiming(),
            );

        expect(result.outcome, SubtitleCalibrationOutcome.offset);
        expect(result.timing.speed, 1);
      },
    );

    test('a new one near an old one replaces it', () {
      // The viewer marking the same scene again is correcting what they
      // said, not saying a second thing. Kept, the stale one would sit at
      // one end of the span and be the mark the rate is read from.
      final result = SubtitleCalibration.none
          .marking(markAt(30), inForce: const SubtitleTiming())
          .calibration
          .marking(markAt(1500, error: 0.4), inForce: const SubtitleTiming())
          .calibration
          .marking(markAt(1510), inForce: const SubtitleTiming());

      expect(result.calibration.marks, hasLength(2));
      expect(result.outcome, SubtitleCalibrationOutcome.rate);
      expect(result.timing.speed, closeTo(rate, 1e-9));
    });
  });

  group('a third mark', () {
    test('refines rather than replaces', () {
      // Two marks a hundred and seventy seconds apart, the second a
      // tenth of a second out, give a rate 0.06 % wrong. A mark
      // twenty-odd minutes in widens the lever arm and the answer comes
      // back to the file's real ratio, without the middle mark being
      // thrown away.
      final short = SubtitleCalibration.none
          .marking(markAt(30), inForce: const SubtitleTiming())
          .calibration
          .marking(markAt(200, error: 0.1), inForce: const SubtitleTiming());
      expect(short.outcome, SubtitleCalibrationOutcome.rate);
      expect(short.timing.speed, isNot(closeTo(rate, 1e-4)));

      final refined = short.calibration.marking(
        markAt(1500),
        inForce: const SubtitleTiming(),
      );

      expect(refined.calibration.marks, hasLength(3));
      expect(refined.timing.speed, closeTo(rate, 1e-9));
    });

    test('between two others does not out-vote the pair around it', () {
      // The widest pair and not a fit over everything: a viewer who
      // fussed over one stretch of the episode would otherwise drag the
      // answer into it.
      final widest = SubtitleCalibration.none
          .marking(markAt(30), inForce: const SubtitleTiming())
          .calibration
          .marking(markAt(1500), inForce: const SubtitleTiming());

      final middle = widest.calibration.marking(
        markAt(700, error: 0.9),
        inForce: const SubtitleTiming(),
      );

      expect(middle.timing.speed, widest.timing.speed);
      expect(middle.timing.delay, widest.timing.delay);
    });
  });

  group('what the viewer is told', () {
    test('asks for the second mark, and names the episode when it comes', () {
      // Both look the same in the picture -- the line landing where it
      // belongs -- and only one of them still holds ten minutes later.
      // One point changes nothing at all, so a note that claimed a fix
      // would be claiming the viewer's own shift; what it says instead
      // is what turns the point into one.
      expect(
        SubtitleCalibrationOutcome.offset.note,
        isNot(SubtitleCalibrationOutcome.rate.note),
      );
      expect(SubtitleCalibrationOutcome.offset.note, contains('again'));
      expect(SubtitleCalibrationOutcome.rate.note, contains('episode'));
    });
  });

  group('the timing a calibration writes', () {
    test('is what the panel shows, sign and all', () {
      final timing = SubtitleCalibration.none
          .marking(
            const SubtitleMark(cueStart: 100, videoPosition: 98.7),
            inForce: const SubtitleTiming(),
          )
          .timing;

      expect(timing.adjusted, isTrue);
      expect(timing.shiftText, '-1.3 s');
      expect(timing.speedText, '1.000×');
    });
  });
}
