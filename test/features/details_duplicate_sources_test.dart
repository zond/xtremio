import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/stream_facts.dart';
import 'package:xtremio/features/details/stream_sources.dart';
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

/// The same release, byte for byte, as two addons would list it: one info
/// hash, one file index, the same name and the same numbers. Only the
/// trackers differ, which is the half of a duplicate worth keeping.
const sharedHash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

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

Map<String, dynamic> torrent(
  String infoHash, {
  required String name,
  int? fileIdx,
  String description = '👤 42 💾 2 GB',
  List<String> announce = const [],
}) => {
  'infoHash': infoHash,
  'fileIdx': ?fileIdx,
  'name': name,
  'description': description,
  'announce': announce,
};

/// The duplicate the owner reported: one release, two addons, everything
/// on screen identical. Their tracker lists overlap without matching.
List<Map<String, dynamic>> theSameReleaseTwice() => [
  ready(alphaUrl, [
    torrent(
      sharedHash,
      name: 'The Same Release 1080p',
      fileIdx: 0,
      announce: const ['udp://one.example:1337', 'udp://shared.example:1337'],
    ),
  ]),
  ready(betaUrl, [
    torrent(
      sharedHash,
      name: 'The Same Release 1080p',
      fileIdx: 0,
      announce: const ['udp://shared.example:1337', 'udp://two.example:1337'],
    ),
  ]),
];

const mergedTrackers = [
  'udp://one.example:1337',
  'udp://shared.example:1337',
  'udp://two.example:1337',
];

double topOf(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

/// The affordance with [tooltip] on the row titled [title].
Finder onRow(String title, String tooltip) => find.descendant(
  of: find.widgetWithText(ListTile, title),
  matching: find.byTooltip(tooltip),
);

void main() {
  Widget harness(
    FakeCoreClient core, {
    AppPrefs? prefs,
    DownloadsClient? downloads,
  }) {
    Widget screen = PrefsScope(
      prefs: prefs ?? AppPrefs.inMemory(),
      child: PlaybackScope(
        createEngine: FakePlaybackEngine.new,
        torrentStats: FakeTorrentStatsClient(),
        child: const MaterialApp(
          home: MetaDetailsScreen(type: 'movie', id: movieId),
        ),
      ),
    );
    if (downloads != null) {
      screen = DownloadsScope(client: downloads, child: screen);
    }
    return CoreScope(client: core, child: screen);
  }

  void useWideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  FakeCoreClient coreWith(
    List<Map<String, dynamic>> streams, {
    Map<CoreField, Map<String, dynamic>> also = const {},
    Map<String, dynamic>? lastUsed,
  }) {
    final fixture = loadMetaDetailsFixture()..['streams'] = streams;
    if (lastUsed != null) fixture['lastUsedStream'] = lastUsed;
    return FakeCoreClient(
      state: {
        CoreField.metaDetails: fixture,
        CoreField.ctx: loadCtxLoggedOutFixture(),
        ...also,
      },
    );
  }

  /// Sectioned is the default, but every section starts collapsed; a
  /// duplicate test cares about identity, not about which resolution
  /// bucket a release happens to land in, so this opens every one that
  /// could possibly appear.
  AppPrefs openSectionsPrefs() {
    final prefs = AppPrefs(
      client: FakePrefsClient({
        'openStreamSections': [
          for (final resolution in StreamResolution.values) resolution.label,
          'unknown',
        ],
      }),
    );
    addTearDown(prefs.dispose);
    return prefs;
  }

  Future<void> pumpSectioned(
    WidgetTester tester,
    FakeCoreClient core, {
    DownloadsClient? downloads,
  }) async {
    final prefs = openSectionsPrefs();
    await prefs.load();
    await tester.pumpWidget(harness(core, prefs: prefs, downloads: downloads));
    await tester.pumpAndSettle();
  }

  /// Grouped is no longer the default; every test that wants it says so.
  /// Loaded already, the way start-up reads it before the first sources
  /// list is built.
  Future<AppPrefs> groupedPrefs() async {
    final prefs = AppPrefs(
      client: FakePrefsClient({'streamsSectioned': false}),
    );
    addTearDown(prefs.dispose);
    await prefs.load();
    return prefs;
  }

  group('identity, not appearance', () {
    testWidgets('one release from two addons is one row naming both', (
      tester,
    ) async {
      useWideViewport(tester);
      await pumpSectioned(tester, coreWith(theSameReleaseTwice()));

      expect(find.text('The Same Release 1080p'), findsOneWidget);
      // The best-ranked instance survives, and the sort is stable, so it
      // is alpha's -- which is also the row that names the other addon.
      expect(find.text('alpha.example'), findsOneWidget);
      expect(find.text(alsoFromLabel(const ['beta.example'])), findsOneWidget);
      expect(find.text('beta.example'), findsNothing);
    });

    testWidgets('an addon repeating itself collapses without a word', (
      tester,
    ) async {
      useWideViewport(tester);
      final streams = [
        ready(alphaUrl, [
          torrent(sharedHash, name: 'The Same Release 1080p', fileIdx: 0),
          torrent(sharedHash, name: 'The Same Release 1080p', fileIdx: 0),
        ]),
      ];
      await pumpSectioned(tester, coreWith(streams));

      expect(find.text('The Same Release 1080p'), findsOneWidget);
      expect(find.textContaining('Also from'), findsNothing);
    });

    testWidgets('two releases that merely look alike both stay', (
      tester,
    ) async {
      useWideViewport(tester);
      // Same resolution, same size, same seeders: identical badges, and
      // two different torrents. Collapsing on what a row *looks* like
      // would lose one of them.
      final streams = [
        ready(alphaUrl, [
          torrent('b' * 40, name: 'Release A 1080p'),
          torrent('c' * 40, name: 'Release B 1080p'),
        ]),
      ];
      await pumpSectioned(tester, coreWith(streams));

      List<String> badgesOf(String title) => [
        for (final text in tester.widgetList<Text>(
          find.descendant(
            of: find.widgetWithText(ListTile, title),
            matching: find.byType(Text),
          ),
        ))
          text.data ?? '',
      ];

      expect(find.text('Release A 1080p'), findsOneWidget);
      expect(find.text('Release B 1080p'), findsOneWidget);
      expect(badgesOf('Release A 1080p').sublist(1), [
        'alpha.example',
        '1080p',
        '2 GB',
        '42 seeders',
      ]);
      expect(
        badgesOf('Release B 1080p').sublist(1),
        badgesOf('Release A 1080p').sublist(1),
        reason: 'identical badges, and still two rows',
      );
      expect(find.textContaining('Also from'), findsNothing);
    });

    testWidgets('the same info hash at another file index is another source', (
      tester,
    ) async {
      useWideViewport(tester);
      final streams = [
        ready(alphaUrl, [
          torrent(sharedHash, name: 'Episode 1', fileIdx: 0),
          torrent(sharedHash, name: 'Episode 2', fileIdx: 1),
        ]),
      ];
      await pumpSectioned(tester, coreWith(streams));

      expect(find.text('Episode 1'), findsOneWidget);
      expect(find.text('Episode 2'), findsOneWidget);
    });

    testWidgets('a direct URL is identified by its URL', (tester) async {
      useWideViewport(tester);
      final streams = [
        ready(alphaUrl, [
          {'url': 'https://cdn.example/film.mp4', 'name': 'Direct 1080p'},
        ]),
        ready(betaUrl, [
          {'url': 'https://cdn.example/film.mp4', 'name': 'Direct 1080p'},
          {'url': 'https://cdn.example/other.mp4', 'name': 'Another 1080p'},
        ]),
      ];
      await pumpSectioned(tester, coreWith(streams));

      expect(find.text('Direct 1080p'), findsOneWidget);
      expect(find.text(alsoFromLabel(const ['beta.example'])), findsOneWidget);
      expect(find.text('Another 1080p'), findsOneWidget);
    });
  });

  group('the merged trackers', () {
    testWidgets('are what playback is handed', (tester) async {
      useWideViewport(tester);
      final core = coreWith(
        theSameReleaseTwice(),
        also: {CoreField.player: loadPlayerFixture()},
      );
      await pumpSectioned(tester, core);

      await tester.tap(find.text('The Same Release 1080p'));
      await tester.pumpAndSettle();

      expect(find.byType(PlayerScreen), findsOneWidget);
      final load = core.dispatched.firstWhere(
        (a) => a.field == CoreField.player,
      );
      final args =
          (load.action['args'] as Map<String, dynamic>)['args']
              as Map<String, dynamic>;
      // The engine builds `<server>/{infoHash}/{fileIdx}?tr=…` out of
      // exactly this: every tracker either addon named, once each, first
      // seen first.
      expect(args['stream']['announce'], mergedTrackers);
      expect(args['stream']['infoHash'], sharedHash);
      expect(args['streamRequest']['base'], alphaUrl);
    });

    testWidgets('are what a download is pinned with', (tester) async {
      useWideViewport(tester);
      final downloads = FakeDownloadsClient();
      addTearDown(downloads.dispose);
      await pumpSectioned(
        tester,
        coreWith(theSameReleaseTwice()),
        downloads: downloads,
      );

      await tester.tap(onRow('The Same Release 1080p', kDownloadTooltip));
      await tester.pumpAndSettle();

      expect(downloads.added, hasLength(1));
      expect(downloads.added.single.stream.trackers, mergedTrackers);
      expect(downloads.added.single.stream.infoHash, sharedHash);
    });

    testWidgets('reach the grouped layout too, in every group', (tester) async {
      useWideViewport(tester);
      final core = coreWith(
        theSameReleaseTwice(),
        also: {CoreField.player: loadPlayerFixture()},
      );
      await tester.pumpWidget(harness(core, prefs: await groupedPrefs()));
      await tester.pumpAndSettle();

      // Beta's copy of the row -- the second one on screen.
      await tester.tap(find.text('The Same Release 1080p').last);
      await tester.pumpAndSettle();

      final load = core.dispatched.firstWhere(
        (a) => a.field == CoreField.player,
      );
      final args =
          (load.action['args'] as Map<String, dynamic>)['args']
              as Map<String, dynamic>;
      expect(args['stream']['announce'], mergedTrackers);
      expect(
        args['streamRequest']['base'],
        betaUrl,
        reason: 'the row still plays from the group it sits in',
      );
    });

    testWidgets('a stream nobody duplicated keeps its own list', (
      tester,
    ) async {
      useWideViewport(tester);
      final core = coreWith(
        [
          ready(alphaUrl, [
            torrent(
              'b' * 40,
              name: 'Only Release 1080p',
              announce: const ['udp://one.example:1337'],
            ),
          ]),
        ],
        also: {CoreField.player: loadPlayerFixture()},
      );
      await pumpSectioned(tester, core);

      await tester.tap(find.text('Only Release 1080p'));
      await tester.pumpAndSettle();

      final load = core.dispatched.firstWhere(
        (a) => a.field == CoreField.player,
      );
      final args =
          (load.action['args'] as Map<String, dynamic>)['args']
              as Map<String, dynamic>;
      expect(args['stream']['announce'], ['udp://one.example:1337']);
    });
  });

  group('the grouped layout', () {
    testWidgets('keeps its groups: the shared source is in both, marked', (
      tester,
    ) async {
      useWideViewport(tester);
      await tester.pumpWidget(
        harness(coreWith(theSameReleaseTwice()), prefs: await groupedPrefs()),
      );
      await tester.pumpAndSettle();

      // Both headings, and the release under each of them: the groups are
      // the whole point of this layout.
      expect(find.text('alpha.example'), findsOneWidget);
      expect(find.text('beta.example'), findsOneWidget);
      expect(find.text('The Same Release 1080p'), findsNWidgets(2));
      // Each says the other has it too, so the two rows do not read as
      // two options.
      expect(find.text(alsoFromLabel(const ['beta.example'])), findsOneWidget);
      expect(find.text(alsoFromLabel(const ['alpha.example'])), findsOneWidget);
      expect(
        topOf(tester, 'alpha.example'),
        lessThan(topOf(tester, 'beta.example')),
      );
    });

    testWidgets('collapses a repeat inside one group, silently', (
      tester,
    ) async {
      useWideViewport(tester);
      final streams = [
        ready(alphaUrl, [
          torrent(sharedHash, name: 'The Same Release 1080p', fileIdx: 0),
          torrent(sharedHash, name: 'The Same Release 1080p', fileIdx: 0),
          torrent('b' * 40, name: 'Another Release 720p'),
        ]),
      ];
      await tester.pumpWidget(
        harness(coreWith(streams), prefs: await groupedPrefs()),
      );
      await tester.pumpAndSettle();

      expect(find.text('The Same Release 1080p'), findsOneWidget);
      expect(find.text('Another Release 720p'), findsOneWidget);
      expect(find.textContaining('Also from'), findsNothing);
    });
  });

  group('everything around the streams is untouched', () {
    testWidgets(
      'the last-used shortcut, the empty summary and the failures, with '
      'duplicates in the list',
      (tester) async {
        useWideViewport(tester);
        final streams = [
          ...theSameReleaseTwice(),
          emptyGroup(youTubeUrl),
          failedGroup(strangerUrl),
        ];
        final core = coreWith(
          streams,
          also: {CoreField.player: loadPlayerFixture()},
          lastUsed: {
            'request': streams.first['request'],
            'content': {
              'type': 'Ready',
              'content':
                  (streams.first['content']
                      as Map<String, dynamic>)['content']![0],
            },
          },
        );
        await pumpSectioned(tester, core);

        // The shortcut is above the one remaining row, still the shortcut.
        expect(find.text('Continue with last source'), findsOneWidget);
        // The shortcut's own subtitle is the release's name too, so the
        // row proper is the last of the two.
        expect(
          topOf(tester, 'Continue with last source'),
          lessThan(
            tester.getTopLeft(find.text('The Same Release 1080p').last).dy,
          ),
        );
        // The addon that had nothing, and the one that failed, both below
        // and both counted exactly as before.
        expect(find.text('1 addon had nothing for this title'), findsOneWidget);
        expect(find.text('mirror.example'), findsOneWidget);
        expect(find.text('Failed to fetch: 404 Not Found'), findsOneWidget);
        expect(find.text('Check addon'), findsOneWidget);

        // And the shortcut is the same source as the collapsed row, so it
        // plays with the merged trackers too.
        await tester.tap(find.text('Continue with last source'));
        await tester.pumpAndSettle();
        final load = core.dispatched.firstWhere(
          (a) => a.field == CoreField.player,
        );
        final args =
            (load.action['args'] as Map<String, dynamic>)['args']
                as Map<String, dynamic>;
        expect(args['stream']['announce'], mergedTrackers);
      },
    );
  });

  group('the index itself', () {
    test('unions the trackers, first seen first, each one once', () {
      final first = StreamInfo({
        'infoHash': sharedHash,
        'announce': ['udp://one', 'udp://shared'],
      });
      final second = StreamInfo({
        'infoHash': sharedHash,
        'announce': ['udp://shared', 'udp://two', 'udp://one'],
      });
      final index = StreamSourceIndex.of([
        (addon: 'Alpha', stream: first),
        (addon: 'Beta', stream: second),
      ]);

      expect(index.merged(first).trackers, [
        'udp://one',
        'udp://shared',
        'udp://two',
      ]);
      expect(index.merged(second).trackers, index.merged(first).trackers);
      expect(index.alsoFrom('Alpha', first), ['Beta']);
      expect(index.alsoFrom('Beta', second), ['Alpha']);
    });

    test('reads the protocol\'s own `sources`, and never leaves both keys', () {
      final stream = StreamInfo({
        'infoHash': sharedHash,
        'sources': ['udp://from-sources'],
      });
      final other = StreamInfo({
        'infoHash': sharedHash,
        'announce': ['udp://from-announce'],
      });
      final index = StreamSourceIndex.of([
        (addon: 'Alpha', stream: stream),
        (addon: 'Beta', stream: other),
      ]);

      final merged = index.merged(stream);
      expect(merged.trackers, ['udp://from-sources', 'udp://from-announce']);
      // stremio-core reads `sources` as an alias of `announce`; both keys
      // at once is a duplicate field to it.
      expect(merged.json.containsKey('sources'), isFalse);
    });

    test('leaves a stream with nothing to add exactly as it was', () {
      final stream = StreamInfo({
        'infoHash': sharedHash,
        'announce': ['udp://one'],
      });
      final index = StreamSourceIndex.of([(addon: 'Alpha', stream: stream)]);

      expect(identical(index.merged(stream), stream), isTrue);
      expect(index.alsoFrom('Alpha', stream), isEmpty);
    });

    test('a source with no key of its own is never folded in', () {
      final unknown = StreamInfo({'name': 'Nothing identifies this'});
      final other = StreamInfo({'name': 'Nor this'});
      final index = StreamSourceIndex.of([
        (addon: 'Alpha', stream: unknown),
        (addon: 'Beta', stream: other),
      ]);

      expect(unknown.sourceKey, isNull);
      expect(index.alsoFrom('Alpha', unknown), isEmpty);
      expect(identical(index.merged(unknown), unknown), isTrue);
    });

    test('an info hash is one torrent however it is spelled', () {
      final upper = StreamInfo({'infoHash': sharedHash.toUpperCase()});
      final lower = StreamInfo({'infoHash': sharedHash});
      expect(upper.sourceKey, lower.sourceKey);
    });
  });
}
