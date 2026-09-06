import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../../support/diagnostics_capture.dart';
import '../../support/fixtures.dart';
import '../../support/player_harness.dart';

/// Leaving a player has to stop it.
///
/// On the owner's Chromecast one RD/HTTP title played for ninety seconds
/// and was backed out of. 158 MB came back at the press and the volume
/// then kept draining at a steady ~32 Mbps with no player on screen, until
/// a force-stop returned 928 MB in one piece: an mpv had outlived the
/// screen that owned it, and was still filling a cache file with no
/// directory entry.
///
/// The screen always asked. What it never did was check the answer: the
/// teardown was deferred by two frames and then `.ignore()`d, so a `stop()`
/// that hung or threw was never heard from again, and neither the log nor
/// the test suite could tell a release that finished from one that never
/// did.
///
/// **The cache file is gone and the bug is not.** The player keeps nothing
/// on disk now, so a wedged one costs memory, a socket and the server
/// engine that socket keeps live -- and a live engine is exactly what the
/// server's cleaner may not evict behind. That is smaller than a gigabyte
/// of somebody's television and it is still a player nobody can stop, which
/// is what this file pins: the teardown is awaited and answered for, and a
/// deadline that was never chained to it kills the player outright when it
/// does not come back. Only something that owes the teardown nothing can
/// get in front of a teardown that is stuck.
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

  testWidgets('leaving the player releases an engine that answers', (
    tester,
  ) async {
    // The half that always held, and the control for everything below:
    // with an engine that comes back, the deferred teardown does reach it.
    final harness = PlayerHarness();
    await pumpPushed(tester, harness);
    final engine = harness.engine;

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen), findsNothing);
    expect(engine.disposed, isTrue);
  });

  testWidgets('the teardown waits two frames, and the deadline does not', (
    tester,
  ) async {
    // The teardown is deferred on purpose -- the raster thread may still be
    // drawing a frame that references the video texture -- and it can then
    // block for as long as mpv is blocked. The deadline is armed in front
    // of those two frames rather than after them, so a screen whose frames
    // never come is still covered.
    //
    // Unmounted directly rather than through a route: what is being timed
    // is the two frames between the screen going and the teardown starting,
    // and a pop's transition would hide them.
    final harness = PlayerHarness();
    await harness.pump(tester);
    final engine = harness.engine;
    harness.calls.clear();

    await tester.pumpWidget(const SizedBox());

    expect(
      engine.disposeAsked,
      isFalse,
      reason: 'the teardown has not even been asked for yet',
    );

    await tester.pumpAndSettle();

    expect(harness.calls, ['dispose']);
    expect(engine.disposed, isTrue);
  });

  testWidgets('a teardown that never comes back ends with the player '
      'destroyed anyway', (tester) async {
    // `MediaKitEngine.dispose` awaits `_player.stop()` before it releases
    // the player, and mpv writing to a volume with no room left blocks and
    // retries -- so the stop is slowest to return exactly when a player
    // that will not die costs the most. The gate is that stop.
    //
    // This used to end at the log line, which was the whole of what the
    // app could do and not enough: a line does not give the volume its
    // blocks back, and on the evening this comes from nothing did but
    // killing the process ninety seconds later. So the deadline kills the
    // player itself, and it is a plain timer rather than anything hung off
    // the release -- everything chained behind a wedged teardown is
    // unreachable in precisely the case it is for, which is why media_kit's
    // own `mpv_terminate_destroy` never ran either.
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
    // Two minutes: longer than any bound worth putting on a stop, and the
    // span the measurement actually covers.
    await tester.pump(const Duration(minutes: 2));
    await tester.pumpAndSettle();

    // The viewer is back on the details screen, the stop has still not
    // answered -- and the player is gone regardless.
    expect(find.byType(PlayerScreen), findsNothing);
    expect(engine.disposeAsked, isTrue, reason: 'the screen did ask');
    expect(engine.disposed, isFalse, reason: 'and mpv never answered');
    expect(engine.destroyed, isTrue, reason: 'and then it was killed');
    expect(
      engine.destroyCalls,
      1,
      reason:
          'once: a deadline that re-armed would be sending a `quit` to '
          'a handle media_kit may have freed in the meantime',
    );

    // Where the ninety seconds used to go: no line, no bound, nothing a
    // copied report could have shown. The line has to say the player was
    // killed rather than that it was slow, because those want different
    // things looked at next.
    expect(
      complaints(lines),
      isNotEmpty,
      reason: 'a player that would not die is what diagnostics are for',
    );
    expect(complaints(lines).single, contains('destroying it'));
  });

  testWidgets('a kill libmpv refused is reported as a kill that failed', (
    tester,
  ) async {
    // The line was always written before the answer came back, and the
    // answer was thrown away: `mpv_command_async` returns
    // `MPV_ERROR_INVALID_PARAMETER`, `MPV_ERROR_UNINITIALIZED` or
    // `MPV_ERROR_EVENT_QUEUE_FULL` without enqueueing anything, and a
    // report that said "destroying it" and then went quiet was describing
    // a player that is still running as one that was killed. Those want
    // very different things looked at next.
    final lines = captureDiagnostics();
    final wedged = Completer<void>();
    final harness = PlayerHarness(
      configureEngine: (engine) => engine
        ..disposeGate = wedged
        ..destroyError = StateError('libmpv refused the quit'),
    );
    addTearDown(wedged.complete);
    await pumpPushed(tester, harness);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 2));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: 'not a crash, a report');
    expect(
      complaints(lines),
      contains(contains('destroying the player failed')),
    );
  });

  testWidgets('a teardown that answers in time is never destroyed', (
    tester,
  ) async {
    // The other side of the deadline, and the one that must not be noisy:
    // an ordinary teardown that takes a moment -- a stop and a file being
    // closed on a device whose volume is nearly full -- is slow rather
    // than broken, and killing it would be taking the texture out from
    // under a release that was going to arrive.
    final lines = captureDiagnostics();
    final slow = Completer<void>();
    final harness = PlayerHarness(
      configureEngine: (engine) => engine.disposeGate = slow,
    );
    await pumpPushed(tester, harness);
    final engine = harness.engine;

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.pump(PlayerScreen.teardownBound - const Duration(seconds: 1));
    slow.complete();
    await tester.pumpAndSettle();
    // Well past the deadline, which is the point: it was disarmed, not
    // merely not reached yet.
    await tester.pump(const Duration(minutes: 2));
    await tester.pumpAndSettle();

    expect(engine.disposed, isTrue);
    expect(engine.destroyCalls, 0, reason: 'nothing had to be killed');
    expect(complaints(lines), isEmpty, reason: 'and nothing to report');
  });

  testWidgets('a player that stops after it was killed says so', (
    tester,
  ) async {
    // The distinction a report is read for. "Slow" and "would not die" want
    // different things looked at next -- a full volume against a wedged
    // libmpv -- and until the release lands there is nothing to tell them
    // apart with, so the line that separates them can only be written when
    // it does.
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
    expect(engine.destroyed, isTrue);

    wedged.complete();
    await tester.pumpAndSettle();

    expect(engine.disposed, isTrue, reason: 'it got there in the end');
    expect(
      lines,
      contains(
        'info player the player stopped after it was '
        'destroyed',
      ),
    );
  });

  testWidgets('a teardown that throws is not swallowed, and the player is '
      'still killed', (tester) async {
    // The same hole from the other side. A throw out of `dispose` never
    // reached `FlutterError.onError` either: `.ignore()` ate it before the
    // zone saw it, so `tester.takeException()` is null and the run was
    // green whatever happened. It still is -- an unhandled error is the
    // wrong shape for "the player would not stop" -- so the log is where
    // this shows.
    //
    // And the deadline is deliberately not disarmed by a throw: a teardown
    // that threw is a teardown that did not finish, and the player may be
    // alive and still writing. What keeps that safe is the engine's own
    // guard -- `MediaKitEngine.destroy` reads the handle at the moment it
    // fires and asks media_kit whether it has already released it, which
    // is a fact about libmpv that no test on this side of it can reach.
    final lines = captureDiagnostics();
    final harness = PlayerHarness(
      configureEngine: (engine) =>
          engine.disposeError = StateError('mpv refused to stop'),
    );
    await pumpPushed(tester, harness);
    final engine = harness.engine;

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(engine.disposeAsked, isTrue);
    expect(engine.disposed, isFalse);
    expect(tester.takeException(), isNull, reason: 'not a crash, a report');
    expect(complaints(lines), isNotEmpty);

    await tester.pump(const Duration(minutes: 2));
    await tester.pumpAndSettle();

    expect(engine.destroyed, isTrue);
  });

  testWidgets('a hand-over keeps the outgoing player until its screen goes', (
    tester,
  ) async {
    // A `pushReplacement` keeps this screen alive until the transition
    // ends, so its `dispose` is a third of a second away and the successor
    // has already opened its own stream by then: two players at once, for
    // as long as the transition. What each of them is holding is now
    // memory and a connection to the server rather than a cache file on
    // the volume, and the outgoing one is released the moment its screen
    // really goes -- freeing its video texture any earlier is what the
    // deferred teardown exists to avoid.
    useWideViewport(tester);
    final harness = PlayerHarness();
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
    expect(harness.engines.first.disposed, isTrue);
  });

  group('a stream the server is holding open is ended, not waited out', () {
    /// The recorded torrent fixture rewritten into an addon's own HTTP
    /// stream, which is the kind that goes through `/proxy` -- a torrent is
    /// already on the server and never does.
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
      // dead connection. So the close goes in front of the release rather
      // than after it.
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
