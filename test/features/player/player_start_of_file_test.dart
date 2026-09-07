import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_engine.dart';

import '../../support/player_harness.dart';

/// Nothing before the start of the film reaches stremio-core.
///
/// A time on the wire is a `u64`, so a negative one is not a slightly
/// wrong position -- serde refuses the whole envelope and the action is
/// never dispatched at all. Two of them arrived from a Chromecast with
/// Google TV within half a second of playback starting (-7414 ms and
/// -10000 ms, the second exactly the seek step), because mpv answers
/// `time-pos` with a relative seek's raw, unclamped target from the
/// moment the seek is queued until the first frame after it lands: a step
/// of ten seconds back from 2.586 s puts -7.414 on the position stream,
/// and the player forwards the position stream to the core.
///
/// Both halves are held here: the press does not ask for a position
/// before the start, and the builder does not put one on the wire
/// whatever it is handed.
void main() {
  const total = Duration(minutes: 96);
  const step = Duration(seconds: 10);

  /// The player playing [total] long, [at] into it.
  Future<PlayerHarness> pumpPlayingAt(WidgetTester tester, Duration at) async {
    useWideViewport(tester);
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitDuration(total);
    harness.engine.emitPosition(at);
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);
    return harness;
  }

  group('a step back from inside the first step lands on the start', () {
    testWidgets('it is asked for as a position, not as a distance', (
      tester,
    ) async {
      // The press that produced -7414: 2.586 s in, ten seconds back.
      final harness = await pumpPlayingAt(
        tester,
        const Duration(milliseconds: 2586),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      // An exact seek to zero, because mpv would work a relative one's
      // target out itself and report the negative it got. It is still a
      // seek: the viewer asked to go back and the film goes to the
      // start, rather than the press doing nothing.
      expect(harness.engine.seeks, [Duration.zero]);
      expect(harness.engine.scans, isEmpty);
      // The bar and the core agree on where that is, as they did before.
      expect(harness.lastPlayerArgs('Seek')?['time'], 0);
    });

    testWidgets('a step that stays inside the file is still a scan', (
      tester,
    ) async {
      // The rule is about the ends of the file and nothing else: mpv is
      // the one that knows where the keyframes are.
      final harness = await pumpPlayingAt(tester, const Duration(minutes: 20));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      expect(harness.engine.scans, [-step]);
      expect(harness.engine.seeks, isEmpty);
    });
  });

  testWidgets('a position report from before the start is never forwarded '
      'as one', (tester) async {
    // What mpv actually put on the stream. The player cannot stop it
    // arriving -- the seek it answers may be one mpv made of its own
    // accord, and a Cast receiver reports positions nobody here computed
    // -- so the clamp on the way out is what holds.
    final harness = await pumpPlayingAt(tester, const Duration(seconds: 65));
    harness.engine.emitPosition(const Duration(milliseconds: -7414));
    await pumpEvents(tester);

    expect(harness.lastPlayerArgs('TimeChanged')?['time'], 0);
  });

  group('the builders are the last line before the bridge', () {
    test('a negative TimeChanged goes on the wire as the start', () {
      final action = CoreActions.playerTimeChanged(
        time: -7414,
        duration: 5760000,
        device: 'android',
      );
      expect(action.action['args']['args']['time'], 0);
    });

    test('a negative Seek does too', () {
      final action = CoreActions.playerSeek(
        time: -10000,
        duration: 5760000,
        device: 'android',
      );
      expect(action.action['args']['args']['time'], 0);
    });

    test('a position inside the file is untouched', () {
      final action = CoreActions.playerTimeChanged(
        time: 2586,
        duration: 5760000,
        device: 'android',
      );
      expect(action.action['args']['args']['time'], 2586);
    });
  });

  group('the scan fallback seeks to the start rather than past it', () {
    // Off libmpv, and once media_kit has decided the media is over, a
    // scan is an absolute seek media_kit hands mpv verbatim -- the same
    // negative by another route.
    test('a step back from inside the first step lands on zero', () {
      expect(
        MediaKitEngine.scanFallbackTarget(
          const Duration(milliseconds: 2586),
          -step,
        ),
        Duration.zero,
      );
    });

    test('anything else is the sum it always was', () {
      expect(
        MediaKitEngine.scanFallbackTarget(const Duration(minutes: 20), -step),
        const Duration(minutes: 19, seconds: 50),
      );
      expect(
        MediaKitEngine.scanFallbackTarget(const Duration(minutes: 20), step),
        const Duration(minutes: 20, seconds: 10),
      );
    });
  });
}
