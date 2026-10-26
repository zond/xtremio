import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/up_next_countdown.dart';

/// The up-next countdown on its own. What the card shows and what a press
/// on it does are held by player_next_episode_test and the television
/// focus tests.
void main() {
  ({UpNextCountdown countdown, List<int?> shown, List<String> due}) make({
    bool Function()? mayTick,
  }) {
    final due = <String>[];
    final shown = <int?>[];
    late final UpNextCountdown countdown;
    countdown = UpNextCountdown(
      onDue: () {
        due.add('due');
        countdown.dismiss();
      },
      mayTick: mayTick ?? () => true,
    )..addListener(() => shown.add(countdown.secondsLeft));
    return (countdown: countdown, shown: shown, due: due);
  }

  test('counts down a second at a time and is due at zero', () {
    fakeAsync((async) {
      final c = make();
      c.countdown.start(const Duration(seconds: 3));
      expect(c.countdown.secondsLeft, 3);
      async.elapse(const Duration(seconds: 2));
      expect(c.shown, [3, 2, 1]);
      expect(c.due, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(c.due, ['due']);
      async.elapse(const Duration(seconds: 5));
      expect(c.due, ['due'], reason: 'due once');
    });
  });

  test('rounds a part of a second up', () {
    final c = make();
    c.countdown.start(const Duration(milliseconds: 2001));
    expect(c.countdown.secondsLeft, 3);
    c.countdown.dismiss();
  });

  test('a countdown of zero is due at once', () {
    fakeAsync((async) {
      final c = make();
      c.countdown.start(Duration.zero);
      expect(c.due, ['due']);
    });
  });

  test('holds while it may not tick, and runs on from where it was', () {
    fakeAsync((async) {
      var held = false;
      final c = make(mayTick: () => !held);
      c.countdown.start(const Duration(seconds: 5));
      async.elapse(const Duration(seconds: 2));
      expect(c.countdown.secondsLeft, 3);
      held = true;
      c.countdown.resume();
      async.elapse(const Duration(seconds: 10));
      expect(c.countdown.secondsLeft, 3);
      expect(c.due, isEmpty);
      held = false;
      c.countdown.resume();
      async.elapse(const Duration(seconds: 3));
      expect(c.due, ['due']);
    });
  });

  test('a pause keeps the card and the seconds on it', () {
    fakeAsync((async) {
      final c = make();
      c.countdown.start(const Duration(seconds: 5));
      c.countdown.pause();
      async.elapse(const Duration(seconds: 10));
      expect(c.countdown.secondsLeft, 5);
      expect(c.due, isEmpty);
      c.countdown.dismiss();
    });
  });

  test('dismissed, the card goes and nothing is due', () {
    fakeAsync((async) {
      final c = make();
      c.countdown.start(const Duration(seconds: 5));
      c.countdown.dismiss();
      expect(c.countdown.secondsLeft, isNull);
      async.elapse(const Duration(seconds: 10));
      expect(c.due, isEmpty);
      expect(c.shown.last, isNull);
    });
  });

  test('a resume with no card does nothing', () {
    fakeAsync((async) {
      final c = make();
      c.countdown.resume();
      async.elapse(const Duration(seconds: 10));
      expect(c.due, isEmpty);
      expect(c.shown, isEmpty);
    });
  });
}
