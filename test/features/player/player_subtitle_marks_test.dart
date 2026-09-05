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
/// paired with the video position the viewer says it belongs at -- and
/// the arithmetic over those is `SubtitleCalibration`'s, tested on its
/// own. What is tested here is the wiring: that a press makes a mark out
/// of the right two numbers, that the panel says which of the two things
/// it did, that the marks belong to the file that was playing, and that
/// what they derive is remembered like every other correction.
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

  /// A press of "This is right" at video position [at], with the cue
  /// written at [cue] in the file on screen.
  ///
  /// The two are given separately and neither is derived from the other,
  /// because that is the whole of what a mark is: [cue] is what libmpv's
  /// `sub-start` answers -- the raw time in the file, before `sub-speed`
  /// and `sub-delay` moved it -- and [at] is the clock the viewer is
  /// judging against.
  Future<void> mark(
    WidgetTester tester,
    PlayerHarness player, {
    required double? cue,
    required double at,
  }) async {
    player.engine.cueStart = cue;
    player.engine.emitPosition(
      Duration(microseconds: (at * Duration.microsecondsPerSecond).round()),
    );
    await pumpEvents(tester);
    await tester.tap(find.byKey(const ValueKey('subtitle-mark')));
    await tester.pumpAndSettle();
  }

  testWidgets('one mark puts the line where the viewer says it belongs', (
    tester,
  ) async {
    useWideViewport(tester);
    final player = await playing(tester);
    await openPanel(tester);

    // The cue the file writes at 10 s was judged to belong at 12 s, so
    // the offset that puts it there is two seconds and the multiplier is
    // not touched: one point says nothing about a rate.
    await mark(tester, player, cue: 10, at: 12);
    expect(player.engine.subtitleDelay, closeTo(2, 1e-9));
    expect(player.engine.subtitleSpeed, 1);
    expect(find.text('+2.0 s'), findsOneWidget);

    // And the panel says which of the two things happened, because the
    // picture does not: an offset and a rate both land this line where
    // it belongs, and only one of them still holds in ten minutes.
    expect(
      find.text(SubtitleCalibrationOutcome.offset.note),
      findsOneWidget,
      reason: 'a single mark is an offset and the panel says so',
    );
  });

  testWidgets('two marks far apart learn the rate, and two close together '
      'do not', (tester) async {
    useWideViewport(tester);
    final player = await playing(tester);
    await openPanel(tester);

    // Ninety seconds apart is a scene and a half: still one observation
    // as far as a rate is concerned, because a tenth of a second of error
    // over that span is three times the drift worth measuring.
    await mark(tester, player, cue: 10, at: 12);
    await mark(tester, player, cue: 100, at: 103);
    expect(player.engine.subtitleSpeed, 1);
    expect(player.engine.subtitleDelay, closeTo(3, 1e-9));
    expect(find.text(SubtitleCalibrationOutcome.offset.note), findsOneWidget);

    // Ten minutes apart is a lever arm. The line through both marks is
    // the answer, and both of them land exactly where the viewer put
    // them.
    await mark(tester, player, cue: 610, at: 613);
    expect(player.engine.subtitleSpeed, closeTo(601 / 600, 1e-9));
    expect(
      player.engine.subtitleSpeed * 10 + player.engine.subtitleDelay,
      closeTo(12, 1e-9),
    );
    expect(
      player.engine.subtitleSpeed * 610 + player.engine.subtitleDelay,
      closeTo(613, 1e-9),
    );
    expect(find.text(SubtitleCalibrationOutcome.rate.note), findsOneWidget);
    expect(find.text(SubtitleCalibrationOutcome.offset.note), findsNothing);
  });

  testWidgets('a mark near an existing one corrects it', (tester) async {
    useWideViewport(tester);
    final player = await playing(tester);
    await openPanel(tester);

    // Ten seconds later is the same observation made again -- the viewer
    // watching the line they just marked and deciding they were early --
    // so the second replaces the first instead of sitting beside it. Kept
    // beside it, the stale judgement would still be one end of the widest
    // pair and would set the rate over the correction of it.
    await mark(tester, player, cue: 10, at: 12);
    await mark(tester, player, cue: 20, at: 30);
    await mark(tester, player, cue: 620, at: 640);

    // The line through the correction and the far mark, not the one
    // through the judgement it replaced (which is 1.0295).
    expect(player.engine.subtitleSpeed, closeTo(610 / 600, 1e-9));
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
    await mark(tester, player, cue: null, at: 12);
    expect(find.text(subtitleNoCueNote), findsOneWidget);
    expect(player.engine.subtitleDelay, 0);
    expect(player.engine.subtitleSpeed, 1);

    // And it is not remembered as a mark either: the next press is still
    // the first one, so it is an offset and not half of a rate.
    await mark(tester, player, cue: 610, at: 613);
    expect(find.text(SubtitleCalibrationOutcome.offset.note), findsOneWidget);
    expect(player.engine.subtitleSpeed, 1);
  });

  testWidgets('switching subtitles throws the marks away', (tester) async {
    useWideViewport(tester);
    final player = await playing(tester);
    await openPanel(tester);
    await mark(tester, player, cue: 10, at: 12);
    expect(player.engine.subtitleDelay, closeTo(2, 1e-9));

    await selectFile(tester, 'OTHER');
    await openPanel(tester);
    expect(player.engine.subtitleDelay, 0);

    // A mark is a point on one file's timeline, so a mark left over from
    // the last file would pair with this one across two of them: a lever
    // arm of ten minutes and a rate solved from neither file. The press
    // below is the first mark on this file, so it is an offset.
    await mark(tester, player, cue: 610, at: 613);
    expect(find.text(SubtitleCalibrationOutcome.offset.note), findsOneWidget);
    expect(player.engine.subtitleSpeed, 1);
    expect(player.engine.subtitleDelay, closeTo(3, 1e-9));
  });

  testWidgets('what the marks derive is remembered under the ordinary keys', (
    tester,
  ) async {
    useWideViewport(tester);
    final prefs = AppPrefs(client: FakePrefsClient());
    final player = await playing(tester, prefs: prefs);
    await openPanel(tester);
    await mark(tester, player, cue: 10, at: 12);
    await mark(tester, player, cue: 610, at: 613);
    await closePanel(tester);

    // A press on the panel is a judgement whichever button made it, and
    // a mark's judgement is a multiplier and an offset like any other:
    // the speed under the series and the group, the shift under the
    // release as well. What is stored is the two numbers, not the marks
    // that produced them -- next episode is a different file and the
    // marks would mean nothing on it.
    expect(
      prefs.subtitleSync.speedFor(series: series, group: '6'),
      closeTo(601 / 600, 1e-9),
    );
    expect(
      prefs.subtitleSync.shiftSecondsFor(
        series: series,
        group: '6',
        release: opened.toLowerCase(),
      ),
      closeTo(12 - (601 / 600) * 10, 1e-9),
    );
  });
}
