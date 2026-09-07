import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/player_controls.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../../support/diagnostics_capture.dart';
import '../../support/fixtures.dart';
import '../../support/player_harness.dart';
import '../../support/tv.dart';

/// Leaving a player has to stop it, and the order it does that in is the
/// whole of what this file pins.
///
/// On the owner's Chromecast one RD/HTTP title played for ninety seconds
/// and was backed out of. 158 MB came back at the press and the volume
/// then kept draining at a steady ~32 Mbps with no player on screen, until
/// a force-stop returned 928 MB in one piece: an mpv had outlived the
/// screen that owned it, and was still filling a cache file with no
/// directory entry.
///
/// The screen used to have it backwards. It left at once, released the
/// engine two frames later through a future nobody held, and sent the
/// `quit` -- the one thing that actually ends the read -- only if a
/// ten-second deadline expired. So the fast fix was withheld until the
/// slow path had failed, and the video texture and the audio device were
/// let go by whatever media_kit did in the background, at no defined
/// moment relative to mpv being gone.
///
/// It is the other way round now: `quit` first, then wait for the teardown
/// with the picture still on screen and the sinks still being drained,
/// then leave. Outcomes alone cannot tell that apart from what it replaced
/// -- both end with a released engine and no screen -- so what is asserted
/// here is the order.
void main() {
  /// The player pushed onto a route, which is how the app opens it and
  /// what [PlayerHarness.pump] on its own is not: mounted as the root
  /// route there is nothing to leave to.
  Future<void> pumpPushed(WidgetTester tester, PlayerHarness harness) async {
    useWideViewport(tester);
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
  }

  /// Everything the app said about the player that was not the routine
  /// `info` line: what a report would have carried out of that evening.
  List<String> complaints(List<String> lines) => [
    for (final line in lines)
      if (line.startsWith('warn player') || line.startsWith('error player'))
        line,
  ];

  /// What the fake engine draws, so a test can ask whether the video sink
  /// is still in the tree.
  final video = find.text('video surface');

  testWidgets('leaving sends the quit before it waits for anything', (
    tester,
  ) async {
    // The inversion, at its narrowest. `quit` is the kill and it is what
    // makes the `stop` inside media_kit's own teardown come back promptly
    // instead of waiting out a five-minute `network-timeout`, so it goes
    // out at the press -- not on a deadline, and not behind the teardown
    // it is there to unstick.
    final wedged = Completer<void>();
    final harness = PlayerHarness(
      // Proxied, so that the close has something to close and takes its
      // place in the log between the two.
      player: remoteStreamFixture('https://rd.example/dl/tok/film.mkv'),
      configureEngine: (engine) => engine.disposeGate = wedged,
    );
    await pumpPushed(tester, harness);
    final engine = harness.engine;
    harness.calls.clear();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(engine.quitCalls, 1, reason: 'the read is already ending');
    expect(
      harness.calls,
      ['quit', 'close-streams', 'dispose'],
      reason:
          'and in that order: the server documents quit-then-close, '
          'because a demuxer that has already been cancelled never '
          'reaches its reconnect',
    );

    wedged.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('the picture stays up until the teardown returns, and the '
      'screen goes only after it', (tester) async {
    // media_kit releases the video texture and the audio device from
    // inside `Player.dispose`, after its `stop()`. So the sinks are alive
    // for exactly as long as mpv might still be handing them something --
    // provided the widget that draws them is still there, which is what
    // waiting here rather than from `State.dispose` buys.
    //
    // Both halves matter and only the order tells them apart: a screen
    // that left first would also end with a released engine.
    final wedged = Completer<void>();
    final harness = PlayerHarness(
      configureEngine: (engine) => engine.disposeGate = wedged,
    );
    await pumpPushed(tester, harness);
    final engine = harness.engine;

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    // Settled, not one frame: a screen that popped and let its exit
    // transition run would still be on screen a frame after the press, and
    // that is exactly the mistake being ruled out here.
    await tester.pumpAndSettle();

    expect(engine.disposeAsked, isTrue, reason: 'the teardown is running');
    expect(engine.disposed, isFalse, reason: 'and has not come back');
    expect(find.byType(PlayerScreen), findsOneWidget, reason: 'still here');
    expect(video, findsOneWidget, reason: 'and still drawing the texture');

    wedged.complete();
    await tester.pumpAndSettle();

    expect(engine.disposed, isTrue);
    expect(find.byType(PlayerScreen), findsNothing);
    expect(video, findsNothing, reason: 'released only now');
  });

  testWidgets('the screen goes on working while the player stops', (
    tester,
  ) async {
    // The wait must yield, never block. A blocking join would deadlock in
    // precisely the case worth waiting for -- mpv waiting on the video
    // sink, the sink waiting on us -- which is what the community Android
    // client does, `pthread_join` and then `mpv_terminate_destroy` inline
    // on the UI thread, and an ANR is what it gets for it.
    //
    // No test on this side can reach that: a wait that really blocked
    // would hang the run rather than fail it, and Dart has no way to
    // express one here in the first place. What this pins is the shape
    // that keeps it out -- an `await` in an ordinary async method, with
    // the screen still laying out and rebuilding the video surface while
    // mpv has not come back. Keeping the sink alive means keeping it
    // consuming, and a tree that has stopped being rebuilt is not
    // consuming anything.
    //
    // What asks for the rebuild here is the framework and not the engine:
    // the screen lets go of every engine subscription at the press
    // (`PlayerScreen._detach`), so an event is the one stimulus it is
    // deliberately deaf to by then. A window resize is the ordinary thing
    // that still arrives -- an exit transition, a rotation, a system bar
    // -- and answering it is what a live tree does.
    final wedged = Completer<void>();
    final harness = PlayerHarness(
      configureEngine: (engine) => engine.disposeGate = wedged,
    );
    await pumpPushed(tester, harness);
    final engine = harness.engine;

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    final builtWhenLeft = engine.videoBuilds;

    tester.view.physicalSize = const Size(1000, 700);
    await pumpEvents(tester);

    expect(engine.disposed, isFalse, reason: 'still stopping');
    expect(
      engine.videoBuilds,
      greaterThan(builtWhenLeft),
      reason: 'and the screen rebuilt around it while it waited',
    );

    wedged.complete();
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsNothing);
  });

  testWidgets('on a television the remote is handed back before the wait', (
    tester,
  ) async {
    // The screen stays up while the player stops, and the control bar goes
    // at the same moment: everything on it aims at an engine that is being
    // released, and media_kit throws on a player that has been. Hiding the
    // bar and handing the remote back to the video are one act here as
    // everywhere else -- a ring left on something undrawn is a press that
    // reaches a stopping player, which is the same fault as a button that
    // is drawn and dead.
    useScreen(tester, tvSize);
    final wedged = Completer<void>();
    final harness = PlayerHarness(
      device: tv,
      configureEngine: (engine) => engine.disposeGate = wedged,
    );
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

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<PlayerBottomBar>(), isTrue, reason: 'the remote is on it');

    // Stop, which has no ladder to come down first.
    await press(tester, LogicalKeyboardKey.mediaStop);
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen), findsOneWidget, reason: 'still waiting');
    expect(video, findsOneWidget, reason: 'and still drawing');
    expect(controlsOpacity(tester), 0, reason: 'but offering nothing');
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'player',
      reason: 'and the remote is back on the video',
    );

    wedged.complete();
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsNothing);
  });

  testWidgets('a teardown that never comes back keeps the viewer for the '
      'bound and no longer', (tester) async {
    // `MediaKitEngine.dispose` awaits `_player.stop()`, and a stop is
    // answered by the mpv core thread -- the thread that has to answer for
    // whatever the playback was doing. Every teardown ever measured here
    // came back in a fraction of a second, and the one that did not is the
    // one this bound exists for.
    //
    // Nothing is escalated to when it expires, because there is nothing
    // stronger than the `quit` that already went out. All it does is stop
    // the viewer waiting.
    final lines = captureDiagnostics();
    final wedged = Completer<void>();
    final harness = PlayerHarness(
      configureEngine: (engine) => engine.disposeGate = wedged,
    );
    addTearDown(wedged.complete);
    await pumpPushed(tester, harness);
    final engine = harness.engine;

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget, reason: 'still waiting');

    await tester.pump(PlayerScreen.teardownBound);
    await tester.pumpAndSettle();

    // The viewer is back on the details screen and the stop has still not
    // answered.
    expect(find.byType(PlayerScreen), findsNothing);
    expect(engine.quitCalls, 1, reason: 'it was asked to stop at the press');
    expect(engine.disposeAsked, isTrue, reason: 'and the teardown ran');
    expect(engine.disposed, isFalse, reason: 'and mpv never answered');

    // Where the ninety seconds used to go: no line, no bound, nothing a
    // copied report could have shown. This is the only instrument that
    // would say the unexplained failure had come back.
    expect(
      complaints(lines),
      isNotEmpty,
      reason: 'a player that would not stop is what diagnostics are for',
    );
    expect(complaints(lines).single, contains('has not stopped'));
  });

  testWidgets('a player that stops after the bound says so', (tester) async {
    // The distinction a report is read for. "Slow" and "never stopped"
    // want different things looked at next, and until the teardown lands
    // there is nothing to tell them apart with, so the line that separates
    // them can only be written when it does.
    final lines = captureDiagnostics();
    final wedged = Completer<void>();
    final harness = PlayerHarness(
      configureEngine: (engine) => engine.disposeGate = wedged,
    );
    await pumpPushed(tester, harness);
    final engine = harness.engine;

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 2));

    wedged.complete();
    await tester.pumpAndSettle();

    expect(engine.disposed, isTrue, reason: 'it got there in the end');
    expect(lines, contains(startsWith('info player the player stopped ')));
  });

  testWidgets('a teardown that answers in time says nothing at all', (
    tester,
  ) async {
    // The other side of the bound, and the one that must not be noisy: an
    // ordinary teardown takes a fraction of a second, and a report full of
    // lines about players that stopped normally is a report nobody reads.
    final lines = captureDiagnostics();
    final harness = PlayerHarness();
    await pumpPushed(tester, harness);
    final engine = harness.engine;

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    // Well past the bound, which is the point: the timer was cancelled,
    // not merely not reached yet.
    await tester.pump(const Duration(minutes: 2));
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen), findsNothing);
    expect(engine.disposed, isTrue);
    expect(complaints(lines), isEmpty, reason: 'nothing to complain of');
    expect(
      lines,
      isNot(contains(startsWith('info player the player stopped'))),
      reason: 'and nothing to say about how long it took',
    );
  });

  testWidgets('a quit libmpv refused is reported, and the teardown runs '
      'anyway', (tester) async {
    // `mpv_command_async` answers `MPV_ERROR_INVALID_PARAMETER`,
    // `MPV_ERROR_UNINITIALIZED` or `MPV_ERROR_EVENT_QUEUE_FULL` without
    // enqueueing anything, and a screen that went quiet about it would be
    // leaving a player that is still running. The teardown behind it is
    // the only other thing there is, so it still runs -- and it is now the
    // slow one, since nothing cancelled the read.
    final lines = captureDiagnostics();
    final harness = PlayerHarness(
      configureEngine: (engine) =>
          engine.quitError = StateError('libmpv refused the quit'),
    );
    await pumpPushed(tester, harness);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: 'not a crash, a report');
    expect(complaints(lines), contains(contains('refused the quit')));
    expect(harness.engine.disposed, isTrue, reason: 'released regardless');
    expect(find.byType(PlayerScreen), findsNothing);
  });

  testWidgets('a teardown that throws is not swallowed, and the streams are '
      'closed anyway', (tester) async {
    // A throw out of `dispose` never reached `FlutterError.onError`
    // either: the future was `.ignore()`d before the zone saw it, so
    // `tester.takeException()` was null and the run was green whatever
    // happened. It still is -- an unhandled error is the wrong shape for
    // "the player would not stop" -- so the log is where this shows.
    //
    // And the streams are closed *before* the release for exactly this
    // reason: a throw there must not take down the one call that gets the
    // socket back.
    final lines = captureDiagnostics();
    final harness = PlayerHarness(
      player: remoteStreamFixture('https://rd.example/dl/tok/film.mkv'),
      configureEngine: (engine) =>
          engine.disposeError = StateError('mpv refused to stop'),
    );
    await pumpPushed(tester, harness);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(harness.engine.disposeAsked, isTrue);
    expect(harness.engine.disposed, isFalse);
    expect(tester.takeException(), isNull, reason: 'not a crash, a report');
    expect(complaints(lines), contains(contains('releasing the player')));
    expect(harness.proxyStreams.closed, hasLength(1));
    expect(find.byType(PlayerScreen), findsNothing, reason: 'and it leaves');
  });

  testWidgets('a hand-over does not wait for the player it is replacing', (
    tester,
  ) async {
    // A `pushReplacement` keeps this screen alive until the transition
    // ends, so its `dispose` is a third of a second away and the successor
    // has already opened its own stream by then: two players at once, for
    // as long as the transition. The outgoing one is torn down when its
    // screen really goes, unwatched -- there is nothing left to await
    // from, and the incoming player must not be held up by a teardown that
    // may not come back.
    useWideViewport(tester);
    // Only the outgoing player's teardown is wedged: what is being shown
    // is that the successor does not care.
    final wedged = Completer<void>();
    var outgoing = true;
    final harness = PlayerHarness(
      configureEngine: (engine) {
        if (outgoing) engine.disposeGate = wedged;
        outgoing = false;
      },
    );
    harness.fixture['nextVideo'] = const {
      'id': 'tt0063350:1:2',
      'title': 'The Cellar',
      'season': 1,
      'episode': 2,
    };
    harness.fixture['nextStream'] = const {
      'url': 'https://x.example/e2.mp4',
      'name': 'Direct',
    };
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(minutes: 20));
    await pumpEvents(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.mediaTrackNext);
    // One frame past the push: the successor's `initState` has run and it
    // has opened its stream. The transition has not finished.
    await tester.pump();
    await tester.pump();

    expect(harness.engines, hasLength(2), reason: 'a new player took over');
    expect(harness.engines.last.opened, isNotEmpty, reason: 'and it is open');
    expect(
      harness.engines.first.disposed,
      isFalse,
      reason: 'and it must still have its texture, which is still on screen',
    );

    await tester.pumpAndSettle();
    expect(harness.engines.first.quitCalls, 1, reason: 'the outgoing one');
    expect(harness.engines.last.quitCalls, 0, reason: 'and not the new one');
    expect(
      harness.engines.first.disposed,
      isFalse,
      reason: 'whose teardown has not come back',
    );
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(video, findsOneWidget, reason: 'and the new player is playing');

    // Past the bound, so the outgoing player's own timer has had its say
    // and there is nothing left running behind this test.
    await tester.pump(PlayerScreen.teardownBound);
    wedged.complete();
    await tester.pumpAndSettle();
  });

  group('a stream the server is holding open is ended, not waited out', () {
    /// The `p=` this player put in the URL it was given, read back out of
    /// it: the token and the URL have to be the same one, and reading it
    /// off the URL is the only way a test can say so.
    String tokenOf(Uri opened) {
      final match = RegExp(r'&p=([^&/?]+)').firstMatch(opened.toString());
      expect(match, isNotNull, reason: 'no player token in $opened');
      return Uri.decodeComponent(match!.group(1)!);
    }

    testWidgets('leaving closes the streams this player was reading', (
      tester,
    ) async {
      // The read is what the teardown is about to wait on, and
      // `network-timeout` is five minutes because a thin swarm is not a
      // dead connection. So leaving asks the server to end it -- and to
      // retire the token, which is what stops ffmpeg reconnecting straight
      // through the same URL.
      final harness = PlayerHarness(
        player: remoteStreamFixture('https://rd.example/dl/tok/film.mkv'),
      );
      await pumpPushed(tester, harness);
      final token = tokenOf(harness.engine.opened.single.$1);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(harness.proxyStreams.closed, [token]);
    });

    testWidgets('a torrent has nothing to close, and is not asked', (
      tester,
    ) async {
      // It is already a URL on the server's own reader, so no `/proxy`
      // stream was ever opened under this player's name. Asking anyway
      // would be harmless and would still be a claim about a stream that
      // does not exist.
      final harness = PlayerHarness();
      await pumpPushed(tester, harness);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(harness.engine.disposed, isTrue);
      expect(harness.proxyStreams.closed, isEmpty);
    });

    testWidgets('a close that throws still releases the player', (
      tester,
    ) async {
      // The call reaches FFI, and FFI throws -- a panic in the core, a
      // bridge that is not up. A throw crossing it would take the release
      // that follows it down as well, leaving a player holding its packet
      // memory, its socket and the engine that socket pins. Which is the
      // leak the close was added to prevent.
      final harness = PlayerHarness(
        player: remoteStreamFixture('https://rd.example/dl/tok/film.mkv'),
      );
      await pumpPushed(tester, harness);
      harness.proxyStreams.failure = StateError('the bridge is not up');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(
        harness.proxyStreams.closed,
        hasLength(1),
        reason: 'the close was attempted',
      );
      expect(
        harness.engine.disposed,
        isTrue,
        reason: 'and the player was released anyway',
      );
    });

    testWidgets('a hand-over ends the outgoing player and not its successor', (
      tester,
    ) async {
      // Two players are alive at once for the length of the transition and
      // both are reading through the proxy, which is exactly the case a
      // token exists for: the server cannot tell them apart, and the app
      // can.
      final harness = PlayerHarness(
        player: remoteStreamFixture('https://rd.example/dl/tok/e1.mkv'),
      );
      harness.fixture['nextVideo'] = const {
        'id': 'tt0063350:1:2',
        'title': 'The Cellar',
        'season': 1,
        'episode': 2,
      };
      harness.fixture['nextStream'] = const {
        'url': 'https://rd.example/dl/tok/e2.mkv',
        'name': 'Direct',
      };
      await harness.pump(tester);
      harness.engine.emitDuration(const Duration(minutes: 20));
      await pumpEvents(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.mediaTrackNext);
      await tester.pumpAndSettle();

      expect(harness.engines, hasLength(2));
      final leaving = tokenOf(harness.engines.first.opened.single.$1);
      final successor = tokenOf(harness.engines.last.opened.single.$1);
      expect(successor, isNot(leaving), reason: 'a token is per player');
      expect(harness.proxyStreams.closed, [leaving]);
    });
  });
}

/// The recorded torrent fixture rewritten into an addon's own HTTP stream,
/// which is the kind that goes through `/proxy` -- a torrent is already on
/// the server and never does.
Map<String, dynamic> remoteStreamFixture(String url) {
  final fixture = loadPlayerFixture();
  final stream = <String, dynamic>{'url': url, 'name': 'Direct'};
  (fixture['selected'] as Map<String, dynamic>)['stream'] = stream;
  fixture['stream'] = {
    'type': 'Ready',
    'content': [
      {'stream': stream, 'streaming_url': url},
      stream,
    ],
  };
  return fixture;
}
