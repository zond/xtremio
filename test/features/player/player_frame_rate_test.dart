import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xtremio/features/player/player_screen.dart';

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

  testWidgets('the rate is given back when playback fails', (tester) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv);
    await harness.pump(tester);
    harness.engine.emitVideoFrameRate(filmRate);
    harness.engine.emitDuration(const Duration(hours: 2));
    harness.engine.emitPosition(const Duration(minutes: 20));
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);

    // The failure card replaces the picture and this screen stays up, so
    // nothing else on the way out runs: without the release here the
    // panel sits at the film's rate under a static card, and under every
    // menu the viewer opens over it, until they press Back.
    harness.engine.emitError('the stream stopped sending data');
    await pumpEvents(tester);

    expect(find.textContaining('Playback failed'), findsOneWidget);
    expect(harness.displayFrameRate.clears, 1);
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

  /// To the background and back, through the transitions the framework
  /// allows.
  Future<void> sendApp(WidgetTester tester, List<AppLifecycleState> to) async {
    for (final state in to) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
  }

  testWidgets('the ask is made again after the app has been away', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv);
    await harness.pump(tester);
    harness.engine.emitVideoFrameRate(filmRate);
    harness.engine.emitDuration(const Duration(hours: 2));
    harness.engine.emitPosition(const Duration(minutes: 20));
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);
    expect(harness.displayFrameRate.requested, [filmRate]);

    // Home, then back to the film. The surface the app draws into was
    // destroyed and rebuilt, and a `Surface.setFrameRate` vote lives on
    // the surface it was made against -- so the ask has to be made again
    // or the rest of the film plays on the 3:2 cadence.
    await sendApp(tester, [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
    ]);
    await sendApp(tester, [
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    await pumpEvents(tester);

    expect(harness.displayFrameRate.requested, [filmRate, filmRate]);
    expect(harness.displayFrameRate.clears, 0);
  });

  testWidgets('the ask is made again when a finished film plays on', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv);
    await harness.pump(tester);
    harness.engine.emitVideoFrameRate(filmRate);
    await pumpEvents(tester);

    // The film ends and the rate goes back with it...
    harness.engine.emitEnd();
    await pumpEvents(tester);
    expect(harness.displayFrameRate.clears, 1);

    // ...and the viewer rewinds to watch the last ten minutes again. The
    // engine reports a rate once per value and this file's has not
    // changed, so nothing else would ever ask for it again.
    harness.engine.emitPosition(const Duration(minutes: 86));
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);

    expect(harness.displayFrameRate.requested, [filmRate, filmRate]);
  });

  testWidgets('a pause is not a release and does not re-ask', (tester) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv);
    await harness.pump(tester);
    harness.engine.emitVideoFrameRate(filmRate);
    harness.engine.emitDuration(const Duration(hours: 2));
    harness.engine.emitPosition(const Duration(minutes: 20));
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);

    // A mode change costs a second of black picture each way, so a pause
    // keeps the rate -- and the play after it must not buy another one.
    harness.engine.emitPlaying(false);
    await pumpEvents(tester);
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);

    expect(harness.displayFrameRate.requested, [filmRate]);
    expect(harness.displayFrameRate.clears, 0);
  });

  testWidgets('the hand-over gives the rate back before the next player is '
      'built', (tester) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv);
    harness.fixture['nextVideo'] = const {
      'id': 'tt0063350:1:2',
      'title': 'The Cellar',
      'season': 1,
      'episode': 2,
    };
    harness.fixture['nextStream'] = const {
      'url': 'https://x.example/e2.mp4',
      'name': 'Direct',
    };
    await harness.pump(tester);
    harness.engine.emitVideoFrameRate(filmRate);
    await pumpEvents(tester);
    expect(harness.displayFrameRate.requested, [filmRate]);

    // Next pressed in the middle of the episode: the film has not ended,
    // so nothing has released the rate yet. `pushReplacement` keeps this
    // screen alive for the length of the transition, and the next
    // player's own ask lands inside it -- so the release has to be out of
    // the way before the push, not left to a dispose that runs after.
    await tester.tap(find.byTooltip('Next episode (N)'));
    await tester.pump();

    expect(harness.displayFrameRate.clears, 1);
    expect(find.byType(PlayerScreen), findsWidgets);

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
