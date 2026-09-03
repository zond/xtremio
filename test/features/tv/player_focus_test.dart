import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../../support/player_harness.dart';
import '../../support/tv.dart';

/// The player driven by a remote: the D-pad's centre and the media keys.
void main() {
  const total = Duration(minutes: 96);
  const nextVideo = {
    'id': 'tt0063350:1:2',
    'title': 'The Cellar',
    'season': 1,
    'episode': 2,
  };

  /// Mounts the player on a TV with the media loaded at 1:05, not playing.
  Future<PlayerHarness> pumpOnTv(
    WidgetTester tester, {
    bool withNext = false,
  }) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv);
    if (withNext) harness.fixture['nextVideo'] = nextVideo;
    await harness.pump(tester);
    harness.engine.emitDuration(total);
    harness.engine.emitPosition(const Duration(seconds: 65));
    await pumpEvents(tester);
    return harness;
  }

  /// Plays and lets the controls fade.
  Future<void> playUntilHidden(WidgetTester tester, PlayerHarness h) async {
    h.engine.emitPlaying(true);
    await pumpEvents(tester);
    await tester.pump(PlayerScreen.controlsTimeout);
    await tester.pumpAndSettle();
    expect(controlsOpacity(tester), 0);
  }

  group('D-pad centre', () {
    testWidgets('brings hidden controls up, toggles play/pause once shown', (
      tester,
    ) async {
      final harness = await pumpOnTv(tester);
      final engine = harness.engine;
      await playUntilHidden(tester, harness);

      await press(tester, LogicalKeyboardKey.select);
      expect(controlsOpacity(tester), 1);
      expect(engine.playOrPauseCalls, 0, reason: 'only showed the controls');

      await press(tester, LogicalKeyboardKey.select);
      expect(engine.playOrPauseCalls, 1);
      expect(controlsOpacity(tester), 1);

      // Enter is the same key on a remote with a keyboard; a held centre
      // key toggles once, not on every repeat.
      await press(tester, LogicalKeyboardKey.enter);
      expect(engine.playOrPauseCalls, 2);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(engine.playOrPauseCalls, 3);
    });

    testWidgets('off a TV the centre key does nothing to playback', (
      tester,
    ) async {
      useWideViewport(tester);
      final harness = PlayerHarness();
      await harness.pump(tester);
      harness.engine.emitDuration(total);
      await pumpEvents(tester);

      await press(tester, LogicalKeyboardKey.select);
      await press(tester, LogicalKeyboardKey.enter);
      expect(harness.engine.playOrPauseCalls, 0);
    });
  });

  group('media keys', () {
    testWidgets('play, pause, play/pause, forward, rewind', (tester) async {
      final harness = await pumpOnTv(tester);
      final engine = harness.engine;

      await press(tester, LogicalKeyboardKey.mediaPlay);
      expect(engine.playCalls, 1);
      await press(tester, LogicalKeyboardKey.mediaPause);
      expect(engine.pauseCalls, 1);
      await press(tester, LogicalKeyboardKey.mediaPlayPause);
      expect(engine.playOrPauseCalls, 1);

      // The seek step is `seekTimeDuration` (10 s by default).
      await press(tester, LogicalKeyboardKey.mediaFastForward);
      await press(tester, LogicalKeyboardKey.mediaRewind);
      expect(engine.seeks, [
        const Duration(seconds: 75),
        const Duration(seconds: 65),
      ]);
    });

    testWidgets('next track plays the next episode, previous starts over', (
      tester,
    ) async {
      final harness = await pumpOnTv(tester, withNext: true);
      final engine = harness.engine;

      await press(tester, LogicalKeyboardKey.mediaTrackPrevious);
      expect(engine.seeks, [Duration.zero]);
      expect(harness.playerActions(), isNot(contains('NextVideo')));

      await press(tester, LogicalKeyboardKey.mediaTrackNext);
      expect(harness.playerActions(), contains('NextVideo'));
    });

    testWidgets('next track without a next episode does nothing', (
      tester,
    ) async {
      final harness = await pumpOnTv(tester);
      await press(tester, LogicalKeyboardKey.mediaTrackNext);
      expect(harness.playerActions(), isNot(contains('NextVideo')));
    });

    testWidgets('stop leaves the player', (tester) async {
      useScreen(tester, tvSize);
      final harness = PlayerHarness(device: tv);
      await harness.pump(
        tester,
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => harness.screen())),
              child: const Text('Play'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerScreen), findsOneWidget);

      await press(tester, LogicalKeyboardKey.mediaStop);
      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.text('Play'), findsOneWidget);
    });
  });
}
