import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/subtitle_timing.dart';
import 'package:xtremio/features/player/track_menus.dart';
import 'package:xtremio/shell/device_profile.dart';

import '../../support/player_harness.dart';
import '../../support/tv.dart';

/// Fixing a subtitle's timing by hand: the panel the subtitle menu opens,
/// what each press writes to the player, and who owns the result.
///
/// Nothing else writes either property. A declared frame rate says where
/// an upload came from and not how it is timed -- files that keep perfect
/// time declare a mismatched rate just as often as files that drift -- so
/// the viewer watching the picture is the only one who can judge it.
void main() {
  const palUrl = 'https://subs.example.org/en-25.srt';
  const plainUrl = 'https://subs.example.org/en-plain.srt';

  Map<String, dynamic> upload(
    String id,
    String url,
    String releaseGroup, {
    int? fpsMilli,
  }) => {
    'id': id,
    'lang': 'eng',
    'url': url,
    'releaseGroup': releaseGroup,
    'fpsMilli': ?fpsMilli,
  };

  /// A 23.976 fps film with two English uploads on offer: one the addon
  /// says nothing about (`PLAIN`) and one it says was cut for 25 fps
  /// (`PAL`). Both are played exactly as they were written.
  PlayerHarness harness({DeviceProfile? device, double? frameRate = 23.976}) {
    final harness = PlayerHarness(
      device: device,
      configureEngine: (engine) => engine.frameRate = frameRate,
    );
    harness.fixture['subtitlePreference'] = null;
    harness.fixture['subtitles'] = [
      {
        'request': {
          'base': 'https://subs.example.org/manifest.json',
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
            upload('en-1', plainUrl, 'PLAIN'),
            upload('en-2', palUrl, 'PAL', fpsMilli: 25000),
          ],
        },
      },
    ];
    return harness;
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
  }

  /// Applies the upload named [releaseGroup] from the menu.
  Future<void> selectFile(WidgetTester tester, String releaseGroup) async {
    await openMenu(tester);
    await tester.tap(find.text('1 other English file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(releaseGroup));
    await tester.pumpAndSettle();
  }

  Future<void> openPanel(WidgetTester tester) async {
    await openMenu(tester);
    await tester.tap(find.text(SubtitleMenu.adjustTimingLabel));
    await tester.pumpAndSettle();
  }

  /// One press of a stepper.
  Future<void> step(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pump();
  }

  /// The player with the media loaded and [pick] playing.
  Future<PlayerHarness> playing(
    WidgetTester tester, {
    String pick = 'PLAIN',
    DeviceProfile? device,
    double? frameRate = 23.976,
  }) async {
    final player = harness(device: device, frameRate: frameRate);
    await player.pump(tester);
    player.engine.emitDuration(const Duration(minutes: 96));
    player.engine.emitPlaying(true);
    await pumpEvents(tester);
    await selectFile(tester, pick);
    return player;
  }

  /// A `player` state change that alters nothing -- what makes the screen
  /// run everything it runs on a state event, the auto-pick included.
  void pokeState(PlayerHarness player) => player.core.setState(
    CoreField.player,
    Map<String, dynamic>.from(player.fixture),
  );

  /// The player with an English track of mpv's own drawn, a session
  /// preference asking for an English addon file, and an engine that
  /// refuses it -- so the auto-pick keeps retrying for the rest of the
  /// media, which is the state both of the tests below start from.
  Future<PlayerHarness> refusedAutoPick(WidgetTester tester) async {
    final player = harness();
    player.fixture['subtitlePreference'] = {
      'enabled': true,
      'source': 'external',
      'language': 'eng',
    };
    await player.pump(tester);
    final engine = player.engine..subtitleError = StateError('mpv: no');
    engine.emitTracks(
      const PlaybackTracks(
        subtitle: [TrackInfo(id: '3', language: 'eng')],
        activeSubtitleId: '3',
      ),
    );
    engine.emitDuration(const Duration(minutes: 96));
    engine.emitPlaying(true);
    await pumpEvents(tester);
    expect(engine.externalSubtitles, hasLength(1));
    return player;
  }

  /// The border the panel button keyed [key] is drawn with: its focus
  /// ring while the remote is on it, and [BorderSide.none] otherwise.
  BorderSide? ring(WidgetTester tester, String key) {
    final material = tester
        .widgetList<Material>(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(Material),
          ),
        )
        .first;
    return (material.shape as OutlinedBorder?)?.side;
  }

  final panel = find.byType(SubtitleTimingOverlay);

  testWidgets('the menu offers the panel only once something is playing', (
    tester,
  ) async {
    useWideViewport(tester);
    final player = harness();
    await player.pump(tester);
    player.engine.emitDuration(const Duration(minutes: 96));
    await pumpEvents(tester);

    // Subtitles off: there is nothing on screen to move, and a control
    // that does nothing visible is worse than one that is not there.
    await openMenu(tester);
    expect(find.text(SubtitleMenu.adjustTimingLabel), findsNothing);
    await tester.tap(find.text('1 other English file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PLAIN'));
    await tester.pumpAndSettle();

    await openPanel(tester);
    expect(panel, findsOneWidget);
  });

  testWidgets('a shift press delays the lines, and the other way brings '
      'them forward', (tester) async {
    useWideViewport(tester);
    final player = await playing(tester);
    final engine = player.engine;
    await openPanel(tester);
    expect(engine.subtitleDelay, 0);

    // mpv's `sub-delay` is seconds and positive means later. The sign is
    // what this pins: reversed, a press moves the cue twice as far from
    // where it belongs as leaving the file alone.
    await step(tester, 'subtitle-shift-later');
    expect(engine.subtitleDelay, closeTo(0.1, 1e-9));
    await step(tester, 'subtitle-shift-later');
    expect(engine.subtitleDelay, closeTo(0.2, 1e-9));
    expect(find.text('+0.2 s'), findsOneWidget);

    await step(tester, 'subtitle-shift-earlier');
    await step(tester, 'subtitle-shift-earlier');
    await step(tester, 'subtitle-shift-earlier');
    expect(engine.subtitleDelay, closeTo(-0.1, 1e-9));
    expect(find.text('-0.1 s'), findsOneWidget);
  });

  testWidgets('a film video offers one press, and it stretches', (
    tester,
  ) async {
    useWideViewport(tester);
    // 23.976 is the film family, which can only be facing a PAL-sourced
    // file: 25 fps events over a 23.976 fps picture, so 1.0427 and never
    // its reciprocal. Reversed it does not half-fix the drift, it
    // doubles it, so the direction is not a thing to leave to a guess in
    // front of the picture.
    final player = await playing(tester);
    final engine = player.engine;
    expect(engine.subtitleSpeed, 1);
    await openPanel(tester);
    expect(find.byKey(const ValueKey('subtitle-speed-compress')), findsNothing);

    await step(tester, 'subtitle-speed-stretch');
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));
    expect(find.text('1.043×'), findsOneWidget);

    // And a second press is exactly 1.0, not the ratio squared.
    await step(tester, 'subtitle-speed-stretch');
    expect(engine.subtitleSpeed, 1);
    expect(find.text('1.000×'), findsOneWidget);
  });

  testWidgets('a PAL video offers the press the other way', (tester) async {
    useWideViewport(tester);
    // 25 fps is the PAL family, and the file it can be out of step with
    // is a film-sourced one that has to be compressed: 23.976/25.
    final player = await playing(tester, frameRate: 25);
    final engine = player.engine;
    await openPanel(tester);
    expect(find.byKey(const ValueKey('subtitle-speed-stretch')), findsNothing);

    await step(tester, 'subtitle-speed-compress');
    expect(engine.subtitleSpeed, closeTo(0.9590, 0.0001));
    expect(find.text('0.959×'), findsOneWidget);
    await step(tester, 'subtitle-speed-compress');
    expect(engine.subtitleSpeed, 1);
  });

  testWidgets('a container that declares no rate offers both', (tester) async {
    useWideViewport(tester);
    // A video needs no declared rate to play -- frames carry timestamps
    // -- so `container-fps` is legitimately absent for variable-rate
    // content and for transport streams. With no direction to choose,
    // both buttons are the only honest answer: without them a stream
    // whose rate mpv never reports would be unfixable.
    final player = await playing(tester, frameRate: null);
    final engine = player.engine;
    await openPanel(tester);
    await step(tester, 'subtitle-speed-compress');
    expect(engine.subtitleSpeed, closeTo(0.9590, 0.0001));
    // The other button replaces the direction rather than compounding
    // it, so the pair still cannot reach the ratio squared.
    await step(tester, 'subtitle-speed-stretch');
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));
  });

  testWidgets('a rate in neither family offers both', (tester) async {
    useWideViewport(tester);
    // 15 fps reduces to nothing in either lineage, so it says as little
    // about which way a file has to be pressed as no rate at all. A
    // number we cannot place is not a licence to guess.
    await playing(tester, frameRate: 15);
    await openPanel(tester);
    expect(
      find.byKey(const ValueKey('subtitle-speed-stretch')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('subtitle-speed-compress')),
      findsOneWidget,
    );
  });

  testWidgets('a rate that arrives after playback started still points the '
      'button', (tester) async {
    useWideViewport(tester);
    // The bug from the field: on a torrent mpv cannot probe the
    // container until the pieces holding it have arrived, so the rate is
    // legitimately minutes late and the read this replaced took its
    // silence for "no rate" -- both buttons for the whole of a 23.976
    // episode that could only ever need the stretch.
    final player = await playing(tester, frameRate: null);
    final engine = player.engine;
    await openPanel(tester);
    expect(
      find.byKey(const ValueKey('subtitle-speed-compress')),
      findsOneWidget,
    );

    engine.emitFrameRate(23.976);
    await pumpEvents(tester);
    // The panel is open while it lands, so the direction has to reach
    // the buttons that are already drawn.
    expect(find.byKey(const ValueKey('subtitle-speed-compress')), findsNothing);
    await step(tester, 'subtitle-speed-stretch');
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));
  });

  testWidgets('a correction the viewer already made survives a rate arriving '
      'after it', (tester) async {
    useWideViewport(tester);
    // Taking a late direction is only safe because of this: while the
    // rate said nothing the panel offered both, and a press could land
    // in the direction the answer then rules out. The toggle is the only
    // way back to exactly 1.0 and a gap cannot be pressed, so the button
    // for a correction in force stays whatever the video turns out to
    // be.
    final player = await playing(tester, frameRate: null);
    final engine = player.engine;
    await openPanel(tester);
    await step(tester, 'subtitle-speed-compress');
    expect(engine.subtitleSpeed, closeTo(0.9590, 0.0001));

    engine.emitFrameRate(23.976);
    await pumpEvents(tester);
    expect(
      find.byKey(const ValueKey('subtitle-speed-compress')),
      findsOneWidget,
    );
    await step(tester, 'subtitle-speed-compress');
    expect(engine.subtitleSpeed, 1);
  });

  testWidgets('the observation goes with the player', (tester) async {
    useWideViewport(tester);
    final player = await playing(tester);
    expect(player.engine.observingFrameRate, isTrue);

    await tester.pumpWidget(const SizedBox());
    expect(player.engine.frameRateListeners, 0);
    // And a rate mpv works out after the screen has gone reaches nobody:
    // the handler is a `setState` on an element the framework has
    // already taken apart.
    player.engine.emitFrameRate(25);
    await pumpEvents(tester);
  });

  testWidgets('a file whose declared rate differs is still played as it '
      'stands', (tester) async {
    useWideViewport(tester);
    // `fpsMilli` is a claim about the release an upload was made for, and
    // the same claim covers files that keep time and files that drift:
    // ten English uploads for one film declaring six different rates all
    // run to within 1 % of the same length. Acting on it would break as
    // many as it fixed, so this file arrives untouched and one press is
    // the whole of what the viewer can decide it needs.
    final player = await playing(tester, pick: 'PAL');
    final engine = player.engine;
    expect(engine.subtitleSpeed, 1);
    expect(find.text('1.000×'), findsNothing);
    await openPanel(tester);
    expect(find.text('1.000×'), findsOneWidget);
    await step(tester, 'subtitle-speed-stretch');
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));
  });

  testWidgets('reset goes back to untouched', (tester) async {
    useWideViewport(tester);
    final player = await playing(tester, pick: 'PAL');
    final engine = player.engine;
    await openPanel(tester);
    await step(tester, 'subtitle-shift-later');
    await step(tester, 'subtitle-speed-stretch');
    expect(engine.subtitleDelay, closeTo(0.1, 1e-9));
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));

    // With nothing else writing either property, "undo what I did" and
    // "back to what the file says" are the same thing.
    await tester.tap(find.byKey(const ValueKey('subtitle-timing-reset')));
    await tester.pump();
    expect(engine.subtitleDelay, 0);
    expect(engine.subtitleSpeed, 1);
  });

  testWidgets('switching subtitles puts both back to untouched', (
    tester,
  ) async {
    useWideViewport(tester);
    final player = await playing(tester);
    final engine = player.engine;
    await openPanel(tester);
    await step(tester, 'subtitle-speed-stretch');
    await step(tester, 'subtitle-shift-later');
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));
    expect(engine.subtitleDelay, closeTo(0.1, 1e-9));

    // Another file is another judgement, and it starts from the timing
    // it was written with -- offset included. An offset made for a file
    // that started late is nonsense on the next one, and mpv keeps
    // `sub-delay` across a track change exactly as it keeps `sub-speed`.
    await selectFile(tester, 'PAL');
    expect(engine.subtitleSpeed, 1);
    expect(engine.subtitleDelay, 0);
    expect(find.text('0.0 s'), findsOneWidget);
    expect(find.text('1.000×'), findsOneWidget);
  });

  testWidgets('turning subtitles off puts both back', (tester) async {
    useWideViewport(tester);
    final player = await playing(tester, pick: 'PAL');
    final engine = player.engine;
    await openPanel(tester);
    await step(tester, 'subtitle-shift-later');
    await step(tester, 'subtitle-speed-stretch');
    await openMenu(tester);
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(engine.subtitleSpeed, 1);
    expect(engine.subtitleDelay, 0);
  });

  testWidgets('an adjustment survives the stream being re-opened', (
    tester,
  ) async {
    useWideViewport(tester);
    final player = await playing(tester);
    final engine = player.engine;
    await openPanel(tester);
    await step(tester, 'subtitle-shift-later');
    await step(tester, 'subtitle-speed-stretch');
    engine.subtitleSpeeds.clear();
    engine.subtitleDelays.clear();

    // A read that stopped producing data reaches mpv as an end of file,
    // and the player re-opens the stream where it was. Both values are
    // per playback, not per file, so a correction made ten minutes ago
    // has to be there when the picture comes back.
    engine.emitPosition(const Duration(seconds: 10));
    engine.emitCompleted();
    await pumpEvents(tester);
    expect(engine.opened, hasLength(2));
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));
    expect(engine.subtitleDelay, closeTo(0.1, 1e-9));
  });

  testWidgets('a refused auto-pick leaves alone a file picked while it was '
      'in flight', (tester) async {
    useWideViewport(tester);
    final player = harness();
    player.fixture['subtitlePreference'] = {
      'enabled': true,
      'source': 'external',
      'language': 'eng',
    };
    await player.pump(tester);
    final gate = Completer<void>();
    final engine = player.engine
      ..subtitleError = StateError('mpv: no')
      ..subtitleGate = gate;
    engine.emitDuration(const Duration(minutes: 96));
    engine.emitPlaying(true);
    await pumpEvents(tester);

    // The session's pick is out on the network and unanswered: `sub-add`
    // fetches the URL under mpv's own `network-timeout`, so a refusal
    // can be minutes away.
    expect(engine.externalSubtitles, hasLength(1));
    expect(engine.externalSubtitles.single.$1.toString(), plainUrl);

    // Meanwhile the viewer picks a file of their own and shifts it.
    engine.subtitleError = null;
    await selectFile(tester, 'PAL');
    await openPanel(tester);
    await step(tester, 'subtitle-shift-later');
    await step(tester, 'subtitle-speed-stretch');
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));
    expect(engine.subtitleDelay, closeTo(0.1, 1e-9));

    // The refusal lands. What it has to undo is its own attempt, and
    // that is no longer what is on screen: reverting here would take the
    // viewer's own multiplier and offset off a file that is playing, and
    // label the menu with a selection nobody made.
    gate.complete();
    await pumpEvents(tester);
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));
    expect(engine.subtitleDelay, closeTo(0.1, 1e-9));
    expect(find.text('+0.1 s'), findsOneWidget);
  });

  testWidgets('a file picked by hand ends a refused auto-pick', (tester) async {
    useWideViewport(tester);
    final player = await refusedAutoPick(tester);
    final engine = player.engine;

    // The viewer picks for themselves, and stretches what they picked.
    engine.subtitleError = null;
    await selectFile(tester, 'PAL');
    await openPanel(tester);
    await step(tester, 'subtitle-speed-stretch');
    expect(engine.externalSubtitles, hasLength(2));
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));

    // Nothing counted the refused pick as done, so it went on retrying on
    // every state and tracks event -- taking the viewer's file away again
    // and their adjustment with it. Their own choice is the answer the
    // preference was guessing at.
    pokeState(player);
    await pumpEvents(tester);
    expect(engine.externalSubtitles, hasLength(2));
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));
  });

  testWidgets('a hand adjustment ends a refused auto-pick', (tester) async {
    useWideViewport(tester);
    final player = await refusedAutoPick(tester);
    final engine = player.engine;

    // mpv's own English track is what is drawn, and the panel reaches it.
    await openPanel(tester);
    await step(tester, 'subtitle-shift-later');
    await step(tester, 'subtitle-shift-later');
    expect(engine.subtitleDelay, closeTo(0.2, 1e-9));

    // One state tick used to retry the refused pick, and every retry
    // replaced the whole timing: the shift vanished a moment after it was
    // made, while the viewer was watching the picture for it to take
    // effect, and it vanished again a second later.
    pokeState(player);
    await pumpEvents(tester);
    expect(engine.subtitleDelay, closeTo(0.2, 1e-9));
    expect(engine.externalSubtitles, hasLength(1));
    expect(find.text('+0.2 s'), findsOneWidget);
  });

  testWidgets('a re-open puts the addon file back before the timing', (
    tester,
  ) async {
    useWideViewport(tester);
    final player = await playing(tester, pick: 'PAL');
    final engine = player.engine;
    expect(engine.externalSubtitles, hasLength(1));
    await openPanel(tester);
    await step(tester, 'subtitle-shift-later');
    await step(tester, 'subtitle-speed-stretch');

    // `open` is `loadfile`, and nothing `sub-add` put in survives one:
    // mpv comes back drawing whatever it selects by its own rules,
    // typically a default-flagged embedded track. Writing the viewer's
    // multiplier and offset onto *that* takes a subtitle that was in
    // step four seconds a minute out, and no path resets it.
    engine.emitPosition(const Duration(seconds: 10));
    engine.emitCompleted();
    await pumpEvents(tester);
    expect(engine.opened, hasLength(2));
    expect(engine.externalSubtitles, hasLength(2));
    expect(engine.externalSubtitles.last.$1.toString(), palUrl);
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));
    expect(engine.subtitleDelay, closeTo(0.1, 1e-9));

    // And only while there is a file to put back. An embedded track and
    // subtitles off are not something `sub-add` can restore, and
    // re-adding the last file would overrule the choice just made.
    await openMenu(tester);
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    engine.emitPosition(const Duration(seconds: 20));
    engine.emitCompleted();
    await pumpEvents(tester);
    expect(engine.opened, hasLength(3));
    expect(engine.externalSubtitles, hasLength(2));
  });

  testWidgets('the panel does not fade on the OSD timer', (tester) async {
    useWideViewport(tester);
    final player = await playing(tester);
    await openPanel(tester);
    expect(panel, findsOneWidget);

    // The bar goes, which is the point: adjusting means pressing and then
    // watching the picture for several seconds, and a panel on the OSD's
    // three-second timer would be gone before the first judgement.
    await tester.pump(PlayerScreen.controlsTimeout);
    await tester.pumpAndSettle();
    expect(controlsOpacity(tester), 0);
    expect(panel, findsOneWidget);
    await step(tester, 'subtitle-shift-later');
    expect(player.engine.subtitleDelay, closeTo(0.1, 1e-9));
  });

  testWidgets('Shift+S opens and closes it; S is still the list', (
    tester,
  ) async {
    useWideViewport(tester);
    final player = await playing(tester);
    expect(panel, findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.pumpAndSettle();
    expect(find.byType(SubtitleMenu), findsOneWidget);
    expect(player.engine.subtitleDelays, isNotEmpty);
  });

  testWidgets('on a television the remote stays in the panel and Back is '
      'the way out', (tester) async {
    useScreen(tester, tvSize);
    final player = await playing(tester, device: tv);
    await openPanel(tester);
    await tester.pumpAndSettle();

    // The remote lands on the first stepper, not on the bar behind it.
    expect(focusedTooltip(), 'Subtitles earlier');

    // Let the bar go. Everything below is then about the panel alone:
    // the only rung Back has left is this one, and the ring is still on
    // something that is drawn.
    await tester.pump(PlayerScreen.controlsTimeout);
    await tester.pumpAndSettle();
    expect(controlsOpacity(tester), 0);
    expect(focusedTooltip(), 'Subtitles earlier');
    // Left and right walk the row; up and down move between them.
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTooltip(), 'Subtitles later');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTooltip(), 'Subtitles run slower');
    // This video's rate is known, so the speed row is one button and a
    // left press along it has nowhere to go. It stays in the panel
    // rather than escaping onto the seek bar behind.
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusIn<SubtitleTimingOverlay>(), isTrue);

    // Nothing steps out of it. The video draws no focus ring, so it is
    // not a legitimate stop while something visible is on screen, and a
    // press that left the panel would put the ring nowhere.
    for (var i = 0; i < 6; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(focusIn<SubtitleTimingOverlay>(), isTrue);
    for (var i = 0; i < 6; i++) {
      await press(tester, LogicalKeyboardKey.arrowUp);
    }
    expect(focusIn<SubtitleTimingOverlay>(), isTrue);
    // And the seek bar never saw a left press: the position is where the
    // media was opened.
    expect(player.engine.seeks, isEmpty);

    // Back closes the panel, and only then leaves the player.
    await systemBack(tester);
    expect(panel, findsNothing);
    expect(find.byType(PlayerScreen), findsOneWidget);
  });

  testWidgets('Reset and Close wear the same ring as the steppers', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    final player = await playing(tester, device: tv);
    await openPanel(tester);
    // Also what makes Reset reachable at all, which is exactly when a
    // viewer wants it.
    await step(tester, 'subtitle-shift-later');
    final primary = Theme.of(tester.element(panel)).colorScheme.primary;
    expect(player.engine.subtitleDelay, closeTo(0.1, 1e-9));

    // Material's own focus for a TextButton and an IconButton is a
    // 10 %-opacity overlay: over this panel's near-black ground it is
    // about 1.2:1, against the 9.7:1 the steppers' ring manages a
    // hundred pixels away. At three metres those two stops of the same
    // panel simply have no ring, and this is the surface meant to be
    // operated after the OSD bar has faded.
    expect(ring(tester, 'subtitle-timing-reset'), BorderSide.none);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedTooltip(), 'Close');
    expect(
      ring(tester, 'subtitle-timing-close'),
      BorderSide(color: primary, width: 2),
    );

    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedLabel(tester), SubtitleTimingOverlay.resetLabel);
    expect(
      ring(tester, 'subtitle-timing-reset'),
      BorderSide(color: primary, width: 2),
    );
    expect(ring(tester, 'subtitle-timing-close'), BorderSide.none);
  });

  testWidgets('the speed toggle held on a remote presses once', (tester) async {
    useScreen(tester, tvSize);
    final player = await playing(tester, device: tv);
    final engine = player.engine;
    await openPanel(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTooltip(), 'Subtitles run slower');

    // The shift stepper repeats while it is held, because twenty presses
    // for a two-second offset is a chore. A toggle must not: held down
    // at the stepper's rate it would flip eight times a second and land
    // on whichever side the release happened to fall.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(SubtitleTimingOverlay.holdDelay);
    for (var i = 0; i < 20; i++) {
      await tester.pump(SubtitleTimingOverlay.repeatInterval);
    }
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump(SubtitleTimingOverlay.repeatInterval * 4);
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));
  });
}
