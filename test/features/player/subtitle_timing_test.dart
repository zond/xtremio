import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/subtitle_groups.dart';
import 'package:xtremio/features/player/subtitle_timing.dart';
import 'package:xtremio/shell/device_profile.dart';

import '../../support/tv.dart';

/// The hand adjustment: what one press of each control is worth, which
/// way it goes, and the panel that drives it.
void main() {
  /// The correction for a 25 fps subtitle on a 23.976 fps film -- what
  /// `subtitleSpeed` would have put in force before anybody touched it.
  const pal = 25 / 23.976;

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

    test('stretching is the PAL ratio and compressing its reciprocal', () {
      // 25/23.976 = 1.042709 and not 0.959040. Reversed it does not
      // half-fix a drift, it doubles it, which is the bug this pins.
      const none = SubtitleTiming();
      expect(none.speed, 1);
      expect(
        none.toggledSpeed(SubtitleSpeedDirection.stretch).speed,
        closeTo(pal, 1e-12),
      );
      expect(
        none.toggledSpeed(SubtitleSpeedDirection.compress).speed,
        closeTo(1 / pal, 1e-12),
      );
    });

    test('the speed control is a toggle, so twice is exactly 1.0', () {
      // Not the ratio squared, which is a state no viewer means to
      // reach: the second press is how somebody who judged the drift
      // backwards gets the file's own timing back, and "exactly" is the
      // point -- 1.0427 squared is nearly 9 % out.
      for (final direction in SubtitleSpeedDirection.values) {
        const none = SubtitleTiming();
        final once = none.toggledSpeed(direction);
        expect(once.speedDirection, direction);
        expect(once.toggledSpeed(direction).speedDirection, isNull);
        expect(once.toggledSpeed(direction).speed, 1);
        expect(once.toggledSpeed(direction).adjusted, isFalse);
      }
      // And pressing the other way replaces the direction rather than
      // compounding it, for the video whose rate said nothing and got
      // both buttons.
      final stretched = const SubtitleTiming().toggledSpeed(
        SubtitleSpeedDirection.stretch,
      );
      expect(
        stretched.toggledSpeed(SubtitleSpeedDirection.compress).speed,
        closeTo(1 / pal, 1e-12),
      );
    });

    test('the video picks the direction, and says so or says nothing', () {
      // The film family runs at one speed and the PAL family 4.27 %
      // faster; drift only appears between the two, so a film-family
      // video can only be facing a PAL-sourced file and needs it
      // stretched. Every rate telecined or doubled off 23.976 or 24 is
      // film, however unlike the numbers look.
      const film = <double>[23.976, 23.98, 24, 29.97, 30, 47.952, 59.94, 60];
      for (final rate in film) {
        expect(
          subtitleSpeedDirection(rate),
          SubtitleSpeedDirection.stretch,
          reason: '$rate is film',
        );
      }
      for (final rate in <double>[25, 50, 12.5]) {
        expect(
          subtitleSpeedDirection(rate),
          SubtitleSpeedDirection.compress,
          reason: '$rate is PAL',
        );
      }
      // A container that said nothing, and a reading in neither family:
      // both mean we know nothing, and the panel offers both buttons.
      expect(subtitleSpeedDirection(null), isNull);
      expect(subtitleSpeedDirection(15), isNull);
      // And why only the container's own figure may reach here: a
      // stalling torrent rendering 12 frames a second reads as film,
      // since 12 is 24 halved, while 12.5 reads as PAL. A measurement
      // of the frames actually delivered would answer confidently and
      // point the button whichever way the stall happened to fall.
      expect(subtitleSpeedDirection(12), SubtitleSpeedDirection.stretch);
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
      expect(
        none.shiftedBy(3).toggledSpeed(SubtitleSpeedDirection.stretch).adjusted,
        isTrue,
      );
    });

    test('no press can reach a multiplier mpv would refuse', () {
      // `sub-speed` is `<0.1-10.0>` and media_kit discards the write's
      // return code, so a value outside it is refused in silence and
      // leaves the *previous* multiplier running while the panel claims
      // a new one. A toggle cannot get near it: three values, and the
      // furthest is 4 % from 1.0.
      for (final direction in [null, ...SubtitleSpeedDirection.values]) {
        final speed = SubtitleTiming(speedDirection: direction).speed;
        expect(speed, greaterThanOrEqualTo(minSubtitleSpeed));
        expect(speed, lessThanOrEqualTo(maxSubtitleSpeed));
      }
    });

    test('what the panel shows is signed, and never a bare number', () {
      expect(const SubtitleTiming().shiftText, '0.0 s');
      expect(const SubtitleTiming().shiftedBy(1).shiftText, '+0.1 s');
      expect(const SubtitleTiming().shiftedBy(-12).shiftText, '-1.2 s');
      expect(const SubtitleTiming().speedText, '1.000×');
      expect(
        const SubtitleTiming(speedDirection: SubtitleSpeedDirection.stretch)
            .speedText,
        '1.043×',
      );
      expect(
        const SubtitleTiming(speedDirection: SubtitleSpeedDirection.compress)
            .speedText,
        '0.959×',
      );
    });
  });

  group('the panel', () {
    /// The overlay over a timing a test drives, recording every press.
    /// [videoDirection] is what the container said the video is, and
    /// null is a container that said nothing.
    Widget panel(
      SubtitleTiming timing, {
      SubtitleSpeedDirection? videoDirection,
      List<int>? shifts,
      List<SubtitleSpeedDirection>? speeds,
      VoidCallback? onReset,
      VoidCallback? onClose,
      FocusNode? firstFocusNode,
    }) => MaterialApp(
      home: Scaffold(
        body: SubtitleTimingOverlay(
          timing: timing,
          videoDirection: videoDirection,
          firstFocusNode: firstFocusNode,
          onShift: (step) => shifts?.add(step),
          onSpeed: (direction) => speeds?.add(direction),
          onReset: onReset ?? () {},
          onClose: onClose ?? () {},
        ),
      ),
    );

    final stretchButton = find.byKey(const ValueKey('subtitle-speed-stretch'));
    final compressButton = find.byKey(
      const ValueKey('subtitle-speed-compress'),
    );

    testWidgets('each button presses its own control, once, in its own '
        'direction', (tester) async {
      final shifts = <int>[];
      final speeds = <SubtitleSpeedDirection>[];
      await tester.pumpWidget(
        panel(const SubtitleTiming(), shifts: shifts, speeds: speeds),
      );
      await tester.tap(find.byKey(const ValueKey('subtitle-shift-later')));
      await tester.tap(find.byKey(const ValueKey('subtitle-shift-earlier')));
      await tester.tap(stretchButton);
      await tester.tap(compressButton);
      await tester.pump();
      expect(shifts, [1, -1]);
      expect(speeds, SubtitleSpeedDirection.values);
    });

    testWidgets('the video that has a rate gets one speed button', (
      tester,
    ) async {
      // The direction is the video's to decide, so there is nothing for
      // a second button to mean: a film-family video can only be facing
      // a PAL-sourced file. Two buttons survive exactly where no
      // direction can be chosen -- otherwise a stream whose rate mpv
      // never reports would be unfixable.
      await tester.pumpWidget(
        panel(
          const SubtitleTiming(),
          videoDirection: SubtitleSpeedDirection.stretch,
        ),
      );
      expect(stretchButton, findsOneWidget);
      expect(compressButton, findsNothing);

      await tester.pumpWidget(
        panel(
          const SubtitleTiming(),
          videoDirection: SubtitleSpeedDirection.compress,
        ),
      );
      expect(compressButton, findsOneWidget);
      expect(stretchButton, findsNothing);

      await tester.pumpWidget(panel(const SubtitleTiming()));
      expect(stretchButton, findsOneWidget);
      expect(compressButton, findsOneWidget);
    });

    testWidgets('a correction in force keeps its button, whatever the '
        'video says', (tester) async {
      // The container's rate is one bounded read taken when the media
      // loads, so a press made while it has not answered can be in the
      // direction the answer then rules out. The toggle is the only way
      // back to exactly 1.0 and a gap cannot be pressed: with its own
      // button gone, the one that is drawn would swap the correction for
      // its reciprocal and never land on 1.0 at all.
      final speeds = <SubtitleSpeedDirection>[];
      await tester.pumpWidget(
        panel(
          const SubtitleTiming(speedDirection: SubtitleSpeedDirection.stretch),
          videoDirection: SubtitleSpeedDirection.compress,
          speeds: speeds,
        ),
      );
      expect(stretchButton, findsOneWidget);
      expect(compressButton, findsOneWidget);
      await tester.tap(stretchButton);
      await tester.pump();
      expect(speeds, [SubtitleSpeedDirection.stretch]);

      // And that press is the whole of the correction, not half of it.
      const inForce = SubtitleTiming(
        speedDirection: SubtitleSpeedDirection.stretch,
      );
      expect(inForce.toggledSpeed(speeds.single).speed, 1);
    });

    testWidgets('a toggle that is on says so on the button', (tester) async {
      // The panel is the surface operated after the OSD bar has gone,
      // and a three-decimal number changing is not enough on its own to
      // say whether the correction is in force.
      Color? fill() =>
          (tester
                      .widget<DecoratedBox>(
                        find
                            .descendant(
                              of: stretchButton,
                              matching: find.byType(DecoratedBox),
                            )
                            .first,
                      )
                      .decoration
                  as BoxDecoration)
              .color;
      await tester.pumpWidget(
        panel(
          const SubtitleTiming(),
          videoDirection: SubtitleSpeedDirection.stretch,
        ),
      );
      final off = fill();
      await tester.pumpWidget(
        panel(
          const SubtitleTiming(speedDirection: SubtitleSpeedDirection.stretch),
          videoDirection: SubtitleSpeedDirection.stretch,
        ),
      );
      expect(fill(), isNot(off));
    });

    testWidgets('the speed toggle does not repeat while it is held', (
      tester,
    ) async {
      // A toggle held down would flip eight times a second, and let go
      // on whichever side the timer happened to leave it.
      final speeds = <SubtitleSpeedDirection>[];
      await tester.pumpWidget(
        panel(
          const SubtitleTiming(),
          videoDirection: SubtitleSpeedDirection.stretch,
          speeds: speeds,
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(stretchButton),
      );
      expect(speeds, [SubtitleSpeedDirection.stretch]);
      await tester.pump(SubtitleTimingOverlay.holdDelay);
      await tester.pump(SubtitleTimingOverlay.repeatInterval * 5);
      expect(speeds, [SubtitleSpeedDirection.stretch]);
      await gesture.up();
      await tester.pump(const Duration(seconds: 2));
      expect(speeds, [SubtitleSpeedDirection.stretch]);
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
