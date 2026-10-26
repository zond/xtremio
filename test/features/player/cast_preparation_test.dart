import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/cast/cast_client.dart';
import 'package:xtremio/features/player/cast_preparation.dart';

/// The wait between a rendition's readiness asks, on its own. The card, its
/// Cancel and the hand-over after it are held by player_cast_test.
void main() {
  const device = CastDevice(id: 'tv', name: 'Living Room TV');
  const period = Duration(seconds: 1);

  test('starts at the index', () {
    expect(CastPreparation(device).phase, 'index');
  });

  test('a wait ends after its period', () {
    fakeAsync((async) {
      final preparation = CastPreparation(device);
      var done = false;
      preparation.wait(period).then((_) => done = true);
      async.elapse(period - const Duration(milliseconds: 1));
      expect(done, isFalse);
      async.elapse(const Duration(milliseconds: 1));
      expect(done, isTrue);
    });
  });

  test('a wake ends it at once, and the timer with it', () {
    fakeAsync((async) {
      final preparation = CastPreparation(device);
      var done = false;
      preparation.wait(period).then((_) => done = true);
      preparation.wake();
      async.flushMicrotasks();
      expect(done, isTrue);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a wake with nothing waiting does nothing', () {
    CastPreparation(device)
      ..wake()
      ..end();
  });

  test('ended, nothing is left armed', () {
    fakeAsync((async) {
      final preparation = CastPreparation(device);
      preparation.wait(period).ignore();
      preparation.end();
      expect(async.pendingTimers, isEmpty);
    });
  });
}
