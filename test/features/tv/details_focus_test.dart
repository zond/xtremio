import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/downloads/download_labels.dart';
import 'package:xtremio/features/downloads/downloads_screen.dart';
import 'package:xtremio/features/downloads/remove_download_dialog.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/remote_press.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_downloads_client.dart';
import '../../support/fake_playback_engine.dart';
import '../../support/fake_prefs_client.dart';
import '../../support/fake_torrent_stats_client.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

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

/// The series episode fixture (S1E1 selected and watched) with a playable
/// torrent for the pilot.
Map<String, dynamic> seriesWithTorrent() {
  final fixture = loadSeriesEpisodeMetaDetailsFixture();
  (fixture['streams'] as List<dynamic>).add(torrentGroup(pilotId));
  return fixture;
}

Widget harness(
  FakeCoreClient core, {
  String type = 'movie',
  String id = 'tt0063350',
  String? videoId,
  DeviceProfile device = tv,
  DownloadsClient? downloads,
  AppPrefs? prefs,
}) {
  Widget screen = PrefsScope(
    prefs: prefs ?? AppPrefs.inMemory(),
    child: PlaybackScope(
      createEngine: FakePlaybackEngine.new,
      torrentStats: FakeTorrentStatsClient(),
      child: MaterialApp(
        home: MetaDetailsScreen(type: type, id: id, videoId: videoId),
      ),
    ),
  );
  if (downloads != null) {
    screen = DownloadsScope(client: downloads, child: screen);
  }
  return DeviceScope(
    profile: device,
    child: CoreScope(client: core, child: screen),
  );
}

/// Two addons whose streams a remote has to walk in sorted order once the
/// list is flat: alpha answers with its worst release first.
List<Map<String, dynamic>> twoTorrentAddons() => [
  for (final (base, streams) in [
    (
      'https://alpha.example/manifest.json',
      [
        {
          'infoHash': 'a' * 40,
          'name': 'Alpha 720p',
          'description': '💾 900 MB',
        },
        {
          'infoHash': 'b' * 40,
          'name': 'Alpha 2160p',
          'description': '💾 20 GB',
        },
      ],
    ),
    (
      'https://beta.example/manifest.json',
      [
        {'infoHash': 'c' * 40, 'name': 'Beta 1080p', 'description': '👤 100'},
      ],
    ),
  ])
    {
      'request': {
        'base': base,
        'path': {
          'resource': 'stream',
          'type': 'movie',
          'id': 'tt0063350',
          'extra': <Object>[],
        },
      },
      'content': {'type': 'Ready', 'content': streams},
    },
];

/// Where the streams pane starts at [tvSize]: 38 % of the width, at most
/// 480 px, on the right.
const double paneLeft = 1280 - 480;

Rect focusedRect() => FocusManager.instance.primaryFocus!.rect;

bool focusInPane() => focusedRect().left >= paneLeft;

bool focusInInfoColumn() =>
    FocusManager.instance.primaryFocus is! FocusScopeNode &&
    focusedRect().right <= paneLeft;

/// Every `Ctx` and `MetaDetails` action dispatched so far (never the
/// screen's own `Load`s), by its inner `action` name.
List<String> innerActions(FakeCoreClient core) => [
  for (final action in core.dispatched)
    if (action.action['action'] case 'Ctx' || 'MetaDetails')
      (action.action['args'] as Map<String, dynamic>)['action'] as String,
];

Object? innerArgs(CoreAction action) =>
    (action.action['args'] as Map<String, dynamic>)['args'];

/// The title of the [ListTile] holding primary focus (an episode's name;
/// its first text is the thumbnail's "E1" badge).
String? focusedTileTitle() {
  final tile = FocusManager.instance.primaryFocus?.context
      ?.findAncestorWidgetOfExactType<ListTile>();
  return (tile?.title as Text?)?.data;
}

/// From the streams pane, left lands on the header (the bookmark, nearest
/// to the stream at the top); [down] presses from there reach [T], the
/// season selector or an episode tile.
Future<void> stepLeftAndDownTo<T extends Widget>(
  WidgetTester tester, {
  int limit = 8,
}) async {
  await press(tester, LogicalKeyboardKey.arrowLeft);
  expect(focusInInfoColumn(), isTrue);
  for (var i = 0; i < limit && !focusIn<T>(); i++) {
    await press(tester, LogicalKeyboardKey.arrowDown);
  }
  expect(focusIn<T>(), isTrue);
}

/// Presses up until the control tooltipped [tooltip] has focus: what is
/// between the top stream and the header's controls is the list's own
/// business (a section header, the order chips) and not this test's.
Future<void> pressUpTo(
  WidgetTester tester,
  String tooltip, {
  int limit = 8,
}) async {
  for (var i = 0; i < limit && focusedTooltip() != tooltip; i++) {
    await press(tester, LogicalKeyboardKey.arrowUp);
  }
  expect(focusedTooltip(), tooltip);
}

/// Mounts Breaking Bad at the pilot on a TV, focus on its torrent.
Future<FakeCoreClient> mountSeries(WidgetTester tester) async {
  useScreen(tester, tvSize);
  final core = FakeCoreClient(
    state: {CoreField.metaDetails: seriesWithTorrent()},
  );
  await tester.pumpWidget(
    harness(core, type: 'series', id: seriesId, videoId: pilotId),
  );
  await tester.pumpAndSettle();
  expect(focusedLabel(tester), startsWith('Torrentio'));
  return core;
}

void main() {
  group('movie', () {
    testWidgets('focus starts on the first playable stream; left is the '
        'info column, right the pane again', (tester) async {
      useScreen(tester, tvSize);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();

      // WatchHub's externals come first but cannot play; the public-domain
      // torrent is the first stream the player can open.
      expect(focusedLabel(tester), '1080p');
      expect(focusInPane(), isTrue);

      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focusInInfoColumn(), isTrue);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusInPane(), isTrue);
      expect(focusedLabel(tester), '1080p');
    });

    testWidgets('select on the stream opens the player; with no downloads '
        'client above, a held select is still a tap', (tester) async {
      useScreen(tester, tvSize);
      final core = FakeCoreClient(
        state: {
          CoreField.metaDetails: loadMetaDetailsFixture(),
          CoreField.player: loadPlayerFixture(),
        },
      );
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();
      expect(focusedLabel(tester), '1080p');

      await hold(
        tester,
        LogicalKeyboardKey.select,
        RemotePress.holdDuration * 2,
      );
      expect(find.byType(PlayerScreen), findsOneWidget);
    });

    testWidgets('the bookmark is reachable and select toggles it', (
      tester,
    ) async {
      useScreen(tester, tvSize);
      final fixture = loadMetaDetailsFixture();
      final core = FakeCoreClient(state: {CoreField.metaDetails: fixture});
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();
      expect(MetaDetailsState.fromJson(fixture).isInLibrary, isFalse);

      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focusInInfoColumn(), isTrue);
      final bookmark = find.byTooltip('Add to library');
      for (var i = 0; i < 6 && !focusIn<IconButton>(); i++) {
        await press(tester, LogicalKeyboardKey.arrowUp);
      }
      expect(focusIn<IconButton>(), isTrue);
      expect(
        tester.getRect(bookmark).contains(focusedRect().center),
        isTrue,
        reason: 'the focused button is the bookmark',
      );

      await press(tester, LogicalKeyboardKey.select);
      expect(innerActions(core), ['AddToLibrary']);
    });

    testWidgets('Tab visits the pane in one go: the two sides are groups', (
      tester,
    ) async {
      useScreen(tester, tvSize);
      final fixture = loadMetaDetailsFixture();
      // A second playable stream, so the pane has more than one stop.
      final torrents = (fixture['streams'] as List<dynamic>)[1];
      final streams = torrents['content']['content'] as List<dynamic>;
      streams.add({
        ...streams.first as Map<String, dynamic>,
        'name': '720p',
        'infoHash': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      });
      final core = FakeCoreClient(state: {CoreField.metaDetails: fixture});
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();
      expect(focusedLabel(tester), '1080p');

      // Tab around the whole screen once. Reading order alone would visit
      // the streams in between the header's controls, which sit at the same
      // height on the left; as groups, the pane is left exactly once.
      final inPane = <bool>[focusInPane()];
      for (var i = 0; i < 40; i++) {
        await press(tester, LogicalKeyboardKey.tab);
        if (focusedLabel(tester) == '1080p') break;
        inPane.add(focusInPane());
      }
      // Four stops: the header's flat/grouped toggle, the two streams, and
      // the row summarising the addons that had nothing (which expands and
      // so takes the remote too).
      expect(inPane.length, lessThan(41), reason: 'came back around');
      expect(inPane.where((b) => b).length, 4);
      // And they are one contiguous run of the cycle: the walk starts on a
      // stream, which is in the middle of the pane's own stops, so the run
      // wraps around the end of the list rather than starting at index 0.
      final leaves = [
        for (var i = 0; i < inPane.length; i++)
          if (inPane[i] != inPane[(i + 1) % inPane.length]) i,
      ];
      expect(leaves, hasLength(2), reason: 'the pane is entered and left once');
    });

    testWidgets(
      'off a TV nothing autofocuses and there is no remote handling',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final core = FakeCoreClient(
          state: {CoreField.metaDetails: loadMetaDetailsFixture()},
        );
        await tester.pumpWidget(harness(core, device: DeviceProfile.fallback));
        await tester.pumpAndSettle();

        expect(focusedLabel(tester), isNull);
        expect(find.byType(RemotePress), findsNothing);
      },
    );
  });

  group('sectioned sources', () {
    /// The movie on a TV with the two torrent addons, listed in sections.
    Future<FakeCoreClient> mountFlat(
      WidgetTester tester, {
      AppPrefs? prefs,
      DownloadsClient? downloads,
    }) async {
      useScreen(tester, tvSize);
      final core = FakeCoreClient(
        state: {
          CoreField.metaDetails: loadMetaDetailsFixture()
            ..['streams'] = twoTorrentAddons(),
        },
      );
      final layout =
          prefs ?? AppPrefs(client: FakePrefsClient({'streamsFlat': true}));
      // Read before the first build, the way start-up does it, so the
      // first sources list a remote sees is already the flat one.
      await layout.load();
      await tester.pumpWidget(
        harness(core, prefs: layout, downloads: downloads),
      );
      await tester.pumpAndSettle();
      return core;
    }

    testWidgets('a stored choice is already in place, and focus starts on '
        'the best stream the list now begins with', (tester) async {
      final prefs = AppPrefs(client: FakePrefsClient({'streamsFlat': true}));
      addTearDown(prefs.dispose);
      await prefs.load();
      await mountFlat(tester, prefs: prefs);

      expect(focusedLabel(tester), 'Alpha 2160p');
      expect(focusInPane(), isTrue);
    });

    testWidgets('down walks the open section and on to the headers below '
        'it, and the ends hold', (tester) async {
      await mountFlat(tester);
      // The best section is open, so the remote starts on its stream.
      expect(focusedLabel(tester), 'Alpha 2160p');

      // Below it: the sections that are folded up, each header a stop of
      // its own -- which is what keeps them reachable at all.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), '1080p');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), '720p');

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(tester), '1080p');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(tester), 'Alpha 2160p');
      // And above the first stream, its own header.
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(tester), '2160p');
      expect(focusInPane(), isTrue);
    });

    testWidgets('select on a collapsed header opens it where the remote is', (
      tester,
    ) async {
      await mountFlat(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), '1080p');
      expect(find.text('Beta 1080p'), findsNothing);

      await press(tester, LogicalKeyboardKey.select);

      expect(find.text('Beta 1080p'), findsOneWidget);
      expect(focusedLabel(tester), '1080p', reason: 'focus stayed');
      // And the stream it just revealed is the next thing down.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), 'Beta 1080p');

      // Closing it again puts the next header back under the remote.
      await press(tester, LogicalKeyboardKey.arrowUp);
      await press(tester, LogicalKeyboardKey.select);
      expect(find.text('Beta 1080p'), findsNothing);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), '720p');
    });

    testWidgets('the remote reaches the toggle and select groups them again', (
      tester,
    ) async {
      final stored = FakePrefsClient({'streamsFlat': true});
      final prefs = AppPrefs(client: stored);
      addTearDown(prefs.dispose);
      await prefs.load();
      await mountFlat(tester, prefs: prefs);

      await pressUpTo(tester, kGroupedStreamsTooltip);
      expect(focusInPane(), isTrue);

      await press(tester, LogicalKeyboardKey.select);
      expect(focusedTooltip(), kFlatStreamsTooltip, reason: 'focus stayed');
      expect(stored.stored, {'streamsFlat': false});
      // Grouped again: each addon's own order, under its own heading.
      expect(find.text('alpha.example'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Alpha 720p')).dy,
        lessThan(tester.getTopLeft(find.text('Alpha 2160p')).dy),
      );
    });

    testWidgets('a held select on a flat row still downloads it', (
      tester,
    ) async {
      final downloads = FakeDownloadsClient();
      addTearDown(downloads.dispose);
      await mountFlat(tester, downloads: downloads);
      expect(focusedLabel(tester), 'Alpha 2160p');

      await hold(
        tester,
        LogicalKeyboardKey.select,
        RemotePress.holdDuration * 2,
      );

      expect(downloads.added, hasLength(1));
      expect(downloads.added.single.stream.infoHash, 'b' * 40);
      expect(find.byType(PlayerScreen), findsNothing);
    });
  });

  group('series', () {
    testWidgets('down the info column reaches the episodes; the menu key '
        'toggles one watched; down and select load the next', (tester) async {
      final core = await mountSeries(tester);
      final meta = MetaDetailsState.fromJson(seriesWithTorrent()).meta!;
      final season1 = meta.videosOfSeason(1);

      await stepLeftAndDownTo<ListTile>(tester);
      final episode = focusedTileTitle();
      final video = season1.singleWhere((v) => v.title == episode);

      await press(tester, LogicalKeyboardKey.contextMenu);
      expect(innerActions(core), ['MarkVideoAsWatched']);
      final args = innerArgs(core.dispatched.last) as List<dynamic>;
      expect((args[0] as Map<String, dynamic>)['id'], video.id);
      expect(args[1], video.id != pilotId, reason: 'flips the state');

      await press(tester, LogicalKeyboardKey.arrowDown);
      final next = focusedTileTitle();
      final nextVideo = season1.singleWhere((v) => v.title == next);
      expect(season1.indexOf(nextVideo), season1.indexOf(video) + 1);

      await press(tester, LogicalKeyboardKey.select);
      final load = core.dispatched.last;
      expect(load.action['action'], 'Load');
      final loadArgs = innerArgs(load) as Map<String, dynamic>;
      expect(loadArgs['streamPath']['id'], nextVideo.id);
    });

    testWidgets('a held select on an episode toggles watched too', (
      tester,
    ) async {
      final core = await mountSeries(tester);
      await stepLeftAndDownTo<ListTile>(tester);
      final loads = core.dispatched.length;

      await hold(
        tester,
        LogicalKeyboardKey.select,
        RemotePress.holdDuration * 2,
      );
      expect(innerActions(core), ['MarkVideoAsWatched']);
      expect(core.dispatched, hasLength(loads + 1), reason: 'no Load');
    });

    testWidgets('the season segments take the D-pad and select switches', (
      tester,
    ) async {
      await mountSeries(tester);
      final meta = MetaDetailsState.fromJson(seriesWithTorrent()).meta!;
      expect(find.text('Pilot'), findsOneWidget);

      await stepLeftAndDownTo<SegmentedButton<int>>(tester);
      // Down from the header's right-hand controls lands on the last
      // segment (Specials sit after the seasons); left walks the seasons.
      expect(focusedLabel(tester), 'Specials');
      for (var i = 0; i < 6 && focusedLabel(tester) != 'Season 2'; i++) {
        await press(tester, LogicalKeyboardKey.arrowLeft);
      }
      expect(focusedLabel(tester), 'Season 2');
      expect(focusIn<SegmentedButton<int>>(), isTrue);

      await press(tester, LogicalKeyboardKey.select);
      expect(find.text('Pilot'), findsNothing);
      expect(find.text(meta.videosOfSeason(2).first.title), findsOneWidget);
    });

    testWidgets('many seasons are picked from a TV menu, not a dropdown', (
      tester,
    ) async {
      useScreen(tester, tvSize);
      final fixture = seriesWithTorrent();
      final videos =
          fixture['metaItems'][0]['content']['content']['videos']
              as List<dynamic>;
      // Nine seasons, one more than the segments can show.
      for (var season = 6; season <= 9; season++) {
        videos.add({
          ...videos.first as Map<String, dynamic>,
          'id': '$seriesId:$season:1',
          'title': 'Season $season opener',
          'season': season,
          'episode': 1,
        });
      }
      final core = FakeCoreClient(state: {CoreField.metaDetails: fixture});
      await tester.pumpWidget(
        harness(core, type: 'series', id: seriesId, videoId: pilotId),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SegmentedButton<int>), findsNothing);
      expect(find.byType(DropdownMenu<int>), findsNothing);
      final menu = find.widgetWithText(OutlinedButton, 'Season: 1');
      expect(menu, findsOneWidget);

      await stepLeftAndDownTo<OutlinedButton>(tester);
      expect(focusedLabel(tester), 'Season: 1');
      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(MenuItemButton), findsNWidgets(10));
      expect(focusedLabel(tester), '1', reason: 'the current season');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(tester), '1', reason: 'first entry: Specials last');
      for (var i = 0; i < 7; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(focusedLabel(tester), '8');
      await press(tester, LogicalKeyboardKey.select);

      expect(find.text('Season 8 opener'), findsOneWidget);
      expect(find.text('Pilot'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Season: 8'), findsOneWidget);
    });
  });

  group('downloads on a remote', () {
    /// The one torrent of the movie fixture.
    const movieHash = '11ea02584fa6351956f35671962ab46354d99060';
    const movieId = 'tt0063350';

    /// A registry holding the movie, downloaded and whole.
    DownloadsRegistry downloaded() {
      final entry = DownloadView({
        'metaId': movieId,
        'videoId': movieId,
        'name': 'Night of the Living Dead',
        'stream': {'infoHash': movieHash, 'fileIdx': 0},
        'infoHash': movieHash,
        'fileIdx': 0,
        'size': 1000,
        'downloaded': 1000,
        'state': 'complete',
        'path': '/downloads/night.mkv',
      });
      return DownloadsRegistry(items: {entry.key: entry});
    }

    testWidgets('holding select on a downloaded stream asks to remove it', (
      tester,
    ) async {
      useScreen(tester, tvSize);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      final downloads = FakeDownloadsClient(registry: downloaded());
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads: downloads));
      await tester.pumpAndSettle();

      // The delete button is on the focused row and cannot be focused
      // itself: a node inside the focused one's rect is not in any
      // direction from it.
      expect(focusedLabel(tester), '1080p');
      expect(find.byTooltip(kDownloadDeleteTooltip), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(tester), '1080p');

      await hold(tester, LogicalKeyboardKey.select, RemotePress.holdDuration);

      expect(find.byType(PlayerScreen), findsNothing, reason: 'not a tap');
      expect(find.text('Remove Night of the Living Dead?'), findsOneWidget);
      await tester.tap(find.text(RemoveDownloadDialog.deleteLabel));
      await tester.pumpAndSettle();
      expect(downloads.removed, [
        (key: '$movieId:$movieId', deleteFiles: true),
      ]);
    });

    testWidgets('holding select on a stream that is not kept downloads it', (
      tester,
    ) async {
      useScreen(tester, tvSize);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      final downloads = FakeDownloadsClient();
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads: downloads));
      await tester.pumpAndSettle();

      expect(focusedLabel(tester), '1080p');
      await hold(tester, LogicalKeyboardKey.select, RemotePress.holdDuration);

      expect(find.byType(PlayerScreen), findsNothing, reason: 'not a tap');
      expect(downloads.added.single.stream.infoHash, movieHash);
    });

    testWidgets('a tap still plays what is kept, rather than removing it', (
      tester,
    ) async {
      useScreen(tester, tvSize);
      final core = FakeCoreClient(
        state: {
          CoreField.metaDetails: loadMetaDetailsFixture(),
          CoreField.player: loadPlayerFixture(),
        },
      );
      final downloads = FakeDownloadsClient(registry: downloaded());
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads: downloads));
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.select);

      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(downloads.removed, isEmpty);
    });

    testWidgets('the app bar way to the downloads list takes the D-pad', (
      tester,
    ) async {
      useScreen(tester, tvSize);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      final downloads = FakeDownloadsClient(registry: downloaded());
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads: downloads));
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.arrowLeft);
      for (
        var i = 0;
        i < 6 && focusedTooltip() != kDownloadsScreenTooltip;
        i++
      ) {
        await press(tester, LogicalKeyboardKey.arrowUp);
      }
      expect(focusedTooltip(), kDownloadsScreenTooltip);

      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(DownloadsScreen), findsOneWidget);
    });
  });
}
