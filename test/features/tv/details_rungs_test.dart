import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/tv_episode_row.dart';
import 'package:xtremio/features/details/tv_meta_header.dart';
import 'package:xtremio/features/details/tv_source_row.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/focusable_tile.dart';
import 'package:xtremio/widgets/tv_ladder.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_playback_engine.dart';
import '../../support/fake_prefs_client.dart';
import '../../support/fake_torrent_stats_client.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

/// The ladder itself: which rung a title opens on, what select and down do
/// to the headers, and what happens to a rung nothing can be done in.
///
/// The rungs' *contents* are the other files here (`details_sources_row`,
/// `details_episode_row`, `details_focus`); this one is about the ladder
/// they hang on.
const movieId = 'tt0063350';
const seriesId = 'tt0903747';
const pilotId = '$seriesId:1:1';

Map<String, dynamic> streamGroup(
  String host,
  String type,
  String id,
  List<Map<String, dynamic>> streams,
) => {
  'request': {
    'base': 'https://$host/manifest.json',
    'path': {'resource': 'stream', 'type': type, 'id': id, 'extra': <Object>[]},
  },
  'content': {'type': 'Ready', 'content': streams},
};

Map<String, dynamic> torrent(String hash, String name, String description) => {
  'infoHash': hash,
  'name': name,
  'description': description,
};

String hash(int seed) => seed.toRadixString(16).padLeft(40, '0');

/// A plot that runs past the header's two lines, whatever the fixture
/// records: that is what makes the description a stop of the walk, and a
/// walk that depends on how a recorded synopsis happens to wrap is a walk
/// that changes when somebody re-records it.
const String longPlot =
    'A chemistry teacher diagnosed with inoperable lung cancer turns to '
    'manufacturing and selling methamphetamine with a former student to '
    'secure his family\'s future. Everybody in it lies to somebody, at '
    'length, and the synopsis says so at greater length still, which is '
    'the whole of why the words are worth a press of their own.';

/// [fixture] with [longPlot] as the title's description.
Map<String, dynamic> plotted(Map<String, dynamic> fixture) {
  final content =
      ((fixture['metaItems'] as List<dynamic>).first
              as Map<String, dynamic>)['content']['content']
          as Map<String, dynamic>;
  content['description'] = longPlot;
  return fixture;
}

/// The film, with one addon answering.
Map<String, dynamic> film() => loadMetaDetailsFixture()
  ..['streams'] = [
    streamGroup('alpha.example', 'movie', movieId, [
      torrent(hash(1), 'Alpha 1080p', '👤 20 💾 2 GB'),
    ]),
  ];

/// The same film with the first stream recorded as the one it was last
/// played from.
Map<String, dynamic> playedFilm() {
  final fixture = film();
  final first =
      (fixture['streams'] as List<dynamic>).first as Map<String, dynamic>;
  fixture['lastUsedStream'] = {
    'request': first['request'],
    'content': {
      'type': 'Ready',
      'content': (first['content'] as Map<String, dynamic>)['content']![0],
    },
  };
  return fixture;
}

/// The series with its torrent recorded as the source it was last played
/// from.
Map<String, dynamic> playedSeries() {
  final fixture = series();
  final first =
      (fixture['streams'] as List<dynamic>).first as Map<String, dynamic>;
  fixture['lastUsedStream'] = {
    'request': first['request'],
    'content': {
      'type': 'Ready',
      'content': (first['content'] as Map<String, dynamic>)['content']![0],
    },
  };
  return fixture;
}

/// Breaking Bad at the pilot, with a torrent for it -- and an addon that
/// could not answer, so the screen has all three rungs on it.
Map<String, dynamic> series() =>
    loadSeriesEpisodeMetaDetailsFixture()
      ..['streams'] = [
        streamGroup('alpha.example', 'series', pilotId, [
          torrent(hash(1), 'Pilot 1080p', '👤 20 💾 2 GB'),
        ]),
        {
          ...streamGroup('mirror.example', 'series', pilotId, const []),
          'content': {
            'type': 'Err',
            'content': {
              'type': 'Env',
              'content': {'code': 1, 'message': 'Failed to fetch: 404'},
            },
          },
        },
      ];

/// Walks [key] to the end of the ladder and says which rung headers the
/// remote stood on along the way, counting the one it started on.
///
/// The walk stops when a press moves nothing, which is what the top and
/// the foot of the ladder answer with: a press nothing can take is left
/// alone rather than swallowed, so the remote stays where it is.
Future<List<String>> walkRungs(
  WidgetTester tester,
  LogicalKeyboardKey key,
) async {
  final headers = rungs(tester).toSet();
  final stood = <String>[];
  void note() {
    final here = focusedLabel(tester);
    if (here == null || !headers.contains(here)) return;
    if (stood.isEmpty || stood.last != here) stood.add(here);
  }

  note();
  var last = focusedLabel(tester);
  for (var i = 0; i < 12; i++) {
    await press(tester, key);
    final here = focusedLabel(tester);
    if (here == last) break;
    last = here;
    note();
  }
  return stood;
}

/// Walks up until the remote is on the header of the rung called [label].
Future<void> stepUpToRung(WidgetTester tester, String label) async {
  for (var i = 0; i < 6 && focusedLabel(tester) != label; i++) {
    await press(tester, LogicalKeyboardKey.arrowUp);
  }
  expect(focusedLabel(tester), label);
}

Future<void> mount(
  WidgetTester tester,
  Map<String, dynamic> fixture, {
  String type = 'movie',
  String id = movieId,
  bool sectioned = false,
  FakeCoreClient? client,
  // A spinner never stops, so a screen that is still waiting cannot be
  // settled; it is pumped a frame at a time instead.
  bool settle = true,
}) async {
  useScreen(tester, tvSize);
  final prefs = AppPrefs(
    client: FakePrefsClient({'streamsSectioned': sectioned}),
  );
  addTearDown(prefs.dispose);
  await prefs.load();
  await tester.pumpWidget(
    DeviceScope(
      profile: tv,
      child: CoreScope(
        client:
            client ?? FakeCoreClient(state: {CoreField.metaDetails: fixture}),
        child: PrefsScope(
          prefs: prefs,
          child: PlaybackScope(
            createEngine: FakePlaybackEngine.new,
            torrentStats: FakeTorrentStatsClient(),
            child: MaterialApp(
              home: MetaDetailsScreen(type: type, id: id),
            ),
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The label of every rung header on the panel, top to bottom.
List<String> rungs(WidgetTester tester) => [
  for (final rung in tester.widgetList<TvLadderRung>(find.byType(TvLadderRung)))
    rung.label,
];

/// The label of the rung that is open, or null when none is.
String? openRungLabel(WidgetTester tester) => tester
    .widgetList<TvLadderRung>(find.byType(TvLadderRung))
    .where((rung) => rung.open)
    .map((rung) => rung.label)
    .singleOrNull;

void main() {
  group('what is open on arrival is whatever the title is for', () {
    testWidgets('a film nobody has played opens on its sources: there is '
        'nothing to choose but which one', (tester) async {
      await mount(tester, film());

      expect(openRungLabel(tester), kSourcesLabel);
      expect(focusIn<TvSourceGroupPill>(), isTrue);
      expect(focusedLabel(tester), 'alpha.example');
    });

    testWidgets('a series nobody has played opens on its episodes, not on '
        'the sources of an episode nobody picked', (tester) async {
      await mount(tester, series(), type: 'series', id: seriesId);

      expect(openRungLabel(tester), kEpisodesLabel);
      expect(focusIn<TvEpisodeCard>(), isTrue);
      expect(find.byType(TvSourceGroupPill), findsNothing);
    });

    testWidgets('a film that has been played opens on the last-used source', (
      tester,
    ) async {
      await mount(tester, playedFilm());

      expect(openRungLabel(tester), kContinueWatchingLabel);
      // One press of select from here carries on watching, which is what
      // the viewer came back for.
      expect(focusedLabel(tester), kContinueWithLastSource);
    });

    testWidgets('and so does a series: carrying on beats picking an episode '
        'that has already been picked', (tester) async {
      await mount(tester, playedSeries(), type: 'series', id: seriesId);

      expect(openRungLabel(tester), kContinueWatchingLabel);
      expect(focusedLabel(tester), kContinueWithLastSource);
      expect(find.byType(TvEpisodeCard), findsNothing);
    });

    testWidgets('and the rung that is open is the only one that is: the '
        'rest are a line each', (tester) async {
      await mount(tester, playedFilm());

      expect(rungs(tester), [kContinueWatchingLabel, kSourcesLabel]);
      expect(find.byType(TvSourceGroupPill), findsNothing);
      expect(find.byType(TvSourceCard), findsOneWidget);
    });

    testWidgets('and a line says what it holds, which is the whole of what '
        'a viewer who never opens it is told', (tester) async {
      await mount(tester, series(), type: 'series', id: seriesId);

      // The season and the count of it, and how many sources there are
      // between how many addons -- the two things worth knowing before
      // deciding which rung to spend a press on.
      expect(find.text('Season 1 · 7'), findsOneWidget);
      expect(find.text('1 from 1 addon'), findsOneWidget);
      expect(
        find.text('1 addons did not answer'),
        findsOneWidget,
        reason: 'and what the rest of them did instead',
      );
    });
  });

  group('walking the ladder', () {
    testWidgets('down walks the headers, one press each', (tester) async {
      await mount(tester, series(), type: 'series', id: seriesId);
      // Out of the open rung first: the episodes are what the screen
      // opened on.
      await press(tester, LogicalKeyboardKey.arrowDown);

      expect(focusedLabel(tester), kSourcesLabel);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), kSourceAccountingLabel);
      // And back up the same way, which is the walk the season pills and
      // the source rows used to be strung out along.
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(tester), kSourcesLabel);
    });

    testWidgets('select on a header opens that rung and shuts the one that '
        'was open', (tester) async {
      await mount(tester, series(), type: 'series', id: seriesId);
      expect(openRungLabel(tester), kEpisodesLabel);

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), kSourcesLabel);
      await press(tester, LogicalKeyboardKey.select);

      expect(openRungLabel(tester), kSourcesLabel);
      expect(find.byType(TvEpisodeCard), findsNothing);
      // The press opens the rung and nothing else: the remote is left on
      // the header, one press above what it opened.
      expect(focusedLabel(tester), kSourcesLabel);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<TvEpisodeCard>(), isFalse);
    });

    testWidgets('select on the sources puts a row of sources out, not a row '
        'of pills with nothing under them', (tester) async {
      await mount(tester, series(), type: 'series', id: seriesId);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), kSourcesLabel);

      await press(tester, LogicalKeyboardKey.select);

      expect(find.byType(TvSourceGroupPill), findsOneWidget);
      expect(
        find.byType(TvSourceCard),
        findsWidgets,
        reason: 'the first group is open, as it is on arrival',
      );
      // And the remote is still on the header: the row appearing under it
      // is not the row taking it.
      expect(focusedLabel(tester), kSourcesLabel);
    });

    testWidgets('and select on the open rung shuts it: a header that only '
        'ever opens is a toggle that lies', (tester) async {
      await mount(tester, film());
      await stepUpToRung(tester, kSourcesLabel);
      expect(openRungLabel(tester), kSourcesLabel);

      await press(tester, LogicalKeyboardKey.select);

      expect(openRungLabel(tester), isNull, reason: 'the ladder is all lines');
      expect(find.byType(TvSourceGroupPill), findsNothing);
      expect(find.byType(TvSourceCard), findsNothing);

      await press(tester, LogicalKeyboardKey.select);
      expect(openRungLabel(tester), kSourcesLabel, reason: 'and open again');
      expect(find.byType(TvSourceGroupPill), findsOneWidget);
    });

    testWidgets('and shutting one leaves the remote on the header it was '
        'pressed on, which is still on the panel', (tester) async {
      await mount(tester, playedSeries(), type: 'series', id: seriesId);
      await stepUpToRung(tester, kContinueWatchingLabel);

      await press(tester, LogicalKeyboardKey.select);

      expect(openRungLabel(tester), isNull);
      expect(focusedLabel(tester), kContinueWatchingLabel);
      // On the panel and not merely in the tree: a remote standing on
      // something scrolled off the bottom is the same dead end as a remote
      // standing on nothing.
      final header = find.ancestor(
        of: find.text(kContinueWatchingLabel),
        matching: find.byType(TvLadderRung),
      );
      expect(header, findsOneWidget);
      expect(tester.getRect(header).top, lessThan(tvSize.height));
      // And the walk still works from there, in both directions.
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(tester), kEpisodesLabel);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), kContinueWatchingLabel);
    });

    testWidgets('up from the continue-watching row lands on the episodes '
        'rung drawn above it, rather than stepping over it', (tester) async {
      await mount(tester, playedSeries(), type: 'series', id: seriesId);
      expect(focusedLabel(tester), kContinueWithLastSource);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(tester), kContinueWatchingLabel, reason: 'its own');
      await press(tester, LogicalKeyboardKey.arrowUp);

      expect(focusedLabel(tester), kEpisodesLabel);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), kContinueWatchingLabel, reason: 'and back');
    });

    testWidgets('and the whole ladder walks both ways: no rung can be '
        'stepped over', (tester) async {
      await mount(tester, playedSeries(), type: 'series', id: seriesId);
      final drawn = rungs(tester);
      expect(drawn, [
        kEpisodesLabel,
        kContinueWatchingLabel,
        kSourcesLabel,
        kSourceAccountingLabel,
      ], reason: 'the order they are drawn down the panel');

      // Down to the foot of the ladder, then up the whole of it and down
      // the whole of it: what the walk stops on is the panel's own order,
      // backwards and forwards, with nothing missing from either.
      await walkRungs(tester, LogicalKeyboardKey.arrowDown);
      expect(
        await walkRungs(tester, LogicalKeyboardKey.arrowUp),
        drawn.reversed.toList(),
      );
      expect(await walkRungs(tester, LogicalKeyboardKey.arrowDown), drawn);
    });

    testWidgets('and it still does with the header\'s description standing '
        'in the walk', (tester) async {
      // The description became a focus stop so the plot could be unfolded
      // with a remote, and a stop added to the top of a ladder is exactly
      // how a rung gets stepped over: the header is the row at level 0,
      // and a press out of it has to reach the rung drawn under it and
      // come back. So the whole ladder is walked again from up there.
      await mount(
        tester,
        plotted(playedSeries()),
        type: 'series',
        id: seriesId,
      );
      final drawn = rungs(tester);
      expect(drawn, [
        kEpisodesLabel,
        kContinueWatchingLabel,
        kSourcesLabel,
        kSourceAccountingLabel,
      ]);

      for (var i = 0; i < 8 && !focusIn<TvMetaHeader>(); i++) {
        await press(tester, LogicalKeyboardKey.arrowUp);
      }
      expect(focusIn<TvMetaHeader>(), isTrue, reason: 'the top of the walk');
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focusIn<TvDescription>(), isTrue, reason: 'beside the bookmark');

      expect(
        await walkRungs(tester, LogicalKeyboardKey.arrowDown),
        drawn,
        reason:
            'down from the plot is the panel\'s own order, with the '
            'rung drawn under the header first',
      );

      // And back up, by hand at the top: what the rungs know nothing about
      // is the header's own two stops, and the walk has to reach both and
      // leave again.
      await stepUpToRung(tester, kEpisodesLabel);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(
        focusIn<TvDescription>(),
        isTrue,
        reason: 'above the top rung is the plot the walk left',
      );
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(
        focusedTooltip(),
        TvMetaHeader.addTooltip,
        reason: 'and above that the bookmark, which is the top of the walk',
      );
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(
        focusedLabel(tester),
        kEpisodesLabel,
        reason:
            'and one press out of the header is the rung drawn under '
            'it, not the one after that',
      );
    });
  });

  group('a rung nothing can be done in', () {
    testWidgets('is still a line the walk lands on and leaves', (tester) async {
      // Every addon is still answering, so the sources rung holds a
      // spinner and not one card. The header is still a stop of the walk,
      // and a press down out of it that nothing can answer is left alone
      // rather than swallowed -- a dead D-pad is the one outcome worse
      // than landing somewhere unexpected.
      final loading = film()
        ..['streams'] = [
          {
            ...streamGroup('slow.example', 'movie', movieId, const []),
            'content': null,
          },
        ];
      await mount(tester, loading, sectioned: true, settle: false);

      expect(rungs(tester), [kSourcesLabel]);
      expect(openRungLabel(tester), kSourcesLabel);
      expect(find.byType(TvSourceCard), findsNothing);
      expect(find.byType(TvSourceGroupPill), findsNothing);
      expect(find.text(kLookingForStreams), findsOneWidget);

      for (var i = 0; i < 6 && focusedLabel(tester) != kSourcesLabel; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
      }
      expect(focusedLabel(tester), kSourcesLabel, reason: 'the header');

      // Down goes as far as the rung's own controls and no further, and
      // the press past them leaves the remote where it is.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(focusedLabel(tester), isNotNull, reason: 'not a dead D-pad');
    });

    testWidgets('and a collapsed one the walk can pass over is passed over', (
      tester,
    ) async {
      // The episodes are what a series opens on, and the sources below
      // them are a shut line with nothing in it yet. Walking down has to
      // reach the line and then leave it, both.
      final loading = series()
        ..['streams'] = [
          {
            ...streamGroup('slow.example', 'series', pilotId, const []),
            'content': null,
          },
        ];
      await mount(tester, loading, type: 'series', id: seriesId, settle: false);

      expect(openRungLabel(tester), kEpisodesLabel);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(focusedLabel(tester), kSourcesLabel);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(focusIn<TvEpisodeCard>(), isTrue, reason: 'and back again');
    });

    testWidgets('and a rung with nothing to say is not drawn, so the walk '
        'steps over it', (tester) async {
      // A film has no episodes, and nothing answered with anything other
      // than streams, so neither of those rungs is a line on the panel.
      await mount(tester, film());

      expect(rungs(tester), [kSourcesLabel]);
      expect(find.text(kEpisodesLabel), findsNothing);
      expect(find.text(kSourceAccountingLabel), findsNothing);
    });
  });

  group('the density the ladder was collapsed for', () {
    testWidgets('a group is a pill as tall as its word, not a card with a '
        'summary under it', (tester) async {
      await mount(tester, film());

      final pill = tester.getRect(find.byType(TvSourceGroupPill).first);
      expect(pill.height, TvSourceRows.pillHeight);
      // The numbers the drawing was made at, spelled out so that changing
      // one is a decision rather than a slip.
      expect(TvSourceRows.pillHeight, 36);
      // As wide as its own label rather than a fixed box, and never
      // wider than the card it replaced: the row reads as a set of
      // choices rather than as a wall of equal boxes.
      expect(pill.width, lessThanOrEqualTo(TvSourceRows.maxPillWidth));
    });

    testWidgets('a source is a card two lines of release tall', (tester) async {
      await mount(tester, film());
      await press(tester, LogicalKeyboardKey.select);

      final card = tester.getRect(find.byType(TvSourceCard).first);
      expect(card.width, TvSourceRows.sourceCardWidth);
      expect(card.height, TvSourceRows.sourceCardHeight);
      expect(TvSourceRows.sourceCardWidth, 260);
      expect(TvSourceRows.sourceCardHeight, 96);
    });

    testWidgets('and a header line is what the sources are headed with, '
        'rather than a heading of their own above them', (tester) async {
      await mount(tester, film());

      expect(find.text(kSourcesLabel), findsOneWidget);
      expect(
        find.text('Streams'),
        findsNothing,
        reason: 'the rung header is the heading here',
      );
    });
  });

  testWidgets('a rung header wears the ring and none of the lift', (
    tester,
  ) async {
    // A line the width of the panel drawn five per cent larger overlaps
    // the rungs either side of it, on every step of a walk down the
    // ladder -- which is what [FocusTreatment.row] exists to say.
    await mount(tester, film());
    await stepUpToRung(tester, kSourcesLabel);

    final lit = tester
        .widgetList<FocusHighlight>(find.byType(FocusHighlight))
        .where((highlight) => highlight.focused)
        .single;
    expect(lit.treatment, FocusTreatment.row);
    expect(lit.treatment.lifts, isFalse);
  });

  testWidgets('a last-used source arriving late takes a remote nobody has '
      'moved, and opens the rung it is on', (tester) async {
    // The addons answer with streams before the engine says which source
    // the title was last played from, so the rung the screen means to
    // offer is built after the one standing in for it. Nobody has touched
    // the D-pad, so the start of the screen is still the screen's to
    // choose.
    final core = FakeCoreClient(state: {CoreField.metaDetails: film()});
    await mount(tester, film(), client: core);
    expect(openRungLabel(tester), kSourcesLabel);
    expect(focusedLabel(tester), 'alpha.example');

    core.setState(CoreField.metaDetails, playedFilm());
    await tester.pumpAndSettle();

    expect(openRungLabel(tester), kContinueWatchingLabel);
    expect(focusedLabel(tester), kContinueWithLastSource);
  });

  testWidgets('but once the remote has been walked anywhere, the rung it is '
      'in is the viewer\'s and a late arrival leaves it alone', (tester) async {
    final core = FakeCoreClient(state: {CoreField.metaDetails: film()});
    await mount(tester, film(), client: core);
    // A walk with no select in it: choosing a rung is not the only way to
    // be standing in one.
    await stepUpToRung(tester, kSourcesLabel);

    core.setState(CoreField.metaDetails, playedFilm());
    await tester.pumpAndSettle();

    expect(openRungLabel(tester), kSourcesLabel);
    expect(focusedLabel(tester), kSourcesLabel);
  });
}
