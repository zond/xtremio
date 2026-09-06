import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';

/// The command a scan step is.
///
/// media_kit has no relative seek and throws `mpv_command`'s return code
/// away, so the one thing a test on this side can hold is the string that
/// was measured against a running libmpv: `relative` for the direction
/// mpv rounds in, `keyframes` for the decode this exists to skip.
void main() {
  group('a scan step is a relative keyframe seek', () {
    test('the step mpv is asked for is the one the viewer pressed', () {
      expect(MediaKitEngine.scanCommand(const Duration(seconds: 10)), [
        'seek',
        '10.0000',
        'relative+keyframes',
      ]);
    });

    test('a step back is the same command signed', () {
      // Not a separate flag: mpv takes the direction from the sign and
      // rounds to the keyframe past the target on the way back too.
      expect(MediaKitEngine.scanCommand(const Duration(seconds: -30)), [
        'seek',
        '-30.0000',
        'relative+keyframes',
      ]);
    });

    test('a fraction of a second survives the trip', () {
      // Whole seconds are what a seek step happens to be today; the
      // command carries what it is given, as media_kit's own absolute
      // seek does.
      expect(
        MediaKitEngine.scanCommand(const Duration(milliseconds: 3500))[1],
        '3.5000',
      );
    });
  });
}
