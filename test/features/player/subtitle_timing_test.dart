import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/subtitle_groups.dart';
import 'package:xtremio/features/player/subtitle_timing.dart';
import 'package:xtremio/shell/device_profile.dart';

import '../../support/tv.dart';

/// The hand adjustment: what a press of the shift control is worth,
/// which way it goes, and the panel that drives it.
void main() {
  /// A multiplier a measurement can come to. Nothing on the panel puts
  /// one in force -- a rate is measured now, never pressed -- so this
  /// stands in for what a calibration or a match solved for.
  const measured = 1.044;

  group('the value', () {
    test('a shift press is a tenth of a second, and plus is later', () {
      // mpv's `sub-delay` is seconds and positive delays the lines, so a
      // viewer whose subtitles arrive too early presses plus. The
      // reciprocal mistake here is a sign, and it moves the cue twice as
      // far from where it belongs as leaving it alone.
      const none = SubtitleTiming();
      expect(none.delay, 0);
      expect(none.shiftedBy(1).delay, closeTo(0.1, 1e-12));
      expect(none.shiftedBy(-1).delay, closeTo(-0.1, 1e-12));
      expect(none.shiftedBy(20).delay, closeTo(2, 1e-12));
    });

    test('shifts accumulate and come back to exactly nothing', () {
      // Counted in presses, not in seconds: seven tenths added up as
      // doubles is 0.7000000000000001, and a viewer who pressed back as
      // often as they pressed forward has to land on zero.
      var timing = const SubtitleTiming();
      for (var i = 0; i < 7; i++) {
        timing = timing.shiftedBy(1);
      }
      expect(timing.shiftSteps, 7);
      for (var i = 0; i < 7; i++) {
        timing = timing.shiftedBy(-1);
      }
      expect(timing.delay, 0);
      expect(timing.adjusted, isFalse);
    });

    test('an untouched timing is what a file was written at', () {
      // Nothing else writes either property, so this is the whole of
      // what mpv is playing: a file is played exactly as it stands until
      // the viewer says otherwise, and "undo what I did" and "back to
      // untouched" are the same thing.
      const none = SubtitleTiming();
      expect(none.speed, 1);
      expect(none.delay, 0);
      expect(none.adjusted, isFalse);
      expect(none.shiftedBy(3).adjusted, isTrue);
      expect(const SubtitleTiming(calibratedSpeed: measured).adjusted, isTrue);
      expect(const SubtitleTiming(calibratedDelay: -2.5).adjusted, isTrue);
    });

    test('a shift press never touches the measured multiplier', () {
      // The two are solved together and pressed apart: the presses count
      // on top of the measured offset, and the ratio is not theirs to
      // move. So a nudge after a measurement comes back to it exactly.
      const measuredTiming = SubtitleTiming(
        calibratedSpeed: measured,
        calibratedDelay: 3.25,
      );
      final nudged = measuredTiming.shiftedBy(4).shiftedBy(-4);
      expect(nudged.speed, measured);
      expect(nudged.delay, closeTo(3.25, 1e-12));
      expect(measuredTiming.shiftedBy(1).speed, measured);
      // And what the panel can reach is inside what mpv accepts: only a
      // measurement moves the multiplier, and every measurement believes
      // a ratio within a tenth of the file's own timing.
      expect(measuredTiming.speed, greaterThanOrEqualTo(minSubtitleSpeed));
      expect(measuredTiming.speed, lessThanOrEqualTo(maxSubtitleSpeed));
    });

    test('what the panel shows is signed, and never a bare number', () {
      expect(const SubtitleTiming().shiftText, '0.0 s');
      expect(const SubtitleTiming().shiftedBy(1).shiftText, '+0.1 s');
      expect(const SubtitleTiming().shiftedBy(-12).shiftText, '-1.2 s');
      expect(const SubtitleTiming().speedText, '1.000×');
      expect(
        const SubtitleTiming(calibratedSpeed: measured).speedText,
        '1.044×',
      );
      expect(
        const SubtitleTiming(calibratedSpeed: 25 / 23.976).speedText,
        '1.043×',
      );
    });
  });

  group('the panel', () {
    /// The overlay over a timing a test drives, recording every press.
    ///
    /// Drawn where the player draws it: top right, under the [inset] the
    /// screen leaves for the OSD's own bar, with no height of its own to
    /// stand on. What the panel is tall enough for is not something it
    /// gets to decide.
    Widget panel(
      SubtitleTiming timing, {
      List<int>? shifts,
      VoidCallback? onReset,
      VoidCallback? onClose,
      VoidCallback? onMatch,
      String? matchNote,
      FocusNode? firstFocusNode,
      double inset = 0,
    }) => MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: EdgeInsets.only(top: inset),
          child: Align(
            alignment: Alignment.topRight,
            child: SubtitleTimingOverlay(
              timing: timing,
              firstFocusNode: firstFocusNode,
              onShift: (step) => shifts?.add(step),
              onReset: onReset ?? () {},
              onClose: onClose ?? () {},
              onMatch: onMatch,
              matchNote: matchNote,
            ),
          ),
        ),
      ),
    );

    testWidgets('the panel fits the room a landscape phone leaves it', (
      tester,
    ) async {
      // 360 dp tall is a Galaxy S-series phone held sideways, and the
      // player draws the panel 64 below the top of it, so there is under
      // 300 to sit in. A refusal is what does not fit: "Only 184 of 694
      // cues matched, so nothing was changed" wraps to three lines, and
      // the panel that overflowed pushed Reset off the bottom of the
      // screen -- Reset being the way back from the state the viewer has
      // just landed in. It is also the one case the panel cannot avoid
      // reaching, since a refusal is the honest answer to a bad
      // reference.
      useScreen(tester, const Size(640, 360));
      await tester.pumpWidget(
        panel(
          const SubtitleTiming(),
          inset: 64,
          onMatch: () {},
          matchNote: 'Only 184 of 694 cues matched, so nothing was changed',
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byType(SubtitleTimingOverlay)).bottom,
        lessThanOrEqualTo(360),
      );

      // Reset is below the fold, and the panel's own scroll is what
      // reaches it -- which is what focus traversal does for a remote and
      // a drag does for a finger.
      final reset = find.byKey(const ValueKey('subtitle-timing-reset'));
      await tester.scrollUntilVisible(reset, 40);
      expect(tester.getRect(reset).bottom, lessThanOrEqualTo(360));
    });

    testWidgets('each stepper presses in its own direction, once', (
      tester,
    ) async {
      final shifts = <int>[];
      await tester.pumpWidget(panel(const SubtitleTiming(), shifts: shifts));
      await tester.tap(find.byKey(const ValueKey('subtitle-shift-later')));
      await tester.tap(find.byKey(const ValueKey('subtitle-shift-earlier')));
      await tester.pump();
      expect(shifts, [1, -1]);
    });

    testWidgets('the multiplier is shown and cannot be pressed', (
      tester,
    ) async {
      // The panel is the surface operated after the OSD bar has faded,
      // and a stretch in force is otherwise invisible: a subtitle that
      // is right at this moment and wrong in ten minutes looks exactly
      // like one that is right. But nothing here sets one -- the toggle
      // that offered the PAL constant and its reciprocal was too blunt
      // for the file it was written for, and a measurement replaced it.
      await tester.pumpWidget(
        panel(const SubtitleTiming(calibratedSpeed: measured)),
      );
      expect(find.text(SubtitleTimingOverlay.speedLabel), findsOneWidget);
      expect(find.text('1.044×'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subtitle-speed-stretch')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('subtitle-speed-compress')),
        findsNothing,
      );
    });

    testWidgets('a held button keeps stepping, and stops on the release', (
      tester,
    ) async {
      // Twenty presses for a two-second offset is a chore, not an
      // adjustment.
      final shifts = <int>[];
      await tester.pumpWidget(panel(const SubtitleTiming(), shifts: shifts));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('subtitle-shift-later'))),
      );
      // The press itself, then nothing until the hold is long enough to
      // be a hold: a slow tap must not step twice.
      expect(shifts, [1]);
      await tester.pump(SubtitleTimingOverlay.holdDelay);
      expect(shifts, [1]);
      await tester.pump(SubtitleTimingOverlay.repeatInterval * 3);
      expect(shifts.length, 4);
      await gesture.up();
      await tester.pump(const Duration(seconds: 2));
      expect(shifts.length, 4);
    });

    test('the three strides are a tenth, a second and five seconds', () {
      // Named in presses of `shiftStep`, so the seconds they are worth
      // are arithmetic rather than a promise. Every one of them is a
      // whole number of presses, which is what keeps ten forward and ten
      // back landing on exactly nothing after a hold as well as after a
      // tap.
      const step = SubtitleTiming.shiftStep;
      const tenths = SubtitleTimingOverlay.tenthStrideSteps;
      const seconds = SubtitleTimingOverlay.secondStrideSteps;
      expect(SubtitleTimingOverlay.shiftStrideAt(0) * step, closeTo(0.1, 1e-9));
      expect(
        SubtitleTimingOverlay.shiftStrideAt(tenths) * step,
        closeTo(1, 1e-9),
      );
      expect(
        SubtitleTimingOverlay.shiftStrideAt(tenths + seconds) * step,
        closeTo(5, 1e-9),
      );
    });

    testWidgets('a held shift accelerates through its three strides', (
      tester,
    ) async {
      // A file whose *rate* is wrong is out by minutes at the end of an
      // episode, and marking a point out there means shifting by that
      // much. At a tenth a step that is eleven hundred steps; the whole
      // reason the strides exist is that the toggle which used to fix a
      // rate has gone.
      final shifts = <int>[];
      await tester.pumpWidget(panel(const SubtitleTiming(), shifts: shifts));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('subtitle-shift-later'))),
      );
      await tester.pump(SubtitleTimingOverlay.holdDelay);
      await tester.pump(SubtitleTimingOverlay.repeatInterval * 40);
      await gesture.up();
      await tester.pump();
      const tenths = SubtitleTimingOverlay.tenthStrideSteps;
      const seconds = SubtitleTimingOverlay.secondStrideSteps;
      expect(shifts.length, 41);
      expect(shifts.take(tenths), everyElement(1));
      expect(shifts.skip(tenths).take(seconds), everyElement(10));
      expect(shifts.skip(tenths + seconds), everyElement(50));
      // In order, and every stride a step further out than the one
      // before it: an acceleration that went backwards would still pass
      // the three buckets above.
      expect(shifts, orderedEquals(List.of(shifts)..sort()));
    });

    testWidgets('six seconds of holding reaches the end of a PAL episode', (
      tester,
    ) async {
      // 4.27 % of a three-quarter-hour episode is a hundred and fifteen
      // seconds, which is where the second mark of a calibration gets
      // made. This is the number that says the strides are big enough:
      // without them the same hold is four seconds of shift.
      final shifts = <int>[];
      await tester.pumpWidget(panel(const SubtitleTiming(), shifts: shifts));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('subtitle-shift-later'))),
      );
      await tester.pump(const Duration(seconds: 6));
      await gesture.up();
      await tester.pump();
      final seconds =
          shifts.fold<int>(0, (sum, step) => sum + step) *
          SubtitleTiming.shiftStep;
      expect(seconds, greaterThan(115));
    });

    testWidgets('a tap after a long hold is a tenth again', (tester) async {
      // The strides belong to the hold, not to the control: a viewer who
      // has just crossed a minute still has to be able to nudge the last
      // tenth, and a stride left over from the hold would take it away.
      final shifts = <int>[];
      await tester.pumpWidget(panel(const SubtitleTiming(), shifts: shifts));
      final later = find.byKey(const ValueKey('subtitle-shift-later'));
      final gesture = await tester.startGesture(tester.getCenter(later));
      await tester.pump(const Duration(seconds: 6));
      await gesture.up();
      await tester.pump();
      expect(shifts.last, 50);
      await tester.tap(later);
      await tester.pump();
      expect(shifts.last, 1);
    });

    testWidgets('reset is offered only once there is something to undo', (
      tester,
    ) async {
      var resets = 0;
      await tester.pumpWidget(
        panel(const SubtitleTiming(), onReset: () => resets++),
      );
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('subtitle-timing-reset')),
            )
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(
        panel(const SubtitleTiming().shiftedBy(1), onReset: () => resets++),
      );
      await tester.tap(find.byKey(const ValueKey('subtitle-timing-reset')));
      await tester.pump();
      expect(resets, 1);
    });

    testWidgets('a remote steps it with select, and holds it too', (
      tester,
    ) async {
      // The panel is walked with a D-pad on a television, so select has
      // to do what a finger does -- including the hold, which is the
      // whole of how a two-second offset gets made from a sofa.
      final shifts = <int>[];
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        DeviceScope(
          profile: tv,
          child: panel(
            const SubtitleTiming(),
            shifts: shifts,
            firstFocusNode: node,
          ),
        ),
      );
      node.requestFocus();
      await tester.pump();
      // `firstFocusNode` is the shift's earlier button: where the remote
      // lands when the panel opens.
      expect(focusedTooltip(), 'Subtitles earlier');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      expect(shifts, [-1]);
      await tester.pump(SubtitleTimingOverlay.holdDelay);
      await tester.pump(SubtitleTimingOverlay.repeatInterval * 2);
      expect(shifts.length, 3);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(seconds: 2));
      expect(shifts.length, 3);
    });
  });
}
