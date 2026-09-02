import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/up_next_card.dart';

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

  PlayerHarness harnessWithNext({bool withStream = true}) {
    final harness = PlayerHarness(
      subtitlesPath: const ResourcePath(
        resource: 'subtitles',
        type: 'series',
        id: 'tt0063350:1:1',
      ),
    );
    harness.fixture['nextVideo'] = nextVideo;
    harness.fixture['nextStream'] = withStream ? nextStream : null;
    return harness;
  }

  Map<String, dynamic> loadArgs(CoreAction action) =>
      action.action['args']['args'] as Map<String, dynamic>;

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
