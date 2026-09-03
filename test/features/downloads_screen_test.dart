import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/downloads/downloads_screen.dart';
import 'package:xtremio/features/downloads/offline_play.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../support/fake_core_client.dart';
import '../support/fake_downloads_client.dart';
import '../support/fake_playback_engine.dart';
import '../support/fake_torrent_stats_client.dart';
import '../support/fixtures.dart';

const movieKey = 'tt0063350:tt0063350';

/// Where the recorded registry says the movie's file is, as a URL.
const movieFileUrl =
    'file:///tmp/.tmpaA6dw9/cache/server/rqbit-downloads/'
    'Night.of.the.Living.Dead.1968.1080p.BluRay/'
    'night.of.the.living.dead.1968.1080p.mkv';
const pilotKey = 'tt0903747:tt0903747:1:1';

/// The recorded registry: a finished movie, an episode two thirds in, an
/// episode with nothing yet.
DownloadsRegistry recorded() =>
    DownloadsRegistry.fromJson(loadDownloadsFixture());

/// The same, with the pilot stopped and a reason for it.
DownloadsRegistry withStoppedPilot() {
  final json = loadDownloadsFixture();
  final pilot =
      (json['items'] as Map<String, dynamic>)[pilotKey] as Map<String, dynamic>;
  pilot['state'] = 'error';
  pilot['error'] = 'this torrent is not managed right now';
  return DownloadsRegistry.fromJson(json);
}

/// A client whose `add` waits, so the row can be looked at while a retry
/// is on its way.
class GatedAddClient extends FakeDownloadsClient {
  GatedAddClient({super.registry});

  final Completer<void> gate = Completer<void>();

  @override
  Future<DownloadAddResult> add(DownloadRequest request) async {
    await gate.future;
    return super.add(request);
  }
}

/// A client whose listing waits, so the screen can be looked at before the
/// first one has landed.
class GatedListingClient extends FakeDownloadsClient {
  GatedListingClient({super.registry});

  final Completer<void> gate = Completer<void>();

  @override
  Future<DownloadsRegistry> list() async {
    await gate.future;
    return super.list();
  }
}

void main() {
  /// Everything the screen and a pushed player need above them.
  Widget harness(
    FakeCoreClient core,
    DownloadsClient downloads, {
    List<String> destinations = const [],
    FakePlaybackEngine? engine,
  }) => CoreScope(
    client: core,
    child: DownloadsScope(
      client: downloads,
      child: PlaybackScope(
        createEngine: () => engine ?? FakePlaybackEngine(),
        torrentStats: FakeTorrentStatsClient(),
        child: MaterialApp(
          home: DownloadsScreen(destinations: () async => destinations),
        ),
      ),
    ),
  );

  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  FakeCoreClient coreWithPlayer() =>
      FakeCoreClient(state: {CoreField.player: loadPlayerFixture()});

  Map<String, dynamic> loadArgs(CoreAction action) =>
      (action.action['args'] as Map<String, dynamic>)['args']
          as Map<String, dynamic>;

  group('the list', () {
    testWidgets('shows every download, newest first, with its progress', (
      tester,
    ) async {
      useTallViewport(tester);
      final downloads = FakeDownloadsClient(registry: recorded());
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(coreWithPlayer(), downloads));
      await tester.pumpAndSettle();

      expect(find.text('Night of the Living Dead'), findsOneWidget);
      expect(find.text('Breaking Bad: Pilot'), findsOneWidget);
      expect(find.text("Breaking Bad: Cat's in the Bag..."), findsOneWidget);
      expect(find.text('Downloaded · 32.8 kB'), findsOneWidget);
      expect(find.text('Downloading 67% · 32.8 kB of 49.2 kB'), findsOneWidget);
      expect(find.text('Downloading 0% · 0 B of 32.8 kB'), findsOneWidget);

      final bars = tester
          .widgetList<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          )
          .toList();
      expect(bars.map((bar) => bar.value), [0, closeTo(2 / 3, 0.01), 1]);
    });

    testWidgets('the header adds up what is on the device', (tester) async {
      useTallViewport(tester);
      final downloads = FakeDownloadsClient(registry: recorded());
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(coreWithPlayer(), downloads));
      await tester.pumpAndSettle();

      expect(find.text('3 downloads · 65.5 kB on this device'), findsOneWidget);
      expect(DownloadsScreen.storageUsed(recorded()), 65536);
    });

    test('one file under two titles takes the room of one', () {
      // The same torrent file offered by two addons under two ids: two
      // rows, one file on the disk.
      DownloadView shared(String metaId) => DownloadView({
        'metaId': metaId,
        'videoId': metaId,
        'infoHash': 'abcdabcdabcdabcdabcd',
        'fileIdx': 2,
        'size': 4000,
        'downloaded': 4000,
        'state': 'complete',
      });
      final registry = DownloadsRegistry(
        items: {
          for (final view in [shared('tt1'), shared('kitsu:1')]) view.key: view,
        },
      );

      expect(registry.length, 2);
      expect(DownloadsScreen.storageUsed(registry), 4000);
    });

    testWidgets('an empty list says how to fill it', (tester) async {
      useTallViewport(tester);
      final downloads = FakeDownloadsClient();
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(coreWithPlayer(), downloads));
      await tester.pumpAndSettle();

      expect(find.text('Nothing downloaded'), findsOneWidget);
      expect(find.text('1 download · 0 B on this device'), findsNothing);
      expect(find.text('0 downloads · 0 B on this device'), findsOneWidget);
    });

    testWidgets('a listing that failed says so, and retries', (tester) async {
      useTallViewport(tester);
      // A broken bridge: the registry is on disk, the app just cannot read
      // it. Telling the user nothing is downloaded would be a lie.
      final downloads = FakeDownloadsClient(registry: recorded())
        ..listError = StateError('the bridge is gone');
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(coreWithPlayer(), downloads));
      await tester.pumpAndSettle();

      expect(find.text('Downloads could not be read'), findsOneWidget);
      expect(find.text('Nothing downloaded'), findsNothing);
      // The header counts a listing, and there is none: three downloads
      // are on the disk, so "0 downloads · 0 B" would be the same lie.
      expect(find.text('0 downloads · 0 B on this device'), findsNothing);
      expect(find.text('Not known right now'), findsOneWidget);

      downloads.listError = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(find.text('Downloads could not be read'), findsNothing);
      expect(find.text('Night of the Living Dead'), findsOneWidget);
      expect(find.text('3 downloads · 65.5 kB on this device'), findsOneWidget);
    });

    testWidgets('the header counts nothing before the first listing', (
      tester,
    ) async {
      useTallViewport(tester);
      final downloads = GatedListingClient(registry: recorded());
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(coreWithPlayer(), downloads));
      await tester.pump();

      expect(find.text('0 downloads · 0 B on this device'), findsNothing);
      expect(find.text('…'), findsOneWidget);

      downloads.gate.complete();
      await tester.pumpAndSettle();

      expect(find.text('3 downloads · 65.5 kB on this device'), findsOneWidget);
    });

    testWidgets('progress from the feed moves a row', (tester) async {
      useTallViewport(tester);
      final downloads = FakeDownloadsClient(registry: recorded());
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(coreWithPlayer(), downloads));
      await tester.pumpAndSettle();

      final pilot = {...recorded()[pilotKey]!.json};
      downloads.emitEntry({...pilot, 'downloaded': 49152, 'state': 'complete'});
      await tester.pumpAndSettle();

      expect(find.text('Downloaded · 49.2 kB'), findsOneWidget);
      expect(find.text('3 downloads · 81.9 kB on this device'), findsOneWidget);
    });
  });

  group('the actions', () {
    testWidgets('play is offered on a finished download only', (tester) async {
      useTallViewport(tester);
      final downloads = FakeDownloadsClient(registry: recorded());
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(coreWithPlayer(), downloads));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Download actions').first);
      await tester.pumpAndSettle();
      expect(find.text('Play'), findsNothing, reason: 'the newest is not done');
      expect(find.text('Delete'), findsOneWidget);

      await tester.tap(find.text('Delete').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Download actions').last);
      await tester.pumpAndSettle();
      expect(find.text('Play'), findsOneWidget);
    });

    testWidgets('play opens the file on the device, not the server', (
      tester,
    ) async {
      useTallViewport(tester);
      final core = coreWithPlayer();
      final downloads = FakeDownloadsClient(registry: recorded());
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Night of the Living Dead'));
      await tester.pumpAndSettle();

      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(downloads.opens, [movieKey]);
      final args = loadArgs(
        core.dispatched.firstWhere((a) => a.field == CoreField.player),
      );
      // A `url` stream on the file itself: no torrent for the player to
      // wait on, and nothing for the embedded server to serve.
      expect(args['stream'], {
        'url': movieFileUrl,
        'name': 'Torrent',
        'description': '1080p BluRay\n\u{1F464} 12 \u{1F4BE} 1.4 GB',
        'behaviorHints': {
          'filename': 'night.of.the.living.dead.1968.1080p.mkv',
          // Kept so the core can still binge-match the next episode.
          'bingeGroup': 'pdm-1080p',
        },
      }, reason: 'the addon labels are kept; the torrent coordinates are not');
      // The addon requests it was downloaded with, which are what keep
      // continue-watching moving while it plays offline.
      expect(
        args['streamRequest']['base'],
        'https://public-domain-movies.now.sh/manifest.json',
      );
      expect(args['metaRequest']['base'], kCinemetaManifestUrl);
      expect(args['subtitlesPath'], {
        'resource': 'subtitles',
        'type': 'movie',
        'id': 'tt0063350',
        'extra': <Object>[],
      });
    });

    testWidgets('a download whose file went away streams it, and says so', (
      tester,
    ) async {
      useTallViewport(tester);
      final core = coreWithPlayer();
      final downloads = FakeDownloadsClient(registry: recorded())
        ..onOpen = (_) => const DownloadOpenResult(
          ok: false,
          reason: DownloadOpenFailure.missing,
        );
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(core, downloads));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Night of the Living Dead'));
      await tester.pump();

      expect(find.text(kDownloadGoneMessage), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byType(PlayerScreen), findsOneWidget);
      final args = loadArgs(
        core.dispatched.firstWhere((a) => a.field == CoreField.player),
      );
      expect(
        args['stream']['infoHash'],
        'bbdd47be75282ea36cddf7a48ba5a73e667e57bb',
        reason: 'the addon stream is played instead of a dead file URL',
      );
    });

    testWidgets('retry is offered on a stopped one, and pins it again', (
      tester,
    ) async {
      useTallViewport(tester);
      final downloads = FakeDownloadsClient(registry: withStoppedPilot());
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(coreWithPlayer(), downloads));
      await tester.pumpAndSettle();

      expect(
        find.text('Stopped · this torrent is not managed right now'),
        findsOneWidget,
      );

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Breaking Bad: Pilot'),
          matching: find.byTooltip('Download actions'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry').hitTestable());
      await tester.pumpAndSettle();

      expect(downloads.added, hasLength(1));
      final request = downloads.added.single;
      expect(request.key, pilotKey);
      expect(
        request.stream.infoHash,
        '3890a4775f6c2375f9987aeddd03c01f72cecbbf',
      );
      expect(
        request.fileIdx,
        1,
        reason: 'the file already half on disk, not another guess',
      );
      expect(find.text('Downloading Breaking Bad: Pilot'), findsOneWidget);
    });

    testWidgets('a retry in flight is not offered a second time', (
      tester,
    ) async {
      useTallViewport(tester);
      // Re-pinning a magnet blocks on its metadata, and the row still
      // reads "Stopped" until the listing lands: a second press would burn
      // another worker on the same file.
      final downloads = GatedAddClient(registry: withStoppedPilot());
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(coreWithPlayer(), downloads));
      await tester.pumpAndSettle();

      Future<void> openMenu() async {
        await tester.tap(
          find.descendant(
            of: find.widgetWithText(ListTile, 'Breaking Bad: Pilot'),
            matching: find.byTooltip('Download actions'),
          ),
        );
        await tester.pumpAndSettle();
      }

      await openMenu();
      await tester.tap(find.text('Retry').hitTestable());
      await tester.pump();

      await openMenu();
      expect(find.text('Retry'), findsNothing);
      await tester.tap(find.text('Retrying…').hitTestable());
      await tester.pump();
      // The disabled item does not even close the menu, so dismiss it.
      await tester.tapAt(const Offset(5, 5));
      await tester.pump();

      downloads.gate.complete();
      await tester.pumpAndSettle();
      expect(downloads.added, hasLength(1));
    });

    testWidgets('a retry the server refuses says why', (tester) async {
      useTallViewport(tester);
      final downloads = FakeDownloadsClient(registry: withStoppedPilot())
        ..onAdd = (request) => DownloadAddResult.fromJson({
          'ok': false,
          'key': request.key,
          'error': {
            'kind': 'insufficientSpace',
            'required': 4000000000,
            'available': 1000000000,
            'message': 'not enough free space for this download',
          },
        });
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(coreWithPlayer(), downloads));
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Breaking Bad: Pilot'),
          matching: find.byTooltip('Download actions'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry').hitTestable());
      await tester.pumpAndSettle();

      expect(
        find.text(
          'not enough free space for this download '
          '(needs 4.0 GB, 1.0 GB free)',
        ),
        findsOneWidget,
      );
    });
  });

  group('deleting', () {
    Future<void> openDelete(WidgetTester tester) async {
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Night of the Living Dead'),
          matching: find.byTooltip('Download actions'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').hitTestable());
      await tester.pumpAndSettle();
    }

    testWidgets('asks first, and cancelling changes nothing', (tester) async {
      useTallViewport(tester);
      final downloads = FakeDownloadsClient(registry: recorded());
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(coreWithPlayer(), downloads));
      await tester.pumpAndSettle();

      await openDelete(tester);
      expect(find.text('Remove Night of the Living Dead?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(downloads.removed, isEmpty);
      expect(find.text('Night of the Living Dead'), findsOneWidget);
    });

    testWidgets('keeping the file drops the pin only', (tester) async {
      useTallViewport(tester);
      final downloads = FakeDownloadsClient(registry: recorded());
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(coreWithPlayer(), downloads));
      await tester.pumpAndSettle();

      await openDelete(tester);
      await tester.tap(find.text('Keep the file'));
      await tester.pumpAndSettle();

      expect(downloads.removed, [(key: movieKey, deleteFiles: false)]);
      expect(
        find.text('Removed Night of the Living Dead from downloads.'),
        findsOneWidget,
      );
      expect(find.text('2 downloads · 32.8 kB on this device'), findsOneWidget);
    });

    testWidgets('deleting the file takes the bytes too', (tester) async {
      useTallViewport(tester);
      final downloads = FakeDownloadsClient(registry: recorded());
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(coreWithPlayer(), downloads));
      await tester.pumpAndSettle();

      await openDelete(tester);
      await tester.tap(find.text('Delete the file'));
      await tester.pumpAndSettle();

      expect(downloads.removed, [(key: movieKey, deleteFiles: true)]);
      expect(find.text('Deleted Night of the Living Dead.'), findsOneWidget);
    });

    testWidgets('a file another download uses stays, and says so', (
      tester,
    ) async {
      useTallViewport(tester);
      final downloads = FakeDownloadsClient(registry: recorded())
        ..onRemove = (key, deleteFiles) => const DownloadRemoveResult(
          removed: true,
          unpinned: false,
          deletedFiles: false,
        );
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(coreWithPlayer(), downloads));
      await tester.pumpAndSettle();

      await openDelete(tester);
      await tester.tap(find.text('Delete the file'));
      await tester.pumpAndSettle();

      expect(
        find.text('Removed. The file stays: another download uses it.'),
        findsOneWidget,
      );
    });

    testWidgets('a removal that threw is a sentence, not a crash', (
      tester,
    ) async {
      useTallViewport(tester);
      final downloads = FakeDownloadsClient(registry: recorded())
        ..removeError = StateError('the server is not running');
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(coreWithPlayer(), downloads));
      await tester.pumpAndSettle();

      await openDelete(tester);
      await tester.tap(find.text('Delete the file'));
      await tester.pumpAndSettle();

      expect(find.text('This download could not be removed.'), findsOneWidget);
    });
  });

  group('where downloads go', () {
    testWidgets('shows what the server says, and picks from what the '
        'platform offers', (tester) async {
      useTallViewport(tester);
      final downloads = FakeDownloadsClient()
        ..settings = const {'downloadsDir': '/storage/emulated/0/downloads'};
      addTearDown(downloads.dispose);
      await tester.pumpWidget(
        harness(
          coreWithPlayer(),
          downloads,
          destinations: const [
            '/storage/emulated/0/downloads',
            '/storage/ABCD-1234/downloads',
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('/storage/emulated/0/downloads'), findsOneWidget);

      await tester.tap(find.byTooltip(DownloadsScreen.destinationTitle));
      await tester.pumpAndSettle();
      await tester.tap(find.text('/storage/ABCD-1234/downloads').last);
      await tester.pumpAndSettle();

      expect(downloads.directories, ['/storage/ABCD-1234/downloads']);
      expect(find.text('/storage/ABCD-1234/downloads'), findsOneWidget);
    });

    testWidgets('the default puts them back with the cache', (tester) async {
      useTallViewport(tester);
      final downloads = FakeDownloadsClient()
        ..settings = const {'downloadsDir': '/storage/emulated/0/downloads'};
      addTearDown(downloads.dispose);
      await tester.pumpWidget(
        harness(
          coreWithPlayer(),
          downloads,
          destinations: const ['/storage/emulated/0/downloads'],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(DownloadsScreen.destinationTitle));
      await tester.pumpAndSettle();
      await tester.tap(find.text(DownloadsScreen.defaultDestinationLabel));
      await tester.pumpAndSettle();

      expect(downloads.directories, [null]);
      expect(
        find.text(DownloadsScreen.defaultDestinationLabel),
        findsOneWidget,
      );
    });

    testWidgets('with nothing to choose between, a path is typed', (
      tester,
    ) async {
      useTallViewport(tester);
      final downloads = FakeDownloadsClient();
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(coreWithPlayer(), downloads));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), '/media/downloads');
      await tester.tap(find.text('Use this folder'));
      await tester.pumpAndSettle();

      expect(downloads.directories, ['/media/downloads']);
      expect(find.text('Downloads go to /media/downloads.'), findsOneWidget);

      await tester.tap(find.text('Use the default'));
      await tester.pumpAndSettle();
      expect(downloads.directories, ['/media/downloads', null]);
    });

    testWidgets('a folder the server refuses says so', (tester) async {
      useTallViewport(tester);
      final downloads = FakeDownloadsClient()
        ..setDirectoryError = StateError('not writable');
      addTearDown(downloads.dispose);
      await tester.pumpWidget(harness(coreWithPlayer(), downloads));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '/root/nope');
      await tester.tap(find.text('Use this folder'));
      await tester.pumpAndSettle();

      expect(
        find.text('That folder cannot be used for downloads.'),
        findsOneWidget,
      );
    });
  });
}
