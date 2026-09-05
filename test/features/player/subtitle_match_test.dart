import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/subtitle_match.dart';
import 'package:xtremio/features/player/subtitle_timing.dart';
import 'package:xtremio/features/player/track_menus.dart';

import '../../support/player_harness.dart';

/// Matching the playing subtitle to another file the viewer says is in
/// sync.
///
/// The measurement itself is Rust's (`rust/src/subtitles.rs`); what is
/// tested here is what the player does with it -- that a convincing
/// answer is applied as both a ratio and an offset, that an unconvincing
/// one changes nothing and says why, and that the option is not offered
/// at all when there is no other file to measure against.
void main() {
  const plainUrl = 'https://subs.example.org/en-plain.srt';
  const palUrl = 'https://subs.example.org/en-25.srt';

  Map<String, dynamic> upload(String id, String url, String releaseGroup) => {
    'id': id,
    'lang': 'eng',
    'url': url,
    'releaseGroup': releaseGroup,
  };

  /// A film-timed video with [uploads] on offer from one addon.
  PlayerHarness harness({required List<Map<String, dynamic>> uploads}) {
    final harness = PlayerHarness();
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
        'content': {'type': 'Ready', 'content': uploads},
      },
    ];
    return harness;
  }

  /// The player with [pick] playing and the timing panel open.
  Future<PlayerHarness> panelOver(
    WidgetTester tester, {
    required List<Map<String, dynamic>> uploads,
    required String pick,
  }) async {
    final player = harness(uploads: uploads);
    await player.pump(tester);
    player.engine.emitDuration(const Duration(minutes: 96));
    player.engine.emitPlaying(true);
    await pumpEvents(tester);
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    if (uploads.length > 1) {
      await tester.tap(find.text('${uploads.length - 1} other English file'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text(pick));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(SubtitleMenu.adjustTimingLabel));
    await tester.pumpAndSettle();
    return player;
  }

  /// Opens the picker and chooses the file named [reference].
  Future<void> matchAgainst(WidgetTester tester, String reference) async {
    await tester.tap(find.text(SubtitleTimingOverlay.matchLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text(reference));
    await tester.pumpAndSettle();
  }

  final both = [
    upload('en-1', plainUrl, 'PLAIN'),
    upload('en-2', palUrl, 'PAL'),
  ];

  testWidgets('a match applies the ratio and the offset it measured, and '
      'says how well', (tester) async {
    useWideViewport(tester);
    final player = await panelOver(tester, uploads: both, pick: 'PAL');
    player.subtitleMatch.response = const SubtitleMatch(
      ratio: 1.0424,
      offset: 1.5,
      matched: 613,
      cues: 694,
      referenceCues: 683,
      convincing: true,
    );

    await matchAgainst(tester, 'PLAIN');

    // The playing file is the one measured and the chosen one is what it
    // is measured against; reversed, the ratio applied is the reciprocal
    // of the one needed, which puts the cue further from where it belongs
    // than leaving the file alone.
    expect(player.subtitleMatch.calls, [
      (Uri.parse(palUrl), Uri.parse(plainUrl)),
    ]);
    // Both halves, because a match answers both: a rate error and an
    // offset are different things and the transform is the line through
    // them.
    expect(player.engine.subtitleSpeed, closeTo(1.0424, 1e-9));
    expect(player.engine.subtitleDelay, closeTo(1.5, 1e-9));
    expect(find.text('Matched 613 of 694 cues'), findsOneWidget);
  });

  testWidgets('a match that does not convince changes nothing and says so', (
    tester,
  ) async {
    useWideViewport(tester);
    // Two files for different episodes, half a film against the whole, a
    // reference that is itself adrift: all of them measure, none of them
    // should be applied, and the count is what makes that judgeable.
    final player = await panelOver(tester, uploads: both, pick: 'PAL');
    player.subtitleMatch.response = const SubtitleMatch(
      ratio: 0.9157,
      offset: 229.5,
      matched: 184,
      cues: 694,
      referenceCues: 754,
      convincing: false,
    );

    await matchAgainst(tester, 'PLAIN');

    expect(player.engine.subtitleSpeed, 1);
    expect(player.engine.subtitleDelay, 0);
    expect(
      find.text('Only 184 of 694 cues matched, so nothing was changed'),
      findsOneWidget,
    );
  });

  testWidgets('a file that cannot be read says one sentence and no URL', (
    tester,
  ) async {
    useWideViewport(tester);
    final player = await panelOver(tester, uploads: both, pick: 'PAL');
    player.subtitleMatch.error = StateError('HTTP 404 at $plainUrl');

    await matchAgainst(tester, 'PLAIN');

    expect(find.text(subtitleMatchFailureNote), findsOneWidget);
    expect(player.engine.subtitleSpeed, 1);
    // An addon's subtitle URL can carry a debrid API key, so no failure
    // puts one on the screen.
    expect(find.textContaining('subs.example.org'), findsNothing);
  });

  testWidgets('with nothing to match against the option is not there', (
    tester,
  ) async {
    useWideViewport(tester);
    // The one file on offer is the one playing, so there is nothing to
    // measure it against -- and a control that cannot work would say the
    // app has a way of fixing this video that it has not got.
    final player = await panelOver(
      tester,
      uploads: [upload('en-1', plainUrl, 'PLAIN')],
      pick: 'English',
    );
    expect(find.byType(SubtitleTimingOverlay), findsOneWidget);
    expect(find.text(SubtitleTimingOverlay.matchLabel), findsNothing);
    expect(player.subtitleMatch.calls, isEmpty);
  });

  testWidgets('a measurement that lands after the subtitle changed is '
      'dropped', (tester) async {
    useWideViewport(tester);
    // Two HTTP fetches take seconds and the viewer can pick another file
    // meanwhile. The transform was measured for a file that is no longer
    // on screen, and applying it would ruin the one that replaced it.
    final player = await panelOver(tester, uploads: both, pick: 'PAL');
    final held = Completer<void>();
    player.subtitleMatch
      ..pending = held.future
      ..response = const SubtitleMatch(
        ratio: 1.0424,
        offset: 1.5,
        matched: 613,
        cues: 694,
        referenceCues: 683,
        convincing: true,
      );

    await tester.tap(find.text(SubtitleTimingOverlay.matchLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PLAIN'));
    await tester.pumpAndSettle();
    expect(find.text(subtitleMatchingNote), findsOneWidget);

    // The viewer picks the other file while it runs.
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 other English file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PLAIN'));
    await tester.pumpAndSettle();
    held.complete();
    await tester.pumpAndSettle();

    expect(player.engine.subtitleSpeed, 1);
    expect(player.engine.subtitleDelay, 0);
    expect(find.text('Matched 613 of 694 cues'), findsNothing);
  });
}
