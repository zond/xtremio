import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/episode_thumbnail.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/tv_episode_row.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/download_badge.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_downloads_client.dart';
import '../../support/fake_playback_engine.dart';
import '../../support/fake_prefs_client.dart';
import '../../support/fake_torrent_stats_client.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

const seriesId = 'tt0903747';
const pilotId = '$seriesId:1:1';
const movieId = 'tt0063350';

/// A Torrentio-style group for [videoId], so the pane has something the
/// remote can start on and the player can open.
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

/// Breaking Bad at the pilot, with a playable torrent for it.
Map<String, dynamic> series() {
  final fixture = loadSeriesEpisodeMetaDetailsFixture();
  (fixture['streams'] as List<dynamic>).add(torrentGroup(pilotId));
  return fixture;
}

/// The season-1 videos of [fixture], in the order the row draws them.
List<VideoInfo> seasonOne(Map<String, dynamic> fixture) =>
    MetaDetailsState.fromJson(fixture).meta!.videosOfSeason(1);

/// The videos of [fixture], to be edited in place.
List<dynamic> videosOf(Map<String, dynamic> fixture) =>
    fixture['metaItems'][0]['content']['content']['videos'] as List<dynamic>;

/// Which episode's sources the state says are on screen.
void selectVideo(Map<String, dynamic> fixture, String videoId) {
  (fixture['selected']['streamPath'] as Map<String, dynamic>)['id'] = videoId;
}

Widget harness(
  FakeCoreClient core, {
  String type = 'series',
  String id = seriesId,
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
        home: MetaDetailsScreen(type: type, id: id),
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

/// The sources list grouped rather than sectioned, so the remote starts on
/// an actual stream: what this file is about is the info column, and a
/// collapsed section header is one more press between it and the row.
Future<AppPrefs> groupedPrefs() async {
  final prefs = AppPrefs(client: FakePrefsClient({'streamsSectioned': false}));
  addTearDown(prefs.dispose);
  await prefs.load();
  return prefs;
}

Future<FakeCoreClient> mount(
  WidgetTester tester,
  Map<String, dynamic> fixture, {
  String type = 'series',
  String id = seriesId,
  DeviceProfile device = tv,
  DownloadsClient? downloads,
  Map<CoreField, Map<String, dynamic>> also = const {},
}) async {
  useScreen(tester, tvSize);
  final core = FakeCoreClient(state: {CoreField.metaDetails: fixture, ...also});
  await tester.pumpWidget(
    harness(
      core,
      type: type,
      id: id,
      device: device,
      downloads: downloads,
      prefs: await groupedPrefs(),
    ),
  );
  await tester.pumpAndSettle();
  return core;
}

/// The card for [videoId].
Finder cardOf(String videoId) =>
    find.byWidgetPredicate((w) => w is TvEpisodeCard && w.video.id == videoId);

/// Everything drawn inside [videoId]'s card.
Finder inCard(String videoId, Finder matching) =>
    find.descendant(of: cardOf(videoId), matching: matching);

/// The name on the card holding primary focus, null when focus is
/// elsewhere.
String? focusedEpisode() {
  final card = FocusManager.instance.primaryFocus?.context
      ?.findAncestorWidgetOfExactType<TvEpisodeCard>();
  return card == null ? null : TvEpisodeCard.title(card.video);
}

/// From the pane, left into the info column and then down onto the row.
Future<void> stepOntoTheRow(WidgetTester tester) async {
  await press(tester, LogicalKeyboardKey.arrowLeft);
  for (var i = 0; i < 8 && focusedEpisode() == null; i++) {
    await press(tester, LogicalKeyboardKey.arrowDown);
  }
  expect(focusedEpisode(), isNotNull, reason: 'the remote reached the row');
}

void main() {
  testWidgets('a series draws its season as a row of cards, in order', (
    tester,
  ) async {
    final fixture = series();
    await mount(tester, fixture);

    final episodes = seasonOne(fixture);
    expect(episodes, hasLength(7));
    expect(
      tester
          .widgetList<TvEpisodeCard>(find.byType(TvEpisodeCard))
          .map((card) => card.video.id),
      [for (final video in episodes) video.id],
    );
    // Side by side on one line, which is what makes it a row: the phone's
    // list is the same episodes stacked.
    final first = tester.getRect(cardOf(episodes.first.id));
    final second = tester.getRect(cardOf(episodes[1].id));
    expect(second.left, greaterThan(first.left));
    expect(second.top, first.top);
  });

  testWidgets('a film has no episode row at all', (tester) async {
    await mount(tester, loadMetaDetailsFixture(), type: 'movie', id: movieId);

    expect(find.byType(TvEpisodeRow), findsNothing);
    expect(find.byType(TvEpisodeCard), findsNothing);
  });

  testWidgets('a card carries the still, the number, the title and the '
      'air date', (tester) async {
    await mount(tester, series());

    expect(inCard(pilotId, find.byType(EpisodeThumbnail)), findsOneWidget);
    expect(inCard(pilotId, find.text('E1')), findsOneWidget);
    expect(inCard(pilotId, find.text('Pilot')), findsOneWidget);
    expect(inCard(pilotId, find.text('2008-01-21')), findsOneWidget);
  });

  testWidgets('the episode whose sources are shown is marked by more than '
      'a colour', (tester) async {
    final fixture = series();
    selectVideo(fixture, '$seriesId:1:3');
    await mount(tester, fixture);

    final theme = Theme.of(tester.element(find.byType(TvEpisodeRow)));
    final title = tester.widget<Text>(
      inCard('$seriesId:1:3', find.text(seasonOne(fixture)[2].title)),
    );
    expect(title.style?.color, theme.colorScheme.primary);
    expect(title.style?.fontWeight, FontWeight.w700);

    final other = tester.widget<Text>(inCard(pilotId, find.text('Pilot')));
    expect(other.style?.color, isNot(theme.colorScheme.primary));
    expect(other.style?.fontWeight, isNot(FontWeight.w700));
  });

  testWidgets('a watched episode is checked, and only that one', (
    tester,
  ) async {
    final fixture = series();
    expect(fixture['watchedVideoIds'], [pilotId]);
    await mount(tester, fixture);

    final checks = find.descendant(
      of: find.byType(TvEpisodeRow),
      matching: find.byIcon(Icons.check_circle),
    );
    expect(checks, findsOneWidget);
    expect(inCard(pilotId, find.byIcon(Icons.check_circle)), findsOneWidget);
  });

  testWidgets('the episode the library is resuming carries a bar saying how '
      'far in, and no other card does', (tester) async {
    final fixture = series();
    final state = fixture['libraryItem']['state'] as Map<String, dynamic>;
    state['video_id'] = '$seriesId:1:4';
    state['timeOffset'] = 300000;
    state['duration'] = 1200000;
    await mount(tester, fixture);

    final bars = find.descendant(
      of: find.byType(TvEpisodeRow),
      matching: find.byType(LinearProgressIndicator),
    );
    expect(bars, findsOneWidget);
    expect(
      inCard('$seriesId:1:4', find.byType(LinearProgressIndicator)),
      findsOneWidget,
    );
    expect(tester.widget<LinearProgressIndicator>(bars).value, 0.25);
  });

  testWidgets('nothing is remembered of an episode, nothing is drawn on it', (
    tester,
  ) async {
    // The engine keeps one resume point per title, and this fixture's is
    // empty: a bar on every card would be an invention.
    await mount(tester, series());

    expect(
      find.descendant(
        of: find.byType(TvEpisodeRow),
        matching: find.byType(LinearProgressIndicator),
      ),
      findsNothing,
    );
  });

  testWidgets('an episode kept on the device says so on its card', (
    tester,
  ) async {
    final entry = DownloadView({
      'metaId': seriesId,
      'videoId': '$seriesId:1:2',
      'name': 'Cat in the Bag...',
      'stream': {'infoHash': 'b' * 40, 'fileIdx': 0},
      'infoHash': 'b' * 40,
      'fileIdx': 0,
      'size': 1000,
      'downloaded': 1000,
      'state': 'complete',
      'path': '/downloads/bb.mkv',
    });
    final downloads = FakeDownloadsClient(
      registry: DownloadsRegistry(items: {entry.key: entry}),
    );
    addTearDown(downloads.dispose);
    await mount(tester, series(), downloads: downloads);

    expect(
      find.descendant(
        of: find.byType(TvEpisodeRow),
        matching: find.byType(DownloadBadge),
      ),
      findsOneWidget,
    );
    expect(inCard('$seriesId:1:2', find.byType(DownloadBadge)), findsOneWidget);
  });

  testWidgets('an episode that has not aired is drawn, says so, and takes '
      'no press', (tester) async {
    final fixture = series();
    final videos = videosOf(fixture);
    final upcoming = videos.firstWhere(
      (v) => (v as Map<String, dynamic>)['id'] == '$seriesId:1:7',
    );
    (upcoming as Map<String, dynamic>)['released'] = '2999-01-01T00:00:00Z';
    await mount(tester, fixture);

    expect(cardOf('$seriesId:1:7'), findsOneWidget);
    expect(
      inCard('$seriesId:1:7', find.textContaining('Upcoming')),
      findsOneWidget,
    );

    // The remote walks the row to its end and steps over it: a card that
    // cannot be pressed must not be a focus stop either.
    await stepOntoTheRow(tester);
    final walked = <String>{};
    for (var i = 0; i < 12 && focusedEpisode() != null; i++) {
      walked.add(focusedEpisode()!);
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(walked, contains(seasonOne(fixture)[5].title));
    expect(walked, isNot(contains(seasonOne(fixture)[6].title)));
  });

  testWidgets('the D-pad reaches the last card of a row far longer than '
      'fits', (tester) async {
    // Directional focus only considers widgets that have been built, so a
    // lazily built row hands the remote back at the last realised card and
    // the rest of the season is unreachable. Two dozen at 208 dp is three
    // times the width of the column they are in.
    final fixture = series();
    final videos = videosOf(fixture);
    final pilot = videos.first as Map<String, dynamic>;
    for (var episode = 8; episode <= 24; episode++) {
      videos.add({
        ...pilot,
        'id': '$seriesId:1:$episode',
        'title': 'Episode $episode',
        'season': 1,
        'episode': episode,
      });
    }
    await mount(tester, fixture);
    expect(find.byType(TvEpisodeCard), findsNWidgets(24));

    await stepOntoTheRow(tester);
    for (var i = 0; i < 30 && focusedEpisode() != 'Episode 24'; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(focusedEpisode(), 'Episode 24');
    // And it is on the panel, not off the end of the strip.
    final row = tester.getRect(find.byType(TvEpisodeRow));
    final card = tester.getRect(cardOf('$seriesId:1:24'));
    expect(card.left, greaterThanOrEqualTo(row.left));
    expect(card.right, lessThanOrEqualTo(row.right));
  });

  testWidgets('the row opens on the episode being resumed rather than at '
      'the start of the season', (tester) async {
    final fixture = series();
    selectVideo(fixture, '$seriesId:1:7');
    await mount(tester, fixture);

    final row = tester.getRect(find.byType(TvEpisodeRow));
    final last = tester.getRect(cardOf('$seriesId:1:7'));
    expect(last.left, greaterThanOrEqualTo(row.left));
    expect(last.right, lessThanOrEqualTo(row.right));
    // Which it only is because the row scrolled: seven cards are twice the
    // width of the column, so the pilot has gone off the left.
    expect(tester.getRect(cardOf(pilotId)).right, lessThan(row.left));
  });

  testWidgets('coming back from the player leaves the remote on the card it '
      'was on', (tester) async {
    await mount(
      tester,
      series(),
      also: {CoreField.player: loadPlayerFixture()},
    );

    await stepOntoTheRow(tester);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    final left = focusedEpisode();
    expect(left, isNot(seasonOne(series()).first.title));

    // A pointer tap on the stream, so nothing but the player moves focus.
    await tester.tap(find.textContaining('Torrentio').first);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(focusedEpisode(), isNull, reason: 'the player took the remote');

    // Paused with nothing put away, so Back leaves the player at once.
    await systemBack(tester);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsNothing);
    expect(focusedEpisode(), left);
  });

  testWidgets('off a television the episodes are still a vertical list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = FakeCoreClient(state: {CoreField.metaDetails: series()});
    await tester.pumpWidget(
      harness(
        core,
        device: DeviceProfile.fallback,
        prefs: await groupedPrefs(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TvEpisodeRow), findsNothing);
    expect(find.byType(TvEpisodeCard), findsNothing);
    expect(find.widgetWithText(ListTile, 'Pilot'), findsOneWidget);
  });
}
