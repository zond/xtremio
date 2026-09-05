import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/player_harness.dart';
import '../../support/tv.dart';

/// What the player tells the display about the film it is showing.
///
/// A 23.98 fps film presented on a 59.94 Hz output is laid on a 3:2
/// cadence, and the frames that miss their vsync are dropped: the owner's
/// projector counted 560 of them at the video output with none at the
/// decoder. Asking for a matching rate removes the cadence; leaving the
/// ask in force afterwards leaves the whole system UI juddering at 24 Hz,
/// which is why every path out of here gives it back.
void main() {
  /// The rate libmpv reports for the owner's film (`container-fps`).
  const filmRate = 23.976025;

  testWidgets('the display is asked for the rate the container declares', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv);
    await harness.pump(tester);

    // Nothing is asked before the file says what it is: a guessed rate
    // buys a mode change and the same uneven cadence afterwards.
    expect(harness.displayFrameRate.requested, isEmpty);

    harness.engine.emitVideoFrameRate(filmRate);
    await pumpEvents(tester);

    expect(harness.displayFrameRate.requested, [filmRate]);
    expect(harness.displayFrameRate.clears, 0);
  });

  testWidgets('the rate is given back when the film ends', (tester) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv);
    await harness.pump(tester);
    harness.engine.emitVideoFrameRate(filmRate);
    await pumpEvents(tester);

    harness.engine.emitEnd();
    await pumpEvents(tester);

    expect(harness.displayFrameRate.clears, 1);
  });

  testWidgets('an end of file that is not the end of the film keeps it', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv);
    await harness.pump(tester);
    harness.engine.emitVideoFrameRate(filmRate);
    harness.engine.emitDuration(const Duration(hours: 2));
    harness.engine.emitPosition(const Duration(seconds: 10));
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);

    // A read that stopped making progress reaches mpv as an end of file;
    // the stream is re-opened and the film goes on, so the display is
    // still showing it.
    harness.engine.emitCompleted();
    await pumpEvents(tester);

    expect(harness.displayFrameRate.clears, 0);
  });

  testWidgets('the rate is given back when the player is left', (tester) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv);
    await harness.pump(tester);
    harness.engine.emitVideoFrameRate(filmRate);
    await pumpEvents(tester);

    // The remote's Stop key, which leaves outright. With nothing under
    // this route to pop to, the screen is still mounted afterwards -- so
    // this is the leaving path on its own, not `dispose` standing in.
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaStop);
    await pumpEvents(tester);

    expect(harness.displayFrameRate.clears, 1);
    expect(find.text('video surface'), findsOneWidget);
  });

  testWidgets('the rate is given back when the screen goes', (tester) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv);
    await harness.pump(tester);
    harness.engine.emitVideoFrameRate(filmRate);
    await pumpEvents(tester);
    expect(harness.displayFrameRate.clears, 0);

    // Whatever took the player away -- Back, the arrow on the bar, the
    // hand-over to the next episode -- the route is gone and the state
    // with it.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();

    expect(harness.displayFrameRate.clears, 1);
  });

  testWidgets('it is given back once, however many paths ask', (tester) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv);
    await harness.pump(tester);
    harness.engine.emitVideoFrameRate(filmRate);
    await pumpEvents(tester);

    harness.engine.emitEnd();
    await pumpEvents(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaStop);
    await pumpEvents(tester);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();

    expect(harness.displayFrameRate.clears, 1);
  });

  testWidgets('a phone is neither asked nor cleared', (tester) async {
    usePhoneViewport(tester);
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitVideoFrameRate(filmRate);
    await pumpEvents(tester);

    harness.engine.emitEnd();
    await pumpEvents(tester);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();

    // A phone's panel has no business switching, so the channel is never
    // spoken to at all -- not even to give back a rate never asked for.
    expect(harness.displayFrameRate.requested, isEmpty);
    expect(harness.displayFrameRate.clears, 0);
  });
}
