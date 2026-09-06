import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../../support/player_harness.dart';

/// Leaving a player has to stop it.
///
/// On the owner's Chromecast one RD/HTTP title played for ninety seconds
/// and was backed out of. 158 MB came back at the press and the volume
/// then kept draining at a steady ~32 Mbps with no player on screen, until
/// a force-stop returned 928 MB in one piece. Blocks that only come back
/// when the process dies are held by a file with no directory entry, and
/// `demuxer-cache-unlink-files=immediate` is the only thing this app
/// unlinks -- so an mpv outlived the screen that owned it, and something
/// else that had been holding the disk alongside it died on the press.
///
/// The screen always asked for a teardown. What it could not do is make one
/// arrive: the release is deferred by two frames on purpose -- the raster
/// thread may still be drawing a frame that references the video texture --
/// and it then awaits mpv's own `stop()`, which blocks and retries for as
/// long as the volume it is writing to has no room left. So the release is
/// slowest exactly when a player still filling the disk costs the most. The
/// hand-over is the same evening from the other side: it opens the next
/// episode's player before the outgoing one has been told anything, so two
/// demuxers hold one volume and each limiter believes it is alone.
///
/// What must not wait on any of that is the one property write that ends
/// the growth. The order is the fix, and the order is what is pinned here.
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

  testWidgets('the disk writing stops on the frame the screen goes, not with '
      'the teardown', (tester) async {
    // The ordering, which is the whole of the first half of the fix. The
    // teardown is deferred two frames on purpose -- the raster thread may
    // still be drawing a frame that references the video texture -- and it
    // can then block for as long as mpv is blocked, which on a full volume
    // is indefinitely. Every second of that is more of the volume, so what
    // must not wait for it is the one property write that ends the growth.
    //
    // Unmounted directly rather than through a route: what is being timed
    // is the two frames between the screen going and the teardown starting,
    // and a pop's transition would hide them.
    final harness = PlayerHarness();
    await harness.pump(tester);
    final engine = harness.engine;
    harness.calls.clear();

    await tester.pumpWidget(const SizedBox());

    expect(engine.stopWritingCalls, 1, reason: 'the bleeding stops at once');
    expect(
      engine.disposeAsked,
      isFalse,
      reason: 'while the teardown has not even been asked for yet',
    );

    await tester.pumpAndSettle();

    expect(harness.calls, ['stop-writing', 'dispose']);
    expect(engine.disposed, isTrue);
  });

  testWidgets('a hand-over stops the outgoing player writing before the next '
      'one opens', (tester) async {
    // The second mechanism, and the one the 158 MB blip fits. A
    // `pushReplacement` keeps this screen alive until the transition ends,
    // so its `dispose` is a third of a second away and the successor has
    // already opened its own stream by then: two demuxers, one volume, and
    // a per-media limiter on each that cannot see the other. The outgoing
    // one is reading ahead for a media the viewer has left, which buys
    // nothing at any price.
    //
    // Only the writing is stopped here, not the player: the outgoing
    // screen is still on screen for the length of the transition, and
    // freeing its video texture under the raster thread is what the
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
      harness.engines.first.stopWritingCalls,
      1,
      reason: 'the outgoing player must not still be filling the disk',
    );
    expect(
      harness.engines.first.disposed,
      isFalse,
      reason: 'and it must still have its texture, which is still on screen',
    );

    await tester.pumpAndSettle();
    expect(harness.engines.first.disposed, isTrue);
  });
}
