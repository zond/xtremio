import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/up_next_card.dart';

import '../../support/fixtures.dart';
import '../../support/player_harness.dart';

/// What `profile.settings` changes in the player: the seek steps, the
/// binge gate and the up-next countdown, pause on minimize and what Esc
/// does in fullscreen.
void main() {
  const total = Duration(minutes: 96);
  const nextVideo = {
    'id': 'tt0063350:1:2',
    'title': 'The Cellar',
    'season': 1,
    'episode': 2,
  };
  const nextStream = {'url': 'https://x.example/e2.mp4', 'name': 'Direct'};

  /// The anonymous profile's `ctx` with some settings changed.
  Map<String, dynamic> ctxWith(Map<String, dynamic> settings) {
    final ctx = loadCtxLoggedOutFixture();
    (ctx['profile']['settings'] as Map<String, dynamic>).addAll(settings);
    return ctx;
  }

  /// A playing movie at 2:00 on the wide layout, over [settings].
  Future<PlayerHarness> pumpPlaying(
    WidgetTester tester,
    Map<String, dynamic> settings, {
    bool withNext = false,
  }) async {
    useWideViewport(tester);
    final harness = PlayerHarness(ctx: ctxWith(settings));
    if (withNext) {
      harness.fixture['nextVideo'] = nextVideo;
      harness.fixture['nextStream'] = nextStream;
    }
    await harness.pump(tester);
    harness.engine.emitDuration(total);
    harness.engine.emitPosition(const Duration(minutes: 2));
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);
    return harness;
  }

  Future<void> key(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
  }

  testWidgets('seek steps follow seekTimeDuration and seekShortTimeDuration', (
    tester,
  ) async {
    final harness = await pumpPlaying(tester, {
      'seekTimeDuration': 30000,
      'seekShortTimeDuration': 5000,
    });
    final engine = harness.engine;
    expect(find.byTooltip('Forward 30 seconds (→)'), findsOneWidget);
    expect(find.byIcon(Icons.forward_30), findsOneWidget);
    expect(find.byIcon(Icons.replay_30), findsOneWidget);

    await tester.tap(find.byTooltip('Forward 30 seconds (→)'));
    await tester.pump();
    await key(tester, LogicalKeyboardKey.arrowLeft);
    await key(tester, LogicalKeyboardKey.arrowRight, shift: true);
    expect(engine.seeks, [
      const Duration(minutes: 2, seconds: 30),
      const Duration(minutes: 2),
      const Duration(minutes: 2, seconds: 5),
    ]);

    // The labels follow a settings change while the player is open.
    harness.core.setState(CoreField.ctx, ctxWith({'seekTimeDuration': 15000}));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back 15 seconds (←)'), findsOneWidget);
    expect(find.byIcon(Icons.fast_rewind), findsOneWidget);
    await key(tester, LogicalKeyboardKey.keyL);
    expect(engine.seeks.last, const Duration(minutes: 2, seconds: 20));
  });

  testWidgets('the up-next card counts down nextVideoNotificationDuration', (
    tester,
  ) async {
    // The engine's default: 35 s.
    final harness = await pumpPlaying(tester, {}, withNext: true);
    harness.engine.emitCompleted();
    await pumpEvents(tester);
    expect(harness.playerActions(), contains('Ended'));
    expect(find.text('Playing in 35 s'), findsOneWidget);

    await tester.pump(const Duration(seconds: 34));
    expect(find.text('Playing in 1 s'), findsOneWidget);
    expect(harness.playerActions(), isNot(contains('NextVideo')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(harness.playerActions(), contains('NextVideo'));
    expect(harness.engines, hasLength(2));
  });

  testWidgets('a duration of 0 plays the next episode at once, no card', (
    tester,
  ) async {
    final harness = await pumpPlaying(tester, {
      'nextVideoNotificationDuration': 0,
    }, withNext: true);
    harness.engine.emitCompleted();
    await pumpEvents(tester);
    expect(find.byType(UpNextCard), findsNothing);
    await tester.pumpAndSettle();
    expect(harness.playerActions(), containsAllInOrder(['Ended', 'NextVideo']));
    expect(harness.engines, hasLength(2));
    expect(find.byType(PlayerScreen), findsOneWidget);
  });

  testWidgets('bingeWatching off ends the episode without moving on', (
    tester,
  ) async {
    final harness = await pumpPlaying(tester, {
      'bingeWatching': false,
      'nextVideoNotificationDuration': 0,
    }, withNext: true);
    harness.engine.emitCompleted();
    await pumpEvents(tester);
    expect(harness.playerActions(), contains('Ended'));
    expect(find.byType(UpNextCard), findsNothing);
    await tester.pump(const Duration(seconds: 40));
    expect(harness.playerActions(), isNot(contains('NextVideo')));
    expect(harness.engines, hasLength(1));
    // Moving on by hand still works.
    expect(find.byTooltip('Next episode (N)'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.keyN);
    await tester.pumpAndSettle();
    expect(harness.playerActions(), contains('NextVideo'));
  });

  group('pauseOnMinimize', () {
    /// Minimised and back, through the transitions the framework allows.
    Future<void> hide(WidgetTester tester) async {
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
    }

    testWidgets('pauses a playing video when the app is hidden', (
      tester,
    ) async {
      final harness = await pumpPlaying(tester, {'pauseOnMinimize': true});
      await hide(tester);
      expect(harness.engine.pauseCalls, 1);

      // Already paused: nothing to do.
      harness.engine.emitPlaying(false);
      await pumpEvents(tester);
      await hide(tester);
      expect(harness.engine.pauseCalls, 1);
    });

    testWidgets('is off by default', (tester) async {
      final harness = await pumpPlaying(tester, {});
      await hide(tester);
      expect(harness.engine.pauseCalls, 0);
    });
  });

  testWidgets('escExitFullscreen off: Esc in fullscreen leaves the player', (
    tester,
  ) async {
    // As in stremio-web, the flag only decides whether Esc leaves
    // fullscreen; off, Esc still leaves the player (which exits fullscreen
    // on its way out).
    useWideViewport(tester);
    final harness = PlayerHarness(ctx: ctxWith({'escExitFullscreen': false}));
    await harness.pump(
      tester,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => harness.screen())),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    harness.engine.emitDuration(total);
    harness.engine.emitPosition(const Duration(minutes: 2));
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);

    await key(tester, LogicalKeyboardKey.keyF);
    expect(harness.fullscreen.enters, 1);
    expect(harness.fullscreen.exits, 0);
    await key(tester, LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsNothing);
    expect(find.text('open'), findsOneWidget);
    // The one exit is the screen leaving, not the key.
    expect(harness.fullscreen.exits, 1);
  });

  testWidgets('escExitFullscreen off: F still toggles fullscreen', (
    tester,
  ) async {
    final harness = await pumpPlaying(tester, {'escExitFullscreen': false});
    await key(tester, LogicalKeyboardKey.keyF);
    expect(harness.fullscreen.enters, 1);
    await key(tester, LogicalKeyboardKey.keyF);
    expect(harness.fullscreen.exits, 1);
  });
}
