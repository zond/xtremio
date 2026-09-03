import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/track_menus.dart';
import 'package:xtremio/features/player/up_next_card.dart';

import '../../support/fake_downloads_client.dart';
import '../../support/fixtures.dart';
import '../../support/player_harness.dart';

/// Moving on to the next episode: the up-next countdown after the credits,
/// the Next button, and where the next stream comes from.
void main() {
  const nextId = 'tt0063350:1:2';
  const nextVideo = {
    'id': nextId,
    'title': 'The Cellar',
    'season': 1,
    'episode': 2,
  };
  const nextStream = {'url': 'https://x.example/e2.mp4', 'name': 'Direct'};

  /// A profile whose up-next card counts down 10 s (the default is 35 s).
  Map<String, dynamic> ctxWithTenSeconds() {
    final ctx = loadCtxLoggedOutFixture();
    ctx['profile']['settings']['nextVideoNotificationDuration'] = 10000;
    return ctx;
  }

  PlayerHarness harnessWithNext({
    bool withStream = true,
    DownloadsClient? downloads,
  }) {
    final harness = PlayerHarness(
      ctx: ctxWithTenSeconds(),
      subtitlesPath: const ResourcePath(
        resource: 'subtitles',
        type: 'series',
        id: 'tt0063350:1:1',
      ),
      downloads: downloads,
    );
    harness.fixture['nextVideo'] = nextVideo;
    harness.fixture['nextStream'] = withStream ? nextStream : null;
    return harness;
  }

  Map<String, dynamic> loadArgs(CoreAction action) =>
      action.action['args']['args'] as Map<String, dynamic>;

  /// The registry key the next episode's download has: the meta the player
  /// was loaded for, and that episode.
  const nextKey = 'tt0063350:$nextId';
  const nextPath = '/downloads/breaking/e2.mkv';

  /// A client holding a finished download of the next episode.
  FakeDownloadsClient withNextEpisodeOnDisk() => FakeDownloadsClient(
    registry: DownloadsRegistry(
      items: {
        nextKey: DownloadView(const {
          'metaId': 'tt0063350',
          'videoId': nextId,
          'type': 'series',
          'name': 'S1E2',
          'stream': {
            'infoHash': 'cccccccccccccccccccccccccccccccccccccccc',
            'fileIdx': 1,
            'name': 'Torrentio',
            'behaviorHints': {'bingeGroup': 'pdm-1080p'},
          },
          'state': 'complete',
          'size': 1000,
          'downloaded': 1000,
          'path': nextPath,
        }),
      },
    ),
  );

  /// The `Load Player` stream of the last load, which is what the next
  /// episode's player was handed.
  Map<String, dynamic> lastLoadedStream(PlayerHarness harness) =>
      loadArgs(
            harness.core.dispatched.lastWhere(
              (a) => a.action['action'] == 'Load',
            ),
          )['stream']
          as Map<String, dynamic>;

  testWidgets('counts down after the end and plays the next stream', (
    tester,
  ) async {
    useWideViewport(tester);
    final harness = harnessWithNext();
    await harness.pump(tester);
    final engine = harness.engine;
    expect(find.byTooltip('Next episode (N)'), findsOneWidget);
    expect(find.byType(UpNextCard), findsNothing);

    engine.emitCompleted();
    await pumpEvents(tester);
    expect(harness.playerActions(), contains('Ended'));
    expect(find.byType(UpNextCard), findsOneWidget);
    expect(find.text('S1E2 · The Cellar'), findsOneWidget);
    expect(find.text('Playing in 10 s'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Playing in 9 s'), findsOneWidget);

    // Cancel keeps us here; the countdown is gone.
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(find.byType(UpNextCard), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    expect(harness.playerActions(), isNot(contains('NextVideo')));
    expect(harness.engines, hasLength(1));

    // Let it run out: the core advances, a new player takes over with the
    // engine's stream for the episode, and this one does not unload the
    // core's player on its way out.
    engine.emitCompleted();
    await pumpEvents(tester);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(harness.playerActions(), contains('NextVideo'));
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(harness.engines, hasLength(2));
    expect(engine.disposed, isTrue);
    final loads = harness.core.dispatched
        .where((a) => a.action['action'] == 'Load')
        .toList();
    expect(loads, hasLength(2));
    final next = loadArgs(loads.last);
    expect(next['stream'], nextStream);
    expect(next['streamRequest']['path']['id'], nextId);
    expect(
      next['streamRequest']['base'],
      harness.selected['streamRequest']['base'],
    );
    expect(next['metaRequest'], harness.selected['metaRequest']);
    expect(next['subtitlesPath']['id'], nextId);
    expect(
      harness.core.dispatched.where(
        (a) => a.action['action'] == 'Unload' && a.field == CoreField.player,
      ),
      isEmpty,
    );
  });

  testWidgets('without a stream for it, hands the episode back to the caller', (
    tester,
  ) async {
    useWideViewport(tester);
    final harness = harnessWithNext(withStream: false);
    PlayerScreenResult? result;
    await harness.pump(
      tester,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push(
                MaterialPageRoute<PlayerScreenResult>(
                  builder: (_) => harness.screen(),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pumpAndSettle();
    expect(harness.playerActions(), contains('NextVideo'));
    expect(find.byType(PlayerScreen), findsNothing);
    expect(result?.selectVideoId, nextId);
    // A normal exit: the player is unloaded.
    expect(
      harness.core.dispatched.last.action,
      CoreActions.unload(CoreField.player).action,
    );
  });

  testWidgets('binges into a downloaded episode off the disk', (tester) async {
    // A whole file for the next episode is on the device, so there is
    // nothing for the server -- or the network -- to do, connection or
    // not. The addon's stream for it is only the fallback.
    useWideViewport(tester);
    final downloads = withNextEpisodeOnDisk();
    addTearDown(downloads.dispose);
    final harness = harnessWithNext(downloads: downloads);
    await harness.pump(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pumpAndSettle();

    expect(downloads.opens, [nextKey]);
    expect(lastLoadedStream(harness), {
      'url': 'file://$nextPath',
      'name': 'Torrentio',
      'behaviorHints': {'filename': 'e2.mkv', 'bingeGroup': 'pdm-1080p'},
    });
    expect(harness.engines, hasLength(2));
  });

  testWidgets('binges offline, where the core has no stream for it', (
    tester,
  ) async {
    // With no connection the next episode's streams never load, so the
    // core offers none -- but the episode is on the disk, which is a
    // stream this screen can make for itself.
    useWideViewport(tester);
    final downloads = withNextEpisodeOnDisk();
    addTearDown(downloads.dispose);
    final harness = harnessWithNext(withStream: false, downloads: downloads);
    await harness.pump(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(lastLoadedStream(harness)['url'], 'file://$nextPath');
    expect(harness.engines, hasLength(2));
    // A hand-over, not an exit: the core's player stays loaded for the
    // screen that took this one's place.
    expect(
      harness.core.dispatched.where(
        (a) => a.action['action'] == 'Unload' && a.field == CoreField.player,
      ),
      isEmpty,
    );
  });

  testWidgets('an episode that is not downloaded streams as before', (
    tester,
  ) async {
    useWideViewport(tester);
    final downloads = FakeDownloadsClient();
    addTearDown(downloads.dispose);
    final harness = harnessWithNext(downloads: downloads);
    await harness.pump(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pumpAndSettle();

    expect(lastLoadedStream(harness), nextStream);
  });

  testWidgets('holds the countdown while a sheet is open', (tester) async {
    useWideViewport(tester);
    final harness = harnessWithNext();
    await harness.pump(tester);
    await tester.tap(find.byTooltip('Playback settings'));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerSettingsSheet), findsOneWidget);

    // The episode ends under the sheet: the end is reported, but the
    // countdown does not run, so nothing replaces the sheet's route.
    harness.engine.emitCompleted();
    await pumpEvents(tester);
    expect(harness.playerActions(), contains('Ended'));
    await tester.pump(const Duration(seconds: 15));
    expect(harness.playerActions(), isNot(contains('NextVideo')));
    expect(find.byType(PlayerSettingsSheet), findsOneWidget);
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(harness.engines, hasLength(1));

    // Closing the sheet starts the countdown, and the hand-off replaces
    // the player as usual.
    Navigator.of(tester.element(find.byType(PlayerSettingsSheet))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(PlayerSettingsSheet), findsNothing);
    expect(find.text('Playing in 10 s'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(harness.playerActions(), contains('NextVideo'));
    expect(harness.engines, hasLength(2));
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(find.byType(UpNextCard), findsNothing);
  });

  testWidgets('drops the countdown when the next episode goes away', (
    tester,
  ) async {
    useWideViewport(tester);
    final harness = harnessWithNext();
    await harness.pump(tester);
    harness.engine.emitCompleted();
    await pumpEvents(tester);
    expect(find.byType(UpNextCard), findsOneWidget);

    // The core no longer offers a next video.
    final without = Map<String, dynamic>.from(harness.fixture)
      ..['nextVideo'] = null;
    harness.core.setState(CoreField.player, without);
    await pumpEvents(tester);
    expect(find.byType(UpNextCard), findsNothing);
    await tester.pump(const Duration(seconds: 12));
    expect(harness.playerActions(), isNot(contains('NextVideo')));

    // When it is back, no stale countdown is still running against it.
    harness.core.setState(CoreField.player, harness.fixture);
    await pumpEvents(tester);
    expect(find.byType(UpNextCard), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    expect(harness.playerActions(), isNot(contains('NextVideo')));
    expect(harness.engines, hasLength(1));
  });

  testWidgets('a movie offers no next episode', (tester) async {
    useWideViewport(tester);
    final harness = PlayerHarness();
    await harness.pump(tester);
    expect(find.byTooltip('Next episode (N)'), findsNothing);
    harness.engine.emitCompleted();
    await pumpEvents(tester);
    expect(find.byType(UpNextCard), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pump();
    expect(harness.playerActions(), isNot(contains('NextVideo')));
  });
}
