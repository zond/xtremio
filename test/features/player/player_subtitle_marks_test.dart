import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/subtitle_calibration.dart';
import 'package:xtremio/features/player/track_menus.dart';

import '../../support/fake_prefs_client.dart';
import '../../support/player_harness.dart';

/// "This is right": marking the line on screen where it belongs, and what
/// the marks add up to.
///
/// A mark is a correspondence -- the cue's own time in the subtitle file
/// paired with the video position it is drawn at, under a transform the
/// viewer has looked at and approved -- and the arithmetic over those is
/// `SubtitleCalibration`'s, tested on its own. What is tested here is the
/// wiring: that a press makes a mark out of the right two numbers and
/// **not out of the moment it was pressed**, that the panel says which of
/// the two things it did, that the marks belong to the file that was
/// playing, and that what they derive is remembered like every other
/// correction.
void main() {
  /// The meta item the recorded fixture is a stream for, and the file the
  /// server says it opened: between them, the keys a correction is
  /// remembered under.
  const series = 'tt0063350';
  const opened = 'Night.of.the.Living.Dead.1080p.mp4';

  const plainUrl = 'https://subs.example.org/en-plain.srt';
  const otherUrl = 'https://subs.example.org/en-other.srt';

  Map<String, dynamic> upload(
    String id,
    String url,
    String releaseGroup, {
    Object? g,
  }) => {
    'id': id,
    'lang': 'eng',
    'url': url,
    'releaseGroup': releaseGroup,
    // The addon's own grouping of its files, which is half of what a
    // correction is remembered under. `OTHER` carries none, so switching
    // to it is a file with nothing remembered about it -- what a mark
    // does to the file it was made on is the whole of what is on screen
    // afterwards.
    'g': ?g,
  };

  PlayerHarness harness({AppPrefs? prefs}) {
    final harness = PlayerHarness(prefs: prefs);
    harness.fixture['subtitlePreference'] = null;
    harness.fixture['subtitles'] = [
      {
        'request': {
          'base': 'https://subs.example.org/manifest.json',
          'path': {
            'resource': 'subtitles',
            'type': 'movie',
            'id': series,
            'extra': <Object>[],
          },
        },
        'content': {
          'type': 'Ready',
          'content': [
            upload('en-1', plainUrl, 'PLAIN', g: 6),
            upload('en-2', otherUrl, 'OTHER'),
          ],
        },
      },
    ];
    return harness;
  }

  /// Applies the upload named [releaseGroup] from the subtitle menu.
  Future<void> selectFile(WidgetTester tester, String releaseGroup) async {
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 other English file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(releaseGroup));
    await tester.pumpAndSettle();
  }

  /// The player with the media loaded, the server having named the file
  /// it opened, and [pick] playing.
  Future<PlayerHarness> playing(
    WidgetTester tester, {
    String pick = 'PLAIN',
    AppPrefs? prefs,
  }) async {
    final player = harness(prefs: prefs);
    player.torrentStats.response = const TorrentStats(
      phase: TorrentPhase.buffering,
      streamName: opened,
      initialWindowReadyBytes: 0,
      initialWindowBytes: 4194304,
    );
    await player.pump(tester);
    player.engine.emitDuration(const Duration(minutes: 96));
    player.engine.emitPlaying(true);
    await pumpEvents(tester);
    await selectFile(tester, pick);
    return player;
  }

  Future<void> openPanel(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(SubtitleMenu.adjustTimingLabel));
    await tester.pumpAndSettle();
  }

  /// Closing the panel, which says the adjusting is over and is when what
  /// it came to gets written down.
  Future<void> closePanel(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('subtitle-timing-close')));
    await tester.pumpAndSettle();
    await pumpEvents(tester);
  }

  /// A press of "This is right" with the cue written at [cue] in the file
  /// on screen, the button pressed at video position [pressedAt].
  ///
  /// [cue] is what libmpv's `sub-start` answers -- the raw time in the
  /// file, before `sub-speed` and `sub-delay` moved it. [pressedAt] is
  /// the clock at the moment of the press, and is deliberately *not* half
  /// of the mark: a cue is on screen for seconds and the press lands
  /// wherever the viewer's hand did, so every test here presses somewhere
  /// inside the cue rather than on its first frame.
  Future<void> mark(
    WidgetTester tester,
    PlayerHarness player, {
    required double? cue,
    double pressedAt = 0,
  }) async {
    player.engine.cueStart = cue;
    player.engine.emitPosition(
      Duration(
        microseconds: (pressedAt * Duration.microsecondsPerSecond).round(),
      ),
    );
    await pumpEvents(tester);
    await tester.tap(find.byKey(const ValueKey('subtitle-mark')));
    await tester.pumpAndSettle();
  }

  /// [presses] taps of the shift stepper, later for a positive count and
  /// earlier for a negative one: the viewer putting the line where it
  /// belongs by hand, which is what a mark is made *of*.
  Future<void> shift(WidgetTester tester, int presses) async {
    final key = ValueKey(
      presses < 0 ? 'subtitle-shift-earlier' : 'subtitle-shift-later',
    );
    for (var i = 0; i < presses.abs(); i++) {
      await tester.tap(find.byKey(key));
      await tester.pump();
    }
  }

  testWidgets('a mark records where the viewer put the line, not when they '
      'pressed', (tester) async {
    useWideViewport(tester);
    final player = await playing(tester);
    await openPanel(tester);

    // The viewer shifts until the line on screen lands where it belongs
    // -- six tenths later -- and then says so.
    await shift(tester, 6);
    expect(player.engine.subtitleDelay, closeTo(0.6, 1e-9));

    // The press comes 4.5 seconds into a cue written at 10 s, because
    // that is how long it took to decide and reach the button. Nothing
    // moves: the transform the viewer approved is the one still running.
    // Taking the press instant as the mark would put the cue at 14.5 --
    // four seconds of reaction time applied to a subtitle the button
    // just said was right.
    await mark(tester, player, cue: 10, pressedAt: 14.5);
    expect(
      player.engine.subtitleDelay,
      closeTo(0.6, 1e-9),
      reason: 'the mark is where the cue is drawn, not when the press was',
    );
    expect(player.engine.subtitleSpeed, 1);
    expect(find.text('+0.6 s'), findsOneWidget);

    // And the panel says which of the two things happened, because the
    // picture does not: one mark holds this moment and asks for the one
    // that fixes the rest, and both look alike here and now.
    expect(
      find.text(SubtitleCalibrationOutcome.offset.note),
      findsOneWidget,
      reason: 'a single mark is one point and the panel says so',
    );
  });

  testWidgets('two marks far apart learn the rate, and two close together '
      'do not', (tester) async {
    useWideViewport(tester);
    final player = await playing(tester);
    await openPanel(tester);

    // Right at the start, so the first mark is made on the file's own
    // timing: the cue at 10 s is drawn at 10 s and belongs there.
    await mark(tester, player, cue: 10, pressedAt: 13);

    // A minute and a half later the line has drifted a tenth and the
    // viewer shifts it back. Ninety seconds is a scene and a half, not a
    // lever arm -- a tenth of a second of error over that span is three
    // times the drift worth measuring -- so this is still one
    // observation.
    await shift(tester, 1);
    await mark(tester, player, cue: 100, pressedAt: 101);
    expect(player.engine.subtitleSpeed, 1);
    expect(player.engine.subtitleDelay, closeTo(0.1, 1e-9));
    expect(find.text(SubtitleCalibrationOutcome.offset.note), findsOneWidget);

    // Ten minutes from the first mark it is six tenths out. The viewer
    // shifts it right again and marks it, and now there is a lever arm:
    // the line through the two marks is the answer, and both of them land
    // exactly where the viewer put them.
    await shift(tester, 5);
    await mark(tester, player, cue: 610, pressedAt: 612);
    expect(player.engine.subtitleSpeed, closeTo(600.6 / 600, 1e-9));
    expect(
      player.engine.subtitleSpeed * 10 + player.engine.subtitleDelay,
      closeTo(10, 1e-9),
    );
    expect(
      player.engine.subtitleSpeed * 610 + player.engine.subtitleDelay,
      closeTo(610.6, 1e-9),
    );
    expect(find.text(SubtitleCalibrationOutcome.rate.note), findsOneWidget);
    expect(find.text(SubtitleCalibrationOutcome.offset.note), findsNothing);
  });

  testWidgets('a mark near an existing one corrects it', (tester) async {
    useWideViewport(tester);
    final player = await playing(tester);
    await openPanel(tester);

    // The first judgement, and then the same one made again ten seconds
    // later -- the viewer watching the line they just marked, deciding
    // they were two tenths early and shifting it. That replaces the mark
    // instead of sitting beside it: kept, the stale judgement would still
    // be one end of the widest pair and would set the rate over the
    // correction of it.
    await mark(tester, player, cue: 10, pressedAt: 12);
    await shift(tester, 2);
    await mark(tester, player, cue: 20, pressedAt: 22);
    await shift(tester, 4);
    await mark(tester, player, cue: 620, pressedAt: 621);

    // The line through the correction and the far mark (600.4 over 600),
    // not the one through the judgement it replaced (610.6 over 610).
    expect(player.engine.subtitleSpeed, closeTo(600.4 / 600, 1e-9));
    expect(find.text(SubtitleCalibrationOutcome.rate.note), findsOneWidget);
  });

  testWidgets('a press with no line on screen marks nothing and says so', (
    tester,
  ) async {
    useWideViewport(tester);
    final player = await playing(tester);
    await openPanel(tester);

    // The gaps between cues are most of a film, and the button cannot
    // come and go with them. A press in one has nothing the viewer can
    // have been pointing at, and a mark invented from the position would
    // say the file is already right.
    await mark(tester, player, cue: null, pressedAt: 12);
    expect(find.text(subtitleNoCueNote), findsOneWidget);
    expect(player.engine.subtitleDelay, 0);
    expect(player.engine.subtitleSpeed, 1);

    // And it is not remembered as a mark either: with the shift below in
    // between, a kept one would have a ten-minute lever arm and set a
    // rate. The next press is still the first mark, so it is one point.
    await shift(tester, 3);
    await mark(tester, player, cue: 610, pressedAt: 613);
    expect(find.text(SubtitleCalibrationOutcome.offset.note), findsOneWidget);
    expect(player.engine.subtitleSpeed, 1);
  });

  testWidgets('Reset throws the marks away with the numbers they made', (
    tester,
  ) async {
    useWideViewport(tester);
    final player = await playing(tester);
    await openPanel(tester);
    await mark(tester, player, cue: 10, pressedAt: 12);
    await shift(tester, 6);
    await mark(tester, player, cue: 610, pressedAt: 612);
    expect(player.engine.subtitleSpeed, closeTo(600.6 / 600, 1e-9));

    await tester.tap(find.byKey(const ValueKey('subtitle-timing-reset')));
    await tester.pumpAndSettle();
    expect(player.engine.subtitleSpeed, 1);
    expect(player.engine.subtitleDelay, 0);

    // The note goes too: left up it would say the episode was fixed over
    // a row that now reads 1.000x and +0.0 s.
    expect(find.text(SubtitleCalibrationOutcome.rate.note), findsNothing);
    expect(find.text(SubtitleCalibrationOutcome.offset.note), findsNothing);

    // And the marks themselves, which are the work Reset undoes: the
    // pair the viewer just discarded is still the widest one there is, so
    // a mark kept behind would come back as the answer at the next press
    // -- and short of switching files there would be no way to take a bad
    // mark back at all.
    await mark(tester, player, cue: 300, pressedAt: 302);
    expect(find.text(SubtitleCalibrationOutcome.offset.note), findsOneWidget);
    expect(player.engine.subtitleSpeed, 1);
    expect(player.engine.subtitleDelay, 0);
  });

  testWidgets('switching subtitles throws the marks away', (tester) async {
    useWideViewport(tester);
    final player = await playing(tester);
    await openPanel(tester);
    await shift(tester, 5);
    await mark(tester, player, cue: 10, pressedAt: 12);
    expect(player.engine.subtitleDelay, closeTo(0.5, 1e-9));

    await selectFile(tester, 'OTHER');
    await openPanel(tester);
    expect(player.engine.subtitleDelay, 0);

    // A mark is a point on one file's timeline, so a mark left over from
    // the last file would pair with this one across two of them: a lever
    // arm of ten minutes and a rate solved from neither file. The press
    // below is the first mark on this file, so it is one point and the
    // speed is untouched.
    await mark(tester, player, cue: 610, pressedAt: 613);
    expect(find.text(SubtitleCalibrationOutcome.offset.note), findsOneWidget);
    expect(player.engine.subtitleSpeed, 1);
    expect(player.engine.subtitleDelay, 0);
  });

  testWidgets('what the marks derive is remembered under the ordinary keys', (
    tester,
  ) async {
    useWideViewport(tester);
    final prefs = AppPrefs(client: FakePrefsClient());
    final player = await playing(tester, prefs: prefs);
    await openPanel(tester);
    await mark(tester, player, cue: 10, pressedAt: 12);
    await shift(tester, 6);
    await mark(tester, player, cue: 610, pressedAt: 612);
    await closePanel(tester);

    // A press on the panel is a judgement whichever button made it, and
    // a mark's judgement is a multiplier and an offset like any other:
    // the speed under the series and the group, the shift under the
    // release as well. What is stored is the two numbers, not the marks
    // that produced them -- next episode is a different file and the
    // marks would mean nothing on it.
    expect(
      prefs.subtitleSync.speedFor(series: series, group: '6'),
      closeTo(600.6 / 600, 1e-9),
    );
    expect(
      prefs.subtitleSync.shiftSecondsFor(
        series: series,
        group: '6',
        release: opened.toLowerCase(),
      ),
      closeTo(10 - (600.6 / 600) * 10, 1e-9),
    );
  });
}
