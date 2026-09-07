import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_tracks.dart';
import 'package:xtremio/features/player/subtitle_groups.dart';
import 'package:xtremio/features/player/track_menus.dart';

import '../../support/fake_prefs_client.dart';
import '../../support/player_harness.dart';

/// The two languages this viewer picks most often, at the top of the
/// menu.
///
/// OpenSubtitles answers one film with sixty-nine files in forty
/// languages, so the row somebody wants is a scroll away every time. The
/// pins are the menu's own presentation, applied after the ordering and
/// never inside it: the rows are still the alphabet's, the pinned ones
/// are lifted rather than copied, and nothing is pinned that this episode
/// does not offer.
void main() {
  const series = 'tt0063350';

  Map<String, dynamic> upload(String id, String lang, String url) => {
    'id': id,
    'lang': lang,
    'url': url,
  };

  PlayerHarness harnessWith(
    List<Map<String, dynamic>> items, {
    AppPrefs? prefs,
  }) {
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
        'content': {'type': 'Ready', 'content': items},
      },
    ];
    return harness;
  }

  /// One addon file, for the tests that build the menu's groups by hand
  /// instead of driving the player.
  SubtitleSource addonFile(String lang, String url) => SubtitleSource(
    SubtitleInfo(<String, dynamic>{'lang': lang, 'url': url}),
    addonBase: 'https://subs.example.org/manifest.json',
  );

  /// Four languages, answered in an order that is nobody's alphabet.
  List<Map<String, dynamic>> fourLanguages() => [
    upload('sv-1', 'swe', 'https://subs.example.org/sv.srt'),
    upload('en-1', 'eng', 'https://subs.example.org/en.srt'),
    upload('da-1', 'dan', 'https://subs.example.org/da.srt'),
    upload('fr-1', 'fre', 'https://subs.example.org/fr.srt'),
  ];

  /// The same answer with the English upload taken out, so English is on
  /// offer only where the video itself carries it.
  List<Map<String, dynamic>> withoutEnglish() => [
    for (final item in fourLanguages())
      if (item['lang'] != 'eng') item,
  ];

  /// One English subtitle track inside the video, which is what the
  /// menu's "In this file" section is drawn from.
  const englishTrack = PlaybackTracks(
    subtitle: [TrackInfo(id: '3', language: 'eng')],
  );

  /// Both of this viewer's languages inside the video, so neither has a
  /// row down among the addons' languages to lift.
  const englishAndSwedishTracks = PlaybackTracks(
    subtitle: [
      TrackInfo(id: '3', language: 'eng'),
      TrackInfo(id: '4', language: 'swe'),
    ],
  );

  /// Preferences whose only content is how often each language has been
  /// picked -- no show row, so nothing is preselected and the menu is the
  /// whole of what changes.
  AppPrefs counting(Map<String, int> languages) => AppPrefs(
    client: FakePrefsClient({
      'subtitlePicks': {'languages': languages},
    }),
  );

  Future<void> openMenu(
    WidgetTester tester,
    PlayerHarness harness, {
    PlaybackTracks? tracks,
  }) async {
    await harness.pump(tester);
    if (tracks != null) harness.engine.emitTracks(tracks);
    harness.engine.emitDuration(const Duration(minutes: 96));
    await pumpEvents(tester);
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
  }

  double topOf(WidgetTester tester, String text) =>
      tester.getTopLeft(find.text(text).first).dy;

  testWidgets('the two most picked are lifted above the alphabet, once', (
    tester,
  ) async {
    useWideViewport(tester);
    final prefs = counting({'Swedish': 12, 'English': 41, 'Danish': 4});
    await prefs.load();

    await openMenu(tester, harnessWith(fourLanguages(), prefs: prefs));

    expect(find.text(SubtitleMenu.pinnedLabel), findsOneWidget);
    expect(find.text(SubtitleMenu.pinnedNote(2)), findsOneWidget);
    // Most picked first, and both above the section the rest are in.
    expect(topOf(tester, 'English'), lessThan(topOf(tester, 'Swedish')));
    expect(
      topOf(tester, 'Swedish'),
      lessThan(topOf(tester, 'From subtitle addons')),
    );
    // Lifted, not copied: a language with two rows would be two rows that
    // apply the same file.
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Swedish'), findsOneWidget);
    // And what is left is still the alphabet, Danish before French, with
    // the third-most-picked language no higher for it.
    expect(topOf(tester, 'Danish'), lessThan(topOf(tester, 'French')));
  });

  testWidgets('a pinned row applies its file like any other', (tester) async {
    useWideViewport(tester);
    final prefs = counting({'Swedish': 12, 'English': 41});
    await prefs.load();
    final harness = harnessWith(fourLanguages(), prefs: prefs);

    await openMenu(tester, harness);
    await tester.tap(find.text('Swedish'));
    await tester.pumpAndSettle();

    expect(harness.engine.externalSubtitles, [
      (Uri.parse('https://subs.example.org/sv.srt'), 'Swedish', 'swe'),
    ]);
    // A pin moves a row; it does not make a different kind of row, so
    // the pick is written down the way any other is.
    expect(prefs.subtitlePicks.forSeries(series)!.language, 'Swedish');
  });

  testWidgets('the pair follows the picks', (tester) async {
    useWideViewport(tester);
    // Danish is one pick short of a row of its own.
    final prefs = counting({
      'English': 41,
      'Swedish': SubtitlePickMemory.pinThreshold,
      'Danish': SubtitlePickMemory.pinThreshold - 1,
    });
    await prefs.load();
    final harness = harnessWith(fourLanguages(), prefs: prefs);

    await openMenu(tester, harness);
    expect(topOf(tester, 'Swedish'), lessThan(topOf(tester, 'Danish')));

    // Picking it twice takes it past Swedish, and the menu says so the
    // next time it is opened. Nothing re-orders while the sheet is up:
    // every pick closes it, which is what keeps a row from moving under
    // a finger.
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('Danish'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Subtitles (S)'));
      await tester.pumpAndSettle();
    }

    expect(topOf(tester, 'Danish'), lessThan(topOf(tester, 'Swedish')));
    expect(topOf(tester, 'English'), lessThan(topOf(tester, 'Danish')));
  });

  testWidgets('one pinned language says so in the singular', (tester) async {
    useWideViewport(tester);
    final prefs = counting({'English': 41});
    await prefs.load();

    await openMenu(tester, harnessWith(fourLanguages(), prefs: prefs));

    expect(find.text(SubtitleMenu.pinnedNote(1)), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
  });

  testWidgets('a language this episode does not offer is not pinned, and '
      'the note does not claim it away', (tester) async {
    useWideViewport(tester);
    // Picked forty times, answered with here not at all -- and picked
    // more often than the one row that is pinned. A pin is a row moved,
    // never a row invented.
    final prefs = counting({'Portuguese': 40, 'English': 12});
    await prefs.load();

    await openMenu(tester, harnessWith(fourLanguages(), prefs: prefs));

    expect(find.text('Portuguese'), findsNothing);
    expect(find.text(SubtitleMenu.pinnedNote(1)), findsOneWidget);
    // The heading's note has to survive exactly this case: English is
    // not the language this viewer picks most often, it is the one they
    // pick most often *of the four on offer*, and that is all the note
    // is allowed to say.
    expect(SubtitleMenu.pinnedNote(1), contains('on offer here'));
    expect(SubtitleMenu.pinnedNote(2), contains('on offer here'));
  });

  testWidgets('a language only the file offers still takes a pin, and the '
      'note says where it went', (tester) async {
    useWideViewport(tester);
    // English is picked three times as often as anything else and no
    // addon answered with it: this sheet offers it as the track inside
    // the video, drawn above the pins. Ranking only the addons' rows
    // lifted Swedish and Danish under a note calling them "the 2
    // languages on offer here that you pick most often" -- with English
    // on offer here, a few rows further up.
    final prefs = counting({'English': 41, 'Swedish': 12, 'Danish': 4});
    await prefs.load();

    await openMenu(
      tester,
      harnessWith(withoutEnglish(), prefs: prefs),
      tracks: englishTrack,
    );

    expect(find.text(SubtitleMenu.pinnedNote(1, inFile: 1)), findsOneWidget);
    // Neither claim this menu could make about its rows alone: English
    // is on offer here and is picked more often than either of them.
    expect(find.text(SubtitleMenu.pinnedNote(2)), findsNothing);
    expect(find.text(SubtitleMenu.pinnedNote(1)), findsNothing);
    // The winner with no row to lift is the file's own track, above the
    // heading, and the slot it holds is one Danish does not get.
    expect(
      topOf(tester, 'English'),
      lessThan(topOf(tester, SubtitleMenu.pinnedLabel)),
    );
    expect(
      topOf(tester, 'Swedish'),
      lessThan(topOf(tester, 'From subtitle addons')),
    );
    expect(
      topOf(tester, 'From subtitle addons'),
      lessThan(topOf(tester, 'Danish')),
    );
  });

  testWidgets('a language the file and the addons both offer is one pin', (
    tester,
  ) async {
    useWideViewport(tester);
    // The file's English track and the English upload are one language
    // to the viewer and to the counts, so English takes one of the two
    // slots and Swedish takes the other.
    final prefs = counting({'English': 41, 'Swedish': 12});
    await prefs.load();

    await openMenu(
      tester,
      harnessWith(fourLanguages(), prefs: prefs),
      tracks: englishTrack,
    );

    expect(find.text(SubtitleMenu.pinnedNote(2)), findsOneWidget);
    // Once in the file's own section and once lifted, and both above the
    // alphabet: a language named twice that took both slots would leave
    // Swedish down in it.
    expect(find.text('English'), findsNWidgets(2));
    expect(
      tester.getTopLeft(find.text('English').last).dy,
      lessThan(topOf(tester, 'From subtitle addons')),
    );
    expect(
      topOf(tester, 'Swedish'),
      lessThan(topOf(tester, 'From subtitle addons')),
    );
  });

  testWidgets('the menu ranks the sheet it draws, and no caller can rank '
      'less of it', (tester) async {
    useWideViewport(tester);
    // The probe that caught the note overclaiming. Handed the ranking of
    // the addons' rows alone -- Swedish and Danish -- the menu drew "The
    // 2 languages on offer here that you pick most often" with English,
    // picked more often than either, three rows above as the video's own
    // track. Nothing can hand a ranking down any more: the menu is given
    // the counts and ranks what it has on offer, both sections of it.
    final groups = groupSubtitlesByLanguage([
      addonFile('swe', 'https://subs.example.org/sv.srt'),
      addonFile('dan', 'https://subs.example.org/da.srt'),
      addonFile('fre', 'https://subs.example.org/fr.srt'),
    ], addonName: (_) => 'OpenSubtitles v3');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubtitleMenu(
            embedded: englishTrack.subtitle,
            groups: groups,
            picks: const SubtitlePickMemory(
              shows: [],
              languages: {'English': 41, 'Swedish': 30, 'Danish': 10},
            ),
            activeId: null,
            loading: false,
            onOff: () {},
            onEmbedded: (_) {},
            onExternal: (_) {},
            onAdjustTiming: () {},
          ),
        ),
      ),
    );

    expect(find.text(SubtitleMenu.pinnedNote(1, inFile: 1)), findsOneWidget);
    expect(find.text(SubtitleMenu.pinnedNote(2)), findsNothing);
    // One slot went to the track above, one lifted Swedish, and Danish
    // -- which the discarded ranking would have lifted -- is left in the
    // alphabet where it belongs.
    expect(find.text('Swedish'), findsOneWidget);
    expect(
      topOf(tester, 'Swedish'),
      lessThan(topOf(tester, 'From subtitle addons')),
    );
    expect(
      topOf(tester, 'From subtitle addons'),
      lessThan(topOf(tester, 'Danish')),
    );
  });

  testWidgets('nothing is pinned when there is nothing to lift it above', (
    tester,
  ) async {
    useWideViewport(tester);
    final prefs = counting({'English': 41, 'Swedish': 12});
    await prefs.load();

    // Both languages there are would be pinned, which moves no row
    // nearer the top and costs a heading and a note to say so.
    await openMenu(
      tester,
      harnessWith([
        upload('en-1', 'eng', 'https://subs.example.org/en.srt'),
        upload('sv-1', 'swe', 'https://subs.example.org/sv.srt'),
      ], prefs: prefs),
    );

    expect(find.text(SubtitleMenu.pinnedLabel), findsNothing);
    expect(find.text('From subtitle addons'), findsOneWidget);
    expect(topOf(tester, 'English'), lessThan(topOf(tester, 'Swedish')));
  });

  testWidgets('both winners inside the file lift nothing, and the next '
      'language down is not promoted into their place', (tester) async {
    useWideViewport(tester);
    // English and Swedish are what this viewer picks, the video carries
    // both, and the addons answered with neither. Both slots are spent
    // where they were won -- on rows already at the top of this sheet --
    // so nothing is lifted and the section is not drawn at all.
    final prefs = counting({'English': 41, 'Swedish': 30, 'Danish': 10});
    await prefs.load();

    await openMenu(
      tester,
      harnessWith([
        upload('da-1', 'dan', 'https://subs.example.org/da.srt'),
        upload('fr-1', 'fre', 'https://subs.example.org/fr.srt'),
      ], prefs: prefs),
      tracks: englishAndSwedishTracks,
    );

    expect(find.text(SubtitleMenu.pinnedLabel), findsNothing);
    // Danish is the third language this viewer picks and the heading
    // would call it one of the two: a freed slot is not a slot for the
    // next language down, so Danish stays in the alphabet.
    expect(
      topOf(tester, 'From subtitle addons'),
      lessThan(topOf(tester, 'Danish')),
    );
    expect(topOf(tester, 'Danish'), lessThan(topOf(tester, 'French')));
    // What the viewer came for is above all of it either way.
    expect(topOf(tester, 'English'), lessThan(topOf(tester, 'Danish')));
    expect(topOf(tester, 'Swedish'), lessThan(topOf(tester, 'Danish')));
  });

  testWidgets('nothing is remembered, nothing is pinned', (tester) async {
    useWideViewport(tester);
    final prefs = AppPrefs(client: FakePrefsClient());
    await prefs.load();

    await openMenu(tester, harnessWith(fourLanguages(), prefs: prefs));

    expect(find.text(SubtitleMenu.pinnedLabel), findsNothing);
    // Straight into the alphabet, exactly as before any of this.
    expect(topOf(tester, 'Danish'), lessThan(topOf(tester, 'English')));
    expect(topOf(tester, 'English'), lessThan(topOf(tester, 'French')));
    expect(topOf(tester, 'French'), lessThan(topOf(tester, 'Swedish')));
  });

  testWidgets('a player with no preferences above it draws no pins', (
    tester,
  ) async {
    useWideViewport(tester);
    // What a player mounted on its own runs under, and what it has to
    // keep working without.
    await openMenu(tester, harnessWith(fourLanguages()));

    expect(find.text(SubtitleMenu.pinnedLabel), findsNothing);
    expect(find.byType(SubtitleMenu), findsOneWidget);
  });

  testWidgets('the language that is playing is still left where the '
      'alphabet put it', (tester) async {
    useWideViewport(tester);
    final prefs = counting({'English': 41});
    await prefs.load();
    final harness = harnessWith(fourLanguages(), prefs: prefs);

    await openMenu(tester, harness);
    await tester.tap(find.text('Swedish'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();

    // One pick is not a pin, and a row that jumped to the top once it
    // was picked would take back the reason to sort at all. The menu
    // marks it instead.
    expect(topOf(tester, 'French'), lessThan(topOf(tester, 'Swedish')));
    expect(
      tester
          .widget<ListTile>(
            find.ancestor(
              of: find.text('Swedish'),
              matching: find.byType(ListTile),
            ),
          )
          .selected,
      isTrue,
    );
  });
}
