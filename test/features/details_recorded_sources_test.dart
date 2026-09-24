import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/stream_facts.dart';
import 'package:xtremio/features/details/tv_source_row.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/tv_density.dart';

import '../support/fake_core_client.dart';
import '../support/fake_playback_engine.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_torrent_stats_client.dart';
import '../support/fixtures.dart';
import '../support/tv.dart';

/// The thirty-one recorded addon answers, drawn.
///
/// `stream_facts_test.dart` walks the same fixture for what is *read* out
/// of each row; this one walks it for what a card *says*, on a phone and on
/// a television, against the real screen. It is the same specification
/// either way: the fixture is what Torrentio, WatchHub and Public Domain
/// Movies actually sent, and a layout that cannot survive it is a layout
/// that will not survive the addons.
const movieId = 'tt0063350';
const addonHost = 'torrentio.example';

/// One addon answering with every recorded stream, so one group holds the
/// whole spread -- a one-line availability phrase next to a four-line pack.
Map<String, dynamic> recordedGroup() => {
  'request': {
    'base': 'https://$addonHost/manifest.json',
    'path': {
      'resource': 'stream',
      'type': 'movie',
      'id': movieId,
      'extra': <Object>[],
    },
  },
  'content': {
    'type': 'Ready',
    'content': [for (final row in loadRecordedStreams()) row['stream']],
  },
};

Map<String, dynamic> recordedMovie() =>
    loadMetaDetailsFixture()..['streams'] = [recordedGroup()];

/// Recorded row 6's lead: `behaviorHints.filename` with every dub spelled
/// out, a hundred and twenty characters of it, where the addon's own line
/// says `MULTi`. The longest release in the fixture and the one every cap
/// on a television card was measured against.
const dubs =
    'The.Matrix.1999.2160p.MAX.WEB-DL.DV.HDR.ENG.LATINO'
    '.CASTELLANO.ITA.FRE.HINDI.PORTUGUESE.DDP5.1.Atmos.H265'
    '.MP4-BEN.THE.MEN';

/// The recorded streams as the app models them, in fixture order.
List<StreamInfo> recordedStreams() => [
  for (final row in loadRecordedStreams())
    StreamInfo(row['stream'] as Map<String, dynamic>),
];

/// What the card for [stream] has to carry.
StreamPresentation shownOf(StreamInfo stream) =>
    StreamPresentation.of(stream, addonName: addonHost);

StreamFacts factsOf(StreamInfo stream) =>
    StreamFacts.of(stream, addonName: addonHost);

Widget harness(FakeCoreClient core, AppPrefs prefs, {DeviceProfile? device}) {
  Widget screen = CoreScope(
    client: core,
    child: PrefsScope(
      prefs: prefs,
      child: PlaybackScope(
        createEngine: FakePlaybackEngine.new,
        torrentStats: FakeTorrentStatsClient(),
        child: const MaterialApp(
          home: MetaDetailsScreen(type: 'movie', id: movieId),
        ),
      ),
    ),
  );
  if (device != null) screen = DeviceScope(profile: device, child: screen);
  return screen;
}

void main() {
  group('on a phone', () {
    /// Tall enough that every one of the thirty-one rows is built: the
    /// list is a sliver and an unbuilt row is not a row this can look at.
    /// Grouped by addon, with the one group open, so the rows are a flat
    /// list and no resolution heading shares a word with a release.
    ///
    /// [width] is a phone's when a test is about what the text does when
    /// it runs out of room; the default is wide enough that most of these
    /// rows fit on one line and the assertions are about the words
    /// themselves.
    ///
    /// [sectioned] takes the other layout, with every section open: the
    /// rows are the same rows, and the one thing that differs is that a
    /// row under a resolution heading names the addon that answered it.
    Future<void> pump(
      WidgetTester tester, {
      double width = 1200,
      bool sectioned = false,
    }) async {
      tester.view.physicalSize = Size(width, 24000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final prefs = AppPrefs.inMemory();
      unawaited(prefs.setStreamsSectioned(sectioned));
      unawaited(
        prefs.setOpenStreamSections({
          for (final resolution in StreamResolution.values) resolution.label,
          'unknown',
        }),
      );
      unawaited(
        prefs.setOpenStreamAddons({'https://$addonHost/manifest.json'}),
      );
      await tester.pumpWidget(
        harness(
          FakeCoreClient(state: {CoreField.metaDetails: recordedMovie()}),
          prefs,
        ),
      );
      await tester.pumpAndSettle();
    }

    List<String> drawnOn(WidgetTester tester, ListTile row) => [
      for (final text in tester.widgetList<Text>(
        find.descendant(of: find.byWidget(row), matching: find.byType(Text)),
      ))
        ?text.data,
    ];

    /// The row for [shown].
    ///
    /// Found by its *title*, and then by what is under it: two recorded
    /// rows are `Amazon Prime Video` with different availability under
    /// them, so the title alone names two rows and only one of them is
    /// this stream's.
    ListTile tileFor(WidgetTester tester, StreamPresentation shown) {
      final led = [
        for (final tile in tester.widgetList<ListTile>(find.byType(ListTile)))
          if ((tile.title as Text?)?.data == shown.lead) tile,
      ];
      expect(led, isNotEmpty, reason: 'a row led by ${shown.lead}');
      return led.firstWhere(
        (tile) => shown.rest.every(drawnOn(tester, tile).contains),
        orElse: () => fail(
          'no row led by ${shown.lead} carries ${shown.rest}; '
          'the rows led by it draw '
          '${[for (final tile in led) drawnOn(tester, tile)]}',
        ),
      );
    }

    /// Everything that row draws.
    List<String> rowFor(WidgetTester tester, StreamPresentation shown) =>
        drawnOn(tester, tileFor(tester, shown));

    testWidgets('every recorded row draws its lead and every line under it', (
      tester,
    ) async {
      await pump(tester);

      for (final (index, stream) in recordedStreams().indexed) {
        final shown = shownOf(stream);
        final why = 'recorded row ${index + 1}';
        // `rowFor` is the assertion that every line is drawn: it is what
        // picks the row out, and it fails by name when none carries them.
        final drawn = rowFor(tester, shown);
        expect(drawn.first, shown.lead, reason: '$why: the lead leads');
        // Said once. The bug this replaces drew the release and then the
        // file line under it, which is the same release with `.mkv` on the
        // end; the lead is taken out of the rest wherever it appears, so
        // the row cannot say it twice however the addon spelled it.
        expect(
          drawn.where((line) => line == shown.lead),
          hasLength(1),
          reason: '$why: the lead is not repeated underneath',
        );
      }
    });

    testWidgets('a line about the lead says only what it adds, and a line '
        'about something else is untouched', (tester) async {
      await pump(tester);
      final streams = recordedStreams();

      // Row 1: the addon sent the release twice, once as the filename and
      // once with the bit depth and the audio on the end of it. The row
      // says the second one's own five words and not the release again.
      final first = rowFor(tester, shownOf(streams[0]));
      expect(first, contains('10bit.HDR.TrueHD.7.1.Atmos'));
      expect(
        first,
        isNot(
          contains(
            startsWith(
              'The.Matrix.1999.RERIP.2160p.UHD.BluRay.'
              'x265',
            ),
          ),
        ),
      );
      // Row 6: a hundred and twenty characters of filename, and the line
      // under it adds one word to it.
      expect(rowFor(tester, shownOf(streams[5])), contains('MULTi'));
      // Row 5: the same release spelled with spaces instead of dots adds
      // nothing at all, so it is not on the row in any form -- which is
      // what the app already did and must keep doing.
      expect(
        rowFor(tester, shownOf(streams[4])),
        isNot(contains(startsWith('The Matrix 1999 UHD BluRay'))),
      );

      // Row 4's pack: ten of its fifteen words were the lead over again
      // and the card is down to the five that name the box set. The old
      // rule drew the whole line, which is what a phone showed.
      expect(
        rowFor(tester, shownOf(streams[3])),
        contains('PACK 4K UHD Collection 1999-2003'),
      );
      // Row 26 is the same shape at its worst -- `30.Rock.S02` under
      // `30.Rock.S02E11`, thirty-eight characters for a difference of
      // three -- and it is the row this parser was rebuilt for.
      expect(rowFor(tester, shownOf(streams[25])), contains('S02'));

      // And the line that is about something else, whole, in the addon's
      // own words: row 13's opens `Во все тяжкие` where the lead opens
      // `Breaking Bad`, so nothing of it belongs to the lead however many
      // of the lead's words turn up further along it.
      expect(
        rowFor(tester, shownOf(streams[12])),
        contains(
          'Во все тяжкие / Breaking Bad / Сезон: 1 / Серии: 1-7 из 7 '
          '[2008 WEB-DL 2160p 4k] MVO (LostFilm FoxCrime) + DVO '
          '(Кубик в Кубе) + Original + Sub (Rus Eng)',
        ),
      );
    });

    testWidgets('the scope of a pack is what survives on the second line', (
      tester,
    ) async {
      await pump(tester);
      final streams = recordedStreams();
      // Every spelling of "which pack this file came out of" the recorded
      // addons use, on the row it came from. These words are the reason
      // the second line of a card exists, and the reduction is worth
      // nothing if it takes them with the repetition.
      const scopes = {
        3: 'PACK 4K UHD Collection 1999-2003',
        8: 'Trilogy 1999-2003 multi',
        9: 'S01',
        11: 'COMPLETE S01-S05 WEB-DL Rus Ukr Eng RiCK',
        15: 'iNTEGRALE',
        25: 'S02',
        26: 'Season 1-7 S01-S07 HEVC 10bit AAC 5.1 QxR',
        27: 'Complete',
        28: 'COMPLETE.SERIES.S01-S07',
        29: 'Season 2',
        30: 'S01-S07 + Specials 10bit',
      };
      for (final MapEntry(key: index, value: scope) in scopes.entries) {
        expect(
          rowFor(tester, shownOf(streams[index])),
          contains(scope),
          reason: 'recorded row ${index + 1}: the scope',
        );
      }
    });

    for (final sectioned in [false, true]) {
      testWidgets(
        'nothing a row says is cut short, ${sectioned ? 'under a '
                  'resolution heading' : 'under an addon heading'}',
        (tester) async {
          // A phone, at the width one actually is. The list scrolls and a
          // row may be any height, so there is nothing for a cap to buy
          // here: a release name cut mid-token says less about which file it
          // is than the whole of it does, and the viewer cannot get the rest
          // of it back from anywhere.
          //
          // Both layouts, because they draw different lines: the sectioned
          // one names the addon under the release and the grouped one has
          // said it in the heading already.
          await pump(tester, width: 400, sectioned: sectioned);

          for (final (index, stream) in recordedStreams().indexed) {
            final tile = tileFor(tester, shownOf(stream));
            final texts = tester.widgetList<Text>(
              find.descendant(
                of: find.byWidget(tile),
                matching: find.byType(Text),
              ),
            );
            expect(
              [for (final text in texts) text.data],
              sectioned ? contains(addonHost) : isNot(contains(addonHost)),
              reason: 'which heading has named the addon already',
            );
            for (final text in texts) {
              expect(
                text.maxLines,
                isNull,
                reason: 'recorded row ${index + 1}: "${text.data}" is capped',
              );
              expect(
                text.overflow ?? TextOverflow.clip,
                TextOverflow.clip,
                reason: 'recorded row ${index + 1}: "${text.data}" is elided',
              );
            }
          }
        },
      );
    }

    testWidgets('so a long release wraps, and the row grows to hold it', (
      tester,
    ) async {
      await pump(tester, width: 400);
      // Recorded row 6: `behaviorHints.filename` spells out every dub, 120
      // characters of it, which is what a viewer picking between two
      // 2160p rips is reading.
      final long = shownOf(recordedStreams()[5]).lead;
      final title = tester.getSize(find.text(long));
      final shortest = tester.getSize(find.text('MUBI'));
      expect(
        title.height,
        greaterThan(shortest.height * 3),
        reason: 'four lines and more of release name, none of them dropped',
      );
      expect(
        tester
            .getSize(
              find.byWidget(tileFor(tester, shownOf(recordedStreams()[5]))),
            )
            .height,
        greaterThan(
          tester
              .getSize(
                find.byWidget(tileFor(tester, shownOf(recordedStreams()[23]))),
              )
              .height,
        ),
        reason: 'the row is as tall as what is on it',
      );
    });

    testWidgets('and a chip for everything that was read, and for nothing '
        'that was not', (tester) async {
      await pump(tester);

      for (final (index, stream) in recordedStreams().indexed) {
        final shown = shownOf(stream);
        final facts = factsOf(stream);
        final why = 'recorded row ${index + 1}';
        final drawn = rowFor(tester, shown);
        for (final pill in facts.pills) {
          // A row whose whole name is the pill (`1080p`, which is all
          // Public Domain Movies calls a stream) is not badged with it
          // again -- the row is already headed with the word.
          if (pill.toLowerCase() == shown.lead.toLowerCase()) continue;
          expect(drawn, contains(pill), reason: '$why: the $pill chip');
        }
        // And nothing is drawn for what nobody said. The nine rows with no
        // swarm are not `0 seeders`, and the sixteen with no language are
        // not a flag.
        if (facts.seeders == null) {
          expect(
            drawn,
            isNot(contains('0 seeders')),
            reason: '$why: a silent swarm is not an empty one',
          );
        }
        if (facts.sizeBytes == null) {
          expect(drawn, isNot(contains('0 B')), reason: '$why: no size');
        }
      }
    });

    testWidgets('the two the app has never shown are on the row now', (
      tester,
    ) async {
      await pump(tester);

      // The whole point of the parser, drawn: the one recorded stream with
      // a Swedish track, and the indexer it came off. Nothing in the app
      // could say either before this.
      final swedish = recordedStreams().firstWhere(
        (stream) => factsOf(stream).languages.contains('🇸🇪'),
      );
      final drawn = rowFor(tester, shownOf(swedish));
      expect(drawn, contains(factsOf(swedish).languagesLabel));
      expect(drawn.singleWhere((line) => line == 'ThePirateBay'), isNotNull);
    });
  });

  group('on a television', () {
    Future<void> pump(WidgetTester tester, {bool sectioned = false}) async {
      useScreen(tester, tvSize);
      final prefs = AppPrefs(
        client: FakePrefsClient({'streamsSectioned': sectioned}),
      );
      addTearDown(prefs.dispose);
      await prefs.load();
      await tester.pumpWidget(
        harness(
          FakeCoreClient(state: {CoreField.metaDetails: recordedMovie()}),
          prefs,
          device: tv,
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Every string the card led by [lead] draws, with the break
    /// opportunities taken back out ([breakableRelease]).
    List<String> drawnOn(WidgetTester tester, String lead) => [
      for (final text in tester.widgetList<Text>(
        find.descendant(
          of: find.byWidgetPredicate(
            (w) => w is TvSourceCard && w.source.title == lead,
          ),
          matching: find.byType(Text),
        ),
      ))
        text.data!.replaceAll('\u200b', ''),
    ];

    List<TvSource> cards(WidgetTester tester) => [
      for (final card in tester.widgetList<TvSourceCard>(
        find.byType(TvSourceCard),
      ))
        card.source,
    ];

    testWidgets('every recorded row is a card carrying the whole answer', (
      tester,
    ) async {
      await pump(tester);
      final drawn = cards(tester);
      // Thirty and not thirty-one: two recorded rows are the same torrent
      // from Public Domain Movies, and one source is one card.
      expect(drawn, hasLength(30));

      for (final (index, stream) in recordedStreams().indexed) {
        final shown = shownOf(stream);
        final why = 'recorded row ${index + 1}';
        // Led by the lead *and* carrying its own lines: two recorded rows
        // are `Amazon Prime Video` with different availability under them.
        final card = drawn.firstWhere(
          (source) =>
              source.title == shown.lead &&
              source.lines.join('\n') == shown.rest.join('\n'),
          orElse: () => fail(
            '$why: no card leading with ${shown.lead} carries ${shown.rest}',
          ),
        );
        expect(card.lines, isNot(contains(shown.lead)), reason: why);
        expect(card.pills, factsOf(stream).pills, reason: '$why: the parse');
      }

      // And the card draws them. Recorded row 4 is the pack: the film is
      // the lead, off `behaviorHints.filename`, and what the collection it
      // came out of adds to that is the line under it -- which is the one
      // thing on that card a viewer cannot work out from the file name.
      const film =
          'The Matrix (1999) (2160p HDR BDRip x265 10bit DTS) '
          '[4KLiGHT]';
      const pack = 'PACK 4K UHD Collection 1999-2003';
      expect(drawnOn(tester, film), containsAllInOrder([film, pack]));
      // Row 6 is the wall of text: ~120 characters of spelled-out dubs in
      // the filename where the addon's own line says `MULTi`. The lead is
      // on the card whole -- what the card does about the length is wrap
      // at the release's own separators and stop at
      // [TvSourceCard.leadLines] -- and the line under it is the one word
      // of it that is not the lead already.
      expect(drawnOn(tester, dubs), containsAllInOrder([dubs, 'MULTi']));
    });

    testWidgets('a card is never taller than a row of them is allowed to '
        'be', (tester) async {
      await pump(tester, sectioned: true);

      // What this is really measuring is the panel. A row of cards is as
      // tall as the tallest card in it, so the tallest recorded answer
      // sets the height of every card beside it -- and the sources have to
      // share a 720p television with the rung headers above them, the
      // heading's own two rungs of controls, and the row of group pills.
      //
      // Uncapped, the tallest recorded card comes out at 403 dp and the
      // row at 427 -- most of a 648 dp safe area, so walking from a pill
      // to a card would scroll the screen. Three lines for the lead and
      // three for each line under it ([TvSourceCard.leadLines],
      // [TvSourceCard.bodyLines]) bring the 2160p row to 337.
      //
      // It was 342 at two lines of lead, before the repeat of the release
      // was taken out of the line underneath it: that took the row to 322,
      // and the third line of the lead spent 15 dp of the 20.
      //
      // Rebuilding the parser around one tokenisation shortened six of
      // these second lines and added six rows, and moved neither capped
      // number: 313 and 337 before, 313 and 337 after. What binds them is
      // row 6's lead, which no line under it can shorten -- uncapped the
      // row did fall, 447 to 427. So the room does not buy a taller cap
      // either: a fourth lead line measures 352 and a fourth body line
      // 353, both past the 342 this panel is known to carry.
      //
      // These numbers are the widget test's own font, whose glyphs are
      // square and therefore wider than any real one: a conservative
      // measure, and the reason this asserts a ceiling rather than an
      // equality.
      final heights = tester
          .widgetList<TvSourceCard>(find.byType(TvSourceCard))
          .map((card) => tester.getRect(find.byWidget(card)).height)
          .toSet();
      expect(
        heights,
        hasLength(1),
        reason:
            'one height for the row: ragged bottoms read as cards half '
            'drawn rather than as addons with different amounts to say',
      );
      expect(heights.single, lessThanOrEqualTo(320));
      expect(
        tester.getRect(find.byType(TvSourceRow)).height,
        lessThanOrEqualTo(tvSize.height / 2),
        reason: 'the sources are a row of the panel, not the panel',
      );

      // And the room the subtraction bought is spent, not banked: the
      // longest recorded release is painted over three lines
      // ([TvSourceCard.leadLines]), written out here rather than read off
      // the constant so that lowering the cap fails this. Two was what the
      // panel could afford while the line underneath was the release over
      // again; six is what the release would take uncut.
      expect(linesOf(tester, breakableRelease(dubs)), 3);
    });

    testWidgets('the card the remote is on is whole on the panel, with the '
        'pills it was opened from still above it', (tester) async {
      await pump(tester, sectioned: true);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<TvSourceCard>(), isTrue);

      // The two rungs a viewer is working between. Both on screen at once
      // is what makes the row usable: the pill says which resolution is
      // open and the card says what one of them is, and a card that ran
      // off the bottom would be a card whose last line nobody ever read.
      final safe = tvSize.height * (1 - TvDensity.overscan);
      final pill = tester.getRect(find.byType(TvSourceGroupPill).first);
      final card = tester.getRect(find.byType(TvSourceCard).first);
      expect(pill.top, greaterThanOrEqualTo(0));
      expect(card.bottom, lessThanOrEqualTo(safe));
      expect(card.top, greaterThan(pill.bottom));
    });

    testWidgets('a one-line answer costs nothing, because it is never in a '
        'row with a four-line one', (tester) async {
      // The worry the sizing was checked against: WatchHub answers with a
      // service and a word (`Amazon Prime Video` / `Subscription`), and a
      // card of that in a row sized for a pack would be mostly empty. It
      // never is. WatchHub states no resolution, so in the sectioned
      // layout its rows are the whole of `Unknown resolution`, and in the
      // grouped layout they are its own pill -- either way a one-line
      // answer only ever shares a row with other one-line answers.
      await pump(tester, sectioned: true);
      for (var i = 0; i < 3; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(groupLabel(tester), 'Unknown resolution');

      final row = tester.getRect(find.byType(TvSourceRow)).height;
      expect(
        row,
        lessThan(
          TvSourceRows.minSourceRowHeight(
                tester.element(find.byType(TvSourceRow)),
              ) *
              1.5,
        ),
        reason: 'a row of one-line cards is near the floor it always was',
      );
      for (final card in cards(tester)) {
        expect(card.lines, hasLength(1));
        expect(card.pills, isEmpty, reason: 'WatchHub states nothing at all');
      }
    });
  });
}

/// How many lines the paragraph drawing [text] is painted over -- the
/// boxes a selection of the whole string lands in, counted by how many
/// heights they sit at. A paragraph that was cut short has boxes for the
/// lines it drew and none for the rest, which is the number this is for.
int linesOf(WidgetTester tester, String text) => tester
    .renderObject<RenderParagraph>(find.text(text))
    .getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: text.length),
    )
    .map((box) => box.top)
    .toSet()
    .length;

/// Which group pill is chosen.
String? groupLabel(WidgetTester tester) => tester
    .widgetList<TvSourceGroupPill>(find.byType(TvSourceGroupPill))
    .where((pill) => pill.chosen)
    .map((pill) => pill.group.label)
    .singleOrNull;
