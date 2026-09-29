import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/stream_facts.dart';
import 'package:xtremio/features/details/stream_list.dart';
import 'package:xtremio/features/downloads/download_labels.dart';
import 'package:xtremio/features/local/local_media.dart';
import 'package:xtremio/features/local/local_playback.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../support/fake_core_client.dart';
import '../support/fake_downloads_client.dart';
import '../support/fake_local_media_source.dart';
import '../support/fake_playback_engine.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_torrent_stats_client.dart';
import '../support/fixtures.dart';
import '../support/stream_groups.dart';

/// A video on this device that was matched to a title is one more source on
/// that title's details page, as a matched Drive file is: in both layouts,
/// played at its own address, recorded under the Local Files addon's
/// address so the engine keeps its progress, and never offered for
/// download.
const movieId = 'tt0063350';
const alphaUrl = 'https://alpha.example/manifest.json';
const localUri = 'content://media/external/video/media/42';
const localRelease = 'Night.of.the.Living.Dead.1968.1080p.BluRay.x264-GROUP';
const localName = '$localRelease.mkv';

const movieMatch = LinkedDriveMatch(
  cinemetaId: movieId,
  type: 'movie',
  name: 'Night of the Living Dead',
  year: 1968,
);

void main() {
  Future<LocalMedia> mediaWith({LinkedDriveMatch? match = movieMatch}) async {
    final prefs = AppPrefs(client: FakePrefsClient());
    addTearDown(prefs.dispose);
    await prefs.load();
    await prefs.setLocalMedia(
      LocalMediaFiles.empty
          .reconciled([localFacts(localUri, localName, height: 1080)])
          .answering(localUri, match),
    );
    final media = LocalMedia(prefs: prefs);
    addTearDown(media.dispose);
    return media;
  }

  FakeCoreClient coreWith(List<Map<String, dynamic>> streams) => FakeCoreClient(
    state: {
      CoreField.metaDetails: loadMetaDetailsFixture()..['streams'] = streams,
      CoreField.ctx: loadCtxLoggedOutFixture(),
      CoreField.player: loadPlayerFixture(),
    },
  );

  List<Map<String, dynamic>> oneAddon() => [
    readyGroup(alphaUrl, [
      {
        'infoHash': 'a' * 40,
        'name': 'Alpha 1080p',
        'description': '👤 42 💾 1.51 GB',
      },
    ]),
  ];

  Widget harness(
    FakeCoreClient core,
    LocalMedia? media, {
    bool sectioned = true,
  }) {
    final downloads = FakeDownloadsClient();
    addTearDown(downloads.dispose);
    final prefs = AppPrefs.inMemory();
    return LocalMediaScope(
      media: media,
      child: CoreScope(
        client: core,
        child: DownloadsScope(
          client: downloads,
          child: PrefsScope(
            prefs: prefs,
            child: PlaybackScope(
              createEngine: FakePlaybackEngine.new,
              torrentStats: FakeTorrentStatsClient(),
              child: const MaterialApp(
                home: MetaDetailsScreen(type: 'movie', id: movieId),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void useWideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> tapKey(WidgetTester tester, Key key) async {
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> playerArgs(FakeCoreClient core) {
    final load = core.dispatched.firstWhere((a) => a.field == CoreField.player);
    return (load.action['args'] as Map<String, dynamic>)['args']
        as Map<String, dynamic>;
  }

  testWidgets('in the sections, it is a row of its resolution, and a press '
      'plays it at its own address, recorded under the Local Files '
      'addon', (tester) async {
    useWideViewport(tester);
    final core = coreWith(oneAddon());
    await tester.pumpWidget(harness(core, await mediaWith()));
    await tester.pumpAndSettle();
    await tapKey(tester, streamSectionKey(StreamResolution.fhd1080));

    final row = find.widgetWithText(ListTile, localRelease);
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.text(localSourceLabel)),
      findsWidgets,
      reason: 'the row says where it is from',
    );
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Alpha 1080p'),
        matching: find.byTooltip(kDownloadTooltip),
      ),
      findsOneWidget,
      reason: 'the torrent beside it can be downloaded',
    );
    expect(
      find.descendant(of: row, matching: find.byTooltip(kDownloadTooltip)),
      findsNothing,
      reason:
          'a video on this device has nothing to download: the server '
          'keeps only what it fetches',
    );

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);
    final args = playerArgs(core);
    expect(args['stream']['url'], localUri);
    expect(
      args['streamRequest'],
      localStreamRequest(type: 'movie', videoId: movieId).toJson(),
    );
    expect(args['metaRequest'], isNotNull);
  });

  testWidgets('grouped by addon, it is a group of its own named Local', (
    tester,
  ) async {
    useWideViewport(tester);
    final core = coreWith(oneAddon());
    final media = await mediaWith();
    final downloads = FakeDownloadsClient();
    addTearDown(downloads.dispose);
    final prefs = AppPrefs(
      client: FakePrefsClient({'streamsSectioned': false}),
    );
    addTearDown(prefs.dispose);
    await prefs.load();
    await tester.pumpWidget(
      LocalMediaScope(
        media: media,
        child: CoreScope(
          client: core,
          child: DownloadsScope(
            client: downloads,
            child: PrefsScope(
              prefs: prefs,
              child: PlaybackScope(
                createEngine: FakePlaybackEngine.new,
                torrentStats: FakeTorrentStatsClient(),
                child: const MaterialApp(
                  home: MetaDetailsScreen(type: 'movie', id: movieId),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapKey(tester, streamAddonKey(localSourceStorageLabel));

    final row = find.widgetWithText(ListTile, localRelease);
    expect(row, findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(playerArgs(core)['stream']['url'], localUri);
  });

  testWidgets('a video matched to another title, or to none, is not here', (
    tester,
  ) async {
    useWideViewport(tester);
    for (final match in [
      const LinkedDriveMatch(
        cinemetaId: 'tt2543164',
        type: 'movie',
        name: 'Arrival',
        year: 2016,
      ),
      null,
    ]) {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        harness(coreWith(oneAddon()), await mediaWith(match: match)),
      );
      await tester.pumpAndSettle();
      await tapKey(tester, streamSectionKey(StreamResolution.fhd1080));
      expect(find.text(localRelease), findsNothing);
    }
  });
}
