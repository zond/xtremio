import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/subtitle_timing.dart';
import 'package:xtremio/features/player/track_menus.dart';
import 'package:xtremio/shell/device_profile.dart';

import '../../support/player_harness.dart';
import '../../support/tv.dart';

/// Fixing a subtitle's timing by hand: the panel the subtitle menu opens,
/// what each press writes to the player, and who owns the result.
///
/// The automatic correction only answers a rate mismatch the addon
/// declared. These are the two things it cannot answer -- a cut that
/// starts somewhere else, and a declared rate that was wrong -- and the
/// viewer watching the drift is the only one who can judge either.
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
  /// says nothing about (`PLAIN`, played as it stands) and one it says was
  /// cut for 25 fps (`PAL`, re-timed to 1.0427 the moment it is picked).
  PlayerHarness harness({DeviceProfile? device}) {
    final harness = PlayerHarness(
      device: device,
      configureEngine: (engine) => engine.frameRate = 23.976,
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
  }) async {
    final player = harness(device: device);
    await player.pump(tester);
    player.engine.emitDuration(const Duration(minutes: 96));
    player.engine.emitPlaying(true);
    await pumpEvents(tester);
    await selectFile(tester, pick);
    return player;
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

  testWidgets('a speed press is the whole PAL correction, and the other '
      'way its reciprocal', (tester) async {
    useWideViewport(tester);
    // The file the addon said nothing about is played as it stands, so
    // this is the case where the declared rate was missing and the drift
    // is there anyway.
    final player = await playing(tester);
    final engine = player.engine;
    expect(engine.subtitleSpeed, 1);
    await openPanel(tester);

    await step(tester, 'subtitle-speed-up');
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));
    expect(find.text('1.043×'), findsOneWidget);
    // Back through 1.0 and out the other side: 23.976/25, not 1.0427
    // again, which is the mistake that doubles a drift instead of
    // removing it.
    await step(tester, 'subtitle-speed-down');
    await step(tester, 'subtitle-speed-down');
    expect(engine.subtitleSpeed, closeTo(0.9590, 0.0001));
    expect(find.text('0.959×'), findsOneWidget);
  });

  testWidgets('one press undoes a correction the addon was wrong about', (
    tester,
  ) async {
    useWideViewport(tester);
    // `fpsMilli` is a claim about the release an upload was made for, and
    // a claim can be wrong. This file is already playing at 1.0427; one
    // press down has to land on the file's own timing, which is what
    // taking the step from the correction rather than from 1.0 buys.
    final player = await playing(tester, pick: 'PAL');
    final engine = player.engine;
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));
    await openPanel(tester);
    await step(tester, 'subtitle-speed-down');
    expect(engine.subtitleSpeed, closeTo(1, 1e-9));
    expect(find.text('1.000×'), findsOneWidget);
  });

  testWidgets('reset goes back to the automatic correction, not to 1.0 '
      'and 0.0', (tester) async {
    useWideViewport(tester);
    final player = await playing(tester, pick: 'PAL');
    final engine = player.engine;
    await openPanel(tester);
    await step(tester, 'subtitle-shift-later');
    await step(tester, 'subtitle-speed-up');
    expect(engine.subtitleDelay, closeTo(0.1, 1e-9));
    expect(engine.subtitleSpeed, closeTo(1.0872, 0.0001));

    // "Undo what I did" is what a viewer means. The correction the frame
    // rates asked for is not something they did, and handing it back
    // would return the drift they never asked about.
    await tester.tap(find.byKey(const ValueKey('subtitle-timing-reset')));
    await tester.pump();
    expect(engine.subtitleDelay, 0);
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));
  });

  testWidgets('switching subtitles hands the timing back to the automatic '
      'path', (tester) async {
    useWideViewport(tester);
    final player = await playing(tester);
    final engine = player.engine;
    await openPanel(tester);
    await step(tester, 'subtitle-speed-up');
    await step(tester, 'subtitle-speed-up');
    await step(tester, 'subtitle-shift-later');
    expect(engine.subtitleSpeed, closeTo(1.0872, 0.0001));
    expect(engine.subtitleDelay, closeTo(0.1, 1e-9));

    // Another file is another judgement: it gets its own correction and
    // nothing of the last one's, offset included. An offset made for a
    // file that started late is nonsense on the next one, and mpv keeps
    // `sub-delay` across a track change exactly as it keeps `sub-speed`.
    await selectFile(tester, 'PAL');
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));
    expect(engine.subtitleDelay, 0);

    // And coming back to the first file finds it plain again: the
    // adjustment belonged to the viewing, not to the upload.
    await selectFile(tester, 'PLAIN');
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
    await step(tester, 'subtitle-speed-up');
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
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedTooltip(), 'Subtitles run faster');

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
}
