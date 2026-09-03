import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/downloads/download_labels.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../support/fake_core_client.dart';
import '../support/fake_downloads_client.dart';
import '../support/fake_playback_engine.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_torrent_stats_client.dart';
import '../support/fixtures.dart';

const movieId = 'tt0063350';
const alphaUrl = 'https://alpha.example/manifest.json';
const betaUrl = 'https://beta.example/manifest.json';
const youTubeUrl = 'https://v3-channels.strem.io/manifest.json';
const strangerUrl = 'https://mirror.example/stremio/manifest.json';

Map<String, dynamic> streamGroup(String base, Map<String, dynamic> content) => {
  'request': {
    'base': base,
    'path': {
      'resource': 'stream',
      'type': 'movie',
      'id': movieId,
      'extra': <Object>[],
    },
  },
  'content': content,
};

Map<String, dynamic> ready(String base, List<Map<String, dynamic>> streams) =>
    streamGroup(base, {'type': 'Ready', 'content': streams});

Map<String, dynamic> emptyGroup(String base) => streamGroup(base, {
  'type': 'Err',
  'content': {'type': 'EmptyContent'},
});

Map<String, dynamic> failedGroup(String base) => streamGroup(base, {
  'type': 'Err',
  'content': {
    'type': 'Env',
    'content': {'code': 1, 'message': 'Failed to fetch: 404 Not Found'},
  },
});

/// Two addons, four streams, deliberately out of order within and across
/// the addons: alpha answers with its worst release first, beta answers
/// with the one nothing can be read from last.
///
/// Grouped, that is exactly what shows. Flat, the order is 2160p, 1080p,
/// 720p, then the unknown — and the unknown is last because unknown
/// resolutions are a bucket of their own, not because it is worst.
List<Map<String, dynamic>> twoAddons() => [
  ready(alphaUrl, [
    {
      'infoHash': 'a' * 40,
      'name': 'Alpha 720p',
      'description': '👤 5 💾 900 MB',
    },
    {
      'infoHash': 'b' * 40,
      'name': 'Alpha 2160p',
      'description': '👤 3 💾 20 GB',
    },
  ]),
  ready(betaUrl, [
    {
      'infoHash': 'c' * 40,
      'name': 'Beta 1080p',
      'description': '👤 100 💾 2 GB',
    },
    {'infoHash': 'd' * 40, 'name': 'Beta mystery release'},
  ]),
];

double topOf(String text) => _tester!.getTopLeft(find.text(text)).dy;

/// The affordance with [tooltip] on the flat row titled [title].
Finder onRow(WidgetTester tester, String title, String tooltip) =>
    find.descendant(
      of: find.widgetWithText(ListTile, title),
      matching: find.byTooltip(tooltip),
    );

WidgetTester? _tester;

void main() {
  Widget harness(
    FakeCoreClient core, {
    AppPrefs? prefs,
    DownloadsClient? downloads,
    String id = movieId,
  }) {
    Widget screen = PrefsScope(
      prefs: prefs ?? AppPrefs.inMemory(),
      child: PlaybackScope(
        createEngine: FakePlaybackEngine.new,
        torrentStats: FakeTorrentStatsClient(),
        child: MaterialApp(
          home: MetaDetailsScreen(type: 'movie', id: id),
        ),
      ),
    );
    if (downloads != null) {
      screen = DownloadsScope(client: downloads, child: screen);
    }
    return CoreScope(client: core, child: screen);
  }

  void useWideViewport(WidgetTester tester) {
    _tester = tester;
    addTearDown(() => _tester = null);
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// The movie fixture with [streams] in place of its own, and the default
  /// profile as `ctx` so the addons can be named.
  FakeCoreClient coreWith(
    List<Map<String, dynamic>> streams, {
    Map<CoreField, Map<String, dynamic>> also = const {},
  }) => FakeCoreClient(
    state: {
      CoreField.metaDetails: loadMetaDetailsFixture()..['streams'] = streams,
      CoreField.ctx: loadCtxLoggedOutFixture(),
      ...also,
    },
  );

  Future<void> flip(WidgetTester tester, String tooltip) async {
    await tester.tap(find.byTooltip(tooltip));
    await tester.pumpAndSettle();
  }

  group('the layout toggle', () {
    testWidgets('starts grouped: the engine order, one section per addon', (
      tester,
    ) async {
      useWideViewport(tester);
      await tester.pumpWidget(harness(coreWith(twoAddons())));
      await tester.pumpAndSettle();

      // A heading per addon, once each, above its own streams.
      expect(find.text('alpha.example'), findsOneWidget);
      expect(find.text('beta.example'), findsOneWidget);
      expect(topOf('alpha.example'), lessThan(topOf('Alpha 720p')));
      // Each addon's own ranking, untouched: alpha's worst release first.
      expect(topOf('Alpha 720p'), lessThan(topOf('Alpha 2160p')));
      expect(topOf('Alpha 2160p'), lessThan(topOf('Beta 1080p')));
      expect(topOf('Beta 1080p'), lessThan(topOf('Beta mystery release')));

      expect(find.byTooltip(kFlatStreamsTooltip), findsOneWidget);
      expect(find.byTooltip(kGroupedStreamsTooltip), findsNothing);
    });

    testWidgets('flips to one flat list, sorted across every addon', (
      tester,
    ) async {
      useWideViewport(tester);
      await tester.pumpWidget(harness(coreWith(twoAddons())));
      await tester.pumpAndSettle();

      await flip(tester, kFlatStreamsTooltip);

      // Resolution first, highest first; the one nothing could be read
      // from is last, as its own bucket rather than as a zero.
      expect(topOf('Alpha 2160p'), lessThan(topOf('Beta 1080p')));
      expect(topOf('Beta 1080p'), lessThan(topOf('Alpha 720p')));
      expect(topOf('Alpha 720p'), lessThan(topOf('Beta mystery release')));

      // No headings any more: each row names its own addon instead.
      expect(find.text('alpha.example'), findsNWidgets(2));
      expect(find.text('beta.example'), findsNWidgets(2));

      // And the toggle now offers the way back.
      expect(find.byTooltip(kGroupedStreamsTooltip), findsOneWidget);
      await flip(tester, kGroupedStreamsTooltip);
      expect(topOf('Alpha 720p'), lessThan(topOf('Alpha 2160p')));
      expect(find.text('alpha.example'), findsOneWidget);
    });

    testWidgets('a row badges only what is known of its stream', (
      tester,
    ) async {
      useWideViewport(tester);
      await tester.pumpWidget(harness(coreWith(twoAddons())));
      await tester.pumpAndSettle();
      await flip(tester, kFlatStreamsTooltip);

      Finder badgesOf(String title) => find.descendant(
        of: find.widgetWithText(ListTile, title),
        matching: find.byType(Text),
      );
      List<String> labels(String title) => [
        for (final text in tester.widgetList<Text>(badgesOf(title)))
          text.data ?? '',
      ];

      expect(labels('Alpha 2160p'), [
        'Alpha 2160p',
        'alpha.example',
        '2160p',
        '20 GB',
        '3 seeders',
      ]);
      expect(labels('Beta 1080p'), [
        'Beta 1080p',
        'beta.example',
        '1080p',
        '2 GB',
        '100 seeders',
      ]);
      // Nothing readable: the addon name and no badge at all, rather than
      // a row of placeholders.
      expect(labels('Beta mystery release'), [
        'Beta mystery release',
        'beta.example',
      ]);
    });
  });

  group('the choice sticks', () {
    testWidgets('across another title, on the app-wide value', (tester) async {
      useWideViewport(tester);
      final prefs = AppPrefs(client: FakePrefsClient());
      addTearDown(prefs.dispose);
      await tester.pumpWidget(harness(coreWith(twoAddons()), prefs: prefs));
      await tester.pumpAndSettle();
      await flip(tester, kFlatStreamsTooltip);
      expect(prefs.streamsFlat, isTrue);

      // A second title, a whole new screen, the same preference above it.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        harness(coreWith(twoAddons()), prefs: prefs, id: 'tt0063350'),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip(kGroupedStreamsTooltip), findsOneWidget);
      expect(topOf('Alpha 2160p'), lessThan(topOf('Alpha 720p')));
    });

    testWidgets('across a fresh app start, through the stored file', (
      tester,
    ) async {
      useWideViewport(tester);
      final stored = FakePrefsClient();
      final first = AppPrefs(client: stored);
      addTearDown(first.dispose);
      await tester.pumpWidget(harness(coreWith(twoAddons()), prefs: first));
      await tester.pumpAndSettle();
      await flip(tester, kFlatStreamsTooltip);
      expect(stored.stored, {'streamsFlat': true});

      // The app comes up again: a new AppPrefs over the same file, loaded
      // before the first sources list is built.
      await tester.pumpWidget(const SizedBox());
      final restarted = AppPrefs(client: stored);
      addTearDown(restarted.dispose);
      await restarted.load();
      await tester.pumpWidget(harness(coreWith(twoAddons()), prefs: restarted));
      await tester.pumpAndSettle();

      expect(find.byTooltip(kGroupedStreamsTooltip), findsOneWidget);
      expect(topOf('Alpha 2160p'), lessThan(topOf('Alpha 720p')));
      expect(find.text('alpha.example'), findsNWidgets(2));
    });

    testWidgets('a load that lands after the screen is up still reaches it', (
      tester,
    ) async {
      useWideViewport(tester);
      final prefs = AppPrefs(client: FakePrefsClient({'streamsFlat': true}));
      addTearDown(prefs.dispose);
      await tester.pumpWidget(harness(coreWith(twoAddons()), prefs: prefs));
      await tester.pumpAndSettle();
      expect(find.byTooltip(kFlatStreamsTooltip), findsOneWidget);

      await prefs.load();
      await tester.pumpAndSettle();

      expect(find.byTooltip(kGroupedStreamsTooltip), findsOneWidget);
      expect(topOf('Alpha 2160p'), lessThan(topOf('Alpha 720p')));
    });

    testWidgets('with no scope above, the screen still toggles', (
      tester,
    ) async {
      useWideViewport(tester);
      await tester.pumpWidget(
        CoreScope(
          client: coreWith(twoAddons()),
          child: PlaybackScope(
            createEngine: FakePlaybackEngine.new,
            torrentStats: FakeTorrentStatsClient(),
            child: const MaterialApp(
              home: MetaDetailsScreen(type: 'movie', id: movieId),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await flip(tester, kFlatStreamsTooltip);
      expect(topOf('Alpha 2160p'), lessThan(topOf('Alpha 720p')));
    });
  });

  group('flat keeps everything around the streams', () {
    testWidgets('the last-used shortcut, the empty summary and the failures', (
      tester,
    ) async {
      useWideViewport(tester);
      final streams = [
        ...twoAddons(),
        emptyGroup(youTubeUrl),
        failedGroup(strangerUrl),
      ];
      final fixture = loadMetaDetailsFixture()..['streams'] = streams;
      fixture['lastUsedStream'] = {
        'request': streams.first['request'],
        'content': {
          'type': 'Ready',
          'content':
              (streams.first['content'] as Map<String, dynamic>)['content']![0],
        },
      };
      final core = FakeCoreClient(
        state: {
          CoreField.metaDetails: fixture,
          CoreField.ctx: loadCtxLoggedOutFixture(),
        },
      );
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();
      await flip(tester, kFlatStreamsTooltip);

      // The shortcut is above the list, still the shortcut.
      expect(find.text('Continue with last source'), findsOneWidget);
      expect(
        topOf('Continue with last source'),
        lessThan(topOf('Alpha 2160p')),
      );
      // The addon that had nothing, and the one that failed, both below.
      expect(find.text('1 addon had nothing for this title'), findsOneWidget);
      expect(
        topOf('1 addon had nothing for this title'),
        greaterThan(topOf('Beta mystery release')),
      );
      expect(find.text('mirror.example'), findsOneWidget);
      expect(find.text('Failed to fetch: 404 Not Found'), findsOneWidget);
      expect(find.text('Check addon'), findsOneWidget);
    });

    testWidgets('the notice when every addon came up empty', (tester) async {
      useWideViewport(tester);
      final core = coreWith([emptyGroup(youTubeUrl), emptyGroup(strangerUrl)]);
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();
      await flip(tester, kFlatStreamsTooltip);

      expect(find.text('2 addons had nothing for this title'), findsOneWidget);
      expect(find.text('Add an addon'), findsOneWidget);
    });
  });

  group('a flat row is a stream tile like any other', () {
    testWidgets('it plays, from the addon request it came from', (
      tester,
    ) async {
      useWideViewport(tester);
      final core = coreWith(
        twoAddons(),
        also: {CoreField.player: loadPlayerFixture()},
      );
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();
      await flip(tester, kFlatStreamsTooltip);

      await tester.tap(find.text('Beta 1080p'));
      await tester.pumpAndSettle();

      expect(find.byType(PlayerScreen), findsOneWidget);
      final load = core.dispatched.firstWhere(
        (a) => a.field == CoreField.player,
      );
      final args =
          (load.action['args'] as Map<String, dynamic>)['args']
              as Map<String, dynamic>;
      expect(args['stream']['infoHash'], 'c' * 40);
      expect(
        args['streamRequest']['base'],
        betaUrl,
        reason: 'the row kept the group it was sorted out of',
      );
    });

    testWidgets('it downloads, from the addon request it came from', (
      tester,
    ) async {
      useWideViewport(tester);
      final downloads = FakeDownloadsClient();
      addTearDown(downloads.dispose);
      await tester.pumpWidget(
        harness(coreWith(twoAddons()), downloads: downloads),
      );
      await tester.pumpAndSettle();
      await flip(tester, kFlatStreamsTooltip);

      expect(onRow(tester, 'Alpha 2160p', kDownloadTooltip), findsOneWidget);
      await tester.tap(onRow(tester, 'Alpha 2160p', kDownloadTooltip));
      await tester.pumpAndSettle();

      expect(downloads.added, hasLength(1));
      expect(downloads.added.single.stream.infoHash, 'b' * 40);
      expect(
        downloads.added.single.streamRequest?['base'],
        alphaUrl,
        reason: 'the pin records the request the stream came from',
      );
      // The row that took it now says it is queued, and the others offer
      // to replace it rather than to add a second download of the title.
      expect(
        onRow(
          tester,
          'Alpha 2160p',
          downloadStateLabel(downloads.registry.items.values.single),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip(kDownloadTooltip), findsNothing);
      expect(
        onRow(tester, 'Beta 1080p', kDownloadReplaceTooltip),
        findsOneWidget,
      );
    });

    testWidgets('a finished download is a delete button on its own row', (
      tester,
    ) async {
      useWideViewport(tester);
      final downloads = FakeDownloadsClient(
        registry: DownloadsRegistry(
          items: {
            '$movieId:$movieId': DownloadView({
              'metaId': movieId,
              'videoId': movieId,
              'name': 'Night of the Living Dead',
              'stream': {'infoHash': 'b' * 40},
              'infoHash': 'b' * 40,
              'size': 1000,
              'downloaded': 1000,
              'state': 'complete',
              'path': '/tmp/x.mkv',
            }),
          },
        ),
      );
      addTearDown(downloads.dispose);
      await tester.pumpWidget(
        harness(coreWith(twoAddons()), downloads: downloads),
      );
      await tester.pumpAndSettle();
      await flip(tester, kFlatStreamsTooltip);

      expect(
        onRow(tester, 'Alpha 2160p', kDownloadDeleteTooltip),
        findsOneWidget,
      );
      expect(find.byTooltip(kDownloadDeleteTooltip), findsWidgets);
      expect(
        onRow(tester, 'Beta 1080p', kDownloadReplaceTooltip),
        findsOneWidget,
      );
      expect(
        onRow(tester, 'Beta mystery release', kDownloadReplaceTooltip),
        findsOneWidget,
      );
    });
  });
}
