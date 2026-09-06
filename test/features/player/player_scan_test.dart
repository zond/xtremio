import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/seek_bar.dart';
import 'package:xtremio/features/player/seek_hold.dart';

import '../../support/player_harness.dart';

/// Scanning: which presses ask mpv for a keyframe and which ask it for a
/// frame, and the command the first of those is.
///
/// media_kit has no relative seek and throws `mpv_command`'s return code
/// away, so the one thing a test on this side can hold is the string that
/// was measured against a running libmpv: `relative` for the direction
/// mpv rounds in, `keyframes` for the decode this exists to skip. What
/// libmpv does with it is not reachable from here at all -- see the
/// measurements written down at `MediaKitEngine.scanBy`.
void main() {
  group('a scan step is a relative keyframe seek', () {
    test('the step mpv is asked for is the one the viewer pressed', () {
      expect(MediaKitEngine.scanCommand(const Duration(seconds: 10)), [
        'seek',
        '10.0000',
        'relative+keyframes',
      ]);
    });

    test('a step back is the same command signed', () {
      // Not a separate flag: mpv takes the direction from the sign and
      // rounds to the keyframe past the target on the way back too.
      expect(MediaKitEngine.scanCommand(const Duration(seconds: -30)), [
        'seek',
        '-30.0000',
        'relative+keyframes',
      ]);
    });

    test('a fraction of a second survives the trip', () {
      // Whole seconds are what a seek step happens to be today; the
      // command carries what it is given, as media_kit's own absolute
      // seek does.
      expect(
        MediaKitEngine.scanCommand(const Duration(milliseconds: 3500))[1],
        '3.5000',
      );
    });
  });

  group('a step is a scan and a named position is not', () {
    const total = Duration(minutes: 96);
    const at = Duration(seconds: 65);

    Future<PlayerHarness> pumpPlaying(WidgetTester tester) async {
      useWideViewport(tester);
      final harness = PlayerHarness();
      await harness.pump(tester);
      harness.engine.emitDuration(total);
      harness.engine.emitPosition(at);
      harness.engine.emitPlaying(true);
      await pumpEvents(tester);
      return harness;
    }

    testWidgets('a press of the seek key asks for a step, not a position', (
      tester,
    ) async {
      final harness = await pumpPlaying(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      // The distance is what mpv is given, because mpv is the one that
      // knows where the keyframes are.
      expect(harness.engine.scans, [const Duration(seconds: 10)]);
      expect(harness.engine.seeks, isEmpty);
      // The bar goes to where the press asked for all the same: mpv's own
      // answer arrives on the position stream a moment later, and until
      // it does the viewer has to see the press do something.
      expect(find.text('1:15 / 1:36:00'), findsOneWidget);
    });

    testWidgets('a tap on the seek bar is seeked to exactly', (tester) async {
      // The viewer named a moment here rather than asking to go further
      // on, so this is the seek that decodes to it.
      final harness = await pumpPlaying(tester);
      final rect = tester.getRect(find.byType(SeekBar));
      await tester.tapAt(Offset(rect.left + rect.width * 0.25, rect.center.dy));
      await tester.pump();

      expect(harness.engine.seeks, [const Duration(minutes: 24)]);
      expect(harness.engine.scans, isEmpty);
    });

    testWidgets('the short step is exact, because a keyframe is longer', (
      tester,
    ) async {
      // `seekShortTimeDuration` is 3 s and the gap between keyframes is
      // routinely ten, so a scan would answer this press with a jump
      // three times the size of the one it asked for -- on the key a
      // viewer reaches for when the ordinary step is already too coarse.
      final harness = await pumpPlaying(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(harness.engine.seeks, [const Duration(seconds: 68)]);
      expect(harness.engine.scans, isEmpty);
    });
  });

  testWidgets('a seek bar with no use for the distinction still seeks', (
    tester,
  ) async {
    // The cast overlay draws one of these with nothing to scan through.
    final seeks = <Duration>[];
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SeekBar(
            position: const Duration(minutes: 1),
            buffered: Duration.zero,
            duration: const Duration(minutes: 10),
            onSeek: seeks.add,
            focusable: true,
            focusNode: node,
          ),
        ),
      ),
    );
    node.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(seeks, [const Duration(minutes: 1, seconds: 10)]);
  });

  group('a held seek key accelerates, and only a held one', () {
    /// A press and a repeat of one of the two keys a hold can be on.
    KeyEvent down(LogicalKeyboardKey key) => KeyDownEvent(
      physicalKey: key == LogicalKeyboardKey.arrowLeft
          ? PhysicalKeyboardKey.arrowLeft
          : PhysicalKeyboardKey.arrowRight,
      logicalKey: key,
      timeStamp: Duration.zero,
    );
    KeyEvent repeat(LogicalKeyboardKey key) => KeyRepeatEvent(
      physicalKey: key == LogicalKeyboardKey.arrowLeft
          ? PhysicalKeyboardKey.arrowLeft
          : PhysicalKeyboardKey.arrowRight,
      logicalKey: key,
      timeStamp: Duration.zero,
    );

    test('a tap is one step, however long the hold before it was', () {
      // The same rule the subtitle shift keeps: the stride belongs to
      // the hold, so the viewer's own step is always a press away.
      final hold = SeekHold();
      const step = Duration(seconds: 10);
      const key = LogicalKeyboardKey.arrowRight;
      expect(hold.stepFor(down(key), step), step);
      for (var i = 0; i < 40; i++) {
        hold.stepFor(repeat(key), step);
      }
      expect(hold.stepFor(down(key), step), step);
    });

    test('holding it moves further, in whole steps of the viewer\'s own', () {
      final hold = SeekHold();
      const step = Duration(seconds: 30);
      const key = LogicalKeyboardKey.arrowRight;
      Duration fire(int times) {
        var last = hold.stepFor(down(key), step);
        for (var i = 0; i < times; i++) {
          last = hold.stepFor(repeat(key), step);
        }
        return last;
      }

      expect(fire(SeekHold.singleStepFires - 1), step);
      expect(fire(SeekHold.singleStepFires), step * 2);
      expect(
        fire(SeekHold.singleStepFires + SeekHold.doubleStepFires - 1),
        step * 2,
      );
      expect(
        fire(SeekHold.singleStepFires + SeekHold.doubleStepFires),
        step * 5,
      );
    });

    test('turning round mid-hold starts again', () {
      // Left and right are different keys and the press that reverses
      // direction is a fresh one -- overshooting at five steps a press
      // and having to come back at five is not a way to land anywhere.
      final hold = SeekHold();
      const step = Duration(seconds: 10);
      hold.stepFor(down(LogicalKeyboardKey.arrowRight), step);
      for (var i = 0; i < 30; i++) {
        hold.stepFor(repeat(LogicalKeyboardKey.arrowRight), step);
      }
      expect(hold.stepFor(down(LogicalKeyboardKey.arrowLeft), step), step);
    });

    testWidgets('a held arrow scans further the longer it is held', (
      tester,
    ) async {
      useWideViewport(tester);
      final harness = PlayerHarness();
      await harness.pump(tester);
      harness.engine.emitDuration(const Duration(minutes: 96));
      harness.engine.emitPosition(const Duration(seconds: 65));
      harness.engine.emitPlaying(true);
      await pumpEvents(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      for (var i = 0; i < SeekHold.singleStepFires; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      final scans = harness.engine.scans;
      expect(scans.first, const Duration(seconds: 10));
      expect(scans.last, const Duration(seconds: 20));
      // Nothing else takes the key: every press is a step, and a
      // release ends the hold rather than seeking again.
      expect(scans, hasLength(SeekHold.singleStepFires + 1));
      expect(harness.engine.seeks, isEmpty);
    });
  });
}
