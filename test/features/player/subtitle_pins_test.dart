import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
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

  /// Four languages, answered in an order that is nobody's alphabet.
  List<Map<String, dynamic>> fourLanguages() => [
    upload('sv-1', 'swe', 'https://subs.example.org/sv.srt'),
    upload('en-1', 'eng', 'https://subs.example.org/en.srt'),
    upload('da-1', 'dan', 'https://subs.example.org/da.srt'),
    upload('fr-1', 'fre', 'https://subs.example.org/fr.srt'),
  ];

  /// Preferences whose only content is how often each language has been
  /// picked -- no show row, so nothing is preselected and the menu is the
  /// whole of what changes.
  AppPrefs counting(Map<String, int> languages) => AppPrefs(
    client: FakePrefsClient({
      'subtitlePicks': {'languages': languages},
    }),
  );

  Future<void> openMenu(WidgetTester tester, PlayerHarness harness) async {
    await harness.pump(tester);
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
