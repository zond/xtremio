import 'package:flutter/foundation.dart';

import 'subtitle_timing.dart';

/// One "this is right": the cue that was on screen when the viewer
/// pressed, and where in the video they judged it to belong.
///
/// **A mark is a correspondence, not a shift.** It says "this line of the
/// subtitle file belongs at this moment of the video", which stays true
/// when the transform changes -- and it must, because the second mark is
/// made after the first has already moved the speed and the offset.
/// Storing "the shift that was in force" instead would need unwinding
/// every time, and would go wrong the moment anything else touched the
/// timing.
@immutable
final class SubtitleMark {
  const SubtitleMark({required this.cueStart, required this.videoPosition});

  /// The cue's start on the subtitle file's own timeline, in seconds:
  /// its raw time in the file, before `sub-speed` and `sub-delay` moved
  /// it anywhere.
  final double cueStart;

  /// The video position, in seconds, that cue belongs at.
  ///
  /// Where the cue is *drawn*, under a transform the viewer has looked
  /// at and approved -- never the instant a button was pressed. A cue is
  /// on screen for seconds and a press can land anywhere in them, so the
  /// press instant carries a reaction time into a number that is
  /// otherwise exact (`PlayerScreen._markSubtitleTiming`).
  final double videoPosition;

  @override
  bool operator ==(Object other) =>
      other is SubtitleMark &&
      other.cueStart == cueStart &&
      other.videoPosition == videoPosition;

  @override
  int get hashCode => Object.hash(cueStart, videoPosition);

  @override
  String toString() => 'SubtitleMark($cueStart -> $videoPosition)';
}

/// Which of the two things a mark did, which is what the viewer has to
/// be told: one point on its own keeps the moment in front of them, a
/// pair of them fixes the rest of the episode as well.
enum SubtitleCalibrationOutcome {
  /// One point, so the line through the marks is the one already in
  /// force: the offset stays where the viewer put it and the speed is
  /// untouched.
  ///
  /// The press is not wasted and the panel must not let it look like a
  /// press that did nothing, because the mark it recorded is half of the
  /// pair that fixes the drift -- so the note asks for the other half,
  /// which is a mark made further on after the picture has been shifted
  /// into place again out there.
  offset('Marked. Mark again further on to fix drift'),

  /// Both moved: two marks far enough apart to trust a rate, and the
  /// drift between them is gone as well as the offset.
  rate('Fixed for the whole episode');

  const SubtitleCalibrationOutcome(this.note);

  /// The line the panel says it with. Which of the two happened is not
  /// visible in the picture -- both look like the subtitle landing where
  /// it belongs, and only one of them holds for another ten minutes.
  final String note;
}

/// What a mark says when there was nothing on screen to make it out of.
///
/// A press is aimed at a line the viewer can see, but the gaps between
/// cues are most of a film and the button cannot come and go with them
/// (`SubtitleTimingOverlay.onMark`), so a press between two lines has to
/// be answered rather than ignored: nothing moved, and a panel that said
/// nothing would look like one that had silently agreed.
const String subtitleNoCueNote = 'No subtitle on screen to mark';

/// A calibration and the timing it resolved to: what
/// [SubtitleCalibration.marking] answers.
@immutable
final class SubtitleCalibrationResult {
  const SubtitleCalibrationResult({
    required this.calibration,
    required this.timing,
    required this.outcome,
  });

  /// The marks, with the new one in and whatever it replaced out. The
  /// caller keeps this: it is working state, not something remembered.
  final SubtitleCalibration calibration;

  /// What to put on `sub-speed` and `sub-delay` now.
  final SubtitleTiming timing;

  /// Which of the two things happened.
  final SubtitleCalibrationOutcome outcome;
}

/// The marks made against the subtitle on screen, and the arithmetic
/// that turns them into a [SubtitleTiming].
///
/// The marks belong to one subtitle file: a point measured against one
/// file says nothing about another, so what is on screen changing throws
/// them away. Only the *derived* speed and shift are worth remembering.
///
/// ## The arithmetic, and what it assumes
///
/// mpv shows the cue whose own start is `t` at video position
///
///     p = speed * t + delay
///
/// -- `sub-speed` multiplies the subtitle's timestamps and `sub-delay`
/// is added to the product, in that order. A mark is a `(t, p)` the
/// viewer has declared true, so marks are points on that line and
/// calibrating is fitting it.
///
/// **One mark** leaves the slope alone and moves the line onto the
/// point: `delay = p - speed * t`, with `speed` whatever is in force.
///
/// **Two marks** far enough apart determine both:
///
///     speed = (p2 - p1) / (t2 - t1)
///     delay = p1 - speed * t1
///
/// and both marks are exact by construction.
///
/// Describing the second as *folding the slope of the required
/// correction into the speed* is the same arithmetic with one
/// assumption hidden in it, and the assumption is which axis the slope
/// is taken against. Write what each mark asked for under the transform
/// that was in force as `c = p - (speed * t + delay)`. Against the
/// **subtitle's own** timeline the slope is `k = (c2 - c1) / (t2 - t1)`,
/// and substituting `c = c1 + k * (t - t1)` into `p = speed * t + delay
/// + c` gives
///
///     speed' = speed + k
///     delay' = delay + c1 - k * t1
///
/// so the slope adds to the speed exactly -- and the pivot of that
/// change is `t = 0`, the start of the subtitle file rather than the
/// first mark, which is what the `- k * t1` in the offset pays for.
/// Fold the slope in and leave the offset alone and the first mark
/// moves by `k * t1`: at five minutes in and a PAL-sized rate that is
/// thirteen seconds, in the one place the viewer is certain it was
/// right.
///
/// Against the **video clock** instead -- the tempting axis, because it
/// is the number on the screen -- the slope is `kp = (c2 - c1) / (p2 -
/// p1)`, and since `p2 - p1 = speed * (t2 - t1) + (c2 - c1)` the honest
/// fold is `speed' = speed / (1 - kp)` rather than `speed * (1 + kp)`.
/// The two differ by `kp` squared: on a PAL-sized 4.3 % drift, 0.18 % --
/// larger than the 0.12 % residual this whole feature exists to catch.
///
/// Solving the two-point line directly, which is what [marking] does,
/// has neither trap in it. It is written down because the next person to
/// check this will reach for one of the two forms above.
@immutable
final class SubtitleCalibration {
  const SubtitleCalibration([this.marks = const <SubtitleMark>[]]);

  /// Nothing marked: what every subtitle starts on, and what a change of
  /// subtitle goes back to.
  static const SubtitleCalibration none = SubtitleCalibration();

  /// The marks in force, in the order they were made.
  final List<SubtitleMark> marks;

  /// How far apart two marks have to be, on the subtitle's own timeline,
  /// before their difference is allowed to set a rate.
  ///
  /// A rate read off two observations carries their error divided by the
  /// span between them, and the error is at best the tenth of a second
  /// one shift press is worth. Across thirty seconds that tenth is a
  /// 0.3 % rate error -- three times the 0.12 % drift the marks are
  /// there to find, and applied to the whole episode. Two minutes puts
  /// it at 0.083 %, under the residual it is chasing, and is well inside
  /// the flow this is for: mark it right at the start, notice the drift
  /// five minutes later, mark it right again.
  static const double rateSpan = 120;

  /// How close a new mark has to be to an existing one to be treated as
  /// a correction of it rather than a second observation.
  ///
  /// Thirty seconds is a scene, not a lever arm: nothing this close can
  /// set a rate anyway ([rateSpan]), and keeping the older of the two
  /// would let a stale judgement sit at one end of the span and win
  /// [_widestPair] over the correction that replaced it.
  static const double sameMoment = 30;

  /// The window a derived rate has to land in to be believed, either
  /// side of the file's own timing.
  ///
  /// Every real mismatch is inside it -- PAL against film, the largest
  /// there is, is 4.3 % -- so a ratio outside says the two marks
  /// disagree about something a rate cannot explain: a mis-press, or a
  /// cue read off the wrong file. The offset is then the honest answer,
  /// and it keeps `sub-speed` inside the `<0.1-10.0>` mpv would
  /// otherwise refuse in silence.
  static const double lowestRate = 0.9;
  static const double highestRate = 1.1;

  /// [mark] added to the marks and the whole lot resolved against
  /// [inForce], which is the timing the mark was made under.
  ///
  /// A mark near an existing one ([sameMoment]) replaces it: it is a
  /// correction of the same observation, not a second one.
  SubtitleCalibrationResult marking(
    SubtitleMark mark, {
    required SubtitleTiming inForce,
  }) {
    final next = SubtitleCalibration(
      List.unmodifiable(<SubtitleMark>[
        for (final existing in marks)
          if ((existing.cueStart - mark.cueStart).abs() >= sameMoment) existing,
        mark,
      ]),
    );
    final pair = next._widestPair();
    if (pair != null) {
      final (first, second) = pair;
      final rate =
          (second.videoPosition - first.videoPosition) /
          (second.cueStart - first.cueStart);
      if (rate >= lowestRate && rate <= highestRate) {
        return SubtitleCalibrationResult(
          calibration: next,
          timing: SubtitleTiming(
            calibratedSpeed: rate,
            calibratedDelay: first.videoPosition - rate * first.cueStart,
          ),
          outcome: SubtitleCalibrationOutcome.rate,
        );
      }
    }
    // The speed stays exactly what it was -- whatever an earlier
    // calibration or a match measured -- because one point says nothing
    // about a rate. The presses fold into the offset, which is now the
    // whole of it: the mark already accounts for the shift that was in
    // force.
    return SubtitleCalibrationResult(
      calibration: next,
      timing: SubtitleTiming(
        calibratedSpeed: inForce.calibratedSpeed,
        calibratedDelay: mark.videoPosition - inForce.speed * mark.cueStart,
      ),
      outcome: SubtitleCalibrationOutcome.offset,
    );
  }

  /// The two marks furthest apart on the subtitle's timeline, or null
  /// when there are not two of them or they are closer than [rateSpan].
  ///
  /// The widest pair rather than a least-squares fit over all of them:
  /// the widest has the longest lever arm, where a fit would be dragged
  /// around by whatever stretch of the episode the viewer happened to
  /// fuss over. A third mark refines the answer by widening the span or
  /// replacing an end of it, and never by out-voting one.
  (SubtitleMark, SubtitleMark)? _widestPair() {
    if (marks.length < 2) return null;
    var first = marks.first;
    var second = marks.first;
    for (final mark in marks) {
      if (mark.cueStart < first.cueStart) first = mark;
      if (mark.cueStart > second.cueStart) second = mark;
    }
    return second.cueStart - first.cueStart >= rateSpan
        ? (first, second)
        : null;
  }

  @override
  bool operator ==(Object other) =>
      other is SubtitleCalibration && listEquals(other.marks, marks);

  @override
  int get hashCode => Object.hashAll(marks);

  @override
  String toString() => 'SubtitleCalibration(${marks.length} marks)';
}
