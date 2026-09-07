import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/player/playback_engine.dart';

import '../support/fake_core_client.dart';
import '../support/fake_downloads_client.dart';
import '../support/fake_playback_engine.dart';
import '../support/fake_torrent_stats_client.dart';
import '../support/fixtures.dart';

/// The details screen's sources list is derived from every stream with a
/// handful of regexes, a sort and a sectioning. That is paid once per
/// change to what it is derived from, and not on the rebuilds the screen
/// gets for other reasons -- above all the download ticker, which moves a
/// row's numbers once a second for as long as anything is downloading.
const movieId = 'tt0063350';

/// The one torrent of the movie fixture (public-domain movies).
const movieHash = '11ea02584fa6351956f35671962ab46354d99060';

/// Another title, downloading at the same time.
const otherId = 'tt0000001';

Map<String, dynamic> entry({
  required String metaId,
  required String infoHash,
  required int downloaded,
}) => {
  'metaId': metaId,
  'videoId': metaId,
  'name': metaId,
  'stream': {'infoHash': infoHash, 'fileIdx': 0},
  'infoHash': infoHash,
  'fileIdx': 0,
  'size': 4,
  'downloaded': downloaded,
  'state': 'downloading',
};

DownloadsRegistry registryOf(List<Map<String, dynamic>> entries) =>
    DownloadsRegistry(
      items: {
        for (final item in entries) DownloadView(item).key: DownloadView(item),
      },
    );

/// The ticker's row for [metaId]: the numbers, not the entry.
Map<String, dynamic> tick(String metaId, int downloaded) => {
  'key': '$metaId:$metaId',
  'downloaded': downloaded,
  'size': 4,
  'state': 'downloading',
};

void main() {
  Widget harness(
    FakeCoreClient core,
    FakeDownloadsClient downloads,
    AppPrefs prefs,
  ) => CoreScope(
    client: core,
    child: DownloadsScope(
      client: downloads,
      child: PlaybackScope(
        createEngine: FakePlaybackEngine.new,
        torrentStats: FakeTorrentStatsClient(),
        child: PrefsScope(
          prefs: prefs,
          child: const MaterialApp(
            home: MetaDetailsScreen(type: 'movie', id: movieId),
          ),
        ),
      ),
    ),
  );

  void useWideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// The screen with the movie downloading at 1 of 4, and [others] too.
  Future<(FakeCoreClient, FakeDownloadsClient, AppPrefs)> pumpDownloading(
    WidgetTester tester, {
    List<Map<String, dynamic>> others = const [],
  }) async {
    useWideViewport(tester);
    final core = FakeCoreClient(
      state: {
        CoreField.metaDetails: loadMetaDetailsFixture(),
        CoreField.ctx: loadFixture('ctx_logged_out.json'),
      },
    );
    final downloads = FakeDownloadsClient(
      registry: registryOf([
        entry(metaId: movieId, infoHash: movieHash, downloaded: 1),
        ...others,
      ]),
    );
    addTearDown(downloads.dispose);
    final prefs = AppPrefs.inMemory();
    addTearDown(prefs.dispose);
    await tester.pumpWidget(harness(core, downloads, prefs));
    await tester.pumpAndSettle();
    expect(find.text('Downloading 25%'), findsOneWidget);
    return (core, downloads, prefs);
  }

  testWidgets(
    'a progress tick redraws the numbers without deriving the sources again',
    (tester) async {
      final (_, downloads, _) = await pumpDownloading(tester);
      final derivations = MetaDetailsScreen.debugStreamDerivations;

      for (final done in [2, 3]) {
        downloads.emitProgress([tick(movieId, done)]);
        await tester.pumpAndSettle();
      }

      expect(find.text('Downloading 75%'), findsOneWidget, reason: 'drawn');
      expect(
        MetaDetailsScreen.debugStreamDerivations,
        derivations,
        reason: 'the streams did not change, so nothing was re-derived',
      );
    },
  );

  testWidgets('a tick that moved another title does not rebuild this screen', (
    tester,
  ) async {
    final (_, downloads, _) = await pumpDownloading(
      tester,
      others: [
        entry(
          metaId: otherId,
          infoHash: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          downloaded: 1,
        ),
      ],
    );
    var rebuilds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is MetaDetailsScreen) rebuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);

    downloads.emitProgress([tick(otherId, 2)]);
    await tester.pumpAndSettle();
    expect(rebuilds, 0, reason: 'nothing of this title moved');

    downloads.emitProgress([tick(movieId, 2)]);
    await tester.pumpAndSettle();
    expect(rebuilds, 1, reason: 'this title moved, and is redrawn');
    expect(find.text('Downloading 50%'), findsOneWidget);
  });

  testWidgets(
    'a new state, a new profile and a new order each derive once more',
    (tester) async {
      final (core, _, prefs) = await pumpDownloading(tester);
      var derivations = MetaDetailsScreen.debugStreamDerivations;

      core.setState(CoreField.metaDetails, loadMetaDetailsFixture());
      await tester.pumpAndSettle();
      expect(MetaDetailsScreen.debugStreamDerivations, derivations + 1);
      derivations++;

      core.setState(CoreField.ctx, loadFixture('ctx_logged_out.json'));
      await tester.pumpAndSettle();
      expect(MetaDetailsScreen.debugStreamDerivations, derivations + 1);
      derivations++;

      unawaited(prefs.setStreamsOrder(StreamOrder.largest));
      await tester.pumpAndSettle();
      expect(MetaDetailsScreen.debugStreamDerivations, derivations + 1);
      derivations++;

      // Opening a section reads the derivation; it does not remake it.
      unawaited(prefs.setOpenStreamSections({'1080p'}));
      await tester.pumpAndSettle();
      expect(MetaDetailsScreen.debugStreamDerivations, derivations);
    },
  );
}
