import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_controls.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/seek_bar.dart';
import 'package:xtremio/features/player/track_menus.dart';
import 'package:xtremio/features/player/up_next_card.dart';

import '../../support/fixtures.dart';
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
    AppPrefs? prefs,
  }) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv, prefs: prefs);
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

  group('the up-next countdown', () {
    /// Ends the episode so the card counts down to the next one.
    Future<PlayerHarness> pumpCountdown(WidgetTester tester) async {
      final harness = await pumpOnTv(tester, withNext: true);
      harness.engine.emitPlaying(true);
      await pumpEvents(tester);
      harness.engine.emitEnd();
      await pumpEvents(tester);
      expect(find.byType(UpNextCard), findsOneWidget);
      return harness;
    }

    testWidgets('down reaches the card, right and left walk it', (
      tester,
    ) async {
      final harness = await pumpCountdown(tester);

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), 'Play now');
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focusedLabel(tester), 'Cancel');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(tester), 'Play now');

      // Select presses the button rather than toggling playback.
      await press(tester, LogicalKeyboardKey.select);
      expect(harness.engine.playOrPauseCalls, 0);
      expect(harness.playerActions(), contains('NextVideo'));
    });

    testWidgets('select on the card cancels the hand-off', (tester) async {
      final harness = await pumpCountdown(tester);

      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focusedLabel(tester), 'Cancel');
      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(UpNextCard), findsNothing);
      expect(harness.playerActions(), isNot(contains('NextVideo')));

      // Down goes back to walking the control bar.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<PlayerBottomBar>(), isTrue);
    });

    testWidgets('the centre key on the video dismisses the countdown', (
      tester,
    ) async {
      final harness = await pumpCountdown(tester);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'player');

      // A tap on the video dismisses it; the remote's centre key is that
      // tap, not a play/pause toggle.
      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(UpNextCard), findsNothing);
      expect(harness.engine.playOrPauseCalls, 0);
      expect(harness.playerActions(), isNot(contains('NextVideo')));
    });

    testWidgets('leaving the card hands the remote back to the video', (
      tester,
    ) async {
      await pumpCountdown(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), 'Play now');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'player');
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

    testWidgets('closing a sheet gives the remote back to its button', (
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
      for (var i = 0; i < 6 && focusedTooltip() != 'Audio track (A)'; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(focusedTooltip(), 'Audio track (A)');
      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(AudioMenu), findsOneWidget);

      await tester.tap(find.text('German'));
      await tester.pumpAndSettle();
      expect(find.byType(AudioMenu), findsNothing);
      expect(
        focusedTooltip(),
        'Audio track (A)',
        reason: 'the neighbouring menu is one press away again',
      );
    });

    testWidgets('the buffer-ahead chips are remote-reachable in the sheet', (
      tester,
    ) async {
      // A control the remote cannot reach is a control a television does
      // not have. The chips are the same shape as the speed ones, so this
      // is really a check that nothing about them opts out of traversal.
      final prefs = AppPrefs.inMemory();
      await pumpOnTv(tester, prefs: prefs);

      await press(tester, LogicalKeyboardKey.arrowUp);
      for (var i = 0; i < 8 && focusedTooltip() != 'Playback settings'; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(focusedTooltip(), 'Playback settings');
      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(PlayerSettingsSheet), findsOneWidget);

      // Down walks into the sheet and onto the first buffer chip.
      for (
        var i = 0;
        i < 8 && focusedLabel(tester) != BufferAhead.normal.label;
        i++
      ) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(focusedLabel(tester), BufferAhead.normal.label);

      // Right walks the scale, and the centre picks what is under it.
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(tester), BufferAhead.large.label);
      await press(tester, LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(PlayerSettingsSheet.bufferChipKey(BufferAhead.large)),
            )
            .selected,
        isTrue,
      );
    });

    testWidgets("a language's other files are reachable with the remote", (
      tester,
    ) async {
      // The alternatives affordance is a row of its own rather than a
      // button inside the language row: directional traversal skips a node
      // inside the focused one's rect, so a nested button would be a
      // control a television does not have.
      final harness = await pumpOnTv(tester);
      harness.fixture['subtitles'] = [
        {
          'request': {
            'base': 'https://opensubtitles-v3.strem.io/manifest.json',
            'path': {
              'resource': 'subtitles',
              'type': 'movie',
              'id': 'tt0063350',
              'extra': <Object>[],
            },
          },
          'content': {
            'type': 'Ready',
            'content': [
              for (var i = 1; i <= 3; i++)
                {
                  'id': 'en-$i',
                  'lang': 'eng',
                  'url': 'https://subs5.strem.io/en/file/$i',
                },
            ],
          },
        },
      ];
      harness.core.setState(
        CoreField.player,
        Map<String, dynamic>.from(harness.fixture),
      );
      await pumpEvents(tester);

      await press(tester, LogicalKeyboardKey.arrowUp);
      for (var i = 0; i < 8 && focusedTooltip() != 'Subtitles (S)'; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(focusedTooltip(), 'Subtitles (S)');
      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(SubtitleMenu), findsOneWidget);

      // Down walks into the sheet: Off, the one language row, then the row
      // that opens its other files.
      const more = '2 other English files';
      for (var i = 0; i < 8 && focusedLabel(tester) != more; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(focusedLabel(tester), more);

      // The centre key opens them, and the next one down is one of them.
      await press(tester, LogicalKeyboardKey.select);
      expect(find.text('Hide other English files'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), 'Option 1');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), 'Option 2');
      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(SubtitleMenu), findsNothing);
      expect(
        harness.engine.externalSubtitles.single.$1,
        Uri.parse('https://subs5.strem.io/en/file/2'),
      );
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
    testWidgets('the centre key plays and pauses from the seek bar', (
      tester,
    ) async {
      final harness = await pumpOnTv(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIn<SeekBar>(), isTrue);

      // The bar has nothing to press, so the centre key means there what
      // it means on the video: play/pause.
      await press(tester, LogicalKeyboardKey.select);
      expect(harness.engine.playOrPauseCalls, 1);
      expect(
        harness.engine.seeks,
        isEmpty,
        reason: 'the centre key is no seek',
      );
      expect(focusIn<SeekBar>(), isTrue, reason: 'focus stays on the bar');
    });

    testWidgets('right walks the transport row to its last button', (
      tester,
    ) async {
      final harness = await pumpOnTv(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedTooltip(), 'Play (Space)');

      // Neither the volume slider nor the fullscreen button is drawn on a
      // television (no pointer to drag one, nothing to toggle in the
      // other), so Mute ends the row: the walk reaches it instead of being
      // trapped on a control that eats every arrow key, and stays there.
      for (var i = 0; i < 8 && focusedTooltip() != 'Mute (M)'; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(focusedTooltip(), 'Mute (M)');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedTooltip(), 'Mute (M)');
      expect(
        harness.engine.volumes,
        isEmpty,
        reason: 'walking the bar never touches the volume',
      );

      // And the remote can still leave the bar from the end of the row.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'player');
    });

    testWidgets('the volume slider stays a focus stop off a TV', (
      tester,
    ) async {
      useWideViewport(tester);
      final harness = PlayerHarness();
      await harness.pump(tester);
      harness.engine.emitDuration(total);
      await pumpEvents(tester);

      // Tab, not the arrows: off a television those change the volume
      // rather than move focus. Where there is a pointer the slider is
      // drawn and takes its turn in the focus order like any other control.
      expect(find.byType(Slider), findsOneWidget);
      for (var i = 0; i < 20 && !focusIn<Slider>(); i++) {
        await press(tester, LogicalKeyboardKey.tab);
      }
      expect(
        focusIn<Slider>(),
        isTrue,
        reason: 'a pointer still drags the volume where there is one',
      );
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

    testWidgets('the subtitles clear the bar the television actually draws', (
      tester,
    ) async {
      final harness = await pumpOnTv(tester);
      // The measured bar, overscan band and all -- not a constant chosen
      // on a phone. On this 720-high panel the television's bar is half
      // again the 96 logical px the constant used to assume.
      final covered =
          tvSize.height - tester.getRect(find.byType(PlayerBottomBar)).top;
      expect(covered, greaterThan(96));
      expect(
        harness.engine.lastSubtitleBottomPadding,
        covered + PlayerScreen.subtitleControlGap,
      );

      // With the bar gone they drop back to their share of the height.
      harness.engine.emitPlaying(true);
      await pumpEvents(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowUp);
      await press(tester, LogicalKeyboardKey.arrowUp);
      await press(tester, LogicalKeyboardKey.arrowUp);
      await tester.pump(PlayerScreen.controlsTimeout);
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester), 0);
      expect(
        harness.engine.lastSubtitleBottomPadding,
        tvSize.height * PlayerScreen.subtitleBottomFraction,
      );
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

    testWidgets('down reaches the bar while the stream is still resolving', (
      tester,
    ) async {
      useScreen(tester, tvSize);
      // No resolved stream yet: no video surface, so no bottom bar to
      // land on.
      final harness = PlayerHarness(
        player: loadPlayerFixture()..['stream'] = null,
        device: tv,
      );
      // The spinner never settles, so this one pumps by hand.
      await tester.pumpWidget(harness.build());
      await pumpEvents(tester);
      expect(find.text('Resolving stream…'), findsOneWidget);
      expect(find.byType(PlayerBottomBar), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await pumpEvents(tester);
      expect(focusIn<PlayerTopBar>(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await pumpEvents(tester);
      expect(
        harness.engine.volumes,
        isEmpty,
        reason: 'the television has its own volume keys',
      );
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
