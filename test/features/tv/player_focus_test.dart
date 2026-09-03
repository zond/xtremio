import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_controls.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/seek_bar.dart';
import 'package:xtremio/features/player/track_menus.dart';

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

  group('the control bar', () {
    testWidgets('down lands on play/pause, up walks the bar and off it', (
      tester,
    ) async {
      final harness = await pumpOnTv(tester);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'player');

      // Down: play/pause in the bottom bar, and select presses it.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<PlayerBottomBar>(), isTrue);
      expect(find.byTooltip('Play (Space)'), findsOneWidget);
      expect(
        tester
            .getRect(find.byTooltip('Play (Space)'))
            .contains(FocusManager.instance.primaryFocus!.rect.center),
        isTrue,
      );
      await press(tester, LogicalKeyboardKey.select);
      expect(harness.engine.playOrPauseCalls, 1);

      // Up from the transport row reaches the seek bar, then the top bar,
      // then the video again.
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIn<SeekBar>(), isTrue);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIn<PlayerTopBar>(), isTrue);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'player');

      // Up from the video is the top bar directly; down leaves it again.
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIn<PlayerTopBar>(), isTrue);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<SeekBar>(), isTrue);
    });

    testWidgets('right walks the top bar to the menus and select opens one', (
      tester,
    ) async {
      final harness = await pumpOnTv(tester);
      harness.engine.emitTracks(
        const PlaybackTracks(
          audio: [
            TrackInfo(id: '1', title: 'English'),
            TrackInfo(id: '2', title: 'German'),
          ],
        ),
      );
      await pumpEvents(tester);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIn<PlayerTopBar>(), isTrue);
      for (var i = 0; i < 6 && focusedTooltip() != 'Audio track (A)'; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(focusedTooltip(), 'Audio track (A)');

      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(AudioMenu), findsOneWidget);
    });

    testWidgets('left and right seek while the seek bar has focus', (
      tester,
    ) async {
      final harness = await pumpOnTv(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIn<SeekBar>(), isTrue);

      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(harness.engine.seeks, [
        const Duration(seconds: 75),
        const Duration(seconds: 85),
        const Duration(seconds: 75),
      ]);
      expect(focusIn<SeekBar>(), isTrue, reason: 'focus stays on the bar');
    });

    testWidgets('the controls do not fade while a control has focus', (
      tester,
    ) async {
      final harness = await pumpOnTv(tester);
      harness.engine.emitPlaying(true);
      await pumpEvents(tester);

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<PlayerBottomBar>(), isTrue);
      await tester.pump(PlayerScreen.controlsTimeout * 3);
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester), 1);

      // Focus back on the video: the idle timer runs again.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'player');
      await tester.pump(PlayerScreen.controlsTimeout);
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester), 0);
    });

    testWidgets('a control that disappears hands the remote back', (
      tester,
    ) async {
      final harness = await pumpOnTv(tester, withNext: true);
      harness.engine.emitPlaying(true);
      await pumpEvents(tester);

      await press(tester, LogicalKeyboardKey.arrowUp);
      for (var i = 0; i < 6 && focusedTooltip() != 'Next episode (N)'; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(focusedTooltip(), 'Next episode (N)');

      // The engine drops the next episode (this turned out to be the last
      // one): the button holding the remote leaves the tree under it.
      harness.core.setState(
        CoreField.player,
        Map<String, dynamic>.from(harness.fixture)..remove('nextVideo'),
      );
      await pumpEvents(tester);
      await tester.pumpAndSettle();

      expect(FocusManager.instance.primaryFocus?.debugLabel, 'player');
      await press(tester, LogicalKeyboardKey.select);
      expect(harness.engine.playOrPauseCalls, 1, reason: 'the remote lives');

      // And with the video focused again the controls fade as they should.
      await tester.pump(PlayerScreen.controlsTimeout);
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester), 0);
    });

    testWidgets('up and down keep changing the volume off a TV', (
      tester,
    ) async {
      useWideViewport(tester);
      final harness = PlayerHarness();
      await harness.pump(tester);
      harness.engine.emitDuration(total);
      await pumpEvents(tester);

      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(harness.engine.volumes, [95.0, 100.0]);
      expect(focusIn<PlayerBottomBar>(), isFalse);
      expect(
        tester.widget<SeekBar>(find.byType(SeekBar)).focusable,
        isFalse,
        reason: 'the seek bar is a focus stop on a television only',
      );
    });
  });
}
