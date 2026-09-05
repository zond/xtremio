import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/subtitle_timing.dart';
import 'package:xtremio/features/player/track_menus.dart';

import '../../support/fake_prefs_client.dart';
import '../../support/player_harness.dart';

/// Remembering what the viewer fixed, and putting it back the next time
/// the same subtitle group is played.
///
/// Nothing re-times a subtitle but the viewer, so the correction they made
/// by hand is the only thing there is to remember -- and it is remembered
/// under what caused it: a speed on the series and the addon's subtitle
/// group, a shift on the video release as well. Any part of a key nobody
/// can name means the adjustment is not remembered at all.
void main() {
  /// The meta item the recorded fixture is a stream for.
  const series = 'tt0063350';
  const opened = 'Night.of.the.Living.Dead.1080p.mp4';

  /// What a press of the stretch button comes to, which is what the file
  /// now stores: the number that was on the player, not the name of the
  /// button that put it there.
  const stretch = 25 / 23.976;

  const plainUrl = 'https://subs.example.org/en-plain.srt';
  const otherUrl = 'https://subs.example.org/en-other.srt';
  const frenchUrl = 'https://subs.example.org/fr.srt';

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
    'g': ?g,
  };

  /// Two English uploads: `SIX` from the addon's group 6, and `NONE` from
  /// an addon that says nothing about where its files came from.
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
            upload('en-1', plainUrl, 'SIX', g: 6),
            upload('en-2', otherUrl, 'NONE'),
            // A language of its own, so its row applies it with one tap
            // and no second menu transition.
            {'id': 'fr-1', 'lang': 'fre', 'url': frenchUrl},
          ],
        },
      },
    ];
    return harness;
  }

  /// The player with the media loaded, the server having named the file
  /// it opened, and [pick] playing.
  Future<PlayerHarness> playing(
    WidgetTester tester, {
    String pick = 'SIX',
    AppPrefs? prefs,
    String? streamName = opened,
  }) async {
    final player = harness(prefs: prefs);
    player.torrentStats.response = TorrentStats(
      phase: TorrentPhase.buffering,
      streamName: streamName,
      initialWindowReadyBytes: 0,
      initialWindowBytes: 4194304,
    );
    await player.pump(tester);
    player.engine.emitDuration(const Duration(minutes: 96));
    player.engine.emitPlaying(true);
    await pumpEvents(tester);
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 other English file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(pick));
    await tester.pumpAndSettle();
    return player;
  }

  Future<void> openPanel(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(SubtitleMenu.adjustTimingLabel));
    await tester.pumpAndSettle();
  }

  /// One press of a panel button.
  Future<void> press(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pump();
  }

  /// Closing the panel, which is what says the adjusting is over and so
  /// is when what was pressed gets written down.
  Future<void> closePanel(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('subtitle-timing-close')));
    await tester.pumpAndSettle();
    await pumpEvents(tester);
  }

  AppPrefs prefsWith([Map<String, dynamic>? stored]) =>
      AppPrefs(client: FakePrefsClient(stored));

  testWidgets('a speed press is remembered against the subtitle group', (
    tester,
  ) async {
    useWideViewport(tester);
    final prefs = prefsWith();
    await playing(tester, prefs: prefs);
    await openPanel(tester);

    await press(tester, 'subtitle-speed-stretch');
    await closePanel(tester);

    // Series and group, and no release: what a file was timed against is
    // a property of where it came from, so the same group's files carry
    // the correction to any release of this show.
    expect(
      prefs.subtitleSync.speedFor(series: series, group: '6'),
      closeTo(stretch, 1e-9),
    );
    expect(
      prefs.subtitleSync.entries.single.release,
      isNull,
      reason: 'a speed does not depend on which release is playing',
    );
  });

  testWidgets('a shift press is remembered against the release too', (
    tester,
  ) async {
    useWideViewport(tester);
    final prefs = prefsWith();
    await playing(tester, prefs: prefs);
    await openPanel(tester);

    await press(tester, 'subtitle-shift-later');
    await closePanel(tester);

    // The offset is the video's pre-roll less whatever the subtitle's
    // source assumed, so it depends on both sides.
    expect(
      prefs.subtitleSync.shiftSecondsFor(
        series: series,
        group: '6',
        release: opened.toLowerCase(),
      ),
      closeTo(SubtitleTiming.shiftStep, 1e-9),
    );
    expect(
      prefs.subtitleSync.shiftSecondsFor(
        series: series,
        group: '6',
        release: 'some.other.release.mkv',
      ),
      0,
    );
  });

  testWidgets('an addon that names no group is not remembered at all', (
    tester,
  ) async {
    useWideViewport(tester);
    final prefs = prefsWith();
    await playing(tester, pick: 'NONE', prefs: prefs);
    await openPanel(tester);

    await press(tester, 'subtitle-shift-later');
    await press(tester, 'subtitle-speed-stretch');
    await closePanel(tester);

    // Nothing keys it, and applying it to the files it might belong to
    // would be worse than forgetting it.
    expect(prefs.subtitleSync.entries, isEmpty);
  });

  testWidgets('a release nobody has named keeps the shift out of the file', (
    tester,
  ) async {
    useWideViewport(tester);
    final prefs = prefsWith();
    // A torrent whose server has not said which file it opened, and an
    // addon that claimed no filename either.
    await playing(tester, prefs: prefs, streamName: null);
    await openPanel(tester);

    await press(tester, 'subtitle-shift-later');
    await press(tester, 'subtitle-speed-stretch');
    await closePanel(tester);

    // The speed still is: it never depended on the release.
    expect(prefs.subtitleSync.entries, hasLength(1));
    expect(
      prefs.subtitleSync.speedFor(series: series, group: '6'),
      closeTo(stretch, 1e-9),
    );
  });

  testWidgets('a remembered adjustment is put back when the group plays', (
    tester,
  ) async {
    useWideViewport(tester);
    final prefs = prefsWith({
      'subtitleSync': [
        {'series': series, 'group': '6', 'speed': stretch},
        {
          'series': series,
          'group': '6',
          'release': opened.toLowerCase(),
          'shiftSeconds': 0.3,
        },
      ],
    });
    await prefs.load();

    final player = await playing(tester, prefs: prefs);
    await openPanel(tester);

    // Both halves are on the player and both are on the panel: what the
    // viewer fixed on the last episode is what this one comes up with.
    expect(player.engine.subtitleSpeed, closeTo(25 / 23.976, 1e-9));
    expect(player.engine.subtitleDelay, closeTo(0.3, 1e-9));
    expect(find.text('+0.3 s'), findsOneWidget);
  });

  testWidgets('a shift made for another release is not put back', (
    tester,
  ) async {
    useWideViewport(tester);
    final prefs = prefsWith({
      'subtitleSync': [
        {'series': series, 'group': '6', 'speed': stretch},
        {
          'series': series,
          'group': '6',
          'release': 'a.different.release.mkv',
          'shiftSeconds': 0.3,
        },
      ],
    });
    await prefs.load();

    final player = await playing(tester, prefs: prefs);

    // The speed carries -- it is the group's, not the release's -- and
    // the offset does not, because a different video starts somewhere
    // else.
    expect(player.engine.subtitleSpeed, closeTo(25 / 23.976, 1e-9));
    expect(player.engine.subtitleDelay, 0);
  });

  testWidgets('a stored speed no player would accept is not applied', (
    tester,
  ) async {
    useWideViewport(tester);
    // The preferences file is forgiving on purpose and holds whatever
    // number was on the player, so this is where a number that is not
    // one is stopped. media_kit writes `sub-speed` with
    // `mpv_set_property_string` and throws the return code away, so a
    // value outside `<0.1-10.0>` is refused in silence and the multiplier
    // the *previous* file left behind keeps running while the panel
    // claims this one.
    final prefs = prefsWith({
      'subtitleSync': [
        {'series': series, 'group': '6', 'speed': 40.0},
      ],
    });
    await prefs.load();

    final player = await playing(tester, prefs: prefs);

    expect(player.engine.subtitleSpeed, 1);
  });

  testWidgets('a row the build before this one wrote is not read as one', (
    tester,
  ) async {
    useWideViewport(tester);
    // That build stored the speed as the name of a toggle direction and
    // the shift as a count of tenth-second presses. Neither survives:
    // `stretch` is not a number, and `shift` is not `shiftSeconds` --
    // which is the point of the rename, since reading 3 presses as 3
    // seconds is thirty times the adjustment that was made.
    final prefs = prefsWith({
      'subtitleSync': [
        {'series': series, 'group': '6', 'speed': 'stretch'},
        {
          'series': series,
          'group': '6',
          'release': opened.toLowerCase(),
          'shift': 3,
        },
      ],
    });
    await prefs.load();

    final player = await playing(tester, prefs: prefs);

    expect(prefs.subtitleSync.entries, isEmpty);
    expect(player.engine.subtitleSpeed, 1);
    expect(player.engine.subtitleDelay, 0);
  });

  testWidgets('another series remembers nothing of this one', (tester) async {
    useWideViewport(tester);
    final prefs = prefsWith({
      'subtitleSync': [
        {'series': 'tt0944947', 'group': '6', 'speed': stretch},
      ],
    });
    await prefs.load();

    final player = await playing(tester, prefs: prefs);

    expect(player.engine.subtitleSpeed, 1);
  });

  testWidgets('switching to a file of another group drops the correction', (
    tester,
  ) async {
    useWideViewport(tester);
    final prefs = prefsWith({
      'subtitleSync': [
        {'series': series, 'group': '6', 'speed': stretch},
      ],
    });
    await prefs.load();
    final player = await playing(tester, prefs: prefs);
    expect(player.engine.subtitleSpeed, closeTo(25 / 23.976, 1e-9));

    // The other addon's file is not from group 6, so nothing is known
    // about it and it is played exactly as it was written.
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 other English file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('NONE'));
    await tester.pumpAndSettle();

    expect(player.engine.subtitleSpeed, 1);
    // And the memory is untouched: playing another file is not a
    // judgement about the one that was on.
    expect(
      prefs.subtitleSync.speedFor(series: series, group: '6'),
      closeTo(stretch, 1e-9),
    );
  });

  testWidgets('Reset forgets rather than storing a correction of none', (
    tester,
  ) async {
    useWideViewport(tester);
    final prefs = prefsWith({
      'subtitleSync': [
        {'series': series, 'group': '6', 'speed': stretch},
      ],
    });
    await prefs.load();
    await playing(tester, prefs: prefs);
    await openPanel(tester);

    await tester.tap(find.byKey(const ValueKey('subtitle-timing-reset')));
    await tester.pump();
    await closePanel(tester);

    // The viewer has said this file needs nothing, and nothing
    // remembered is what nothing applied looks like next time.
    expect(prefs.subtitleSync.entries, isEmpty);
  });

  testWidgets('a held shift is one write, not one a press', (tester) async {
    useWideViewport(tester);
    final client = FakePrefsClient();
    final prefs = AppPrefs(client: client);
    await playing(tester, prefs: prefs);
    await openPanel(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('subtitle-shift-later'))),
    );
    await tester.pump(SubtitleTimingOverlay.holdDelay);
    for (var i = 0; i < 10; i++) {
      await tester.pump(SubtitleTimingOverlay.repeatInterval);
    }
    await gesture.up();
    await closePanel(tester);

    // Eleven steps of the stepper, one preferences file written: the
    // shift repeats eight times a second and a preferences file is not a
    // keystroke log. Ten of those steps are a tenth and the eleventh is
    // already a whole second, because a hold accelerates
    // (`SubtitleTimingOverlay.shiftStrideAt`).
    expect(
      prefs.subtitleSync.shiftSecondsFor(
        series: series,
        group: '6',
        release: opened.toLowerCase(),
      ),
      closeTo(
        (SubtitleTimingOverlay.tenthStrideSteps +
                SubtitleTimingOverlay.shiftStrideAt(
                  SubtitleTimingOverlay.tenthStrideSteps,
                )) *
            SubtitleTiming.shiftStep,
        1e-9,
      ),
    );
    expect(client.writes, ['subtitleSync']);
  });

  testWidgets('a press just before the file changes is still that file\'s', (
    tester,
  ) async {
    useWideViewport(tester);
    final prefs = prefsWith();
    await playing(tester, prefs: prefs);
    await openPanel(tester);

    // Pressed, and then the viewer picks a file of another language and
    // presses again, both inside the moment before either write is made.
    // The offset belongs to the file it was made on, and the second
    // press must not take the first one down with it.
    await tester.tap(find.byKey(const ValueKey('subtitle-shift-later')));
    await tester.pump();
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('French'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('subtitle-shift-earlier')));
    await tester.pump();
    await closePanel(tester);

    expect(
      prefs.subtitleSync.shiftSecondsFor(
        series: series,
        group: '6',
        release: opened.toLowerCase(),
      ),
      closeTo(SubtitleTiming.shiftStep, 1e-9),
    );
  });

  testWidgets('a press the player is taken away under is still written', (
    tester,
  ) async {
    useWideViewport(tester);
    final prefs = prefsWith();
    await playing(tester, prefs: prefs);
    await openPanel(tester);
    await press(tester, 'subtitle-shift-later');

    // The panel is still up and the write is still waiting when the
    // screen goes. Nothing closes the panel first on either path that
    // does this: the up-next countdown replaces the player, and the
    // stop key pops it straight past the Back ladder.
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpEvents(tester);

    expect(
      prefs.subtitleSync.shiftSecondsFor(
        series: series,
        group: '6',
        release: opened.toLowerCase(),
      ),
      closeTo(SubtitleTiming.shiftStep, 1e-9),
    );
  });

  testWidgets('nothing is written by a file the viewer never touched', (
    tester,
  ) async {
    useWideViewport(tester);
    final client = FakePrefsClient();
    final prefs = AppPrefs(client: client);
    final player = await playing(tester, prefs: prefs);

    // Opening a file, and the auto-pick putting the tracks back, both go
    // through the same reset. Neither is a judgement about anything, so
    // neither may overwrite what an earlier evening decided.
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    await pumpEvents(tester);

    expect(client.writes, isEmpty);
    expect(player.engine.subtitleSpeed, 1);
  });
}
