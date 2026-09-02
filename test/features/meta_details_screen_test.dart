import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/discover/discover_screen.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../support/fake_core_client.dart';
import '../support/fake_playback_engine.dart';
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

void main() {
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
      child: MaterialApp(
        home: MetaDetailsScreen(type: type, id: id, videoId: videoId),
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

  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
      expect(find.byType(SegmentedButton<int>), findsNothing);
      expect(find.byType(DropdownMenu<int>), findsNothing);

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
      expect(find.text('No streams'), findsOneWidget);
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
      await tester.pumpAndSettle();

      expect(find.byType(DiscoverScreen), findsOneWidget);
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
        final selector = tester.widget<SegmentedButton<int>>(
          find.byType(SegmentedButton<int>),
        );
        expect(
          [for (final s in selector.segments) (s.label as Text).data],
          [
            'Season 1',
            'Season 2',
            'Season 3',
            'Season 4',
            'Season 5',
            'Specials',
          ],
        );
        expect(selector.selected, {1});
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

      // One section per addon: an empty one, a failed one, torrents with
      // hints parsed into chips and the rest of the description kept.
      expect(find.text('watchhub.strem.io'), findsOneWidget);
      expect(find.text('No streams'), findsOneWidget);
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
      final selector = tester.widget<SegmentedButton<int>>(
        find.byType(SegmentedButton<int>),
      );
      expect(selector.selected, {2});
      expect(find.text('Seven Thirty-Seven'), findsOneWidget);
      expect(find.text('Pilot'), findsNothing);
    });

    testWidgets('switching season shows its episodes', (tester) async {
      useWideViewport(tester);
      await mountSeries(tester);

      // The segmented button scrolls sideways when the pane is narrow.
      await tester.ensureVisible(find.text('Specials'));
      await tester.tap(find.text('Specials'));
      await tester.pumpAndSettle();
      expect(find.text('Good Cop Bad Cop'), findsOneWidget);
      expect(find.text('Pilot'), findsNothing);
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

    testWidgets('phones stack everything and pick seasons from a dropdown', (
      tester,
    ) async {
      usePhoneViewport(tester);
      await mountSeries(tester);

      expect(find.byType(VerticalDivider), findsNothing);
      expect(find.byType(SegmentedButton<int>), findsNothing);
      expect(find.byType(DropdownMenu<int>), findsOneWidget);
      expect(find.text('Pilot'), findsOneWidget);
      expect(find.text('Streams'), findsOneWidget);

      await tester.tap(find.byType(DropdownMenu<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Season 3').last);
      await tester.pumpAndSettle();

      expect(find.text('No Mas'), findsOneWidget);
      expect(find.text('Pilot'), findsNothing);
    });

    testWidgets('wide layouts put the streams in a side pane', (tester) async {
      useWideViewport(tester);
      await mountSeries(tester);

      expect(find.byType(VerticalDivider), findsOneWidget);
      expect(find.byType(CustomScrollView), findsNWidgets(2));
      final streams = tester.getTopLeft(find.text('Streams'));
      final pilot = tester.getTopLeft(find.text('Pilot'));
      expect(streams.dx, greaterThan(pilot.dx));
    });
  });
}
