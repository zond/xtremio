import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/similar_row.dart';
import 'package:xtremio/features/details/tv_episode_row.dart';
import 'package:xtremio/features/details/tv_meta_header.dart';
import 'package:xtremio/features/details/tv_source_row.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/similar/similar_resolver.dart';
import 'package:xtremio/shell/device_profile.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_playback_engine.dart';
import '../../support/fake_prefs_client.dart';
import '../../support/fake_torrent_stats_client.dart';
import '../../support/fixtures.dart';
import '../../support/stream_groups.dart';
import '../../support/tv.dart';

/// Where a details screen opens: at the top the first time a title is
/// visited, where it was left every time after, and -- from a Continue
/// watching tile -- on the card that carries on.
const movieId = 'tt0063350';
const seriesId = 'tt0903747';

String hash(int seed) => seed.toRadixString(16).padLeft(40, '0');

Map<String, dynamic> torrent(int seed, String name) => {
  'infoHash': hash(seed),
  'fileIdx': 0,
  'name': name,
  'description': '👤 ${seed * 3} 💾 2 GB',
};

/// The film, with two addons answering: three sources from alpha and
/// [beta] from beta (all four of them when null; none of beta at all when
/// empty). Addons in [loading] are still being waited on instead.
Map<String, dynamic> film({
  List<int>? beta,
  Set<String> loading = const {},
  bool gamma = false,
  // Gamma answering between alpha and beta, which puts its pill there.
  bool gammaBetween = false,
}) {
  final betaSeeds = beta ?? [11, 12, 13, 14];
  return loadMetaDetailsFixture()
    ..['streams'] = [
      if (loading.contains('alpha'))
        loadingGroup('alpha.example')
      else
        readyGroup('alpha.example', [
          for (final seed in [1, 2, 3]) torrent(seed, 'Alpha $seed 1080p'),
        ]),
      if (gammaBetween)
        readyGroup('gamma.example', [torrent(21, 'Gamma 21 2160p')]),
      if (loading.contains('beta'))
        loadingGroup('beta.example')
      else if (betaSeeds.isNotEmpty)
        readyGroup('beta.example', [
          for (final seed in betaSeeds) torrent(seed, 'Beta $seed 720p'),
        ]),
      if (gamma) readyGroup('gamma.example', [torrent(21, 'Gamma 21 2160p')]),
    ];
}

/// [fixture] with its first stream recorded as the one it was last played
/// from.
Map<String, dynamic> played(Map<String, dynamic> fixture) {
  final first =
      (fixture['streams'] as List<dynamic>).first as Map<String, dynamic>;
  fixture['lastUsedStream'] = {
    'request': first['request'],
    'content': {
      'type': 'Ready',
      'content': (first['content'] as Map<String, dynamic>)['content']![0],
    },
  };
  return fixture;
}

/// Breaking Bad with nothing selected, so the screen picks the episode
/// itself -- the last visit's, when there is one, else the library's: the
/// pilot, watched a month ago.
Map<String, dynamic> series() {
  final fixture = loadSeriesEpisodeMetaDetailsFixture();
  (fixture['selected'] as Map<String, dynamic>)['streamPath'] = null;
  final item = fixture['libraryItem'] as Map<String, dynamic>;
  item['removed'] = false;
  item['temp'] = false;
  final state = item['state'] as Map<String, dynamic>;
  state['video_id'] = '$seriesId:1:1';
  state['lastWatched'] = DateTime.utc(2026, 9, 1).toIso8601String();
  return fixture;
}

String? focusedEpisodeTitle() {
  final card = FocusManager.instance.primaryFocus?.context
      ?.findAncestorWidgetOfExactType<TvEpisodeCard>();
  return card == null ? null : TvEpisodeCard.title(card.video);
}

Future<(AppPrefs, FakePrefsClient)> freshPrefs([
  Map<String, dynamic>? stored,
]) async {
  final client = FakePrefsClient({'streamsSectioned': false, ...?stored});
  final prefs = AppPrefs(client: client);
  addTearDown(prefs.dispose);
  await prefs.load();
  return (prefs, client);
}

/// The app started again over what [client] has on disk.
Future<AppPrefs> restart(FakePrefsClient client) async =>
    (await freshPrefs(client.stored)).$1;

/// Opens the details screen for [fixture] over a screen it can go back to,
/// the way a tile opens it.
Future<FakeCoreClient> open(
  WidgetTester tester,
  Map<String, dynamic> fixture, {
  required AppPrefs prefs,
  String type = 'movie',
  String id = movieId,
  String? videoId,
  DetailsOpenedFrom openedFrom = DetailsOpenedFrom.elsewhere,
  DeviceProfile device = tv,
  // A Chromecast's panel in logical pixels, where the walk into the
  // sources scrolls the page.
  Size size = const Size(960, 540),
  bool settle = true,
  SimilarAskBuilder? similar,
}) async {
  useScreen(tester, size);
  final core = FakeCoreClient(
    state: {
      CoreField.metaDetails: fixture,
      CoreField.player: loadPlayerFixture(),
    },
  );
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
            child: SimilarScope(
              askFor:
                  similar ??
                  (_) =>
                      ({required String type, required String id}) async =>
                          const <SimilarTitle>[],
              child: MaterialApp(
                home: MetaDetailsScreen(
                  type: type,
                  id: id,
                  videoId: videoId,
                  openedFrom: openedFrom,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // A spinner never stops: a screen still waiting is pumped a frame at a
    // time.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }
  return core;
}

/// Leaves the screen: it is taken down, which is when it writes where the
/// viewer was.
Future<void> leave(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

/// Walks from the header to the third of beta's sources, and says what the
/// card is called.
Future<String> walkToBetaThree(WidgetTester tester) async {
  await walkIntoTheOpenRung(tester);
  expect(focusedLabel(tester), 'alpha.example');
  await press(tester, LogicalKeyboardKey.arrowRight);
  expect(focusedLabel(tester), 'beta.example');
  await press(tester, LogicalKeyboardKey.arrowDown);
  await press(tester, LogicalKeyboardKey.arrowRight);
  await press(tester, LogicalKeyboardKey.arrowRight);
  expect(focusIn<TvSourceCard>(), isTrue);
  final label = focusedLabel(tester)!;
  expect(label, contains('Beta 13'), reason: 'the third of beta\'s');
  return label;
}

void expectAtTheTop(WidgetTester tester) {
  expect(focusIn<TvMetaHeader>(), isTrue, reason: 'the remote');
  expect(pageScrollOffset(tester), 0, reason: 'the page');
}

void main() {
  group('a title never visited', () {
    testWidgets('opens at the top, and leaving it writes that down', (
      tester,
    ) async {
      final (prefs, _) = await freshPrefs();
      await open(tester, film(), prefs: prefs);
      expectAtTheTop(tester);

      await leave(tester);
      final visit = prefs.detailsVisits.forMeta(movieId);
      expect(visit, isNotNull, reason: 'a film is visited too');
      expect(visit!.remote?.row, 'header');
      expect(visit.offset, isNull);
    });

    testWidgets('and so does one whose visit has fallen off the end', (
      tester,
    ) async {
      final (prefs, _) = await freshPrefs();
      await open(tester, film(), prefs: prefs);
      await walkToBetaThree(tester);
      await leave(tester);
      expect(prefs.detailsVisits.forMeta(movieId)?.remote?.row, 'sources');

      var memory = prefs.detailsVisits;
      for (var i = 0; i < DetailsVisitMemory.limit; i++) {
        memory = memory.withVisit(
          DetailsVisit(meta: 'tt$i', at: DateTime.utc(2026, 9, 1)),
        );
      }
      await prefs.setDetailsVisits(memory);
      expect(prefs.detailsVisits.forMeta(movieId), isNull);

      await open(tester, film(), prefs: prefs);
      expectAtTheTop(tester);
    });
  });

  group('a title visited before', () {
    testWidgets('opens on the source it was left on, the page where it was, '
        'after the app has started again', (tester) async {
      final (prefs, client) = await freshPrefs();
      await open(tester, film(), prefs: prefs);
      final left = await walkToBetaThree(tester);
      final scrolled = pageScrollOffset(tester);
      expect(scrolled, greaterThan(0), reason: 'the walk scrolled the page');
      await leave(tester);

      final visit = prefs.detailsVisits.forMeta(movieId)!;
      expect(visit.remote?.row, 'sources');
      expect(visit.remote?.id, 'torrent:${hash(13)}/0');
      expect(visit.remote?.group, 'beta.example');

      await open(tester, film(), prefs: await restart(client));
      expect(focusedLabel(tester), left);
      expect(pageScrollOffset(tester), closeTo(scrolled, 1));
    });

    testWidgets('and where it was left the second time, not the first', (
      tester,
    ) async {
      final (prefs, _) = await freshPrefs();
      await open(tester, film(), prefs: prefs);
      await walkToBetaThree(tester);
      await leave(tester);

      await open(tester, film(), prefs: prefs);
      expect(focusedLabel(tester), contains('Beta 13'));
      await press(tester, LogicalKeyboardKey.arrowLeft);
      final left = focusedLabel(tester);
      expect(left, contains('Beta 12'));
      await leave(tester);

      await open(tester, film(), prefs: prefs);
      expect(focusedLabel(tester), left);
    });

    testWidgets('finds the group pill it was left on by its name, when '
        'another addon has answered ahead of it', (tester) async {
      final (prefs, _) = await freshPrefs();
      await open(tester, film(), prefs: prefs);
      await walkIntoTheOpenRung(tester);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(tester), 'beta.example');
      await leave(tester);

      await open(tester, film(gammaBetween: true), prefs: prefs);
      expect(focusIn<TvSourceGroupPill>(), isTrue);
      expect(focusedLabel(tester), 'beta.example');
    });

    testWidgets('waits on the header for the source to arrive, takes it then, '
        'and an addon answering after that moves nothing', (tester) async {
      final (prefs, _) = await freshPrefs();
      await open(tester, film(), prefs: prefs);
      final left = await walkToBetaThree(tester);
      await leave(tester);

      final core = await open(
        tester,
        film(loading: {'alpha', 'beta'}),
        prefs: prefs,
        settle: false,
      );
      expectAtTheTop(tester);

      // Alpha answers first: the group the source is in is still out.
      core.setState(CoreField.metaDetails, film(loading: {'beta'}));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expectAtTheTop(tester);

      core.setState(CoreField.metaDetails, film());
      await tester.pumpAndSettle();
      expect(focusedLabel(tester), left);

      core.setState(CoreField.metaDetails, film(gamma: true));
      await tester.pumpAndSettle();
      expect(find.text('gamma.example'), findsOneWidget, reason: 'it landed');
      expect(focusedLabel(tester), left);
    });

    testWidgets('and leaving while it waits keeps where it was left', (
      tester,
    ) async {
      final (prefs, _) = await freshPrefs();
      await open(tester, film(), prefs: prefs);
      await walkToBetaThree(tester);
      await leave(tester);

      await open(
        tester,
        film(loading: {'alpha', 'beta'}),
        prefs: prefs,
        settle: false,
      );
      expectAtTheTop(tester);
      await leave(tester);

      final remote = prefs.detailsVisits.forMeta(movieId)?.remote;
      expect(remote?.row, 'sources');
      expect(remote?.id, 'torrent:${hash(13)}/0');
    });

    testWidgets('and a remote the viewer has moved while it waited stays '
        'where they moved it', (tester) async {
      final (prefs, _) = await freshPrefs();
      await open(tester, film(), prefs: prefs);
      await walkToBetaThree(tester);
      await leave(tester);

      final core = await open(
        tester,
        film(loading: {'alpha', 'beta'}),
        prefs: prefs,
        settle: false,
      );
      expectAtTheTop(tester);
      for (var i = 0; i < 4 && focusIn<TvMetaHeader>(); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      final moved = FocusManager.instance.primaryFocus;
      expect(focusIn<TvMetaHeader>(), isFalse, reason: 'it moved');

      core.setState(CoreField.metaDetails, film());
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, moved);
      expect(focusIn<TvSourceCard>(), isFalse);
    });

    testWidgets('opens on the card beside it when that source is gone', (
      tester,
    ) async {
      final (prefs, _) = await freshPrefs();
      await open(tester, film(), prefs: prefs);
      await walkToBetaThree(tester);
      await leave(tester);

      // Beta no longer has the third, or anything after it: the remote
      // goes to the same place in the row, which is its last card now.
      await open(tester, film(beta: [11, 12]), prefs: prefs);
      expect(focusIn<TvSourceCard>(), isTrue);
      expect(focusedLabel(tester), contains('Beta 12'));
    });

    testWidgets('and on the groups when the whole addon is gone', (
      tester,
    ) async {
      final (prefs, _) = await freshPrefs();
      await open(tester, film(), prefs: prefs);
      await walkToBetaThree(tester);
      await leave(tester);

      await open(tester, film(beta: []), prefs: prefs);
      expect(focusIn<TvSourceGroupPill>(), isTrue);
      expect(focusedLabel(tester), 'alpha.example');
    });

    testWidgets('opens on the episode it was left on', (tester) async {
      final (prefs, client) = await freshPrefs();
      await open(tester, series(), prefs: prefs, type: 'series', id: seriesId);
      await walkIntoTheOpenRung(tester);
      final first = focusedEpisodeTitle();
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      final left = focusedEpisodeTitle();
      expect(left, isNot(first));
      // Resting on it chooses it.
      await tester.pump(const Duration(seconds: 2));
      await leave(tester);
      expect(prefs.detailsVisits.forMeta(seriesId)?.remote?.row, 'episodes');

      await open(
        tester,
        series(),
        prefs: await restart(client),
        type: 'series',
        id: seriesId,
      );
      expect(focusedEpisodeTitle(), left);
    });
  });

  testWidgets('a played title left in its sources opens there, not on the '
      'card that carries on', (tester) async {
    final (prefs, _) = await freshPrefs();
    await open(tester, played(film()), prefs: prefs);
    await walkIntoTheOpenRung(tester);
    expect(focusedLabel(tester), kContinueWithLastSource);
    // Down to the sources rung, and open it.
    for (var i = 0; i < 4 && focusedLabel(tester) != kSourcesLabel; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    await press(tester, LogicalKeyboardKey.select);
    for (var i = 0; i < 4 && !focusIn<TvSourceGroupPill>(); i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(focusIn<TvSourceGroupPill>(), isTrue);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), 'beta.example');
    await leave(tester);

    await open(tester, played(film()), prefs: prefs);
    expect(focusedLabel(tester), 'beta.example');
  });

  group('a suggestion it was left on', () {
    SimilarTitle suggestion(String id, String name) => SimilarTitle(
      item: MetaItemPreview({
        'id': id,
        'type': 'movie',
        'name': name,
        'releaseInfo': '1979',
      }),
      why: 'the same grey and the same pace',
    );

    Future<(AppPrefs, Completer<List<SimilarTitle>>)> leftOnTheSecond(
      WidgetTester tester,
    ) async {
      final (prefs, _) = await freshPrefs({
        AppPrefs.detailsVisitsKey: DetailsVisitMemory.empty
            .withVisit(
              DetailsVisit(
                meta: movieId,
                at: DateTime.utc(2026, 9, 1),
                remote: const DetailsRemote(
                  row: 'similar',
                  index: 1,
                  rung: 'moreLikeThis',
                ),
              ),
            )
            .toJson(),
      });
      // Made in the test body: a completer from outside it completes in a
      // zone the test's pumps never run.
      final answer = Completer<List<SimilarTitle>>();
      await open(
        tester,
        film(),
        prefs: prefs,
        // The open rung's spinner turns until the answer lands.
        settle: false,
        similar: (_) =>
            ({required String type, required String id}) => answer.future,
      );
      return (prefs, answer);
    }

    testWidgets('is waited for, and taken once the answer lands', (
      tester,
    ) async {
      final (_, answer) = await leftOnTheSecond(tester);
      expectAtTheTop(tester);

      answer.complete([
        suggestion('tt0079944', 'Stalker'),
        suggestion('tt0120907', 'eXistenZ'),
      ]);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(focusedTileName(tester), 'eXistenZ');
    });

    testWidgets('and when the answer is nothing, the remote stays on the '
        'header', (tester) async {
      final (_, answer) = await leftOnTheSecond(tester);
      answer.complete(const []);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text(kMoreLikeThisLabel), findsNothing);
      expectAtTheTop(tester);
    });
  });

  group('from Continue watching', () {
    testWidgets('the remote goes to the card that carries on, whatever the '
        'last visit was left on', (tester) async {
      final (prefs, _) = await freshPrefs();
      await open(tester, played(film()), prefs: prefs);
      // Into the sources rung, under the one the title opened on.
      await walkIntoTheOpenRung(tester);
      for (var i = 0; i < 6 && !focusIn<TvSourceGroupPill>(); i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
        if (focusedLabel(tester) == kSourcesLabel) {
          await press(tester, LogicalKeyboardKey.select);
        }
      }
      expect(focusIn<TvSourceGroupPill>(), isTrue);
      await leave(tester);
      expect(prefs.detailsVisits.forMeta(movieId)?.remote?.row, 'groups');

      await open(
        tester,
        played(film()),
        prefs: prefs,
        openedFrom: DetailsOpenedFrom.continueWatching,
      );
      expect(focusedLabel(tester), kContinueWithLastSource);
    });

    testWidgets('waiting for it when the streams come after the screen', (
      tester,
    ) async {
      final (prefs, _) = await freshPrefs();
      final core = await open(
        tester,
        film(loading: {'alpha', 'beta'}),
        prefs: prefs,
        openedFrom: DetailsOpenedFrom.continueWatching,
        settle: false,
      );
      expectAtTheTop(tester);

      core.setState(CoreField.metaDetails, played(film()));
      await tester.pumpAndSettle();
      expect(focusedLabel(tester), kContinueWithLastSource);
    });

    testWidgets('and a title with nothing to carry on with stays at the top', (
      tester,
    ) async {
      final (prefs, _) = await freshPrefs();
      await open(
        tester,
        film(),
        prefs: prefs,
        openedFrom: DetailsOpenedFrom.continueWatching,
      );
      expectAtTheTop(tester);
    });
  });

  group('leaving', () {
    testWidgets('for the player writes where the remote was, before the '
        'player is back', (tester) async {
      final (prefs, _) = await freshPrefs();
      await open(tester, film(), prefs: prefs);
      await walkToBetaThree(tester);
      expect(prefs.detailsVisits.forMeta(movieId)?.remote, isNull);

      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(PlayerScreen), findsOneWidget);
      final remote = prefs.detailsVisits.forMeta(movieId)?.remote;
      expect(remote?.row, 'sources');
      expect(remote?.id, 'torrent:${hash(13)}/0');
    });

    testWidgets('for the background writes where the remote was', (
      tester,
    ) async {
      final (prefs, _) = await freshPrefs();
      await open(tester, film(), prefs: prefs);
      await walkToBetaThree(tester);
      expect(prefs.detailsVisits.forMeta(movieId)?.remote, isNull);

      // The way Android goes to the background, a state at a time.
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      expect(
        prefs.detailsVisits.forMeta(movieId)?.remote?.id,
        'torrent:${hash(13)}/0',
      );
    });
  });

  group('a phone', () {
    const phoneSize = Size(400, 700);
    const phone = DeviceProfile.fallback;

    testWidgets('opens at the top the first time, and where it was left '
        'after, once the sources have made the page that long', (tester) async {
      final (prefs, _) = await freshPrefs();
      await open(tester, film(), prefs: prefs, device: phone, size: phoneSize);
      expect(pageScrollOffset(tester), 0);
      // To the foot of the page, which the sources are what make long.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
      await tester.pumpAndSettle();
      final scrolled = pageScrollOffset(tester);
      expect(scrolled, greaterThan(100));
      await leave(tester);

      // The addons not asked yet: the page is the title and little else.
      final core = await open(
        tester,
        film()..['streams'] = <Object>[],
        prefs: prefs,
        device: phone,
        size: phoneSize,
        settle: false,
      );
      expect(pageScrollOffset(tester), lessThan(scrolled));

      core.setState(CoreField.metaDetails, film());
      await tester.pumpAndSettle();
      expect(pageScrollOffset(tester), closeTo(scrolled, 1));
    });

    testWidgets('and a page the viewer drags while it grows stays where '
        'they dragged it', (tester) async {
      final (prefs, _) = await freshPrefs();
      await open(tester, film(), prefs: prefs, device: phone, size: phoneSize);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
      await tester.pumpAndSettle();
      final scrolled = pageScrollOffset(tester);
      await leave(tester);

      final core = await open(
        tester,
        film()..['streams'] = <Object>[],
        prefs: prefs,
        device: phone,
        size: phoneSize,
        settle: false,
      );
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(pageScrollOffset(tester), 0);

      core.setState(CoreField.metaDetails, film());
      await tester.pumpAndSettle();
      expect(pageScrollOffset(tester), 0);
      expect(scrolled, greaterThan(0));
    });

    testWidgets('and leaving before it has got there keeps where it was '
        'left', (tester) async {
      final (prefs, _) = await freshPrefs();
      await open(tester, film(), prefs: prefs, device: phone, size: phoneSize);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
      await tester.pumpAndSettle();
      final scrolled = pageScrollOffset(tester);
      await leave(tester);
      expect(prefs.detailsVisits.forMeta(movieId)?.offset, scrolled);

      await open(
        tester,
        film()..['streams'] = <Object>[],
        prefs: prefs,
        device: phone,
        size: phoneSize,
        settle: false,
      );
      expect(pageScrollOffset(tester), lessThan(scrolled));
      await leave(tester);
      expect(prefs.detailsVisits.forMeta(movieId)?.offset, scrolled);
    });

    testWidgets('and at the top from Continue watching', (tester) async {
      final (prefs, _) = await freshPrefs();
      await open(tester, film(), prefs: prefs, device: phone, size: phoneSize);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(pageScrollOffset(tester), greaterThan(0));
      await leave(tester);

      await open(
        tester,
        played(film()),
        prefs: prefs,
        device: phone,
        size: phoneSize,
        openedFrom: DetailsOpenedFrom.continueWatching,
      );
      expect(pageScrollOffset(tester), 0);
    });
  });
}
