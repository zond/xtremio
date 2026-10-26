import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/controls_visibility.dart';

/// The player's controls: up, held up, and faded on a timer. The screen's
/// own tests (player_controls_fade_test, the television focus tests) hold
/// what the viewer sees. These hold the rules on their own.
void main() {
  const timeout = Duration(seconds: 3);

  /// A visibility whose holds are [held] and whose frames run when
  /// [frame] is called.
  ({
    ControlsVisibility controls,
    List<VoidCallback> frames,
    List<String> events,
  })
  make(bool Function() held) {
    final frames = <VoidCallback>[];
    final events = <String>[];
    final controls = ControlsVisibility(
      timeout: timeout,
      canFade: () => !held(),
      onHidden: () => events.add('hidden'),
      afterFrame: frames.add,
    )..addListener(() => events.add('changed'));
    return (controls: controls, frames: frames, events: events);
  }

  void runFrames(List<VoidCallback> frames) {
    final due = [...frames];
    frames.clear();
    for (final frame in due) {
      frame();
    }
  }

  test('fades the timeout after it was shown, and says so', () {
    fakeAsync((async) {
      final v = make(() => false);
      v.controls.show();
      expect(v.controls.visible, isTrue);
      async.elapse(timeout - const Duration(milliseconds: 1));
      expect(v.controls.visible, isTrue);
      async.elapse(const Duration(milliseconds: 1));
      expect(v.controls.visible, isFalse);
      expect(v.controls.shown, isFalse);
      expect(v.events, ['changed', 'hidden']);
    });
  });

  test('showing again starts the fade over', () {
    fakeAsync((async) {
      final v = make(() => false);
      v.controls.show();
      async.elapse(const Duration(seconds: 2));
      v.controls.show();
      async.elapse(const Duration(seconds: 2));
      expect(v.controls.visible, isTrue);
      async.elapse(const Duration(seconds: 1));
      expect(v.controls.visible, isFalse);
    });
  });

  test('a hold keeps them on screen, and stops the fade', () {
    fakeAsync((async) {
      var held = true;
      final v = make(() => held);
      v.controls.show();
      async.elapse(const Duration(seconds: 10));
      expect(v.controls.visible, isTrue);
      expect(v.controls.hide(), isFalse, reason: 'held up, so not put away');
      expect(v.controls.shown, isTrue);
      held = false;
      expect(v.controls.shown, isTrue, reason: 'still up by its own flag');
    });
  });

  test('held up is shown even when put away', () {
    fakeAsync((async) {
      var held = false;
      final v = make(() => held);
      expect(v.controls.hide(), isTrue);
      expect(v.controls.shown, isFalse);
      held = true;
      expect(v.controls.visible, isFalse);
      expect(v.controls.shown, isTrue);
    });
  });

  test('the fade is armed after the frame in which the last hold went', () {
    fakeAsync((async) {
      var held = true;
      final v = make(() => held);
      v.controls.show();
      v.controls.rebuilt();
      expect(v.frames, isEmpty, reason: 'still held');
      held = false;
      v.controls.rebuilt();
      expect(v.frames, hasLength(1));
      v.controls.rebuilt();
      expect(v.frames, hasLength(1), reason: 'armed once per release');
      async.elapse(const Duration(seconds: 10));
      expect(v.controls.visible, isTrue, reason: 'not before the frame');
      runFrames(v.frames);
      async.elapse(timeout);
      expect(v.controls.visible, isFalse);
    });
  });

  test('a pause stops the fade until the next restart', () {
    fakeAsync((async) {
      final v = make(() => false);
      v.controls.show();
      v.controls.pause();
      async.elapse(const Duration(seconds: 10));
      expect(v.controls.visible, isTrue);
      v.controls.restart();
      async.elapse(timeout);
      expect(v.controls.visible, isFalse);
    });
  });

  test('a restart while put away arms nothing', () {
    fakeAsync((async) {
      final v = make(() => false);
      v.controls.hide();
      v.events.clear();
      v.controls.restart();
      async.elapse(const Duration(seconds: 10));
      expect(v.events, isEmpty);
    });
  });

  test('stopped, nothing fades and nothing is put away', () {
    fakeAsync((async) {
      final v = make(() => false);
      v.controls.show();
      v.controls.stop();
      async.elapse(const Duration(seconds: 10));
      expect(v.controls.visible, isTrue);
      expect(v.controls.hide(), isFalse);
      v.controls.rebuilt();
      runFrames(v.frames);
      async.elapse(const Duration(seconds: 10));
      expect(v.controls.visible, isTrue);
    });
  });
}
