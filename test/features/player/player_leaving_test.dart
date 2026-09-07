import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/cast/cast_client.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../../support/fake_cast_client.dart';
import '../../support/fixtures.dart';
import '../../support/player_harness.dart';

/// What may act on the player between the press that leaves and the
/// teardown coming back.
///
/// The screen used to be gone by then: it popped at once and released the
/// engine two frames later, so there was nobody left to answer an event.
/// Waiting for the teardown with the picture still in the tree is right,
/// and it puts the screen somewhere it has never been -- alive, built,
/// subscribed, and holding an engine that is being released. Every handler
/// it still has is a way for the last seconds of a session to change what
/// the viewer comes back to.
///
/// So the rule is not a guard per handler: the screen lets go of
/// everything that could reach the player before it awaits anything, and
/// each test here names one thing that used to get through.
///
/// What letting go cannot reach is an `await` that was already out when
/// the press landed. That half is `player_leaving_awaits_test.dart`.
void main() {
  const total = Duration(minutes: 96);
  const watched = Duration(minutes: 37);

  const livingRoom = CastDevice(
    id: 'device-1',
    name: 'Living Room TV',
    model: 'Chromecast',
  );

  /// A film 37 minutes in, playing, with its teardown held open so that
  /// every test here runs inside the wait.
  Future<PlayerHarness> pumpWatching(
    WidgetTester tester,
    Completer<void> wedged, {
    Map<String, dynamic>? player,
    CastClient? cast,
    LanMediaControl? lanMedia,
  }) async {
    final harness = PlayerHarness(
      player: player,
      cast: cast,
      lanMedia: lanMedia,
      configureEngine: (engine) => engine.disposeGate = wedged,
    );
    await harness.pumpPushed(tester);
    harness.engine.emitDuration(total);
    harness.engine.emitPosition(watched);
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);
    return harness;
  }

  testWidgets('a film left part-way is still reported at the position it '
      'was watched to', (tester) async {
    // The worst thing this wait made possible. `MediaKitEngine.dispose`
    // stops the player, and media_kit's `stop` defaults to `notify: true`:
    // it pushes `position: Duration.zero` and then `duration:
    // Duration.zero` down the same streams the screen has been listening
    // to all session. The zero position arrives while the duration is
    // still the film's, which is exactly the shape `_reportTime` forwards
    // -- so the last thing the core heard about a film the viewer left at
    // 37 minutes was that they were at the start of it, and
    // continue-watching offered it back from the beginning.
    //
    // Nothing later corrects that: it is the last report of the session.
    final wedged = Completer<void>();
    final harness = await pumpWatching(tester, wedged);
    expect(
      harness.lastPlayerArgs('TimeChanged')?['time'],
      watched.inMilliseconds,
      reason: 'where the viewer got to',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    wedged.complete();
    await tester.pumpAndSettle();

    expect(harness.engine.disposed, isTrue, reason: 'the stop has run');
    expect(
      harness.lastPlayerArgs('TimeChanged')?['time'],
      watched.inMilliseconds,
      reason: 'and the film is still 37 minutes in',
    );
  });

  testWidgets('an end of file during the wait does not re-open the stream', (
    tester,
  ) async {
    // A read that stops making progress reaches mpv as an end of file, and
    // a stop reaches it as one too. Ten seconds into a two-hour film that
    // is not an ending, so the screen re-opens the stream where playback
    // stopped -- a fresh `loadfile` and a fresh HTTP read on the engine it
    // is in the middle of releasing.
    final wedged = Completer<void>();
    final harness = await pumpWatching(tester, wedged);
    final engine = harness.engine;
    expect(engine.opened, hasLength(1));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    engine.emitCompleted();
    await pumpEvents(tester);

    expect(engine.opened, hasLength(1), reason: 'nothing is re-opened');
    wedged.complete();
    await tester.pumpAndSettle();
    expect(engine.opened, hasLength(1));
  });

  testWidgets('the app going to the background during the wait does not '
      'pause the player', (tester) async {
    // `pauseOnMinimize` is about a playback the viewer is coming back to.
    // A player being released is not one, and media_kit throws on a player
    // it has already let go.
    final ctx = loadCtxLoggedOutFixture();
    (ctx['profile']['settings'] as Map<String, dynamic>)['pauseOnMinimize'] =
        true;
    final wedged = Completer<void>();
    final harness = PlayerHarness(
      ctx: ctx,
      configureEngine: (engine) => engine.disposeGate = wedged,
    );
    await harness.pumpPushed(tester);
    harness.engine.emitDuration(total);
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }

    expect(harness.engine.pauseCalls, 0);
    wedged.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a cast session ending during the wait does not seek and play '
      'the player', (tester) async {
    // A session ends elsewhere -- the receiver's own remote, the system
    // notification, another phone -- and playback comes back to this
    // device exactly as if Stop had been pressed here: a seek to where the
    // receiver got to, and a play. Both on an engine that is being
    // released, and both after the viewer has left.
    final cast = FakeCastClient(devices: const [livingRoom]);
    final lan = FakeLanMediaControl()
      ..baseUrl = Uri.parse('http://192.168.1.20:39271/');
    final fixture = loadPlayerFixture();
    final stream =
        (fixture['selected'] as Map<String, dynamic>)['stream']
            as Map<String, dynamic>;
    stream['behaviorHints'] = {'filename': 'film.mp4'};
    final content =
        (fixture['stream'] as Map<String, dynamic>)['content'] as List<dynamic>;
    (content[1] as Map<String, dynamic>)['behaviorHints'] = {
      'filename': 'film.mp4',
    };
    final wedged = Completer<void>();
    final harness = await pumpWatching(
      tester,
      wedged,
      player: fixture,
      cast: cast,
      lanMedia: lan,
    );

    await tester.tap(find.byKey(const ValueKey('cast')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cast-device-device-1')));
    await tester.pumpAndSettle();
    expect(cast.loads, hasLength(1), reason: 'the receiver has the stream');
    final seeksBefore = harness.engine.seeks.length;
    final playsBefore = harness.engine.playCalls;

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await cast.disconnect();
    await tester.pumpAndSettle();

    expect(harness.engine.seeks, hasLength(seeksBefore));
    expect(harness.engine.playCalls, playsBefore);
    wedged.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('an open waiting to be retried is not retried during the wait', (
    tester,
  ) async {
    // The retry is a whole `open` on the engine being released, and it is
    // armed for exactly the case a viewer gives up on: a torrent that is
    // still starting and a stream that will not open yet.
    final wedged = Completer<void>();
    final harness = PlayerHarness(
      configureEngine: (engine) {
        engine.openError = 'Failed to open the stream';
        engine.disposeGate = wedged;
      },
    );
    harness.torrentStats.response = const TorrentStats(
      phase: TorrentPhase.checking,
      checkedBytes: 250,
      checkTotalBytes: 1000,
    );
    await harness.pumpPushed(tester);
    expect(harness.engine.opened, hasLength(1), reason: 'and it failed');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    harness.engine.openError = null;
    await tester.pump(PlayerScreen.torrentOpenRetryBackoff * 3);
    await tester.pump();

    expect(harness.engine.opened, hasLength(1));
    wedged.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a mouse moved over the picture during the wait arms nothing', (
    tester,
  ) async {
    // The last door left open. The `MouseRegion` sits above the
    // `IgnorePointer` that covers everything else, so a hover still
    // arrives while the screen is waiting -- and it used to bring the OSD
    // back up, re-arm the fade timer that [PlayerScreen._detach] had just
    // cancelled, and start the stats hover timer. Both timers then
    // outlived the screen, which is the shape the detach exists to
    // prevent: the test binding is what says so, since a timer still
    // pending when the tree has gone fails the test on its own.
    final wedged = Completer<void>();
    final harness = await pumpWatching(tester, wedged);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('video surface')));
    await tester.pump();

    expect(controlsOpacity(tester), 0, reason: 'nothing came back up');
    wedged.complete();
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsNothing);
    expect(harness.engine.disposed, isTrue);
  });

  testWidgets('the torrent poll stops at the press, not at the pop', (
    tester,
  ) async {
    // The start-up poll runs every half second and asks the server over
    // FFI. Nothing it could learn is worth anything to a screen whose
    // player is being released, and the wait is as long as the teardown
    // takes.
    final wedged = Completer<void>();
    final harness = PlayerHarness(
      configureEngine: (engine) => engine.disposeGate = wedged,
    );
    await harness.pumpPushed(tester);
    await tester.pump(PlayerScreen.torrentStatsInterval);
    await tester.pump();
    expect(harness.torrentStats.requests, isNotEmpty, reason: 'it was polling');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    final asked = harness.torrentStats.requests.length;
    await tester.pump(PlayerScreen.torrentStatsInterval * 4);
    await tester.pump();

    expect(harness.torrentStats.requests, hasLength(asked));
    wedged.complete();
    await tester.pumpAndSettle();
  });
}
