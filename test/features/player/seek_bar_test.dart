import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/seek_bar.dart';

/// A TalkBack or VoiceOver user cannot drag or tap a bar they cannot see,
/// so the bar's only way to reach them is the semantics tree -- and until
/// now it offered nothing a screen reader reads as a control to move: a
/// `GestureDetector`'s own tap and horizontal-scroll semantics, which a
/// screen reader has no gesture for (`test/dev/app_driver_test.dart`'s
/// driver saw exactly `{tap, scrollLeft, scrollRight}` on this bar). This
/// is the fix: the bar now presents as a slider, with a value a screen
/// reader can read aloud and an increase/decrease pair that seeks the
/// same ten seconds the on-screen step buttons do.
void main() {
  Widget harness({
    required Duration position,
    required Duration duration,
    Duration buffered = Duration.zero,
    ValueChanged<Duration>? onSeek,
    ValueChanged<Duration>? onStep,
  }) => MaterialApp(
    home: Scaffold(
      body: SeekBar(
        position: position,
        buffered: buffered,
        duration: duration,
        onSeek: onSeek ?? (_) {},
        onStep: onStep,
      ),
    ),
  );

  /// The bar's one semantics node -- there is exactly one `Semantics` in
  /// it, carrying the label every other assertion here finds it by.
  SemanticsNode node() => find.semantics.byLabel('Seek').evaluate().single;

  testWidgets('presents as a slider with a value label, and none of the raw '
      'tap/scroll semantics a GestureDetector would otherwise expose', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      harness(
        position: const Duration(minutes: 15, seconds: 48),
        duration: const Duration(hours: 1, minutes: 48, seconds: 40),
      ),
    );

    final semantics = node();
    final data = semantics.getSemanticsData();

    expect(data.flagsCollection.isSlider, isTrue);
    expect(semantics.value, '15:48 of 1:48:40');
    expect(semantics.increasedValue, '15:58 of 1:48:40');
    expect(semantics.decreasedValue, '15:38 of 1:48:40');
    expect(data.hasAction(SemanticsAction.increase), isTrue);
    expect(data.hasAction(SemanticsAction.decrease), isTrue);
    // The bug: a screen reader had a tap and a horizontal scroll to
    // work with, neither of which TalkBack turns into a seek gesture.
    expect(data.hasAction(SemanticsAction.tap), isFalse);
    expect(data.hasAction(SemanticsAction.scrollLeft), isFalse);
    expect(data.hasAction(SemanticsAction.scrollRight), isFalse);

    handle.dispose();
  });

  testWidgets(
    'increase seeks +10 s through the step path the ±10 s buttons use',
    (tester) async {
      final handle = tester.ensureSemantics();
      final steps = <Duration>[];
      await tester.pumpWidget(
        harness(
          position: const Duration(seconds: 65),
          duration: const Duration(minutes: 96),
          onStep: steps.add,
        ),
      );

      tester.semantics.increase(find.semantics.byLabel('Seek'));
      await tester.pump();

      expect(steps, [const Duration(seconds: 10)]);

      handle.dispose();
    },
  );

  testWidgets('decrease seeks -10 s the same way', (tester) async {
    final handle = tester.ensureSemantics();
    final steps = <Duration>[];
    await tester.pumpWidget(
      harness(
        position: const Duration(seconds: 65),
        duration: const Duration(minutes: 96),
        onStep: steps.add,
      ),
    );

    tester.semantics.decrease(find.semantics.byLabel('Seek'));
    await tester.pump();

    expect(steps, [const Duration(seconds: -10)]);

    handle.dispose();
  });

  testWidgets(
    'with no step callback, increase and decrease move onSeek from the '
    'current position instead',
    (tester) async {
      final handle = tester.ensureSemantics();
      final seeks = <Duration>[];
      await tester.pumpWidget(
        harness(
          position: const Duration(seconds: 65),
          duration: const Duration(minutes: 96),
          onSeek: seeks.add,
        ),
      );

      tester.semantics.increase(find.semantics.byLabel('Seek'));
      await tester.pump();
      tester.semantics.decrease(find.semantics.byLabel('Seek'));
      await tester.pump();

      expect(seeks, [const Duration(seconds: 75), const Duration(seconds: 55)]);

      handle.dispose();
    },
  );

  testWidgets(
    'a bar with nothing playable yet offers no increase or decrease',
    (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        harness(position: Duration.zero, duration: Duration.zero),
      );

      final data = node().getSemanticsData();
      expect(data.hasAction(SemanticsAction.increase), isFalse);
      expect(data.hasAction(SemanticsAction.decrease), isFalse);

      handle.dispose();
    },
  );
}
