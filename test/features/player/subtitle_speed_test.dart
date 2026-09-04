import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';

/// What re-timing a subtitle actually writes to libmpv:
/// [MediaKitEngine.subtitleSpeedProperty] and the string
/// [MediaKitEngine.subtitleSpeedValue] hands it.
void main() {
  test('the property is sub-speed, not sub-fps', () {
    // `sub-fps` is the neighbouring property and the wrong one: it only
    // re-times a subtitle mpv itself converts from frame numbers, which
    // an SRT timed in seconds is not. `sub-speed` multiplies the event
    // timestamps of whatever is loaded, which is the whole of the fix.
    expect(MediaKitEngine.subtitleSpeedProperty, 'sub-speed');
  });

  test('a ratio survives being written as a string', () {
    // The correction for a 25 fps subtitle on a 23.976 fps video. Six
    // decimals is a hundredth of a frame over a three-hour film, and
    // stops a `1.0427093760427093` reaching a property parser.
    expect(MediaKitEngine.subtitleSpeedValue(25 / 23.976), '1.042709');
    expect(MediaKitEngine.subtitleSpeedValue(1), '1.000000');
    expect(MediaKitEngine.subtitleSpeedValue(23.976 / 25), '0.959040');
  });
}
