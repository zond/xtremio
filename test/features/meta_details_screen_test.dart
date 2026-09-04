import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/addons/addon_details_screen.dart';
import 'package:xtremio/features/addons/addons_screen.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/discover/discover_screen.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../support/fake_core_client.dart';
import '../support/fake_playback_engine.dart';
import '../support/fake_torrent_stats_client.dart';
import '../support/fixtures.dart';

const seriesId = 'tt0903747';
const pilotId = '$seriesId:1:1';

/// A Torrentio-style stream group for the selected episode, to graft onto
/// the series fixture (the default addons have no torrents for it).
Map<String, dynamic> torrentGroup(String videoId) => {
  'request': {
    'base': 'https://torrentio.example/manifest.json',
    'path': {
      'resource': 'stream',
      'type': 'series',
      'id': videoId,
      'extra': <Object>[],
    },
  },
  'content': {
    'type': 'Ready',
    'content': [
      {
        'infoHash': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'fileIdx': 3,
        'name': 'Torrentio\n1080p',
        'description': 'Breaking.Bad.S01E01.1080p.mkv\n👤 42 💾 1.51 GB',
        'behaviorHints': {'filename': 'Breaking.Bad.S01E01.1080p.mkv'},
      },
    ],
  },
};

/// The season pills, in the order the row draws them: every [ChoiceChip]
/// under the widget that also holds the row's own "Season" label.
Finder seasonPills() => find.descendant(
  of: find.ancestor(of: find.text('Season'), matching: find.byType(Row)).first,
  matching: find.byType(ChoiceChip),
);

/// What each season pill reads.
List<String?> seasonLabels(WidgetTester tester) => [
  for (final pill in tester.widgetList<ChoiceChip>(seasonPills()))
    (pill.label as Text).data,
];

/// The pill the row fills, and there is exactly one of those.
String? selectedSeason(WidgetTester tester) {
  final filled = [
    for (final pill in tester.widgetList<ChoiceChip>(seasonPills()))
      if (pill.selected) (pill.label as Text).data,
  ];
  expect(filled, hasLength(1), reason: 'one season is current');
  return filled.single;
}

void main() {
  /// Grouped, not the sources list's sectioned default: this file is
  /// about the screen's own loading and routing, not resolution sections,
  /// and most of it wants a stream on screen with no section to open
  /// first. `AppPrefs.inMemory()` persists nothing, so the setter's write
  /// below completes synchronously (nothing to await) and the value is
  /// already in place by the time this returns.
  AppPrefs groupedPrefs() {
    final prefs = AppPrefs.inMemory();
    unawaited(prefs.setStreamsSectioned(false));
    return prefs;
  }

  // Scopes sit above MaterialApp, as in the app, so pushed routes see them.
  Widget harness(
    FakeCoreClient core,
    FakePlaybackEngine engine, {
    String type = 'movie',
    String id = 'tt0063350',
    String? videoId,
  }) => CoreScope(
    client: core,
    child: PlaybackScope(
      createEngine: () => engine,
      torrentStats: FakeTorrentStatsClient(),
      child: PrefsScope(
        prefs: groupedPrefs(),
        child: MaterialApp(
          home: MetaDetailsScreen(type: type, id: id, videoId: videoId),
        ),
      ),
    ),
  );

  /// Wide layout, tall enough that the lazy episode and stream lists are
  /// built without scrolling.
  void useWideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// Narrow. Tall by default so the lazy lists are built without scrolling;
  /// a test about scrolling passes a real phone's height.
  void usePhoneViewport(WidgetTester tester, {double height = 3000}) {
    tester.view.physicalSize = Size(400, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// Runs the scroll a tap on an episode starts. It is scheduled after the
  /// frame of the tap, an animation needs a frame of its own to begin, and
  /// the section's spinner means `pumpAndSettle` never returns.
  Future<void> pumpReveal(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Map<String, dynamic> loadArgs(CoreAction action) =>
      (action.action['args'] as Map<String, dynamic>)['args']
          as Map<String, dynamic>;

  group('movie', () {
    testWidgets('loads the title on mount and lists streams per addon', (
      tester,
    ) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      await tester.pumpWidget(harness(core, FakePlaybackEngine()));
      await tester.pumpAndSettle();

      expect(core.dispatched, hasLength(1), reason: 'the engine guessed');
      expect(
        core.dispatched.single.action,
        CoreActions.loadMetaDetails(type: 'movie', id: 'tt0063350').action,
      );

      expect(find.text('Night of the Living Dead'), findsWidgets);
      expect(find.text('1968 · 96 min · movie'), findsOneWidget);
      expect(find.text('7.8'), findsOneWidget, reason: 'IMDb rating');
      expect(find.widgetWithText(ActionChip, 'Horror'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Thriller'), findsOneWidget);
      expect(find.text('Season'), findsNothing, reason: 'a movie has none');

      // Addon groups, a playable torrent with its size parsed into a chip,
      // disabled externals, an addon that answered with nothing.
      expect(find.text('caching.stremio.net'), findsOneWidget);
      expect(find.text('1080p'), findsOneWidget);
      expect(find.text('1.51 GB'), findsOneWidget);
      expect(find.text('💾 1.51 GB'), findsNothing);
      expect(find.text('Amazon Prime Video'), findsOneWidget);
      final external = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('Amazon Prime Video'),
          matching: find.byType(ListTile),
        ),
      );
      expect(external.enabled, isFalse);
      // The addon that answered with nothing is a line below the streams,
      // not a labelled section of its own.
      expect(find.text('No streams'), findsNothing);
      expect(find.text('1 addon had nothing for this title'), findsOneWidget);
      expect(find.text('EmptyContent'), findsNothing);

      // Leaving unloads the field.
      await tester.pumpWidget(const SizedBox());
      expect(
        core.dispatched.last.action,
        CoreActions.unload(CoreField.metaDetails).action,
      );
    });

    testWidgets('tapping a stream opens the player with it', (tester) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {
          CoreField.metaDetails: loadMetaDetailsFixture(),
          CoreField.player: loadPlayerFixture(),
        },
      );
      final engine = FakePlaybackEngine();
      await tester.pumpWidget(harness(core, engine));
      await tester.pumpAndSettle();

      await tester.tap(find.text('1080p'));
      await tester.pumpAndSettle();

      expect(find.byType(PlayerScreen), findsOneWidget);
      final load = core.dispatched.firstWhere(
        (a) => a.field == CoreField.player,
      );
      final args = loadArgs(load);
      expect(
        args['stream']['infoHash'],
        '11ea02584fa6351956f35671962ab46354d99060',
      );
      expect(
        args['streamRequest']['base'],
        'https://caching.stremio.net/publicdomainmovies.now.sh/manifest.json',
      );
      expect(args['metaRequest']['base'], kCinemetaManifestUrl);
      expect(args['subtitlesPath'], {
        'resource': 'subtitles',
        'type': 'movie',
        'id': 'tt0063350',
        'extra': <Object>[],
      });
      expect(engine.opened, hasLength(1), reason: 'the player opened the URL');
    });

    testWidgets('pins the last used stream when the engine found one', (
      tester,
    ) async {
      useWideViewport(tester);
      final fixture = loadMetaDetailsFixture();
      final torrents = (fixture['streams'] as List<dynamic>)[1];
      fixture['lastUsedStream'] = {
        'request': torrents['request'],
        'content': {
          'type': 'Ready',
          'content': torrents['content']['content'][0],
        },
      };
      final core = FakeCoreClient(
        state: {
          CoreField.metaDetails: fixture,
          CoreField.player: loadPlayerFixture(),
        },
      );
      await tester.pumpWidget(harness(core, FakePlaybackEngine()));
      await tester.pumpAndSettle();

      expect(find.text('Continue with last source'), findsOneWidget);
      final pinned = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('Continue with last source'),
          matching: find.byType(ListTile),
        ),
      );
      expect(pinned.selected, isTrue);

      await tester.tap(find.text('Continue with last source'));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerScreen), findsOneWidget);
      final load = core.dispatched.firstWhere(
        (a) => a.field == CoreField.player,
      );
      expect(
        loadArgs(load)['streamRequest']['base'],
        'https://caching.stremio.net/publicdomainmovies.now.sh/manifest.json',
      );
    });

    testWidgets('loads the episode the player hands back for the next one', (
      tester,
    ) async {
      useWideViewport(tester);
      final fixture = loadSeriesEpisodeMetaDetailsFixture();
      (fixture['streams'] as List<dynamic>).add(torrentGroup(pilotId));
      // The player will know the next episode but have no stream for it.
      final player = loadPlayerFixture();
      player['nextVideo'] = {
        'id': '$seriesId:1:2',
        'title': "Cat's in the Bag...",
        'season': 1,
        'episode': 2,
      };
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: fixture, CoreField.player: player},
      );
      await tester.pumpWidget(
        harness(core, FakePlaybackEngine(), type: 'series', id: seriesId),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Torrentio\n1080p'));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerScreen), findsOneWidget);

      await tester.tap(find.byTooltip('Next episode (N)'));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.byType(MetaDetailsScreen), findsOneWidget);
      // (The player's own Unload follows once its route is gone.)
      final reload = core.dispatched.lastWhere(
        (a) => a.field == CoreField.metaDetails,
      );
      expect(reload.action['action'], 'Load');
      expect(loadArgs(reload)['streamPath']['id'], '$seriesId:1:2');
    });

    testWidgets('a genre chip opens Discover on that genre', (tester) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {
          CoreField.metaDetails: loadMetaDetailsFixture(),
          CoreField.discover: loadDiscoverFixture(),
        },
      );
      await tester.pumpWidget(harness(core, FakePlaybackEngine()));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ActionChip, 'Horror'));
      // The field holds another catalog (the fixture, no genre), which the
      // new screen ignores: it shows a spinner (never settling) until its
      // own state arrives, so pump the route transition by hand.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.byType(DiscoverScreen), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final load = core.dispatched.firstWhere(
        (a) => a.field == CoreField.discover,
      );
      expect(
        load.action,
        CoreActions.loadDiscover(
          ResourceRequest.cinemetaCatalog(
            type: 'movie',
            id: 'top',
            extra: const [ExtraValue('genre', 'Horror')],
          ),
        ).action,
      );
    });

    testWidgets(
      'covered by another title, keeps its own state and takes the field '
      'back when it is on top again',
      (tester) async {
        useWideViewport(tester);
        final core = FakeCoreClient(
          state: {CoreField.metaDetails: loadMetaDetailsFixture()},
        );
        await tester.pumpWidget(harness(core, FakePlaybackEngine()));
        await tester.pumpAndSettle();
        expect(core.dispatched, hasLength(1));

        // A poster in Discover (reached through a genre chip) pushes a second
        // details screen over this one; the shared field now serves it.
        Navigator.of(tester.element(find.byType(MetaDetailsScreen))).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                const MetaDetailsScreen(type: 'series', id: seriesId),
          ),
        );
        // (Its spinner never settles until its state is in.)
        await tester.pump();
        await tester.pump();
        core.setState(CoreField.metaDetails, loadSeriesMetaDetailsFixture());
        await tester.pumpAndSettle();

        // The second screen loaded and picked its pilot; the covered one
        // neither reloaded nor went blank on the other title's state.
        expect(core.dispatched, hasLength(3));
        expect(loadArgs(core.dispatched[1])['metaPath']['id'], seriesId);
        expect(find.text('Breaking Bad'), findsWidgets);
        expect(find.text('Night of the Living Dead'), findsNothing);
        expect(
          find.text('Night of the Living Dead', skipOffstage: false),
          findsWidgets,
        );
        expect(
          find.byType(CircularProgressIndicator, skipOffstage: false),
          findsNothing,
        );

        // Back: the first screen loads its title again, with the video it
        // had, and the popped screen leaves the field to it.
        Navigator.of(tester.element(find.byType(MetaDetailsScreen))).pop();
        await tester.pumpAndSettle();
        expect(find.byType(MetaDetailsScreen), findsOneWidget);
        expect(find.text('Night of the Living Dead'), findsWidgets);
        expect(core.dispatched, hasLength(4));
        expect(
          core.dispatched.last.action,
          CoreActions.loadMetaDetails(
            type: 'movie',
            id: 'tt0063350',
            videoId: 'tt0063350',
          ).action,
        );

        // Its own exit unloads the field as usual.
        await tester.pumpWidget(const SizedBox());
        expect(
          core.dispatched.last.action,
          CoreActions.unload(CoreField.metaDetails).action,
        );
        expect(
          core.dispatched.where((a) => a.action['action'] == 'Unload'),
          hasLength(1),
        );
      },
    );

    testWidgets('coming back from the player does not reload the title', (
      tester,
    ) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {
          CoreField.metaDetails: loadMetaDetailsFixture(),
          CoreField.player: loadPlayerFixture(),
        },
      );
      await tester.pumpWidget(harness(core, FakePlaybackEngine()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1080p'));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerScreen), findsOneWidget);
      final before = core.dispatched
          .where((a) => a.field == CoreField.metaDetails)
          .length;

      Navigator.of(tester.element(find.byType(PlayerScreen))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(MetaDetailsScreen), findsOneWidget);
      expect(
        core.dispatched.where((a) => a.field == CoreField.metaDetails),
        hasLength(before),
        reason: 'the field still holds this title',
      );
    });

    testWidgets(
      'shows a spinner while the meta loads and the error otherwise',
      (tester) async {
        Map<String, dynamic> withMeta(Map<String, dynamic> content) => {
          'selected': {
            'metaPath': {
              'resource': 'meta',
              'type': 'movie',
              'id': 'tt0063350',
              'extra': <Object>[],
            },
            'streamPath': null,
            'guessStream': true,
          },
          'metaItems': [
            {
              'request': ResourceRequest(
                base: kCinemetaManifestUrl,
                path: const ResourcePath(
                  resource: 'meta',
                  type: 'movie',
                  id: 'tt0063350',
                ),
              ).toJson(),
              'content': content,
            },
          ],
          'metaStreams': <Object>[],
          'streams': <Object>[],
        };
        final core = FakeCoreClient(
          state: {
            CoreField.metaDetails: withMeta({'type': 'Loading'}),
          },
        );
        await tester.pumpWidget(harness(core, FakePlaybackEngine()));
        await tester.pump();
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        core.setState(
          CoreField.metaDetails,
          withMeta({
            'type': 'Err',
            'content': {
              'type': 'Env',
              'content': {'code': 2, 'message': 'HTTP 404'},
            },
          }),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Could not load this title: HTTP 404'),
          findsOneWidget,
        );
        expect(core.dispatched, hasLength(1), reason: 'nothing to pick');
      },
    );
  });

  group('library bookmark', () {
    testWidgets('a title outside the library offers Add and sends the meta', (
      tester,
    ) async {
      useWideViewport(tester);
      final fixture = loadMetaDetailsFixture();
      final core = FakeCoreClient(state: {CoreField.metaDetails: fixture});
      await tester.pumpWidget(harness(core, FakePlaybackEngine()));
      await tester.pumpAndSettle();

      // The recorded item was only played: a removed temp item.
      expect(MetaDetailsState.fromJson(fixture).isInLibrary, isFalse);
      expect(find.byTooltip('Add to library'), findsOneWidget);
      expect(find.byTooltip('Remove from library'), findsNothing);
      expect(find.byIcon(Icons.bookmark_border), findsOneWidget);
      expect(find.byIcon(Icons.bookmark), findsNothing);

      await tester.tap(find.byTooltip('Add to library'));
      await tester.pump();

      final ctx = core.dispatched.where((a) => a.action['action'] == 'Ctx');
      expect(ctx, hasLength(1));
      expect(ctx.single.field, CoreField.ctx);
      final meta = MetaDetailsState.fromJson(fixture).meta!;
      expect(ctx.single.action, CoreActions.addToLibrary(meta.json).action);
      expect(ctx.single.action['args']['args']['id'], 'tt0063350');
      expect(ctx.single.action['args']['args']['videos'], isNotNull);
    });

    testWidgets('a title in the library offers Remove and sends the id', (
      tester,
    ) async {
      useWideViewport(tester);
      final fixture = loadMetaDetailsFixture();
      (fixture['libraryItem'] as Map<String, dynamic>)
        ..['removed'] = false
        ..['temp'] = false;
      final core = FakeCoreClient(state: {CoreField.metaDetails: fixture});
      await tester.pumpWidget(harness(core, FakePlaybackEngine()));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Remove from library'), findsOneWidget);
      expect(find.byIcon(Icons.bookmark), findsOneWidget);
      expect(find.byIcon(Icons.bookmark_border), findsNothing);

      await tester.tap(find.byTooltip('Remove from library'));
      await tester.pump();

      final ctx = core.dispatched.where((a) => a.action['action'] == 'Ctx');
      expect(ctx, hasLength(1));
      expect(ctx.single.field, CoreField.ctx);
      expect(
        ctx.single.action,
        CoreActions.removeFromLibrary('tt0063350').action,
      );
      expect(ctx.single.action['args']['args'], 'tt0063350');
    });

    testWidgets('the bookmark follows the engine after an add', (tester) async {
      useWideViewport(tester);
      final fixture = loadMetaDetailsFixture();
      final core = FakeCoreClient(state: {CoreField.metaDetails: fixture});
      await tester.pumpWidget(harness(core, FakePlaybackEngine()));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.bookmark_border), findsOneWidget);

      final added = loadMetaDetailsFixture();
      (added['libraryItem'] as Map<String, dynamic>)
        ..['removed'] = false
        ..['temp'] = false;
      core.setState(CoreField.metaDetails, added);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.bookmark), findsOneWidget);
      expect(find.byIcon(Icons.bookmark_border), findsNothing);
    });
  });

  group('series', () {
    /// Mounts Breaking Bad with the guessing-load fixture.
    Future<FakeCoreClient> mountSeries(
      WidgetTester tester, {
      String? videoId,
      Map<String, dynamic>? fixture,
    }) async {
      final core = FakeCoreClient(
        state: {
          CoreField.metaDetails: fixture ?? loadSeriesMetaDetailsFixture(),
          CoreField.player: loadPlayerFixture(),
        },
      );
      await tester.pumpWidget(
        harness(
          core,
          FakePlaybackEngine(),
          type: 'series',
          id: seriesId,
          videoId: videoId,
        ),
      );
      await tester.pumpAndSettle();
      return core;
    }

    testWidgets(
      'picks the first episode when the engine guesses nothing, and lists '
      'the seasons with specials last',
      (tester) async {
        useWideViewport(tester);
        final core = await mountSeries(tester);

        expect(core.dispatched, hasLength(2));
        expect(
          core.dispatched[0].action,
          CoreActions.loadMetaDetails(type: 'series', id: seriesId).action,
        );
        expect(
          core.dispatched[1].action,
          CoreActions.loadMetaDetails(
            type: 'series',
            id: seriesId,
            videoId: pilotId,
          ).action,
        );
        expect(loadArgs(core.dispatched[1])['guessStream'], isFalse);

        expect(find.text('2008–2013 · 49 min · series'), findsOneWidget);
        expect(find.text('9.5'), findsOneWidget);
        expect(find.text('Season'), findsOneWidget, reason: 'the row label');
        expect(seasonLabels(tester), ['1', '2', '3', '4', '5', 'Specials']);
        expect(selectedSeason(tester), '1');
        expect(find.text('Pilot'), findsOneWidget);
        expect(find.text("Cat's in the Bag..."), findsOneWidget);
        expect(find.text('2008-01-21'), findsOneWidget);
        expect(find.text('Seven Thirty-Seven'), findsNothing);
        expect(find.text('Pick an episode to see its streams'), findsOneWidget);

        // A second state without a stream path (the engine has not answered
        // yet) does not trigger another pick.
        core.setState(CoreField.metaDetails, loadSeriesMetaDetailsFixture());
        await tester.pumpAndSettle();
        expect(core.dispatched, hasLength(2));
      },
    );

    testWidgets('renders the selected episode: header, watched, streams', (
      tester,
    ) async {
      useWideViewport(tester);
      final core = await mountSeries(tester);
      final fixture = loadSeriesEpisodeMetaDetailsFixture();
      (fixture['streams'] as List<dynamic>).add(torrentGroup(pilotId));
      core.setState(CoreField.metaDetails, fixture);
      await tester.pumpAndSettle();

      expect(find.text('S1E1 · Pilot'), findsOneWidget);
      expect(find.text('Pick an episode to see its streams'), findsNothing);
      final pilot = tester.widget<ListTile>(
        find.ancestor(of: find.text('Pilot'), matching: find.byType(ListTile)),
      );
      expect(pilot.selected, isTrue);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(
        find.descendant(
          of: find.byWidget(pilot),
          matching: find.byIcon(Icons.check_circle),
        ),
        findsOneWidget,
      );

      // A section per addon that has something to show: the one that
      // answered with nothing is a line below them, the one that failed
      // has its own row, and the torrents keep their parsed hints.
      expect(find.text('No streams'), findsNothing);
      expect(find.text('1 addon had nothing for this episode'), findsOneWidget);
      expect(find.text('127.0.0.1'), findsOneWidget);
      expect(find.textContaining('Failed to fetch'), findsOneWidget);
      expect(find.text('torrentio.example'), findsOneWidget);
      expect(find.text('Torrentio\n1080p'), findsOneWidget);
      expect(find.text('Breaking.Bad.S01E01.1080p.mkv'), findsOneWidget);
      expect(find.byTooltip('Breaking.Bad.S01E01.1080p.mkv'), findsOneWidget);
      expect(find.text('1080p'), findsOneWidget);
      expect(find.text('1.51 GB'), findsOneWidget);
      expect(find.text('42 seeders'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a stream addon still answering shows the header spinner', (
      tester,
    ) async {
      useWideViewport(tester);
      final fixture = loadSeriesEpisodeMetaDetailsFixture();
      fixture['streams'] = [
        {
          'request': torrentGroup(pilotId)['request'],
          'content': {'type': 'Loading'},
        },
      ];
      final core = FakeCoreClient(state: {CoreField.metaDetails: fixture});
      await tester.pumpWidget(
        harness(core, FakePlaybackEngine(), type: 'series', id: seriesId),
      );
      // (A spinner never settles.)
      await tester.pump();
      await tester.pump();

      // Small spinners only -- the "Streams" header's and the waiting
      // group's own -- and no large one below them.
      final spinners = tester
          .widgetList<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator),
          )
          .toList();
      expect(spinners, hasLength(2));
      expect(spinners.every((s) => s.strokeWidth == 2), isTrue);
      // The group that is still answering keeps its label and says so.
      expect(find.text('torrentio.example'), findsOneWidget);
      expect(find.text(kLookingForStreams), findsOneWidget);
      expect(find.text('Pick an episode to see its streams'), findsNothing);
    });

    testWidgets('an episode no addon has a stream for says so and offers '
        'the Addons screen', (tester) async {
      useWideViewport(tester);
      // The recorded state: WatchHub answered with nothing, the local
      // addon failed, and nothing else was asked -- a fresh profile.
      await mountSeries(tester, fixture: loadSeriesEpisodeMetaDetailsFixture());

      expect(find.text('No streams for this episode'), findsOneWidget);
      expect(
        find.textContaining('comes with no torrent addon'),
        findsOneWidget,
      );
      // The addon that failed still says so on its own row, and the one
      // that answered with nothing is counted below -- neither of them
      // repeating the notice above.
      expect(find.textContaining('Failed to fetch'), findsOneWidget);
      expect(find.text('No streams'), findsNothing);
      expect(find.text('1 addon had nothing for this episode'), findsOneWidget);
      expect(find.text('No streams for this episode'), findsOneWidget);

      await tester.tap(find.text('Add an addon'));
      // (That screen spins over the fields this fake has no state for.)
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(AddonsScreen), findsOneWidget);
      expect(
        find.byTooltip('Add addon'),
        findsOneWidget,
        reason: 'the flow that installs one by manifest URL',
      );
    });

    testWidgets('an addon still answering is not an empty answer', (
      tester,
    ) async {
      useWideViewport(tester);
      final fixture = loadSeriesEpisodeMetaDetailsFixture();
      fixture['streams'] = [
        {
          'request': torrentGroup(pilotId)['request'],
          'content': {'type': 'Loading'},
        },
      ];
      final core = FakeCoreClient(state: {CoreField.metaDetails: fixture});
      await tester.pumpWidget(
        harness(core, FakePlaybackEngine(), type: 'series', id: seriesId),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('No streams for this episode'), findsNothing);

      // The same state once that addon has answered with a stream.
      core.setState(
        CoreField.metaDetails,
        loadSeriesEpisodeMetaDetailsFixture()
          ..['streams'] = [torrentGroup(pilotId)],
      );
      await tester.pumpAndSettle();
      expect(find.text('No streams for this episode'), findsNothing);
      expect(find.text('Torrentio\n1080p'), findsOneWidget);
    });

    testWidgets('tapping an episode loads its streams', (tester) async {
      useWideViewport(tester);
      final core = await mountSeries(tester);

      await tester.tap(find.text("Cat's in the Bag..."));
      await tester.pump();

      expect(core.dispatched, hasLength(3));
      expect(
        core.dispatched.last.action,
        CoreActions.loadMetaDetails(
          type: 'series',
          id: seriesId,
          videoId: '$seriesId:1:2',
        ).action,
      );
      expect(loadArgs(core.dispatched.last)['guessStream'], isFalse);
    });

    testWidgets('long-pressing an episode toggles watched', (tester) async {
      useWideViewport(tester);
      final core = await mountSeries(
        tester,
        fixture: loadSeriesEpisodeMetaDetailsFixture(),
      );
      final before = core.dispatched.length;

      await tester.longPress(find.text('Pilot'));
      await tester.pump();
      final pilot = MetaDetailsState.fromJson(
        loadSeriesEpisodeMetaDetailsFixture(),
      ).meta!.videoById(pilotId)!;
      expect(
        core.dispatched[before].action,
        CoreActions.markVideoAsWatched(pilot.json, watched: false).action,
        reason: 'the fixture has the pilot watched',
      );

      await tester.longPress(find.text("Cat's in the Bag..."));
      await tester.pump();
      final args = core.dispatched.last.action['args'] as Map<String, dynamic>;
      expect(args['action'], 'MarkVideoAsWatched');
      expect(args['args'][0]['id'], '$seriesId:1:2');
      expect(args['args'][1], isTrue);
    });

    testWidgets('opening at a video selects its season and loads it', (
      tester,
    ) async {
      useWideViewport(tester);
      const s2e1 = '$seriesId:2:1';
      final core = await mountSeries(tester, videoId: s2e1);

      expect(core.dispatched, hasLength(1), reason: 'no follow-up pick');
      final args = loadArgs(core.dispatched.single);
      expect(args['streamPath']['id'], s2e1);
      expect(args['guessStream'], isFalse);
      expect(selectedSeason(tester), '2');
      expect(find.text('Seven Thirty-Seven'), findsOneWidget);
      expect(find.text('Pilot'), findsNothing);
    });

    testWidgets('switching season shows its episodes', (tester) async {
      useWideViewport(tester);
      await mountSeries(tester);

      // The pills scroll sideways when the info column is narrow.
      await tester.ensureVisible(find.text('Specials'));
      await tester.tap(find.text('Specials'));
      await tester.pumpAndSettle();
      expect(find.text('Good Cop Bad Cop'), findsOneWidget);
      expect(find.text('Pilot'), findsNothing);
    });

    testWidgets('a long series opens with its season on screen, unscrolled', (
      tester,
    ) async {
      useWideViewport(tester);
      final fixture = loadSeriesMetaDetailsFixture();
      final videos =
          fixture['metaItems'][0]['content']['content']['videos']
              as List<dynamic>;
      // Twenty seasons: far more than the row can hold at once.
      for (var season = 6; season <= 20; season++) {
        videos.add({
          ...videos.first as Map<String, dynamic>,
          'id': '$seriesId:$season:1',
          'title': 'Season $season opener',
          'season': season,
          'episode': 1,
        });
      }
      await mountSeries(tester, fixture: fixture, videoId: '$seriesId:18:1');

      expect(seasonLabels(tester), hasLength(21), reason: '20 and specials');
      expect(selectedSeason(tester), '18');

      // The row scrolled itself to the current season: 18 is inside the
      // viewport and 1, where an unscrolled row would start, is off it.
      final viewport = tester.getRect(
        find
            .ancestor(
              of: seasonPills().first,
              matching: find.byType(SingleChildScrollView),
            )
            .first,
      );
      final current = tester.getRect(find.widgetWithText(ChoiceChip, '18'));
      expect(current.left, greaterThanOrEqualTo(viewport.left));
      expect(current.right, lessThanOrEqualTo(viewport.right));
      expect(
        tester.getRect(find.widgetWithText(ChoiceChip, '1')).right,
        lessThan(viewport.left),
      );
    });

    testWidgets('an unreleased episode is dimmed and marked upcoming', (
      tester,
    ) async {
      useWideViewport(tester);
      final fixture = loadSeriesMetaDetailsFixture();
      final videos =
          fixture['metaItems'][0]['content']['content']['videos']
              as List<dynamic>;
      videos.firstWhere((v) => v['id'] == '$seriesId:1:2')['released'] =
          '2999-01-01T00:00:00Z';
      await mountSeries(tester, fixture: fixture);

      final tile = tester.widget<ListTile>(
        find.ancestor(
          of: find.text("Cat's in the Bag..."),
          matching: find.byType(ListTile),
        ),
      );
      expect(tile.enabled, isFalse);
      expect(find.text('2999-01-01 · Upcoming'), findsOneWidget);
    });

    testWidgets('a stream tap opens the player for the selected episode', (
      tester,
    ) async {
      useWideViewport(tester);
      final fixture = loadSeriesEpisodeMetaDetailsFixture();
      (fixture['streams'] as List<dynamic>).add(torrentGroup(pilotId));
      final core = await mountSeries(tester, fixture: fixture);

      await tester.tap(find.text('Torrentio\n1080p'));
      await tester.pumpAndSettle();

      expect(find.byType(PlayerScreen), findsOneWidget);
      final load = core.dispatched.firstWhere(
        (a) => a.field == CoreField.player,
      );
      final args = loadArgs(load);
      expect(args['stream']['fileIdx'], 3);
      expect(args['streamRequest']['path']['id'], pilotId);
      expect(args['metaRequest']['path']['id'], seriesId);
      expect(args['subtitlesPath'], {
        'resource': 'subtitles',
        'type': 'series',
        'id': pilotId,
        'extra': <Object>[],
      });
    });

    testWidgets('phones stack everything and pick a season from the same '
        'row of pills', (tester) async {
      usePhoneViewport(tester);
      await mountSeries(tester);

      expect(find.byType(VerticalDivider), findsNothing);
      expect(seasonLabels(tester), ['1', '2', '3', '4', '5', 'Specials']);
      expect(selectedSeason(tester), '1');
      expect(find.text('Pilot'), findsOneWidget);
      expect(find.text('Streams'), findsOneWidget);

      // One press, in place: no menu to open and nothing to dismiss.
      await tester.ensureVisible(find.text('3'));
      await tester.tap(find.text('3'));
      await tester.pumpAndSettle();

      expect(selectedSeason(tester), '3');
      expect(find.text('No Mas'), findsOneWidget);
      expect(find.text('Pilot'), findsNothing);
    });

    testWidgets('a tap on a phone brings the stream section to the tap', (
      tester,
    ) async {
      usePhoneViewport(tester, height: 800);
      final core = await mountSeries(tester);
      const fold = 800.0;

      await tester.ensureVisible(find.text("Cat's in the Bag..."));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Streams')).dy,
        greaterThan(fold / 2),
        reason: 'the stream section is at the bottom edge before the tap',
      );

      await tester.tap(find.text("Cat's in the Bag..."));
      await tester.pump();

      final tapped = tester.widget<ListTile>(
        find.ancestor(
          of: find.text("Cat's in the Bag..."),
          matching: find.byType(ListTile),
        ),
      );
      expect(tapped.selected, isTrue, reason: 'selected before the answer');
      expect(
        core.dispatched.last.action,
        CoreActions.loadMetaDetails(
          type: 'series',
          id: seriesId,
          videoId: '$seriesId:1:2',
        ).action,
      );

      await pumpReveal(tester);
      expect(find.text('S1E2 · Cat\'s in the Bag...'), findsOneWidget);
      expect(
        tester.getRect(find.text('Looking for streams…')).bottom,
        lessThan(fold),
        reason: 'the section was scrolled to the tap, saying what it does',
      );
    });

    testWidgets('the answer to a tap replaces the looking-for-streams tile', (
      tester,
    ) async {
      usePhoneViewport(tester, height: 800);
      final core = await mountSeries(tester);

      await tester.tap(find.text('Pilot'));
      await pumpReveal(tester);
      expect(find.text('Looking for streams…'), findsOneWidget);
      final waiting = tester.getTopLeft(find.text('Streams')).dy;

      final fixture = loadSeriesEpisodeMetaDetailsFixture();
      (fixture['streams'] as List<dynamic>).add(torrentGroup(pilotId));
      core.setState(CoreField.metaDetails, fixture);
      await tester.pumpAndSettle();

      expect(find.text('Looking for streams…'), findsNothing);
      // The streams themselves, with the section pulled up so the list
      // under it is what fills the screen.
      expect(tester.getTopLeft(find.text('Streams')).dy, lessThan(waiting));
      expect(
        tester.getRect(find.text('Torrentio\n1080p')).bottom,
        lessThan(800),
      );
    });

    testWidgets('wide layouts put the streams in a side pane', (tester) async {
      useWideViewport(tester);
      await mountSeries(tester);

      expect(find.byType(VerticalDivider), findsOneWidget);
      expect(find.byType(CustomScrollView), findsNWidgets(2));
      final streams = tester.getTopLeft(find.text('Streams'));
      final pilot = tester.getTopLeft(find.text('Pilot'));
      expect(streams.dx, greaterThan(pilot.dx));

      // Nothing scrolls on a tap here: the section is already in view.
      await tester.tap(find.text("Cat's in the Bag..."));
      await pumpReveal(tester);
      expect(tester.getTopLeft(find.text('Pilot')), pilot);
      expect(tester.getTopLeft(find.text('Streams')), streams);
    });
  });

  group('failing addons', () {
    const watchHubUrl = 'https://watchhub.strem.io/manifest.json';
    const youTubeUrl = 'https://v3-channels.strem.io/manifest.json';
    const localAddonUrl = 'http://127.0.0.1:11470/local-addon/manifest.json';
    const strangerUrl = 'https://mirror.example/stremio/manifest.json';
    const failure = 'Failed to fetch: 404 Not Found';

    /// A stream group for the movie that came back `Err Env`, as the
    /// engine records an addon whose host is gone.
    Map<String, dynamic> failedGroup(String base) => {
      'request': {
        'base': base,
        'path': {
          'resource': 'stream',
          'type': 'movie',
          'id': 'tt0063350',
          'extra': <Object>[],
        },
      },
      'content': {
        'type': 'Err',
        'content': {
          'type': 'Env',
          'content': {'code': 1, 'message': failure},
        },
      },
    };

    /// The movie fixture with [streams] in place of its own, and the
    /// default profile as `ctx` so the failing addons can be named.
    Future<FakeCoreClient> mount(
      WidgetTester tester,
      List<Map<String, dynamic>> streams,
    ) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {
          CoreField.metaDetails: loadMetaDetailsFixture()
            ..['streams'] = streams,
          CoreField.ctx: loadCtxLoggedOutFixture(),
        },
      );
      await tester.pumpWidget(harness(core, FakePlaybackEngine()));
      await tester.pumpAndSettle();
      return core;
    }

    testWidgets('names the installed addon behind the error', (tester) async {
      await mount(tester, [failedGroup(watchHubUrl)]);

      expect(find.text('WatchHub'), findsOneWidget);
      expect(find.text(failure), findsOneWidget);
      expect(
        find.text('watchhub.strem.io'),
        findsNothing,
        reason: 'the host is what the profile replaces',
      );
      expect(find.text('Check addon'), findsOneWidget);
      expect(find.text('Uninstall'), findsOneWidget);
    });

    testWidgets('an addon that is not installed is still named by its host', (
      tester,
    ) async {
      await mount(tester, [failedGroup(strangerUrl)]);

      expect(find.text('mirror.example'), findsOneWidget);
      expect(find.text(failure), findsOneWidget);
      expect(find.text('Check addon'), findsOneWidget);
      expect(
        find.text('Uninstall'),
        findsNothing,
        reason: 'there is nothing installed to uninstall',
      );
    });

    testWidgets('a protected addon cannot be uninstalled from here', (
      tester,
    ) async {
      await mount(tester, [failedGroup(localAddonUrl)]);

      expect(
        find.text('Local Files (without catalog support)'),
        findsOneWidget,
      );
      expect(find.text('Check addon'), findsOneWidget);
      expect(find.text('Uninstall'), findsNothing);
    });

    testWidgets('uninstalling asks first, then sends the descriptor', (
      tester,
    ) async {
      final core = await mount(tester, [failedGroup(watchHubUrl)]);
      final descriptor = ProfileState.fromCtx(loadCtxLoggedOutFixture())
          .installedAddon(watchHubUrl)!;

      // A cancelled dialog changes nothing.
      await tester.tap(find.text('Uninstall'));
      await tester.pumpAndSettle();
      expect(find.text('Uninstall WatchHub?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(core.dispatched.where((a) => a.field == CoreField.ctx), isEmpty);

      await tester.tap(find.text('Uninstall'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Uninstall'));
      await tester.pumpAndSettle();

      expect(
        core.dispatched.last.action,
        CoreActions.uninstallAddon(descriptor).action,
      );
      expect(find.text('Uninstalled WatchHub'), findsOneWidget);
    });

    testWidgets('checking an addon opens its details on that manifest URL', (
      tester,
    ) async {
      final core = await mount(tester, [failedGroup(watchHubUrl)]);

      await tester.tap(find.text('Check addon'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.byType(AddonDetailsScreen), findsOneWidget);
      expect(
        core.dispatched.last.action,
        CoreActions.loadAddonDetails(watchHubUrl).action,
      );
    });

    testWidgets('several failures collapse into one row below the streams', (
      tester,
    ) async {
      final core = await mount(tester, [
        ...(loadMetaDetailsFixture()['streams'] as List<dynamic>)
            .cast<Map<String, dynamic>>(),
        failedGroup(youTubeUrl),
        failedGroup(strangerUrl),
      ]);

      // The playable stream is still the first thing in the section.
      expect(find.text('1080p'), findsOneWidget);
      expect(find.text(failure), findsNothing);
      expect(find.text('2 addons did not answer'), findsOneWidget);
      expect(find.text('YouTube, mirror.example'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('2 addons did not answer')).dy,
        greaterThan(tester.getTopLeft(find.text('1080p')).dy),
      );

      await tester.tap(find.text('2 addons did not answer'));
      await tester.pumpAndSettle();

      expect(find.text('YouTube'), findsOneWidget);
      expect(find.text('mirror.example'), findsOneWidget);
      expect(find.text(failure), findsNWidgets(2));
      expect(find.text('Check addon'), findsNWidgets(2));
      expect(
        find.text('Uninstall'),
        findsOneWidget,
        reason: 'only the installed one can be dropped',
      );
      expect(
        core.dispatched,
        hasLength(1),
        reason: 'expanding dispatches nothing',
      );
    });
  });

  group('addons with nothing to say', () {
    const youTubeUrl = 'https://v3-channels.strem.io/manifest.json';
    const strangerUrl = 'https://mirror.example/stremio/manifest.json';
    const localAddonUrl = 'http://127.0.0.1:11470/local-addon/manifest.json';

    Map<String, dynamic> group(String base, Map<String, dynamic> content) => {
      'request': {
        'base': base,
        'path': {
          'resource': 'stream',
          'type': 'movie',
          'id': 'tt0063350',
          'extra': <Object>[],
        },
      },
      'content': content,
    };

    /// An addon that answered and had nothing, as the engine records it.
    Map<String, dynamic> emptyGroup(String base) => group(base, {
      'type': 'Err',
      'content': {'type': 'EmptyContent'},
    });

    /// One still being waited on.
    Map<String, dynamic> loadingGroup(String base) =>
        group(base, {'type': 'Loading'});

    /// One whose host is gone.
    Map<String, dynamic> failedGroup(String base) => group(base, {
      'type': 'Err',
      'content': {
        'type': 'Env',
        'content': {'code': 1, 'message': 'Failed to fetch: 404 Not Found'},
      },
    });

    /// The movie's own groups that answered with streams.
    List<Map<String, dynamic>> playableGroups() => [
      for (final g
          in (loadMetaDetailsFixture()['streams'] as List<dynamic>)
              .cast<Map<String, dynamic>>())
        if ((g['content'] as Map)['type'] == 'Ready') g,
    ];

    /// The movie fixture with [streams] in place of its own, and the
    /// default profile as `ctx` so the addons can be named. Pumped by hand
    /// rather than settled: a waiting group's spinner never settles.
    Future<FakeCoreClient> mount(
      WidgetTester tester,
      List<Map<String, dynamic>> streams,
    ) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {
          CoreField.metaDetails: loadMetaDetailsFixture()
            ..['streams'] = streams,
          CoreField.ctx: loadCtxLoggedOutFixture(),
        },
      );
      await tester.pumpWidget(harness(core, FakePlaybackEngine()));
      await tester.pump();
      await tester.pump();
      return core;
    }

    testWidgets('an empty answer is a line below the streams, not a section', (
      tester,
    ) async {
      await mount(tester, [...playableGroups(), emptyGroup(youTubeUrl)]);

      // Nothing is labelled with an addon that had nothing under it.
      expect(find.text('No streams'), findsNothing);
      expect(find.text('1 addon had nothing for this title'), findsOneWidget);
      expect(find.text('1080p'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('1 addon had nothing for this title')).dy,
        greaterThan(tester.getTopLeft(find.text('1080p')).dy),
      );
      // Named from the profile, and only in that line.
      expect(find.text('YouTube'), findsOneWidget);
    });

    testWidgets('the summary counts them and expands to name them', (
      tester,
    ) async {
      final core = await mount(tester, [
        ...playableGroups(),
        emptyGroup(youTubeUrl),
        emptyGroup(strangerUrl),
        emptyGroup(localAddonUrl),
      ]);

      expect(find.text('3 addons had nothing for this title'), findsOneWidget);
      expect(find.text('YouTube, mirror.example, Local Files'), findsNothing);

      await tester.tap(find.text('3 addons had nothing for this title'));
      await tester.pumpAndSettle();

      expect(find.text('YouTube'), findsOneWidget);
      expect(find.text('mirror.example'), findsOneWidget);
      expect(
        find.text('Local Files (without catalog support)'),
        findsOneWidget,
      );
      expect(
        core.dispatched,
        hasLength(1),
        reason: 'expanding dispatches nothing',
      );
    });

    testWidgets('an addon still answering keeps its label and a spinner', (
      tester,
    ) async {
      await mount(tester, [loadingGroup(youTubeUrl)]);

      // Nothing yet, not nothing at all: it is still a section.
      expect(find.text('v3-channels.strem.io'), findsOneWidget);
      expect(find.text(kLookingForStreams), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
      expect(find.textContaining('had nothing for this'), findsNothing);
    });

    testWidgets('empty, waiting, failed and populated each land in place', (
      tester,
    ) async {
      await mount(tester, [
        ...playableGroups(),
        loadingGroup(youTubeUrl),
        emptyGroup(strangerUrl),
        failedGroup(localAddonUrl),
      ]);

      final stream = tester.getTopLeft(find.text('1080p')).dy;
      final waiting = tester.getTopLeft(find.text(kLookingForStreams)).dy;
      final empty = tester
          .getTopLeft(find.text('1 addon had nothing for this title'))
          .dy;
      final failed = tester
          .getTopLeft(find.text('Local Files (without catalog support)'))
          .dy;
      expect(stream, lessThan(waiting));
      expect(waiting, lessThan(empty));
      expect(empty, lessThan(failed));
      expect(find.text('Failed to fetch: 404 Not Found'), findsOneWidget);
      expect(find.text('No streams'), findsNothing);
    });

    testWidgets('everything empty still offers the Addons screen', (
      tester,
    ) async {
      await mount(tester, [emptyGroup(youTubeUrl), emptyGroup(strangerUrl)]);

      // The notice is what it always was, and the summary says how many
      // addons that "nothing" came from rather than repeating it.
      expect(find.text('No streams for this title'), findsOneWidget);
      expect(find.text('Add an addon'), findsOneWidget);
      expect(find.text('2 addons had nothing for this title'), findsOneWidget);
    });
  });
}
