import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/downloads/download_labels.dart';
import 'package:xtremio/features/player/playback_engine.dart';

import '../support/fake_core_client.dart';
import '../support/fake_downloads_client.dart';
import '../support/fake_playback_engine.dart';
import '../support/fake_torrent_stats_client.dart';
import '../support/fixtures.dart';

const movieId = 'tt0063350';
const seriesId = 'tt0903747';
const pilotId = '$seriesId:1:1';

/// The one torrent of the movie fixture (public-domain movies).
const movieHash = '11ea02584fa6351956f35671962ab46354d99060';

/// A Torrentio-style group for an episode, as the series fixture has none.
Map<String, dynamic> episodeTorrentGroup(String videoId) => {
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
        'announce': ['udp://tracker.example:1337/announce'],
      },
    ],
  },
};

/// A registry entry for [stream] of [videoId], as `downloads_list` writes
/// one. Only the fields the tile reads are filled in.
Map<String, dynamic> entry({
  required String metaId,
  required String videoId,
  required Map<String, dynamic> stream,
  required String state,
  int size = 0,
  int downloaded = 0,
}) => {
  'metaId': metaId,
  'videoId': videoId,
  'stream': stream,
  'infoHash': stream['infoHash'],
  'fileIdx': stream['fileIdx'],
  'size': size,
  'downloaded': downloaded,
  'state': state,
};

DownloadsRegistry registryOf(List<Map<String, dynamic>> entries) =>
    DownloadsRegistry(
      items: {
        for (final item in entries) DownloadView(item).key: DownloadView(item),
      },
    );

/// A client whose `add` waits, so the tile can be looked at while the pin
/// is being taken (which for a magnet means waiting on its metadata).
class GatedDownloadsClient extends FakeDownloadsClient {
  final Completer<void> gate = Completer<void>();

  @override
  Future<DownloadAddResult> add(DownloadRequest request) async {
    await gate.future;
    return super.add(request);
  }
}

void main() {
  Widget harness(
    FakeCoreClient core,
    DownloadsClient downloads, {
    String type = 'movie',
    String id = movieId,
    String? videoId,
  }) => CoreScope(
    client: core,
    child: DownloadsScope(
      client: downloads,
      child: PlaybackScope(
        createEngine: FakePlaybackEngine.new,
        torrentStats: FakeTorrentStatsClient(),
        child: MaterialApp(
          home: MetaDetailsScreen(type: type, id: id, videoId: videoId),
        ),
      ),
    ),
  );

  void useWideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// The movie fixture's meta item, as the screen hands it to the pin.
  Map<String, dynamic> movieMeta() =>
      MetaDetailsState.fromJson(loadMetaDetailsFixture()).meta!.json;

  /// The movie fixture with its library item no longer removed.
  Map<String, dynamic> inLibraryFixture() {
    final fixture = loadMetaDetailsFixture();
    (fixture['libraryItem'] as Map<String, dynamic>)['removed'] = false;
    return fixture;
  }

  /// The series fixture for S1E1 with a torrent group grafted on.
  Map<String, dynamic> episodeFixture() {
    final fixture = loadSeriesEpisodeMetaDetailsFixture();
    fixture['streams'] = [
      ...(fixture['streams'] as List<dynamic>),
      episodeTorrentGroup(pilotId),
    ];
    return fixture;
  }

  group('the download button', () {
    testWidgets('sends the pin what the play path sends the player', (
      tester,
    ) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      final downloads = FakeDownloadsClient();
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(kDownloadTooltip));
      await tester.pumpAndSettle();

      expect(downloads.added, hasLength(1));
      final request = downloads.added.single;
      expect(request.metaId, movieId);
      expect(request.videoId, movieId, reason: 'a movie is its own video');
      expect(request.key, 'tt0063350:tt0063350');
      expect(request.type, 'movie');
      expect(request.name, 'Night of the Living Dead');
      expect(request.poster, contains(movieId));
      expect(request.stream.infoHash, movieHash);
      expect(request.stream.fileIdx, 0);
      expect(request.meta, movieMeta(), reason: 'so Details renders offline');
      expect(request.streamRequest, {
        'base':
            'https://caching.stremio.net/publicdomainmovies.now.sh/'
            'manifest.json',
        'path': {
          'resource': 'stream',
          'type': 'movie',
          'id': movieId,
          'extra': <Object>[],
        },
      });
      expect(request.metaRequest, {
        'base': 'https://v3-cinemeta.strem.io/manifest.json',
        'path': {
          'resource': 'meta',
          'type': 'movie',
          'id': movieId,
          'extra': <Object>[],
        },
      });
      expect(find.text('Downloading Night of the Living Dead'), findsOneWidget);
    });

    testWidgets('an episode is pinned under its own video id and name', (
      tester,
    ) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: episodeFixture()},
      );
      final downloads = FakeDownloadsClient();
      addTearDown(downloads.dispose);
      await tester.pumpWidget(
        harness(
          core,
          downloads,
          type: 'series',
          id: seriesId,
          videoId: pilotId,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(kDownloadTooltip));
      await tester.pumpAndSettle();

      final request = downloads.added.single;
      expect(request.metaId, seriesId);
      expect(request.videoId, pilotId);
      expect(request.key, 'tt0903747:tt0903747:1:1');
      expect(request.name, 'Breaking Bad: S1E1 · Pilot');
      expect(request.streamRequest!['base'], contains('torrentio'));
    });

    testWidgets('only a torrent is offered: the server keeps nothing else', (
      tester,
    ) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      final downloads = FakeDownloadsClient();
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads));
      await tester.pumpAndSettle();

      // The fixture lists five external streams (Prime, Plex, ...) and one
      // torrent; only the torrent has a button.
      expect(find.text('Amazon Prime Video'), findsOneWidget);
      expect(find.byTooltip(kDownloadTooltip), findsOneWidget);
    });

    testWidgets('with no client above, no tile offers one', (tester) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      await tester.pumpWidget(
        CoreScope(
          client: core,
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

      expect(find.byTooltip(kDownloadTooltip), findsNothing);
      expect(find.text('1080p'), findsOneWidget, reason: 'the tile is there');
    });

    testWidgets('says it is working, and a second press does not pin twice', (
      tester,
    ) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      final downloads = GatedDownloadsClient();
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(kDownloadTooltip));
      await tester.pump();

      expect(find.byTooltip(kDownloadStartingTooltip), findsOneWidget);
      expect(find.byTooltip(kDownloadTooltip), findsNothing);

      downloads.gate.complete();
      await tester.pumpAndSettle();
      expect(downloads.added, hasLength(1));
    });
  });

  group('the library', () {
    testWidgets('gets the title, so offline progress is recorded', (
      tester,
    ) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      final downloads = FakeDownloadsClient();
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(kDownloadTooltip));
      await tester.pumpAndSettle();

      expect(
        core.dispatched.last.action,
        CoreActions.addToLibrary(movieMeta()).action,
      );
    });

    testWidgets('is left alone when the title is already in it', (
      tester,
    ) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: inLibraryFixture()},
      );
      final downloads = FakeDownloadsClient();
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads));
      await tester.pumpAndSettle();
      final before = core.dispatched.length;

      await tester.tap(find.byTooltip(kDownloadTooltip));
      await tester.pumpAndSettle();

      expect(downloads.added, hasLength(1));
      expect(core.dispatched, hasLength(before));
    });

    testWidgets('keeps nothing when the pin was refused', (tester) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      final downloads = FakeDownloadsClient()
        ..onAdd = (request) => DownloadAddResult.fromJson({
          'ok': false,
          'key': request.key,
          'error': {'kind': 'backend', 'message': 'the engine said no'},
        });
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads));
      await tester.pumpAndSettle();
      final before = core.dispatched.length;

      await tester.tap(find.byTooltip(kDownloadTooltip));
      await tester.pumpAndSettle();

      expect(core.dispatched, hasLength(before));
      expect(find.text('the engine said no'), findsOneWidget);
    });
  });

  group('a refusal', () {
    testWidgets('says how much room the download wanted', (tester) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      final downloads = FakeDownloadsClient()
        ..onAdd = (request) => DownloadAddResult.fromJson({
          'ok': false,
          'key': request.key,
          'error': {
            'kind': 'insufficientSpace',
            'required': 4000000000,
            'available': 1000000000,
            'margin': 524288000,
            'message': 'not enough free space for this download',
          },
        });
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(kDownloadTooltip));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'not enough free space for this download '
          '(needs 4.0 GB, 1.0 GB free)',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a call that threw is a sentence, not a crash', (tester) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      final downloads = FakeDownloadsClient()
        ..addError = StateError('the server is not running');
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(kDownloadTooltip));
      await tester.pumpAndSettle();

      expect(find.text('This stream could not be downloaded.'), findsOneWidget);
      expect(find.byTooltip(kDownloadTooltip), findsOneWidget);
    });
  });

  group('a stream already downloaded', () {
    Future<void> pumpWith(
      WidgetTester tester,
      String state, {
      int done = 0,
    }) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      final downloads = FakeDownloadsClient(
        registry: registryOf([
          entry(
            metaId: movieId,
            videoId: movieId,
            stream: {'infoHash': movieHash, 'fileIdx': 0},
            state: state,
            size: 1000000,
            downloaded: done,
          ),
        ]),
      );
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads));
      await tester.pumpAndSettle();
    }

    testWidgets('shows it is on the device instead of offering it', (
      tester,
    ) async {
      await pumpWith(tester, 'complete', done: 1000000);

      expect(find.byTooltip(kDownloadedTooltip), findsOneWidget);
      expect(find.byTooltip(kDownloadTooltip), findsNothing);
    });

    testWidgets('shows how far along it is while it arrives', (tester) async {
      await pumpWith(tester, 'downloading', done: 500000);

      expect(find.byTooltip('Downloading 50%'), findsOneWidget);
      final ring = tester.widget<CircularProgressIndicator>(
        find.descendant(
          of: find.byTooltip('Downloading 50%'),
          matching: find.byType(CircularProgressIndicator),
        ),
      );
      expect(ring.value, 0.5);
      expect(find.byTooltip(kDownloadTooltip), findsNothing);
    });

    testWidgets('offers to try again when it stopped', (tester) async {
      await pumpWith(tester, 'error', done: 10);

      expect(find.byTooltip(kDownloadRetryTooltip), findsOneWidget);
      await tester.tap(find.byTooltip(kDownloadRetryTooltip));
      await tester.pumpAndSettle();
      expect(find.text('Downloading Night of the Living Dead'), findsOneWidget);
    });
  });

  testWidgets('a download of another source leaves this tile offering one', (
    tester,
  ) async {
    useWideViewport(tester);
    final core = FakeCoreClient(
      state: {CoreField.metaDetails: loadMetaDetailsFixture()},
    );
    // The same movie, kept from a different release: pressing download here
    // replaces that pin, so the tile must not read as done.
    final downloads = FakeDownloadsClient(
      registry: registryOf([
        entry(
          metaId: movieId,
          videoId: movieId,
          stream: {'infoHash': 'ffff', 'fileIdx': 0},
          state: 'complete',
        ),
      ]),
    );
    addTearDown(downloads.dispose);
    await tester.pumpWidget(harness(core, downloads));
    await tester.pumpAndSettle();

    expect(find.byTooltip(kDownloadTooltip), findsOneWidget);
    expect(find.byTooltip(kDownloadedTooltip), findsNothing);
  });

  testWidgets('progress from the feed reaches the tile', (tester) async {
    useWideViewport(tester);
    final core = FakeCoreClient(
      state: {CoreField.metaDetails: loadMetaDetailsFixture()},
    );
    final downloads = FakeDownloadsClient();
    addTearDown(downloads.dispose);
    await tester.pumpWidget(harness(core, downloads));
    await tester.pumpAndSettle();

    downloads.emitEntry(
      entry(
        metaId: movieId,
        videoId: movieId,
        stream: {'infoHash': movieHash, 'fileIdx': 0},
        state: 'downloading',
        size: 4,
        downloaded: 1,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Downloading 25%'), findsOneWidget);
  });
}
