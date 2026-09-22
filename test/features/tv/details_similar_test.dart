import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/similar_row.dart';
import 'package:xtremio/features/details/tv_source_row.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/similar/similar_resolver.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/poster_tile.dart';
import 'package:xtremio/widgets/tv_ladder.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_playback_engine.dart';
import '../../support/fake_prefs_client.dart';
import '../../support/fake_torrent_stats_client.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

/// The "More like this" rung: when there is one at all, and what an answer
/// that arrives three seconds after the viewer does is allowed to disturb.
///
/// Everything behind the row is `features/similar/` and tested there; this
/// file is about the row's arrival, which is the dangerous part. Nothing
/// here reaches a model or a catalogue: the ask is a [Completer] the test
/// completes when it wants the answer to land.
const movieId = 'tt0063350';

Map<String, dynamic> streamGroup(
  String host,
  List<Map<String, dynamic>> streams,
) => {
  'request': {
    'base': 'https://$host/manifest.json',
    'path': {
      'resource': 'stream',
      'type': 'movie',
      'id': movieId,
      'extra': <Object>[],
    },
  },
  'content': {'type': 'Ready', 'content': streams},
};

/// The film, with one addon answering.
Map<String, dynamic> film() => loadMetaDetailsFixture()
  ..['streams'] = [
    streamGroup('alpha.example', [
      {
        'infoHash': '1'.padLeft(40, '0'),
        'name': 'Alpha 1080p',
        'description': '👤 20 💾 2 GB',
      },
    ]),
  ];

/// One resolved suggestion, as the guard hands them over: a real catalogue
/// item and the model's sentence about it. No poster, so nothing here
/// reaches the network for an image either.
SimilarTitle suggestion(String id, String name, int year) => SimilarTitle(
  item: MetaItemPreview({
    'id': id,
    'type': 'movie',
    'name': name,
    'releaseInfo': '$year',
  }),
  why: 'the same grey and the same pace',
);

final stalker = suggestion('tt0079944', 'Stalker', 1979);
final existenz = suggestion('tt0120907', 'eXistenZ', 1999);

/// The labels of every rung header on the panel, top to bottom.
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

/// The summary on the rung called [label].
String summaryOf(WidgetTester tester, String label) => tester
    .widgetList<TvLadderRung>(find.byType(TvLadderRung))
    .firstWhere((rung) => rung.label == label)
    .summary;

/// Walks down until the remote is on the header of the rung called
/// [label], and says how many presses it took.
Future<int> stepDownToRung(WidgetTester tester, String label) async {
  for (var i = 1; i <= 8; i++) {
    await press(tester, LogicalKeyboardKey.arrowDown);
    if (focusedLabel(tester) == label) return i;
  }
  fail('never reached $label; the remote is on ${focusedLabel(tester)}');
}

void main() {
  /// What the screen asked for, and the answer it is still waiting on.
  ///
  /// Both are made in [mount] rather than in a `setUp`, and that is not
  /// housekeeping: a [Completer] built outside the test body belongs to
  /// the real zone, and its completion is a microtask the fake clock's
  /// `pump` never runs. The answer would land after the test had ended.
  late List<String> asked;
  late Completer<List<SimilarTitle>> answer;

  /// The preferences the screen is mounted over, so a test can paste a key
  /// into them while the title is open.
  late AppPrefs prefs;

  /// An asker that records the question and answers when the test says so.
  SimilarAsk waiting(AppPrefs prefs) =>
      ({
        required String type,
        required String id,
        required String name,
        int? year,
        bool afresh = false,
      }) {
        final subject = year == null
            ? '$type $id $name'
            : '$type $id $name ($year)';
        asked.add(afresh ? '$subject afresh' : subject);
        return answer.future;
      };

  /// One that fails the test if anything asks it anything at all.
  SimilarAsk never(AppPrefs prefs) =>
      ({
        required String type,
        required String id,
        required String name,
        int? year,
        bool afresh = false,
      }) {
        fail('the model was asked about $name with no key configured');
      };

  Future<void> mount(
    WidgetTester tester, {
    String? apiKey = 'not-a-real-key',
    SimilarAskBuilder? askFor,
    Map<String, dynamic>? fixture,
  }) async {
    asked = [];
    answer = Completer<List<SimilarTitle>>();
    useScreen(tester, tvSize);
    prefs = AppPrefs(
      client: FakePrefsClient({AppPrefs.similarApiKeyKey: ?apiKey}),
    );
    addTearDown(prefs.dispose);
    await prefs.load();
    await tester.pumpWidget(
      DeviceScope(
        profile: tv,
        child: CoreScope(
          client: FakeCoreClient(
            state: {CoreField.metaDetails: fixture ?? film()},
          ),
          child: PrefsScope(
            prefs: prefs,
            child: PlaybackScope(
              createEngine: FakePlaybackEngine.new,
              torrentStats: FakeTorrentStatsClient(),
              child: SimilarScope(
                askFor: askFor ?? waiting,
                child: const MaterialApp(
                  home: MetaDetailsScreen(type: 'movie', id: movieId),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Lands the answer on the screen. The completion is a microtask and
  /// [WidgetTester.pumpAndSettle] does not run one before its first frame,
  /// so the tree is pumped once for it and settled after.
  ///
  /// A fresh completer is left behind it, so a re-ask has one of its own.
  Future<void> land(WidgetTester tester, List<SimilarTitle> titles) async {
    final landing = answer;
    answer = Completer<List<SimilarTitle>>();
    landing.complete(titles);
    await tester.pump();
    await tester.pumpAndSettle();
  }

  /// Opens the rung, walks the remote down into the strip and along it to
  /// the far end, and says what it stood on at every step.
  Future<List<String?>> walkTheRow(WidgetTester tester) async {
    await stepDownToRung(tester, kMoreLikeThisLabel);
    await press(tester, LogicalKeyboardKey.select);
    await press(tester, LogicalKeyboardKey.arrowDown);
    final walk = <String?>[focusedLabel(tester)];
    for (var i = 0; i < 2; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
      walk.add(focusedLabel(tester));
    }
    return walk;
  }

  /// Select on the card the remote is standing on. Not settled: while the
  /// ask is out the card holds a spinner, and a spinner never stops.
  Future<void> pressSelect(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
  }

  group('whether there is a rung at all', () {
    testWidgets('with no key configured there is none, and nothing is '
        'asked: the feature is off and says nothing about itself', (
      tester,
    ) async {
      await mount(tester, apiKey: null, askFor: never);

      expect(rungs(tester), [kSourcesLabel]);
      expect(find.text(kMoreLikeThisLabel), findsNothing);
      expect(find.byType(SimilarTitlesRow), findsNothing);
    });

    testWidgets('with a key the header is on the panel before the answer '
        'is, and says it is looking', (tester) async {
      await mount(tester);

      expect(rungs(tester), [kSourcesLabel, kMoreLikeThisLabel]);
      expect(summaryOf(tester, kMoreLikeThisLabel), kLookingForSimilar);
      // The title and its year are the question, asked once.
      expect(asked, ['movie $movieId Night of the Living Dead (1968)']);
    });

    testWidgets('and fills when the answer arrives', (tester) async {
      await mount(tester);

      await land(tester, [stalker, existenz]);

      expect(summaryOf(tester, kMoreLikeThisLabel), '2 titles');
      // Still shut: the answer landing is not the viewer asking for it.
      expect(find.byType(SimilarTitlesRow), findsNothing);
    });

    testWidgets('an answer of nothing takes the rung away rather than '
        'leaving a header over an empty row', (tester) async {
      await mount(tester);
      expect(find.text(kMoreLikeThisLabel), findsOneWidget);

      await land(tester, const []);

      expect(rungs(tester), [kSourcesLabel]);
      expect(find.text(kMoreLikeThisLabel), findsNothing);
    });

    testWidgets('and a key pasted in while the title is open turns it on: '
        'the settings screen is a press away from here', (tester) async {
      await mount(tester, apiKey: null);
      expect(find.text(kMoreLikeThisLabel), findsNothing);

      await prefs.setSimilarApiKey('not-a-real-key');
      await tester.pumpAndSettle();

      expect(rungs(tester), [kSourcesLabel, kMoreLikeThisLabel]);
      expect(asked, hasLength(1));
    });

    testWidgets('and the screen never opens it by itself, even when it is '
        'the only rung there is', (tester) async {
      // No addon answered at all, so there is no sources rung to be open
      // instead -- and this one still is not, because what is in it
      // arrives when a stranger's server feels like answering.
      await mount(tester, fixture: loadMetaDetailsFixture()..['streams'] = []);

      expect(rungs(tester), [kMoreLikeThisLabel]);
      expect(openRungLabel(tester), isNull);

      // Not settled: the rung this press opens holds the spinner, and a
      // spinner never stops.
      await stepDownToRung(tester, kMoreLikeThisLabel);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(openRungLabel(tester), kMoreLikeThisLabel, reason: 'the viewer');
    });
  });

  group('a row that arrives late', () {
    testWidgets('does not take a remote the viewer has moved, and does not '
        'move the panel under it', (tester) async {
      await mount(tester);
      // A walk with no select in it: the viewer is standing where they
      // put themselves, in the rung above.
      await stepDownToRung(tester, kMoreLikeThisLabel);
      await press(tester, LogicalKeyboardKey.arrowUp);
      final standingOn = focusedLabel(tester);
      final panel = {
        for (final label in rungs(tester))
          label: tester.getRect(find.text(label)),
      };

      await land(tester, [stalker, existenz]);

      expect(focusedLabel(tester), standingOn, reason: 'the remote stayed');
      expect(
        {
          for (final label in rungs(tester))
            label: tester.getRect(find.text(label)),
        },
        panel,
        reason: 'and so did every rung',
      );
    });

    testWidgets('and lands in a box the size of the row it fills, so even a '
        'viewer standing in the open rung sees nothing move', (tester) async {
      await mount(tester);
      await stepDownToRung(tester, kMoreLikeThisLabel);
      // Open it while the answer is still out: the spinner's own box.
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      final waiting = tester.getRect(find.byType(SimilarTitlesRow));
      expect(find.byType(CircularProgressIndicator), findsWidgets);

      await land(tester, [stalker, existenz]);

      expect(tester.getRect(find.byType(SimilarTitlesRow)), waiting);
      expect(find.text('Stalker'), findsOneWidget);
      expect(
        focusedLabel(tester),
        kMoreLikeThisLabel,
        reason: 'a row appearing is not a row taking the remote',
      );
    });
  });

  group('walking to it', () {
    testWidgets('the D-pad reaches it from the sources rung and gives the '
        'remote back', (tester) async {
      await mount(tester);
      await land(tester, [stalker, existenz]);
      expect(focusIn<TvSourceGroupPill>(), isTrue, reason: 'the arrival');

      final presses = await stepDownToRung(tester, kMoreLikeThisLabel);

      for (var i = 0; i < presses; i++) {
        await press(tester, LogicalKeyboardKey.arrowUp);
      }
      expect(focusIn<TvSourceGroupPill>(), isTrue);
    });

    testWidgets('select opens it, and the row is a press below the header', (
      tester,
    ) async {
      await mount(tester);
      await land(tester, [stalker, existenz]);
      await stepDownToRung(tester, kMoreLikeThisLabel);

      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(SimilarTitlesRow), findsOneWidget);
      expect(find.text('Stalker'), findsOneWidget);
      expect(find.text('1979'), findsOneWidget);
      // The press opens the rung and nothing else, as every rung does.
      expect(focusedLabel(tester), kMoreLikeThisLabel);

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), 'Stalker');
    });

    testWidgets('and a poster opens that title', (tester) async {
      await mount(tester);
      await land(tester, [stalker, existenz]);
      await stepDownToRung(tester, kMoreLikeThisLabel);
      await press(tester, LogicalKeyboardKey.select);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), 'Stalker');

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      // Not settled: the screen pushed over this one is loading a title
      // the fake core has no state for, and a spinner never settles.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(
        tester
            .widgetList<MetaDetailsScreen>(
              find.byType(MetaDetailsScreen, skipOffstage: false),
            )
            .map((screen) => screen.id),
        contains('tt0079944'),
      );
    });
  });

  /// The way to ask again, which on a television is a card at the end of
  /// the strip rather than anything on the rung's header: the remote is
  /// already in the row, and walking off the end of it is the gesture.
  group('asking again', () {
    testWidgets('is the last card of the row, reached by walking off the '
        'end of it, and is not what the rung focuses first', (tester) async {
      await mount(tester);
      await land(tester, [stalker, existenz]);

      final walk = await walkTheRow(tester);

      expect(walk, ['Stalker', 'eXistenZ', kAskAgainLabel]);
      // The strip still swallows a press past its end, so the card is the
      // last stop rather than a way out of the row.
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(tester), kAskAgainLabel);
      // And left comes straight back to the posters.
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focusedLabel(tester), 'eXistenZ');
    });

    testWidgets('with no key configured there is no rung, and so no card', (
      tester,
    ) async {
      await mount(tester, apiKey: null, askFor: never);

      expect(find.text(kAskAgainLabel), findsNothing);
    });

    testWidgets('select on it asks again although an answer is remembered, '
        'and the new answer replaces the old one', (tester) async {
      await mount(tester);
      await land(tester, [stalker, existenz]);
      await walkTheRow(tester);
      expect(asked, hasLength(1));

      await pressSelect(tester);

      expect(
        asked.last,
        'movie $movieId Night of the Living Dead (1968) afresh',
      );
      expect(
        find.text('Stalker'),
        findsOneWidget,
        reason: 'the old row stands while the new ask is out',
      );

      await land(tester, [suggestion('tt0113277', 'Heat', 1995)]);

      expect(find.text('Heat'), findsOneWidget);
      expect(find.text('Stalker'), findsNothing);
      expect(summaryOf(tester, kMoreLikeThisLabel), '1 title');
    });

    testWidgets('a re-ask that comes back with nothing keeps the row, the '
        'rung and the remote, and says so', (tester) async {
      await mount(tester);
      await land(tester, [stalker, existenz]);
      await walkTheRow(tester);

      await pressSelect(tester);
      await land(tester, const []);

      expect(rungs(tester), [kSourcesLabel, kMoreLikeThisLabel]);
      expect(find.text('Stalker'), findsOneWidget);
      expect(find.text('eXistenZ'), findsOneWidget);
      expect(find.text(kNothingNewSimilar), findsOneWidget);
      expect(
        focusedLabel(tester),
        kAskAgainLabel,
        reason: 'a press that changed nothing moved nothing either',
      );
    });

    testWidgets('and four presses while the ask is out cost one call', (
      tester,
    ) async {
      await mount(tester);
      await land(tester, [stalker, existenz]);
      await walkTheRow(tester);

      for (var i = 0; i < 4; i++) {
        await pressSelect(tester);
      }

      expect(asked, hasLength(2), reason: 'the first ask and one re-ask');
    });
  });

  testWidgets('the poster is the size the drawing settled on', (tester) async {
    // Small enough that seven fit across a 720p panel, with room under
    // each for the name of a film the viewer has not seen.
    await mount(tester);
    await land(tester, [stalker, existenz]);
    await stepDownToRung(tester, kMoreLikeThisLabel);
    await press(tester, LogicalKeyboardKey.select);

    final poster = tester.getRect(find.byType(PosterImage).first);
    expect(poster.width, SimilarTitlesRow.posterWidth);
    expect(poster.height, SimilarTitlesRow.posterHeight);
    expect(SimilarTitlesRow.posterWidth, 120);
    expect(SimilarTitlesRow.posterHeight, 180);
  });
}
