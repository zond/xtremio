import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/seek_bar.dart';

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
}
