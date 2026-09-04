import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';

/// What shifting a subtitle by hand actually writes to libmpv:
/// [MediaKitEngine.subtitleDelayProperty] and the string
/// [MediaKitEngine.subtitleDelayValue] hands it.
void main() {
  test('the property is sub-delay', () {
    // `sub-speed` is the neighbour and answers the other question: a
    // multiplier fixes a file that drifts, this fixes one whose cues are
    // all the same distance from where they belong.
    expect(MediaKitEngine.subtitleDelayProperty, 'sub-delay');
  });

  test('a shift survives being written as a string, sign and all', () {
    // mpv's sign: positive delays the lines, so `+0.1` is a cue that
    // appears a tenth of a second later than the file asks for.
    expect(MediaKitEngine.subtitleDelayValue(0.1), '0.100');
    expect(MediaKitEngine.subtitleDelayValue(-0.1), '-0.100');
    expect(MediaKitEngine.subtitleDelayValue(0), '0.000');
    // Ten tenths added up: a millisecond of resolution swallows the
    // rounding a repeated `+ 0.1` leaves behind.
    expect(MediaKitEngine.subtitleDelayValue(0.1 * 7), '0.700');
    expect(MediaKitEngine.subtitleDelayValue(-2.35), '-2.350');
  });
}
