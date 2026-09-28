import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/details_header.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/tv_episode_row.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/shell/device_profile.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_playback_engine.dart';
import '../../support/fake_prefs_client.dart';
import '../../support/fake_torrent_stats_client.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

/// Where the details screen opens on a series, and where the remote lands
/// on its season and episode rows: the episode the viewer was on when they
/// last left this title, or the one the library last watched.
const seriesId = 'tt0903747';

String episode(int season, int number) => '$seriesId:$season:$number';

/// Breaking Bad with nothing selected, so the screen picks the episode
/// itself, and in the library at [libraryVideo], last watched at
/// [lastWatched].
Map<String, dynamic> series({String? libraryVideo, DateTime? lastWatched}) {
  final fixture = loadSeriesEpisodeMetaDetailsFixture();
  (fixture['selected'] as Map<String, dynamic>)['streamPath'] = null;
  final item = fixture['libraryItem'] as Map<String, dynamic>;
  item['removed'] = false;
  item['temp'] = false;
  final state = item['state'] as Map<String, dynamic>;
  state['video_id'] = libraryVideo;
  state['lastWatched'] = (lastWatched ?? DateTime.utc(2026, 9, 1))
      .toIso8601String();
  return fixture;
}

/// The title the row draws for [videoId].
String titleOf(String videoId) => TvEpisodeCard.title(
  MetaDetailsState.fromJson(loadSeriesEpisodeMetaDetailsFixture()).meta!
      .videoById(videoId)!,
);

String? focusedEpisodeTitle() {
  final card = FocusManager.instance.primaryFocus?.context
      ?.findAncestorWidgetOfExactType<TvEpisodeCard>();
  return card == null ? null : TvEpisodeCard.title(card.video);
}

/// The season on the pill holding the remote, null off the pills.
String? focusedSeason(WidgetTester tester) =>
    focusIn<SeasonSelector>() ? focusedLabel(tester) : null;

/// The season the episode list is showing.
int shownSeason(WidgetTester tester) =>
    tester.widget<SeasonSelector>(find.byType(SeasonSelector)).selected;

/// The episodes every `Load` this screen dispatched asked for, in order.
List<String?> loadedVideos(FakeCoreClient core) => [
  for (final action in core.dispatched)
    if (action.action['action'] == 'Load')
      ((action.action['args'] as Map<String, dynamic>)['args']
              as Map<String, dynamic>)['streamPath']?['id']
          as String?,
];

/// Preferences holding [visit], if any, over a client a test can read back.
Future<(AppPrefs, FakePrefsClient)> prefsWith([DetailsVisit? visit]) async {
  final client = FakePrefsClient({
    'streamsSectioned': false,
    if (visit != null)
      AppPrefs.detailsVisitsKey: DetailsVisitMemory.empty
          .withVisit(visit)
          .toJson(),
  });
  final prefs = AppPrefs(client: client);
  addTearDown(prefs.dispose);
  await prefs.load();
  return (prefs, client);
}

Future<FakeCoreClient> mount(
  WidgetTester tester,
  Map<String, dynamic> fixture, {
  required AppPrefs prefs,
  String? videoId,
  DeviceProfile device = tv,
}) async {
  useScreen(tester, tvSize);
  final core = FakeCoreClient(state: {CoreField.metaDetails: fixture});
  await tester.pumpWidget(
    DeviceScope(
      profile: device,
      child: CoreScope(
        client: core,
        child: PrefsScope(
          prefs: prefs,
          child: PlaybackScope(
            createEngine: FakePlaybackEngine.new,
            torrentStats: FakeTorrentStatsClient(),
            child: MaterialApp(
              home: MetaDetailsScreen(
                type: 'series',
                id: seriesId,
                videoId: videoId,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return core;
}

void main() {
  group('the first visit to a title in the library', () {
    testWidgets('opens on the episode last watched, and the pills and the '
        'row keep it', (tester) async {
      final (prefs, _) = await prefsWith();
      final core = await mount(
        tester,
        series(libraryVideo: episode(3, 4)),
        prefs: prefs,
      );

      expect(loadedVideos(core).last, episode(3, 4));
      expect(shownSeason(tester), 3);
      expect(focusedEpisodeTitle(), titleOf(episode(3, 4)));

      // Up onto the pills lands on the season on screen. Landing on any
      // other pill would switch the list to that season.
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedSeason(tester), '3');
      expect(shownSeason(tester), 3);

      // And back down lands on the episode, not the first of the season.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedEpisodeTitle(), titleOf(episode(3, 4)));
    });
  });

  group('a title visited before', () {
    testWidgets('opens on the season and episode it was left on', (
      tester,
    ) async {
      final (prefs, _) = await prefsWith(
        DetailsVisit(
          meta: seriesId,
          season: 2,
          videoId: episode(2, 5),
          at: DateTime.utc(2026, 9, 20),
        ),
      );
      final core = await mount(
        tester,
        series(
          libraryVideo: episode(3, 4),
          lastWatched: DateTime.utc(2026, 9, 10),
        ),
        prefs: prefs,
      );

      expect(loadedVideos(core).last, episode(2, 5));
      expect(shownSeason(tester), 2);
      expect(focusedEpisodeTitle(), titleOf(episode(2, 5)));
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedSeason(tester), '2');
    });

    testWidgets('opens on the season it was browsing, even with the episode '
        'in another', (tester) async {
      // Walking the pills changes the list without choosing an episode:
      // the season is where the viewer was, and the episode stays chosen.
      final (prefs, _) = await prefsWith(
        DetailsVisit(
          meta: seriesId,
          season: 4,
          videoId: episode(2, 5),
          at: DateTime.utc(2026, 9, 20),
        ),
      );
      final core = await mount(tester, series(), prefs: prefs);

      expect(loadedVideos(core).last, episode(2, 5));
      expect(shownSeason(tester), 4);
      await tester.pumpAndSettle();
      for (var i = 0; i < 4 && focusedSeason(tester) == null; i++) {
        await press(tester, LogicalKeyboardKey.arrowUp);
      }
      expect(focusedSeason(tester), '4');
    });

    testWidgets('opens where the library is when it watched something since', (
      tester,
    ) async {
      // The player moves on to the next episode by itself: back from a
      // binge, the episode stopped on is newer than the one chosen here.
      final (prefs, _) = await prefsWith(
        DetailsVisit(
          meta: seriesId,
          season: 2,
          videoId: episode(2, 5),
          at: DateTime.utc(2026, 9, 10),
        ),
      );
      final core = await mount(
        tester,
        series(
          libraryVideo: episode(3, 4),
          lastWatched: DateTime.utc(2026, 9, 20),
        ),
        prefs: prefs,
      );

      expect(loadedVideos(core).last, episode(3, 4));
      expect(shownSeason(tester), 3);
    });

    testWidgets('opens on the episode it was told to, whatever it was left '
        'on', (tester) async {
      final (prefs, _) = await prefsWith(
        DetailsVisit(
          meta: seriesId,
          season: 2,
          videoId: episode(2, 5),
          at: DateTime.utc(2026, 9, 20),
        ),
      );
      final core = await mount(
        tester,
        series(),
        prefs: prefs,
        videoId: episode(1, 2),
      );

      expect(loadedVideos(core), [episode(1, 2)]);
      expect(shownSeason(tester), 1);
    });

    testWidgets('opens on the season it was left on off a television too', (
      tester,
    ) async {
      final (prefs, _) = await prefsWith(
        DetailsVisit(
          meta: seriesId,
          season: 2,
          videoId: episode(2, 5),
          at: DateTime.utc(2026, 9, 20),
        ),
      );
      final core = await mount(
        tester,
        series(),
        prefs: prefs,
        device: DeviceProfile.fallback,
      );

      expect(loadedVideos(core).last, episode(2, 5));
      expect(shownSeason(tester), 2);
    });
  });

  group('where the viewer goes', () {
    testWidgets('is written down once they stop there', (tester) async {
      final (prefs, client) = await prefsWith();
      await mount(tester, series(libraryVideo: episode(3, 4)), prefs: prefs);

      await press(tester, LogicalKeyboardKey.arrowUp);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedSeason(tester), '4');
      await tester.pump(const Duration(seconds: 2));

      final visit = prefs.detailsVisits.forMeta(seriesId);
      expect(visit?.season, 4);
      expect(visit?.videoId, episode(3, 4));
      expect(
        client.stored,
        contains(AppPrefs.detailsVisitsKey),
        reason: 'persisted, not only held',
      );
    });

    testWidgets('is written down when the screen goes, however soon', (
      tester,
    ) async {
      final (prefs, _) = await prefsWith();
      await mount(tester, series(libraryVideo: episode(3, 4)), prefs: prefs);

      await press(tester, LogicalKeyboardKey.arrowUp);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await tester.pumpWidget(const SizedBox());

      expect(prefs.detailsVisits.forMeta(seriesId)?.season, 4);
    });
  });
}
