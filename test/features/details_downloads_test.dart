import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/downloads/download_labels.dart';
import 'package:xtremio/features/downloads/offline_play.dart';
import 'package:xtremio/features/downloads/remove_download_dialog.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/widgets/download_badge.dart';

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

/// A client whose `open` waits, so the tile can be tapped again while the
/// registry round trip that stands between the tap and the player is still
/// out.
class GatedOpenClient extends FakeDownloadsClient {
  GatedOpenClient({super.registry});

  final Completer<void> gate = Completer<void>();

  @override
  Future<DownloadOpenResult> open(String key) async {
    await gate.future;
    return super.open(key);
  }
}

/// A registry entry for [stream] of [videoId], as `downloads_list` writes
/// one. Only the fields the tile reads are filled in.
Map<String, dynamic> entry({
  required String metaId,
  required String videoId,
  required Map<String, dynamic> stream,
  required String state,
  String name = '',
  int size = 0,
  int downloaded = 0,
  String? path,
}) => {
  'metaId': metaId,
  'videoId': videoId,
  'name': name,
  'stream': stream,
  'infoHash': stream['infoHash'],
  'fileIdx': stream['fileIdx'],
  'size': size,
  'downloaded': downloaded,
  'state': state,
  'path': path,
};

/// The affordance with [tooltip] on the movie's torrent stream tile. The
/// header shows the same states, so a bare tooltip finder matches twice.
Finder onStreamTile(String tooltip) => find.descendant(
  of: find.widgetWithText(ListTile, '1080p'),
  matching: find.byTooltip(tooltip),
);

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

/// A client whose *listing* waits, once a pin has been taken, so the tile
/// can be looked at in the window between the pin landing and the registry
/// catching up with it.
class GatedListingClient extends FakeDownloadsClient {
  final Completer<void> gate = Completer<void>();
  bool _pinned = false;

  @override
  Future<DownloadAddResult> add(DownloadRequest request) async {
    final result = await super.add(request);
    _pinned = true;
    return result;
  }

  @override
  Future<DownloadsRegistry> list() async {
    if (_pinned) await gate.future;
    return super.list();
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

  /// The width the screens are actually used at.
  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(360, 800);
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

    testWidgets('the tile stays busy until the listing has the pin', (
      tester,
    ) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      final downloads = GatedListingClient();
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(kDownloadTooltip));
      // The pin is taken; the listing that would put the entry on the tile
      // is still out.
      await tester.pump();
      await tester.pump();

      expect(
        find.byTooltip(kDownloadTooltip),
        findsNothing,
        reason: 'the tile would take a second press for the same pin',
      );
      expect(find.byTooltip(kDownloadStartingTooltip), findsOneWidget);

      downloads.gate.complete();
      await tester.pumpAndSettle();
      expect(onStreamTile('Waiting to start'), findsOneWidget);
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
    Future<FakeDownloadsClient> pumpWith(
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
            name: 'Night of the Living Dead',
            size: 1000000,
            downloaded: done,
          ),
        ]),
      );
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads));
      await tester.pumpAndSettle();
      return downloads;
    }

    testWidgets('offers to delete it instead of offering to download it', (
      tester,
    ) async {
      await pumpWith(tester, 'complete', done: 1000000);

      expect(onStreamTile(kDownloadDeleteTooltip), findsOneWidget);
      expect(find.byTooltip(kDownloadTooltip), findsNothing);
      // A tick said the same thing and did nothing; this is pressable.
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: onStreamTile(kDownloadDeleteTooltip),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('deleting from the tile keeps the file when asked to', (
      tester,
    ) async {
      final downloads = await pumpWith(tester, 'complete', done: 1000000);

      await tester.tap(onStreamTile(kDownloadDeleteTooltip));
      await tester.pumpAndSettle();
      expect(find.text('Remove Night of the Living Dead?'), findsOneWidget);
      await tester.tap(find.text(RemoveDownloadDialog.keepLabel));
      await tester.pumpAndSettle();

      expect(downloads.removed, [
        (key: '$movieId:$movieId', deleteFiles: false),
      ]);
      expect(
        find.text('Removed Night of the Living Dead from downloads.'),
        findsOneWidget,
      );
      // The registry no longer has it, so the tile offers a download again.
      expect(onStreamTile(kDownloadTooltip), findsOneWidget);
    });

    testWidgets('deleting from the tile takes the bytes when asked to', (
      tester,
    ) async {
      final downloads = await pumpWith(tester, 'complete', done: 1000000);

      await tester.tap(onStreamTile(kDownloadDeleteTooltip));
      await tester.pumpAndSettle();
      await tester.tap(find.text(RemoveDownloadDialog.deleteLabel));
      await tester.pumpAndSettle();

      expect(downloads.removed, [
        (key: '$movieId:$movieId', deleteFiles: true),
      ]);
      expect(find.text('Deleted Night of the Living Dead.'), findsOneWidget);
    });

    testWidgets('a dismissed question removes nothing', (tester) async {
      final downloads = await pumpWith(tester, 'complete', done: 1000000);

      await tester.tap(onStreamTile(kDownloadDeleteTooltip));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(downloads.removed, isEmpty);
      expect(onStreamTile(kDownloadDeleteTooltip), findsOneWidget);
    });

    testWidgets('a removal that threw is a sentence, not a crash', (
      tester,
    ) async {
      final downloads = await pumpWith(tester, 'complete', done: 1000000);
      downloads.removeError = StateError('the server is not running');

      await tester.tap(onStreamTile(kDownloadDeleteTooltip));
      await tester.pumpAndSettle();
      await tester.tap(find.text(RemoveDownloadDialog.deleteLabel));
      await tester.pumpAndSettle();

      expect(find.text('This download could not be removed.'), findsOneWidget);
      expect(onStreamTile(kDownloadDeleteTooltip), findsOneWidget);
    });

    testWidgets('shows how far along it is while it arrives', (tester) async {
      await pumpWith(tester, 'downloading', done: 500000);

      expect(onStreamTile('Downloading 50%'), findsOneWidget);
      final ring = tester.widget<CircularProgressIndicator>(
        find.descendant(
          of: onStreamTile('Downloading 50%'),
          matching: find.byType(CircularProgressIndicator),
        ),
      );
      expect(ring.value, 0.5);
      expect(find.byTooltip(kDownloadTooltip), findsNothing);
    });

    testWidgets('offers to try again when it stopped', (tester) async {
      await pumpWith(tester, 'error', done: 10);

      expect(onStreamTile(kDownloadRetryTooltip), findsOneWidget);
      await tester.tap(find.byTooltip(kDownloadRetryTooltip));
      await tester.pumpAndSettle();
      expect(find.text('Downloading Night of the Living Dead'), findsOneWidget);
    });
  });

  group('badges', () {
    testWidgets('an episode kept on the device says so on its tile', (
      tester,
    ) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadSeriesEpisodeMetaDetailsFixture()},
      );
      final downloads = FakeDownloadsClient(
        registry: registryOf([
          entry(
            metaId: seriesId,
            videoId: pilotId,
            stream: {'infoHash': 'aaaa', 'fileIdx': 3},
            state: 'complete',
            size: 10,
            downloaded: 10,
          ),
        ]),
      );
      addTearDown(downloads.dispose);
      await tester.pumpWidget(
        harness(core, downloads, type: 'series', id: seriesId),
      );
      await tester.pumpAndSettle();

      final badge = find.byType(DownloadBadge);
      expect(badge, findsOneWidget);
      expect(
        find.ancestor(of: badge, matching: find.byType(ListTile)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.ancestor(of: badge, matching: find.byType(ListTile)),
          matching: find.text('Pilot'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the header counts what of a series is kept', (tester) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadSeriesEpisodeMetaDetailsFixture()},
      );
      final downloads = FakeDownloadsClient(
        registry: registryOf([
          entry(
            metaId: seriesId,
            videoId: pilotId,
            stream: {'infoHash': 'aaaa', 'fileIdx': 3},
            state: 'complete',
            size: 10,
            downloaded: 10,
          ),
          entry(
            metaId: seriesId,
            videoId: '$seriesId:1:2',
            stream: {'infoHash': 'aaaa', 'fileIdx': 4},
            state: 'downloading',
            size: 10,
            downloaded: 5,
          ),
        ]),
      );
      addTearDown(downloads.dispose);
      await tester.pumpWidget(
        harness(core, downloads, type: 'series', id: seriesId),
      );
      await tester.pumpAndSettle();

      expect(find.text('1 downloaded · 1 downloading'), findsOneWidget);
    });

    testWidgets('the longest header count still fits a phone', (tester) async {
      usePhoneViewport(tester);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadSeriesEpisodeMetaDetailsFixture()},
      );
      // All three states at once, which is the longest line the summary can
      // build; on a phone the header column is narrower than it is wide.
      final downloads = FakeDownloadsClient(
        registry: registryOf([
          for (final (episode, state) in const [
            (1, 'complete'),
            (2, 'complete'),
            (3, 'complete'),
            (4, 'downloading'),
            (5, 'queued'),
            (6, 'error'),
          ])
            entry(
              metaId: seriesId,
              videoId: '$seriesId:1:$episode',
              stream: {'infoHash': 'aaaa', 'fileIdx': episode},
              state: state,
              size: 10,
              downloaded: state == 'complete' ? 10 : 5,
            ),
        ]),
      );
      addTearDown(downloads.dispose);
      await tester.pumpWidget(
        harness(core, downloads, type: 'series', id: seriesId),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: 'the header overflowed');
      expect(
        find.text('3 downloaded · 2 downloading · 1 stopped'),
        findsOneWidget,
      );
    });

    testWidgets('a movie header says the state of the one download', (
      tester,
    ) async {
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
            state: 'downloading',
            size: 4,
            downloaded: 3,
          ),
        ]),
      );
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads));
      await tester.pumpAndSettle();

      expect(find.text('Downloading 75%'), findsOneWidget);
    });

    testWidgets('nothing downloaded puts nothing in the header', (
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

      expect(find.byType(DownloadSummary), findsNothing);
    });

    test('the summary line counts by state', () {
      DownloadView view(String videoId, String state) => DownloadView(
        entry(
          metaId: seriesId,
          videoId: videoId,
          stream: const {'infoHash': 'aaaa'},
          state: state,
        ),
      );

      expect(DownloadSummary.label(const [], metaId: seriesId), isNull);
      expect(
        DownloadSummary.label([view(seriesId, 'complete')], metaId: seriesId),
        'Downloaded',
        reason: 'the title itself is a movie, not a count of one',
      );
      expect(
        DownloadSummary.label([
          view('$seriesId:1:1', 'complete'),
          view('$seriesId:1:2', 'queued'),
          view('$seriesId:1:3', 'error'),
        ], metaId: seriesId),
        '1 downloaded · 1 downloading · 1 stopped',
      );
    });
  });

  group('a download of the same video from another source', () {
    /// The movie kept from a different release, at [state].
    FakeDownloadsClient keptElsewhere(String state) => FakeDownloadsClient(
      registry: registryOf([
        entry(
          metaId: movieId,
          videoId: movieId,
          stream: {'infoHash': 'ffff', 'fileIdx': 0},
          state: state,
          name: 'Night of the Living Dead',
          size: 4200000000,
          downloaded: state == 'complete' ? 4200000000 : 1000000,
        ),
      ]),
    );

    testWidgets('leaves this tile offering one, marked as a replacement', (
      tester,
    ) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      // Pressing download here replaces that pin, so the tile must neither
      // read as done nor as an ordinary first download.
      final downloads = keptElsewhere('complete');
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads));
      await tester.pumpAndSettle();

      expect(onStreamTile(kDownloadDeleteTooltip), findsNothing);
      expect(onStreamTile(kDownloadTooltip), findsNothing);
      expect(onStreamTile(kDownloadReplaceTooltip), findsOneWidget);
    });

    testWidgets('asks before deleting the finished copy, and cancels', (
      tester,
    ) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      final downloads = keptElsewhere('complete');
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads));
      await tester.pumpAndSettle();

      await tester.tap(onStreamTile(kDownloadReplaceTooltip));
      await tester.pumpAndSettle();

      expect(find.text('Replace Night of the Living Dead?'), findsOneWidget);
      expect(find.textContaining('4.2 GB'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(downloads.added, isEmpty, reason: 'nothing was deleted');
      expect(onStreamTile(kDownloadReplaceTooltip), findsOneWidget);
    });

    testWidgets('pins once the replacement is confirmed', (tester) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      final downloads = keptElsewhere('complete');
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads));
      await tester.pumpAndSettle();

      await tester.tap(onStreamTile(kDownloadReplaceTooltip));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Replace it'));
      await tester.pumpAndSettle();

      expect(downloads.added.single.stream.infoHash, movieHash);
      expect(find.text('Downloading Night of the Living Dead'), findsOneWidget);
    });

    testWidgets('an unfinished one is replaced without a question', (
      tester,
    ) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      // There is no whole file to lose, so asking would be noise.
      final downloads = keptElsewhere('downloading');
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads));
      await tester.pumpAndSettle();

      await tester.tap(onStreamTile(kDownloadReplaceTooltip));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(downloads.added, hasLength(1));
    });
  });

  group('playing what is kept', () {
    const movieKey = '$movieId:$movieId';
    const path = '/downloads/abc/Night of the Living Dead.mkv';
    const fileUrl =
        'file:///downloads/abc/Night%20of%20the%20Living%20Dead.mkv';

    /// The stream tile of the movie fixture's one torrent.
    final tile = find.widgetWithText(ListTile, '1080p');

    /// The `Load Player` args of the pushed player.
    Map<String, dynamic> loadArgs(FakeCoreClient core) =>
        (core.dispatched
                    .firstWhere((a) => a.field == CoreField.player)
                    .action['args']
                as Map<String, dynamic>)['args']
            as Map<String, dynamic>;

    /// The screen with a finished download of [stream] for the movie.
    Future<(FakeCoreClient, FakeDownloadsClient)> pumpWithDownload(
      WidgetTester tester, {
      Map<String, dynamic> stream = const {
        'infoHash': movieHash,
        'fileIdx': 0,
        'name': '1080p',
      },
    }) async {
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {
          CoreField.metaDetails: loadMetaDetailsFixture(),
          CoreField.player: loadPlayerFixture(),
        },
      );
      final downloads = FakeDownloadsClient(
        registry: registryOf([
          entry(
            metaId: movieId,
            videoId: movieId,
            stream: stream,
            state: 'complete',
            size: 1000,
            downloaded: 1000,
            path: path,
          ),
        ]),
      );
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads));
      await tester.pumpAndSettle();
      return (core, downloads);
    }

    testWidgets('a finished download of this release plays off the disk', (
      tester,
    ) async {
      final (core, downloads) = await pumpWithDownload(tester);

      await tester.tap(tile);
      await tester.pumpAndSettle();

      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(downloads.opens, [movieKey]);
      final args = loadArgs(core);
      expect(args['stream'], {
        'url': fileUrl,
        'name': '1080p',
        'behaviorHints': {'filename': 'Night of the Living Dead.mkv'},
      });
      // The addon requests are still the picker's, which is what lets the
      // core record progress against the library item while offline.
      expect(
        args['streamRequest']['base'],
        'https://caching.stremio.net/publicdomainmovies.now.sh/manifest.json',
      );
      expect(args['metaRequest']['base'], kCinemetaManifestUrl);
      expect(args['subtitlesPath']['id'], movieId);
    });

    testWidgets('a second tap while the file is looked up is dropped', (
      tester,
    ) async {
      // `downloads_open` is a round trip, and the tile stays hit-testable
      // for as long as it is out. Two players would each load the shared
      // `player` field and start an engine of their own.
      useWideViewport(tester);
      final core = FakeCoreClient(
        state: {
          CoreField.metaDetails: loadMetaDetailsFixture(),
          CoreField.player: loadPlayerFixture(),
        },
      );
      final downloads = GatedOpenClient(
        registry: registryOf([
          entry(
            metaId: movieId,
            videoId: movieId,
            stream: const {'infoHash': movieHash, 'fileIdx': 0},
            state: 'complete',
            size: 1000,
            downloaded: 1000,
            path: path,
          ),
        ]),
      );
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads));
      await tester.pumpAndSettle();

      await tester.tap(tile);
      await tester.pump();
      await tester.tap(tile);
      await tester.pump();
      downloads.gate.complete();
      await tester.pumpAndSettle();

      expect(downloads.opens, ['$movieId:$movieId'], reason: 'one lookup');
      expect(
        find.byType(PlayerScreen),
        findsOneWidget,
        reason: 'one player route, so one engine',
      );
    });

    testWidgets('a tap on another release plays that release', (tester) async {
      // The video is kept, but from a different torrent: picking this tile
      // is a request for *this* source, not for the copy on the disk.
      final (core, downloads) = await pumpWithDownload(
        tester,
        stream: const {
          'infoHash': 'ffffffffffffffffffffffffffffffffffffffff',
          'fileIdx': 0,
        },
      );

      await tester.tap(tile);
      await tester.pumpAndSettle();

      expect(downloads.opens, isEmpty);
      expect(loadArgs(core)['stream']['infoHash'], movieHash);
    });

    testWidgets('a download whose file went away streams it, and says so', (
      tester,
    ) async {
      final (core, downloads) = await pumpWithDownload(tester);
      downloads.onOpen = (_) => const DownloadOpenResult(
        ok: false,
        reason: DownloadOpenFailure.missing,
      );

      await tester.tap(tile);
      await tester.pump();

      expect(find.text(kDownloadGoneMessage), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(loadArgs(core)['stream']['infoHash'], movieHash);
    });
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

    expect(onStreamTile('Downloading 25%'), findsOneWidget);
  });
}
