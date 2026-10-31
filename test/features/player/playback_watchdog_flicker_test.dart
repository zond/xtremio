import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_stats.dart';
import 'package:xtremio/features/player/playback_watchdog.dart';
import 'package:xtremio/features/player/player_screen.dart';

/// A film that plays without a hitch while mpv's read-ahead waits on a piece,
/// under the player's real timings. The film moves about as far between two
/// asks as counts as moving, so the stall card has to hold still through
/// every frame rate and however late the position reports arrive.
void main() {
  const parked = ReadWait(waiting: Duration(seconds: 5), offset: 1024);

  /// How many times the card changes over 20 s of playback at [fps], with
  /// each frame's report reaching Dart up to [jitterMs] late.
  int changes(double fps, {int jitterMs = 0, int seed = 1}) {
    final random = Random(seed);
    var changes = 0;
    fakeAsync((async) {
      var position = Duration.zero;
      final dog = PlaybackWatchdog(
        stuckInterval: PlayerScreen.stuckInterval,
        stuckAfter: PlayerScreen.stuckAfter,
        stuckTwitch: PlayerScreen.stuckTwitch,
        readWaitInterval: PlayerScreen.readWaitInterval,
        readWaitShown: PlayerScreen.readWaitShown,
        position: () => position,
        shouldMove: () => true,
        playingLoaded: () => true,
        readWaitId: () => 'media',
        playingId: () => 'media',
        askReadWait: (_) async => parked,
        stats: () => const Stream<PlaybackStats>.empty(),
      )..addListener(() => changes++);
      dog.start();
      final frame = (1e6 / fps).round();
      var clock = 0;
      for (var i = 1; i * frame < 20000000; i++) {
        final due =
            i * frame + (jitterMs == 0 ? 0 : random.nextInt(jitterMs * 1000));
        if (due > clock) {
          async.elapse(Duration(microseconds: due - clock));
          clock = due;
        }
        position = Duration(microseconds: i * frame);
        dog
          ..sawPosition()
          ..positionMoved(position);
      }
      dog.stop();
    });
    return changes;
  }

  for (final fps in [23.976, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94]) {
    test('the card stays down while the film plays at $fps fps', () {
      expect(changes(fps), 0);
      for (final jitterMs in [15, 30, 100]) {
        for (var seed = 1; seed <= 5; seed++) {
          expect(
            changes(fps, jitterMs: jitterMs, seed: seed),
            0,
            reason: 'jitter $jitterMs ms, seed $seed',
          );
        }
      }
    });
  }
}
