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

    test('a speed press is the PAL ratio, and down is its reciprocal', () {
      // 25/23.976 = 1.042709 and not 0.959040. Reversed it does not
      // half-fix a drift, it doubles it, which is the bug this pins.
      const none = SubtitleTiming();
      expect(none.speed, 1);
      expect(none.stretchedBy(1).speed, closeTo(pal, 1e-12));
      expect(none.stretchedBy(-1).speed, closeTo(1 / pal, 1e-12));
      expect(none.stretchedBy(2).speed, closeTo(pal * pal, 1e-12));
    });

    test('a press is taken from the automatic correction, not from 1.0', () {
      // The file the addons said was 25 fps against a 23.976 fps video is
      // already playing at 1.0427. One press down is the whole of "that
      // correction was wrong", and it lands on the file's own timing --
      // not on 1/1.0427, which would be the drift back again and doubled.
      const corrected = SubtitleTiming(automaticSpeed: pal);
      expect(corrected.speed, pal);
      expect(corrected.stretchedBy(-1).speed, closeTo(1, 1e-12));
      // And a file nothing corrected picks the PAL correction up whole.
      expect(const SubtitleTiming().stretchedBy(1).speed, closeTo(pal, 1e-12));
    });

    test('reset goes back to the automatic state, not to 1.0 and 0.0', () {
      // "Undo what I did" is what a viewer means, and what they did is
      // the presses -- not the correction the frame rates asked for,
      // which they never saw and which is still right about the file.
      const corrected = SubtitleTiming(automaticSpeed: pal);
      final adjusted = corrected.shiftedBy(3).stretchedBy(1);
      expect(adjusted.adjusted, isTrue);
      expect(adjusted.automatic.speed, pal);
      expect(adjusted.automatic.delay, 0);
      expect(adjusted.automatic.adjusted, isFalse);
    });

    test('a press mpv would refuse never happens', () {
      // `sub-speed` is `<0.1-10.0>` and media_kit discards the write's
      // return code, so a value outside it is refused in silence and
      // leaves the *previous* multiplier running while the panel claims
      // a new one. The press is dropped instead, and the button that
      // would have made it is drawn dead.
      var timing = const SubtitleTiming();
      for (var i = 0; i < 200; i++) {
        timing = timing.stretchedBy(1);
      }
      expect(timing.speed, lessThanOrEqualTo(maxSubtitleSpeed));
      expect(timing.canStretchBy(1), isFalse);
      expect(timing.stretchedBy(1), same(timing));
      var down = const SubtitleTiming();
      for (var i = 0; i < 200; i++) {
        down = down.stretchedBy(-1);
      }
      expect(down.speed, greaterThanOrEqualTo(minSubtitleSpeed));
      expect(down.canStretchBy(-1), isFalse);
    });

    test('what the panel shows is signed, and never a bare number', () {
      expect(const SubtitleTiming().shiftText, '0.0 s');
      expect(const SubtitleTiming().shiftedBy(1).shiftText, '+0.1 s');
      expect(const SubtitleTiming().shiftedBy(-12).shiftText, '-1.2 s');
      expect(const SubtitleTiming().speedText, '1.000×');
      expect(const SubtitleTiming().stretchedBy(1).speedText, '1.043×');
      expect(const SubtitleTiming().stretchedBy(-1).speedText, '0.959×');
    });
  });

  group('the panel', () {
    /// The overlay over a timing a test drives, recording every press.
    Widget panel(
      SubtitleTiming timing, {
      List<int>? shifts,
      List<int>? stretches,
      VoidCallback? onReset,
      VoidCallback? onClose,
      FocusNode? firstFocusNode,
    }) => MaterialApp(
      home: Scaffold(
        body: SubtitleTimingOverlay(
          timing: timing,
          firstFocusNode: firstFocusNode,
          onShift: (step) => shifts?.add(step),
          onStretch: (step) => stretches?.add(step),
          onReset: onReset ?? () {},
          onClose: onClose ?? () {},
        ),
      ),
    );

    testWidgets('each button steps its own control, once, in its own '
        'direction', (tester) async {
      final shifts = <int>[];
      final stretches = <int>[];
      await tester.pumpWidget(
        panel(const SubtitleTiming(), shifts: shifts, stretches: stretches),
      );
      await tester.tap(find.byKey(const ValueKey('subtitle-shift-later')));
      await tester.tap(find.byKey(const ValueKey('subtitle-shift-earlier')));
      await tester.tap(find.byKey(const ValueKey('subtitle-speed-up')));
      await tester.tap(find.byKey(const ValueKey('subtitle-speed-down')));
      await tester.pump();
      expect(shifts, [1, -1]);
      expect(stretches, [1, -1]);
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

    testWidgets('a press mpv would refuse is not offered either', (
      tester,
    ) async {
      final stretches = <int>[];
      // Past ten times the file's own timing there is nothing left to
      // ask for: the write would be refused in silence.
      var timing = const SubtitleTiming();
      // Bounded rather than `while`, so a guard that stopped guarding
      // fails the test instead of spinning here for ever.
      for (var i = 0; i < 200 && timing.canStretchBy(1); i++) {
        timing = timing.stretchedBy(1);
      }
      expect(timing.canStretchBy(1), isFalse);
      await tester.pumpWidget(panel(timing, stretches: stretches));
      await tester.tap(find.byKey(const ValueKey('subtitle-speed-up')));
      await tester.pump();
      expect(stretches, isEmpty);
      // The other direction is still there to come back with.
      await tester.tap(find.byKey(const ValueKey('subtitle-speed-down')));
      await tester.pump();
      expect(stretches, [-1]);
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
