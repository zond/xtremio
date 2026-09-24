import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_controls.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/seek_bar.dart';
import 'package:xtremio/features/player/seek_hold.dart';
import 'package:xtremio/features/player/track_menus.dart';
import 'package:xtremio/features/player/up_next_card.dart';
import 'package:xtremio/widgets/focusable_tile.dart';

import '../../support/fixtures.dart';
import '../../support/player_harness.dart';
import '../../support/tv.dart';

/// Whether any [FocusHighlight] [ring] finds is drawn lit.
bool lit(WidgetTester tester, Finder ring) => tester
    .widgetList<FocusHighlight>(ring)
    .any((highlight) => highlight.focused);

/// What the seek bar is drawn at, which is what a viewer reading the
/// progress sees: the opacity of whatever dims it, or 1 where nothing
/// does.
double seekBarOpacity(WidgetTester tester) {
  final fader = find.descendant(
    of: find.byType(SeekBar),
    matching: find.byType(AnimatedOpacity),
  );
  if (fader.evaluate().isEmpty) return 1;
  return tester.widget<AnimatedOpacity>(fader.first).opacity;
}

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

  /// Preferences that persist nothing, with the emphasis turned up: the
  /// setting under which a missing -- or a misplaced -- indicator is most
  /// obviously so.
  AppPrefs bold() => AppPrefs.inMemory()..setFocusEmphasis(FocusEmphasis.bold);

  /// Plays and lets the controls fade.
  Future<void> playUntilHidden(WidgetTester tester, PlayerHarness h) async {
    h.engine.emitPlaying(true);
    await pumpEvents(tester);
    await tester.pump(PlayerScreen.controlsTimeout);
    await tester.pumpAndSettle();
    expect(controlsOpacity(tester), 0);
  }

  group('D-pad centre', () {
    testWidgets('over a hidden OSD stops the film, and the next press '
        'starts it', (tester) async {
      // The two presses a viewer makes without looking: one to stop the
      // film, one to start it again. The first brings the bar up as it
      // always did, but it also stops the film, and it leaves the remote
      // on the button the second press needs -- so the second press is the
      // same key again, with no hunting in between.
      final harness = await pumpOnTv(tester);
      final engine = harness.engine;
      await playUntilHidden(tester, harness);

      await press(tester, LogicalKeyboardKey.select);
      expect(controlsOpacity(tester), 1);
      expect(engine.playOrPauseCalls, 1);
      expect(focusedTooltip(), 'Pause (Space)');
      expect(
        engine.seeks,
        isEmpty,
        reason: 'the press that stops the film is not also a seek',
      );
      expect(engine.scans, isEmpty);

      // The engine reports it, as mpv does a few milliseconds later.
      engine.emitPlaying(false);
      await pumpEvents(tester);
      expect(focusedTooltip(), 'Play (Space)');

      // Which is the button the second press presses.
      await press(tester, LogicalKeyboardKey.select);
      expect(engine.playOrPauseCalls, 2);
      expect(controlsOpacity(tester), 1);
    });

    testWidgets('with the OSD up it toggles play/pause', (tester) async {
      final harness = await pumpOnTv(tester);
      final engine = harness.engine;
      expect(controlsOpacity(tester), 1);

      await press(tester, LogicalKeyboardKey.select);
      expect(engine.playOrPauseCalls, 1);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'player',
        reason: 'a press with the bar already up moves nothing',
      );

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

    testWidgets('the OSD it brought up stays up while the film is stopped', (
      tester,
    ) async {
      // What a paused player draws is not on a timer: the bar only fades
      // while something is playing, so the button the second press is
      // aimed at is still there however long the viewer takes over it.
      final harness = await pumpOnTv(tester);
      await playUntilHidden(tester, harness);

      await press(tester, LogicalKeyboardKey.select);
      harness.engine.emitPlaying(false);
      await pumpEvents(tester);

      await tester.pump(PlayerScreen.controlsTimeout * 3);
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester), 1);
      expect(focusedTooltip(), 'Play (Space)');

      // And playing again puts it back on its timer, with the remote
      // handed back to the video rather than left on a button nobody can
      // see any more.
      await press(tester, LogicalKeyboardKey.select);
      harness.engine.emitPlaying(true);
      await pumpEvents(tester);
      await tester.pump(PlayerScreen.controlsTimeout);
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester), 0);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'player');
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
      expect(harness.engine.pauseCalls, 0, reason: 'nor does it pause');

      // Space is what a keyboard plays and pauses with, here as anywhere.
      await press(tester, LogicalKeyboardKey.space);
      expect(harness.engine.playOrPauseCalls, 1);
    });

    testWidgets('a touch screen still shows and hides the OSD by tapping', (
      tester,
    ) async {
      // The phone has no D-pad and no centre key: a tap on the picture is
      // how the OSD comes and goes, and it says nothing about playback.
      useWideViewport(tester);
      final harness = PlayerHarness();
      await harness.pump(tester);
      harness.engine.emitDuration(total);
      harness.engine.emitPlaying(true);
      await pumpEvents(tester);
      await tester.pump(PlayerScreen.controlsTimeout);
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester), 0);

      // The video takes double taps too (they seek), so a single one is
      // only a single one once the second has not come.
      await tester.tapAt(tester.getCenter(find.byType(PlayerScreen)));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester), 1);
      expect(harness.engine.pauseCalls, 0);
      expect(harness.engine.playOrPauseCalls, 0);

      await tester.tapAt(tester.getCenter(find.byType(PlayerScreen)));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester), 0);
      expect(harness.engine.pauseCalls, 0);
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

      // The seek step is `seekTimeDuration` (10 s by default), and a
      // remote's transport keys scan with it like the arrows do.
      await press(tester, LogicalKeyboardKey.mediaFastForward);
      await press(tester, LogicalKeyboardKey.mediaRewind);
      expect(engine.scans, [
        const Duration(seconds: 10),
        const Duration(seconds: -10),
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

    testWidgets('the D-pad stays on the card once it is there', (tester) async {
      await pumpCountdown(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), 'Play now');

      // Neither direction walks off the card onto the video, which shows
      // no focus at all. Back is what puts the card away.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), 'Play now');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(tester), 'Play now');
    });
  });

  group('the control bar', () {
    testWidgets('down lands on the seek bar, then on play/pause', (
      tester,
    ) async {
      final harness = await pumpOnTv(tester);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'player');

      // Down: the seek bar. Down again: play/pause, and select presses it.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<SeekBar>(), isTrue);
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
      // and stops there. The video is not a stop on the way out: it draws
      // no focus ring, so landing on it is focus disappearing.
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIn<SeekBar>(), isTrue);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIn<PlayerTopBar>(), isTrue);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIn<PlayerTopBar>(), isTrue);

      // And down from the top of the bar is the seek bar again: the two
      // stops down knows are the two the whole bar leads back to.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<SeekBar>(), isTrue);
    });

    testWidgets('down over a hidden OSD brings it up on the seek bar', (
      tester,
    ) async {
      // One press, and the viewer sees where they landed. The stop is
      // named rather than measured from wherever focus happens to be, so
      // there is nothing invisible being walked: the bar comes up with the
      // remote already on it.
      final harness = await pumpOnTv(tester);
      await playUntilHidden(tester, harness);

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(controlsOpacity(tester), 1);
      expect(focusIn<SeekBar>(), isTrue);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedTooltip(), 'Pause (Space)', reason: 'the film is playing');

      expect(
        harness.engine.playOrPauseCalls,
        0,
        reason: 'a direction is not a transport key',
      );
      expect(harness.engine.seeks, isEmpty);
    });

    testWidgets('and up over a hidden OSD brings it up on the top bar', (
      tester,
    ) async {
      // The same bargain in the other direction: one press, one named
      // stop, and the viewer is shown it.
      final harness = await pumpOnTv(tester);
      await playUntilHidden(tester, harness);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(controlsOpacity(tester), 1);
      expect(focusIn<PlayerTopBar>(), isTrue);
      expect(harness.engine.playOrPauseCalls, 0);
      expect(harness.engine.volumes, isEmpty);
    });

    testWidgets('a press landing as the bar goes strands nothing', (
      tester,
    ) async {
      // The instant the fade starts is a coin toss between the two modes,
      // and the viewer is content with either answer -- so this pins
      // neither. What it pins is that whichever one runs, the press is not
      // also a seek and does not leave the remote on something that is not
      // drawn.
      final harness = await pumpOnTv(tester);
      harness.engine.emitPlaying(true);
      await pumpEvents(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<SeekBar>(), isTrue);

      // Exactly the timeout: the timer and the key in the same instant.
      await tester.pump(PlayerScreen.controlsTimeout);
      await press(tester, LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(controlsOpacity(tester), 1, reason: 'the press brings it back');
      expect(harness.engine.seeks, isEmpty);
      expect(harness.engine.scans, isEmpty);
      final focused = FocusManager.instance.primaryFocus;
      expect(focused?.context, isNotNull, reason: 'focus is on something');
      expect(
        focused?.debugLabel == 'player' || focusIn<PlayerBottomBar>(),
        isTrue,
        reason: 'on the video or on a control of the bar that is up',
      );
    });

    testWidgets('down stays on the seek bar where no transport is drawn', (
      tester,
    ) async {
      // A television narrow enough for the phone layout draws the
      // transport in the middle of the picture, where it is not a focus
      // stop at all: there is no play/pause on the bar to go down to. A
      // press that cannot reach its stop moves nothing, which is what the
      // rest of the bar does at its edges -- it does not climb back up to
      // the top bar, which would be the one direction the viewer did not
      // ask for.
      useScreen(tester, const Size(640, 360));
      final harness = PlayerHarness(device: tv);
      await harness.pump(tester);
      harness.engine.emitDuration(total);
      await pumpEvents(tester);
      expect(find.byType(PlayerCenterControls), findsOneWidget);
      expect(find.byTooltip('Play (Space)'), findsNothing);

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<SeekBar>(), isTrue);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<SeekBar>(), isTrue);
      expect(focusIn<PlayerTopBar>(), isFalse);
    });

    testWidgets('down reaches the seek bar from every stop on the bar', (
      tester,
    ) async {
      // The rule stated over the whole OSD rather than over one column of
      // it: wherever the remote is, one down press is the seek bar and the
      // next is play/pause. Geometry cannot promise that -- directional
      // traversal ranks by distance, so down from a button on the right of
      // the transport row found whatever lay under it -- which is why the
      // two stops are named instead of measured.
      final harness = await pumpOnTv(tester);

      /// Parks the remote on the [index]th stop of the top bar, counting
      /// from the back arrow: up onto the bar, left to its start, then
      /// [index] presses right.
      Future<String?> parkOnTopBar(int index) async {
        for (var i = 0; i < 3 && !focusIn<PlayerTopBar>(); i++) {
          await press(tester, LogicalKeyboardKey.arrowUp);
        }
        for (var i = 0; i < 8; i++) {
          await press(tester, LogicalKeyboardKey.arrowLeft);
        }
        for (var i = 0; i < index; i++) {
          await press(tester, LogicalKeyboardKey.arrowRight);
        }
        return focusedTooltip();
      }

      /// The same for the transport row, whose start is play/pause: the
      /// two down presses under test are how it is reached.
      Future<String?> parkOnTransport(int index) async {
        await press(tester, LogicalKeyboardKey.arrowDown);
        await press(tester, LogicalKeyboardKey.arrowDown);
        for (var i = 0; i < index; i++) {
          await press(tester, LogicalKeyboardKey.arrowRight);
        }
        return focusedTooltip() ?? '${focusedLabel(tester)}';
      }

      final visited = <String>[];
      for (final park in [parkOnTopBar, parkOnTransport]) {
        final seen = <String>[];
        for (var i = 0; i < 8; i++) {
          final here = await park(i);
          // The row's last stop swallows a further right, so a repeat is
          // the end of it.
          if (here == null || seen.contains(here)) break;
          seen.add(here);
          await press(tester, LogicalKeyboardKey.arrowDown);
          expect(
            focusIn<SeekBar>(),
            isTrue,
            reason: 'down from $here missed the seek bar',
          );
          await press(tester, LogicalKeyboardKey.arrowDown);
          expect(
            focusedTooltip(),
            'Play (Space)',
            reason: 'down from the seek bar missed play/pause (from $here)',
          );
        }
        expect(seen.length, greaterThan(2), reason: 'the walk ran: $seen');
        visited.addAll(seen);
      }
      expect(visited, contains('Playback settings'));
      expect(visited, contains('Mute (M)'));
      expect(
        harness.engine.seeks,
        isEmpty,
        reason: 'walking the bar never seeks',
      );
      expect(harness.engine.scans, isEmpty);
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

    testWidgets('every button on the bar wears the floor, stroke and fill', (
      tester,
    ) async {
      // The bar's buttons are marked by the theme floor rather than by a
      // ring, and they were getting half of it: an [IconButton] given a
      // `color` has [IconButton.styleFrom] build an `overlayColor` on the
      // widget's own style -- white at a tenth -- which beats the
      // [IconButtonTheme] the floor is. A tenth over video in a lit room
      // is the cue `FocusTheme` exists because nobody can see, and
      // `FocusTheme.lift` is written for this bar by name.
      await pumpOnTv(tester, prefs: bold());
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedTooltip(), 'Play (Space)');

      final visited = <String>[];
      for (var i = 0; i < 12; i++) {
        final tooltip = focusedTooltip();
        if (tooltip != null && !focusIn<SeekBar>()) {
          visited.add(tooltip);
          expect(focusMarks(), {
            FocusMark.stroke,
            FocusMark.fill,
          }, reason: 'the floor reaches $tooltip by halves');
        }
        await press(tester, LogicalKeyboardKey.arrowRight);
        if (visited.length > 2 && tooltip == focusedTooltip()) {
          // The last button of the row swallows a further right.
          await press(tester, LogicalKeyboardKey.arrowUp);
          await press(tester, LogicalKeyboardKey.arrowUp);
        }
      }
      expect(visited, contains('Play (Space)'));
      expect(visited, contains('Playback settings'));
    });

    testWidgets('and its icons are still white over the video', (tester) async {
      // The colour moved from `color` to the style; a bar whose icons went
      // grey would be a worse fault than the one that move fixed.
      await pumpOnTv(tester);
      final icon = find.descendant(
        of: find.byType(PlayerTopBar),
        matching: find.byIcon(Icons.query_stats),
      );
      expect(
        IconTheme.of(tester.element(icon)).color,
        Colors.white,
        reason: 'the top bar is drawn on black, and its icons are white',
      );
    });

    testWidgets('the seek bar wears the ring while it holds focus', (
      tester,
    ) async {
      // The bar is a bare [Focus] over a [CustomPaint]: no Material in
      // it, so the theme floor has nothing to stroke or fill, and what it
      // drew for itself -- a thicker track in the scheme's violet -- is
      // the cue it also shows a hovering pointer. The ring is what says
      // the remote is here.
      await pumpOnTv(tester);
      final ring = find.descendant(
        of: find.byType(SeekBar),
        matching: find.byType(FocusHighlight),
      );
      expect(lit(tester, ring), isFalse, reason: 'focus starts on the video');

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<SeekBar>(), isTrue);
      expect(lit(tester, ring), isTrue);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIn<PlayerTopBar>(), isTrue);
      expect(lit(tester, ring), isFalse, reason: 'the ring follows focus');
    });

    testWidgets('and does not fade out while the remote is on the rest of '
        'the bar', (tester) async {
      // Bold dims everything the remote is not on, and that is a cue only
      // where the neighbours dim too: on a grid of posters the focused one
      // is the one left bright. On the control bar the seek bar is the
      // only thing wearing a [FocusHighlight] -- play/pause, the seek
      // buttons, the time labels and every button on the top bar are
      // marked by the theme floor and stay where they are -- so dimming it
      // fades out the one element of the bar the viewer is reading, at
      // exactly the moment they are reading it from another control.
      final harness = await pumpOnTv(tester, prefs: bold());
      expect(seekBarOpacity(tester), 1, reason: 'nothing is focused yet');

      // Down onto the seek bar and down again onto the transport row,
      // then right along all of it.
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowDown);
      final visited = <String>[];
      for (var i = 0; i < 10; i++) {
        visited.add(focusedTooltip() ?? '${focusedLabel(tester)}');
        expect(
          seekBarOpacity(tester),
          1,
          reason: 'the seek bar faded while the remote was on ${visited.last}',
        );
        await press(tester, LogicalKeyboardKey.arrowRight);
      }

      // Up onto the bar itself, and up again onto the top bar's buttons.
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIn<SeekBar>(), isTrue);
      expect(seekBarOpacity(tester), 1);

      await press(tester, LogicalKeyboardKey.arrowUp);
      for (var i = 0; i < 8; i++) {
        visited.add(focusedTooltip() ?? '${focusedLabel(tester)}');
        expect(
          seekBarOpacity(tester),
          1,
          reason: 'the seek bar faded while the remote was on ${visited.last}',
        );
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(
        visited,
        contains('Playback settings'),
        reason: 'the walk never left the transport row',
      );
      expect(harness.engine.seeks, isEmpty);
    });

    testWidgets('left and right seek while the seek bar has focus', (
      tester,
    ) async {
      final harness = await pumpOnTv(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<SeekBar>(), isTrue);

      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      // Steps, so they reach the engine as the distance each press
      // asked for; the bar itself is at 75 s.
      expect(harness.engine.scans, [
        const Duration(seconds: 10),
        const Duration(seconds: 10),
        const Duration(seconds: -10),
      ]);
      expect(focusIn<SeekBar>(), isTrue, reason: 'focus stays on the bar');
    });
    testWidgets('holding right on the seek bar scans further', (tester) async {
      // The bar is where the remote scans from, so the acceleration has
      // to be here too; it keeps its own count, because the presses are
      // its own.
      final harness = await pumpOnTv(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<SeekBar>(), isTrue);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      for (var i = 0; i < SeekHold.singleStepFires; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      expect(harness.engine.scans.first, const Duration(seconds: 10));
      expect(harness.engine.scans.last, const Duration(seconds: 20));
      expect(focusIn<SeekBar>(), isTrue, reason: 'focus stays on the bar');
    });

    testWidgets('the centre key plays and pauses from the seek bar', (
      tester,
    ) async {
      final harness = await pumpOnTv(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
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
      expect(harness.engine.scans, isEmpty);
      expect(focusIn<SeekBar>(), isTrue, reason: 'focus stays on the bar');
    });

    testWidgets('right walks the transport row to its last button', (
      tester,
    ) async {
      final harness = await pumpOnTv(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
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

      // Down from the end of the transport row is the seek bar, as it is
      // from every other stop, and down again is play/pause: the far end
      // of the bar is two presses from the control the viewer wants most.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<SeekBar>(), isTrue);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedTooltip(), 'Play (Space)');
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

    testWidgets('the controls fade with a control holding the remote', (
      tester,
    ) async {
      final harness = await pumpOnTv(tester);
      harness.engine.emitPlaying(true);
      await pumpEvents(tester);

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<PlayerBottomBar>(), isTrue);

      // A button holding focus is no reason to keep the bar up -- on a
      // remote there is nowhere else for focus to be, so a veto on it kept
      // the OSD up for the rest of the session. It fades, and the remote
      // comes back to the video with it rather than being left on a
      // button that is no longer drawn.
      await tester.pump(PlayerScreen.controlsTimeout);
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester), 0);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'player');

      // The next press brings the bar back, and the one after walks into it.
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(controlsOpacity(tester), 1);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIn<PlayerTopBar>(), isTrue);
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

  group('Back', () {
    /// The player pushed over a home screen, so Back has somewhere to go.
    Future<PlayerHarness> pushOnTv(
      WidgetTester tester, {
      bool withNext = false,
    }) async {
      useScreen(tester, tvSize);
      final harness = PlayerHarness(device: tv);
      if (withNext) harness.fixture['nextVideo'] = nextVideo;
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
      harness.engine.emitDuration(total);
      harness.engine.emitPosition(const Duration(seconds: 65));
      await pumpEvents(tester);
      return harness;
    }

    testWidgets('hides the OSD and takes the remote back to the video', (
      tester,
    ) async {
      final harness = await pushOnTv(tester);
      harness.engine.emitPlaying(true);
      await pumpEvents(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<PlayerBottomBar>(), isTrue);

      await systemBack(tester);
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(controlsOpacity(tester), 0);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'player');

      // With nothing left to put away it leaves the player.
      await systemBack(tester);
      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.text('Play'), findsOneWidget);
    });

    testWidgets('takes the up-next card away first, and only then leaves', (
      tester,
    ) async {
      final harness = await pushOnTv(tester, withNext: true);
      harness.engine.emitPlaying(true);
      await pumpEvents(tester);
      harness.engine.emitEnd();
      await pumpEvents(tester);
      expect(find.byType(UpNextCard), findsOneWidget);

      // The most transient thing on screen goes first, and the hand-off it
      // was counting down to does not happen.
      await systemBack(tester);
      expect(find.byType(UpNextCard), findsNothing);
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(harness.playerActions(), isNot(contains('NextVideo')));

      // The film has ended, so the engine has stopped playing and the bar
      // is up because nothing may hide it -- the same state as paused,
      // where there is no OSD rung to come down either. Back leaves.
      expect(controlsOpacity(tester), 1);
      await systemBack(tester);
      expect(find.byType(PlayerScreen), findsNothing);
    });

    testWidgets('leaves at once while the controls cannot fade anyway', (
      tester,
    ) async {
      // Paused: the bar is up because nothing may hide it, so there is no
      // rung there for Back to come down. Appearing to do nothing would be
      // worse than leaving.
      final harness = await pushOnTv(tester);
      expect(controlsOpacity(tester), 1);
      expect(harness.engine.playCalls, 0);

      await systemBack(tester);
      expect(find.byType(PlayerScreen), findsNothing);
    });

    testWidgets('off a television it leaves the player, OSD or no OSD', (
      tester,
    ) async {
      useWideViewport(tester);
      final harness = PlayerHarness();
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
      harness.engine.emitDuration(total);
      harness.engine.emitPlaying(true);
      await pumpEvents(tester);
      expect(controlsOpacity(tester), 1);

      // Where there is a pointer the controls have their own way of going
      // away, and Back means what it means everywhere else in the app.
      await systemBack(tester);
      expect(find.byType(PlayerScreen), findsNothing);
    });
  });
}
