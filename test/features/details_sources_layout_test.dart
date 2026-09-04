import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/stream_facts.dart';
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
/// Grouped, that is exactly what shows. In sections it is one stream per
/// section: 2160p, 1080p, 720p, then the unknown — which is last because
/// an unreadable resolution is a bucket of its own, not because it is
/// worst.
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

/// One addon, five releases of the same resolution, so what decides the
/// rows is the order inside the section and nothing else. The ratios are
/// 41 MB a peer for the biggest file, 205 for the middle one and 350 for
/// the smallest, so peers per megabyte, largest first and most peers each
/// give a different answer.
List<Map<String, dynamic>> oneResolution() => [
  ready(alphaUrl, [
    {
      'infoHash': 'a' * 40,
      'name': 'Middle 1080p',
      'description': '👤 10 💾 2 GB',
    },
    {
      'infoHash': 'b' * 40,
      'name': 'Fat 1080p',
      'description': '👤 200 💾 8 GB',
    },
    {
      'infoHash': 'c' * 40,
      'name': 'Lonely 1080p',
      'description': '👤 2 💾 700 MB',
    },
    {'infoHash': 'd' * 40, 'name': 'Sizeless 1080p', 'description': '👤 90'},
    {'infoHash': 'e' * 40, 'name': 'Peerless 1080p', 'description': '💾 3 GB'},
  ]),
];

/// The rows [oneResolution] draws, top to bottom.
List<String> rows(WidgetTester tester) {
  final titles = [
    for (final name in [
      'Fat 1080p',
      'Middle 1080p',
      'Lonely 1080p',
      'Sizeless 1080p',
      'Peerless 1080p',
    ])
      (name, topOf(name)),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  return [for (final row in titles) row.$1];
}

double topOf(String text) => _tester!.getTopLeft(find.text(text)).dy;

/// Opens or closes the section headed [resolution]. Found by its key
/// rather than by its heading, because a 1080p row badges itself `1080p`
/// too and the text alone would match both.
Future<void> toggleSection(
  WidgetTester tester,
  StreamResolution? resolution,
) async {
  await tester.tap(find.byKey(streamSectionKey(resolution)));
  await tester.pumpAndSettle();
}

/// Where the header of [resolution] is, which is not `topOf` its label: a
/// row inside the section badges the same text.
double topOfSection(WidgetTester tester, StreamResolution? resolution) =>
    tester.getTopLeft(find.byKey(streamSectionKey(resolution))).dy;

/// What the header of [resolution] says it is holding.
String sectionSummary(WidgetTester tester, StreamResolution? resolution) {
  final header = tester.widget<ListTile>(
    find.byKey(streamSectionKey(resolution)),
  );
  return (header.subtitle! as Text).data!;
}

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

  /// [AppPrefs.inMemory] plus a widget rebuild, so the streams pane keeps
  /// its state -- section identity, expansion memory -- across it the way
  /// a real title change does.
  Future<void> rebuild(WidgetTester tester, Widget widget) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
  }

  group('the layout toggle', () {
    testWidgets(
      'starts sectioned: highest resolution first, every section collapsed',
      (tester) async {
        useWideViewport(tester);
        await tester.pumpWidget(harness(coreWith(twoAddons())));
        await tester.pumpAndSettle();

        // A heading per resolution, highest first, and the one nothing
        // could be read from last -- said to be unknown rather than
        // guessed at.
        expect(
          topOfSection(tester, StreamResolution.uhd2160),
          lessThan(topOfSection(tester, StreamResolution.fhd1080)),
        );
        expect(
          topOfSection(tester, StreamResolution.fhd1080),
          lessThan(topOfSection(tester, StreamResolution.hd720)),
        );
        expect(
          topOfSection(tester, StreamResolution.hd720),
          lessThan(topOfSection(tester, null)),
        );
        expect(find.text('Unknown resolution'), findsOneWidget);

        // Nothing has been opened yet, so nothing but the headers is on
        // screen -- not even the best one.
        expect(find.text('Alpha 2160p'), findsNothing);
        expect(find.text('Beta 1080p'), findsNothing);
        expect(find.text('Alpha 720p'), findsNothing);
        expect(find.text('Beta mystery release'), findsNothing);
        expect(
          find.text('alpha.example'),
          findsNothing,
          reason: 'no row is open to badge an addon name on',
        );

        // The toggle says where it is and what tapping it does, both in
        // its tooltip and, with room in the header, right next to the
        // heading.
        expect(find.byTooltip(kStreamsSectionedTooltip), findsOneWidget);
        expect(find.byTooltip(kStreamsGroupedTooltip), findsNothing);
        expect(find.text(kStreamsSectionedLabel), findsOneWidget);
      },
    );

    testWidgets('flips to grouped, each addon\'s own order intact, and back to '
        'sectioned -- still with nothing open', (tester) async {
      useWideViewport(tester);
      await tester.pumpWidget(harness(coreWith(twoAddons())));
      await tester.pumpAndSettle();

      await flip(tester, kStreamsSectionedTooltip);

      // A heading per addon, once each, above its own streams: what this
      // list looked like before the sectioned layout existed.
      expect(find.text('alpha.example'), findsOneWidget);
      expect(find.text('beta.example'), findsOneWidget);
      expect(topOf('alpha.example'), lessThan(topOf('Alpha 720p')));
      // Each addon's own ranking, untouched: alpha's worst release first.
      expect(topOf('Alpha 720p'), lessThan(topOf('Alpha 2160p')));
      expect(topOf('Alpha 2160p'), lessThan(topOf('Beta 1080p')));
      expect(topOf('Beta 1080p'), lessThan(topOf('Beta mystery release')));
      expect(find.byTooltip(kStreamsGroupedTooltip), findsOneWidget);
      expect(find.byTooltip(kStreamsSectionedTooltip), findsNothing);
      expect(find.text(kStreamsGroupedLabel), findsOneWidget);

      await flip(tester, kStreamsGroupedTooltip);

      // Sectioned again, and flipping the layout did not open anything
      // on its own.
      expect(find.text('alpha.example'), findsNothing);
      expect(find.text('Alpha 2160p'), findsNothing);
      expect(find.byTooltip(kStreamsSectionedTooltip), findsOneWidget);
    });

    testWidgets(
      'an install that had already chosen grouped keeps it, not the new '
      'sectioned default',
      (tester) async {
        useWideViewport(tester);
        final prefs = AppPrefs(
          client: FakePrefsClient({'streamsSectioned': false}),
        );
        addTearDown(prefs.dispose);
        await prefs.load();
        await tester.pumpWidget(harness(coreWith(twoAddons()), prefs: prefs));
        await tester.pumpAndSettle();

        expect(find.text('alpha.example'), findsOneWidget);
        expect(topOf('Alpha 720p'), lessThan(topOf('Alpha 2160p')));
        expect(find.byTooltip(kStreamsGroupedTooltip), findsOneWidget);
      },
    );

    testWidgets('a collapsed header says how many streams and how healthy', (
      tester,
    ) async {
      useWideViewport(tester);
      final streams = [
        ready(alphaUrl, [
          {'infoHash': 'a' * 40, 'name': '2160p one', 'description': '👤 2'},
          {'infoHash': 'b' * 40, 'name': '2160p two', 'description': '👤 137'},
          {'infoHash': 'c' * 40, 'name': '2160p three'},
          {'infoHash': 'd' * 40, 'name': '1080p only', 'description': '👤 1'},
          {'infoHash': 'e' * 40, 'name': '720p quiet'},
        ]),
      ];
      await tester.pumpWidget(harness(coreWith(streams)));
      await tester.pumpAndSettle();

      // Closed, a section still says what is in it: how many streams, and
      // the best swarm among them, which is what tells an empty-looking
      // 2160p from a healthy one without opening either.
      expect(
        sectionSummary(tester, StreamResolution.uhd2160),
        '3 streams · best 137 seeders',
      );
      expect(
        sectionSummary(tester, StreamResolution.fhd1080),
        '1 stream · best 1 seeder',
      );
      // Nobody said, which is not the same as nobody being there.
      expect(
        sectionSummary(tester, StreamResolution.hd720),
        '1 stream · seeders unknown',
      );
      expect(find.text('1080p only'), findsNothing);
    });

    testWidgets('a row badges only what is known of its stream', (
      tester,
    ) async {
      useWideViewport(tester);
      await tester.pumpWidget(harness(coreWith(twoAddons())));
      await tester.pumpAndSettle();
      await toggleSection(tester, StreamResolution.uhd2160);
      await toggleSection(tester, StreamResolution.fhd1080);
      await toggleSection(tester, null);

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

  group('the order inside a section', () {
    testWidgets('is peers per megabyte, which the biggest file can win', (
      tester,
    ) async {
      useWideViewport(tester);
      await tester.pumpWidget(harness(coreWith(oneResolution())));
      await tester.pumpAndSettle();
      await toggleSection(tester, StreamResolution.fhd1080);

      // 8 GB for 200 peers is 41 MB a peer: the fattest file on the list
      // is the one likeliest to arrive faster than it is watched, which
      // neither "largest" nor "most peers" alone would have told us --
      // most peers would have put the 90-peer stream of unknown size
      // second, and it is last but one here.
      expect(rows(tester), [
        'Fat 1080p',
        'Middle 1080p',
        'Lonely 1080p',
        'Sizeless 1080p',
        'Peerless 1080p',
      ]);
    });

    testWidgets('an unknown size or peer count sorts after every ranked '
        'stream, and is not drawn as a zero', (tester) async {
      useWideViewport(tester);
      await tester.pumpWidget(harness(coreWith(oneResolution())));
      await tester.pumpAndSettle();
      await toggleSection(tester, StreamResolution.fhd1080);

      // Behind even the worst ratio on the list (350 MB a peer)...
      expect(topOf('Lonely 1080p'), lessThan(topOf('Sizeless 1080p')));
      expect(topOf('Lonely 1080p'), lessThan(topOf('Peerless 1080p')));
      // ...and between themselves, in the order the addon gave them.
      expect(topOf('Sizeless 1080p'), lessThan(topOf('Peerless 1080p')));

      // What is unknown is not badged at all: no `0 B`, no `0 seeders`.
      List<String> badges(String title) => [
        for (final text in tester.widgetList<Text>(
          find.descendant(
            of: find.widgetWithText(ListTile, title),
            matching: find.byType(Text),
          ),
        ))
          text.data ?? '',
      ];
      expect(badges('Sizeless 1080p'), [
        'Sizeless 1080p',
        'alpha.example',
        '1080p',
        '90 seeders',
      ]);
      expect(badges('Peerless 1080p'), [
        'Peerless 1080p',
        'alpha.example',
        '1080p',
        '3 GB',
      ]);
      // And every row that knows them shows both, so an outlier encode is
      // visible without opening anything.
      expect(badges('Fat 1080p'), contains('8 GB'));
      expect(badges('Fat 1080p'), contains('200 seeders'));
    });
  });

  group('the section order is the viewer to pick', () {
    Future<void> pick(WidgetTester tester, StreamOrder order) async {
      await tester.tap(find.widgetWithText(ChoiceChip, order.label));
      await tester.pumpAndSettle();
    }

    testWidgets('a chip re-orders the section and stores the choice', (
      tester,
    ) async {
      useWideViewport(tester);
      final stored = FakePrefsClient();
      final prefs = AppPrefs(client: stored);
      addTearDown(prefs.dispose);
      await prefs.load();
      await tester.pumpWidget(harness(coreWith(oneResolution()), prefs: prefs));
      await tester.pumpAndSettle();

      // Sectioned to begin with, and nothing written for it: a default is
      // not a choice.
      expect(stored.stored.containsKey('streamsSectioned'), isFalse);
      await toggleSection(tester, StreamResolution.fhd1080);

      // Peers per megabyte to begin with.
      expect(rows(tester).first, 'Fat 1080p');

      await pick(tester, StreamOrder.largest);
      // Largest first, with the one whose size nobody gave last -- after
      // the smallest known file, not among the big ones.
      expect(rows(tester), [
        'Fat 1080p',
        'Peerless 1080p',
        'Middle 1080p',
        'Lonely 1080p',
        'Sizeless 1080p',
      ]);
      expect(stored.stored['streamsOrder'], 'largest');

      await pick(tester, StreamOrder.mostPeers);
      // Most peers first, and now it is the one with no peer count that
      // goes last.
      expect(rows(tester), [
        'Fat 1080p',
        'Sizeless 1080p',
        'Middle 1080p',
        'Lonely 1080p',
        'Peerless 1080p',
      ]);
      expect(stored.stored['streamsOrder'], 'mostPeers');

      await pick(tester, StreamOrder.peersPerSize);
      expect(rows(tester).first, 'Fat 1080p');
      expect(rows(tester)[1], 'Middle 1080p');
      expect(stored.stored['streamsOrder'], 'peersPerSize');
    });

    testWidgets('the order, and which section is open, survive a rebuild and a '
        'fresh start', (tester) async {
      useWideViewport(tester);
      final stored = FakePrefsClient();
      final first = AppPrefs(client: stored);
      addTearDown(first.dispose);
      await first.load();
      await tester.pumpWidget(harness(coreWith(oneResolution()), prefs: first));
      await tester.pumpAndSettle();
      await toggleSection(tester, StreamResolution.fhd1080);
      await pick(tester, StreamOrder.largest);
      expect(rows(tester)[1], 'Peerless 1080p');

      // Another title, the same preferences above it.
      await rebuild(tester, harness(coreWith(oneResolution()), prefs: first));
      expect(rows(tester)[1], 'Peerless 1080p');

      // And the app comes up again: a new AppPrefs over the same file,
      // read before the first sources list is built.
      await tester.pumpWidget(const SizedBox());
      final restarted = AppPrefs(client: stored);
      addTearDown(restarted.dispose);
      await restarted.load();
      expect(restarted.streamsOrder, StreamOrder.largest);
      expect(restarted.openStreamSections, {'1080p'});
      await tester.pumpWidget(
        harness(coreWith(oneResolution()), prefs: restarted),
      );
      await tester.pumpAndSettle();
      expect(rows(tester)[1], 'Peerless 1080p');
    });

    testWidgets('is not offered where there are no sections to order', (
      tester,
    ) async {
      useWideViewport(tester);
      final prefs = AppPrefs(
        client: FakePrefsClient({'streamsSectioned': false}),
      );
      addTearDown(prefs.dispose);
      await prefs.load();
      await tester.pumpWidget(harness(coreWith(oneResolution()), prefs: prefs));
      await tester.pumpAndSettle();

      // Grouped is each addon's own ranking, which is the point of it.
      expect(find.byType(ChoiceChip), findsNothing);
      await flip(tester, kStreamsGroupedTooltip);
      expect(find.byType(ChoiceChip), findsNWidgets(StreamOrder.values.length));
    });
  });

  group('which resolution sections are open', () {
    testWidgets('a fresh install has nothing open', (tester) async {
      useWideViewport(tester);
      await tester.pumpWidget(harness(coreWith(twoAddons())));
      await tester.pumpAndSettle();

      expect(find.text('Alpha 2160p'), findsNothing);
      expect(find.text('Beta 1080p'), findsNothing);
      expect(find.text('Alpha 720p'), findsNothing);
      expect(find.text('Beta mystery release'), findsNothing);
    });

    testWidgets('is the one still open when the streams are rebuilt', (
      tester,
    ) async {
      useWideViewport(tester);
      final core = coreWith(twoAddons());
      await tester.pumpWidget(harness(core));
      await tester.pumpAndSettle();

      // Open 720p; nothing else was open to begin with.
      await toggleSection(tester, StreamResolution.hd720);
      expect(find.text('Alpha 720p'), findsOneWidget);
      expect(find.text('Alpha 2160p'), findsNothing);

      // The engine answers again -- another episode, a late addon -- and
      // the list is built from scratch.
      core.setState(
        CoreField.metaDetails,
        loadMetaDetailsFixture()..['streams'] = twoAddons(),
      );
      await tester.pumpAndSettle();

      expect(find.text('Alpha 720p'), findsOneWidget);
      expect(find.text('Alpha 2160p'), findsNothing);
    });

    testWidgets('a remembered resolution this title does not have simply stays '
        'unopened, never substituted for another section', (tester) async {
      useWideViewport(tester);
      final prefs = AppPrefs(
        client: FakePrefsClient({
          'openStreamSections': ['2160p'],
        }),
      );
      addTearDown(prefs.dispose);
      await prefs.load();
      // Streams with no 2160p in them at all.
      final core = coreWith([
        ready(alphaUrl, [
          {'infoHash': 'f' * 40, 'name': 'Only 1080p', 'description': '👤 4'},
        ]),
      ]);
      await tester.pumpWidget(harness(core, prefs: prefs));
      await tester.pumpAndSettle();

      expect(
        find.text('Only 1080p'),
        findsNothing,
        reason: 'not substituted for the section this title actually has',
      );
      expect(
        find.text('1080p'),
        findsOneWidget,
        reason: 'the header is still there, just closed',
      );
    });

    testWidgets('collapsing everything stays empty, and is not re-expanded '
        'by the fallback that used to open the best section', (tester) async {
      useWideViewport(tester);
      final stored = FakePrefsClient();
      final prefs = AppPrefs(client: stored);
      addTearDown(prefs.dispose);
      await tester.pumpWidget(harness(coreWith(twoAddons()), prefs: prefs));
      await tester.pumpAndSettle();

      await toggleSection(tester, StreamResolution.hd720);
      expect(find.text('Alpha 720p'), findsOneWidget);
      await toggleSection(tester, StreamResolution.hd720);
      expect(find.text('Alpha 720p'), findsNothing);
      expect(prefs.openStreamSections, isEmpty);
      expect(stored.stored['openStreamSections'], isEmpty);

      // Rebuilding the streams -- another episode, a late addon -- must
      // not reopen the best section on its own.
      await rebuild(tester, harness(coreWith(twoAddons()), prefs: prefs));
      expect(find.text('Alpha 2160p'), findsNothing);
      expect(find.text('Alpha 720p'), findsNothing);

      // And it survives a restart: an empty stored set is a choice, kept
      // apart from "unset" -- see AppPrefs.openStreamSections.
      final restarted = AppPrefs(client: stored);
      addTearDown(restarted.dispose);
      await restarted.load();
      expect(restarted.openStreamSections, isEmpty);
      expect(restarted.openStreamSections, isNotNull);
    });
  });

  group('the choice sticks', () {
    testWidgets('the layout, across another title, on the app-wide value', (
      tester,
    ) async {
      useWideViewport(tester);
      final prefs = AppPrefs(client: FakePrefsClient());
      addTearDown(prefs.dispose);
      await tester.pumpWidget(harness(coreWith(twoAddons()), prefs: prefs));
      await tester.pumpAndSettle();
      await flip(tester, kStreamsSectionedTooltip);
      expect(prefs.streamsSectioned, isFalse);

      // A second title, a whole new screen, the same preference above it.
      await rebuild(
        tester,
        harness(coreWith(twoAddons()), prefs: prefs, id: 'tt0063350'),
      );

      expect(find.byTooltip(kStreamsGroupedTooltip), findsOneWidget);
      expect(find.text('alpha.example'), findsOneWidget);
      expect(topOf('Alpha 720p'), lessThan(topOf('Alpha 2160p')));
    });

    testWidgets('the layout, across a fresh app start, through the stored '
        'file', (tester) async {
      useWideViewport(tester);
      final stored = FakePrefsClient();
      final first = AppPrefs(client: stored);
      addTearDown(first.dispose);
      await tester.pumpWidget(harness(coreWith(twoAddons()), prefs: first));
      await tester.pumpAndSettle();
      await flip(tester, kStreamsSectionedTooltip);
      expect(stored.stored['streamsSectioned'], isFalse);

      // The app comes up again: a new AppPrefs over the same file, loaded
      // before the first sources list is built.
      await tester.pumpWidget(const SizedBox());
      final restarted = AppPrefs(client: stored);
      addTearDown(restarted.dispose);
      await restarted.load();
      await tester.pumpWidget(harness(coreWith(twoAddons()), prefs: restarted));
      await tester.pumpAndSettle();

      expect(find.byTooltip(kStreamsGroupedTooltip), findsOneWidget);
      expect(find.text('alpha.example'), findsOneWidget);
    });

    testWidgets('which section is open, across another title, on the '
        'app-wide value', (tester) async {
      useWideViewport(tester);
      final prefs = AppPrefs(client: FakePrefsClient());
      addTearDown(prefs.dispose);
      await tester.pumpWidget(harness(coreWith(twoAddons()), prefs: prefs));
      await tester.pumpAndSettle();
      await toggleSection(tester, StreamResolution.fhd1080);
      expect(prefs.openStreamSections, {'1080p'});

      // A second title, a whole new screen, the same preference above it.
      await rebuild(
        tester,
        harness(coreWith(twoAddons()), prefs: prefs, id: 'tt0063350'),
      );

      expect(find.text('Beta 1080p'), findsOneWidget);
      expect(find.text('Alpha 2160p'), findsNothing);
    });

    testWidgets('a load that lands after the screen is up still reaches it', (
      tester,
    ) async {
      useWideViewport(tester);
      final prefs = AppPrefs(
        client: FakePrefsClient({'streamsSectioned': false}),
      );
      addTearDown(prefs.dispose);
      await tester.pumpWidget(harness(coreWith(twoAddons()), prefs: prefs));
      await tester.pumpAndSettle();
      // Not loaded yet, so still the in-memory default: sectioned.
      expect(find.byTooltip(kStreamsSectionedTooltip), findsOneWidget);

      await prefs.load();
      await tester.pumpAndSettle();

      // The stored choice -- grouped -- has caught up.
      expect(find.byTooltip(kStreamsGroupedTooltip), findsOneWidget);
      expect(find.text('alpha.example'), findsOneWidget);
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

      await toggleSection(tester, StreamResolution.hd720);
      expect(find.text('Alpha 720p'), findsOneWidget);
      await toggleSection(tester, StreamResolution.uhd2160);
      expect(find.text('Alpha 2160p'), findsOneWidget);
      expect(
        topOf('Alpha 2160p'),
        lessThan(topOf('Alpha 720p')),
        reason: 'the sections are still in resolution order',
      );
    });
  });

  group('sections keep everything around the streams', () {
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

      // The shortcut is above the list, still the shortcut -- shown
      // whether or not any section is open.
      expect(find.text('Continue with last source'), findsOneWidget);
      expect(
        topOf('Continue with last source'),
        lessThan(topOfSection(tester, StreamResolution.uhd2160)),
      );
      // The addon that had nothing, and the one that failed, both below --
      // below the last section, open or not.
      expect(find.text('1 addon had nothing for this title'), findsOneWidget);
      expect(
        topOf('1 addon had nothing for this title'),
        greaterThan(topOfSection(tester, null)),
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

      expect(find.text('2 addons had nothing for this title'), findsOneWidget);
      expect(find.text('Add an addon'), findsOneWidget);
    });
  });

  group('a row in a section is a stream tile like any other', () {
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
      await toggleSection(tester, StreamResolution.fhd1080);

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
      await toggleSection(tester, StreamResolution.fhd1080);

      expect(onRow(tester, 'Alpha 2160p', kDownloadTooltip), findsNothing);
      await toggleSection(tester, StreamResolution.uhd2160);
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
      await toggleSection(tester, StreamResolution.fhd1080);
      await toggleSection(tester, null);
      await toggleSection(tester, StreamResolution.uhd2160);

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
