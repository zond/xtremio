import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';

/// What the engine will call a frame rate: [MediaKitEngine.frameRateFrom]
/// over the raw strings the observation of
/// [MediaKitEngine.frameRateProperty] carries.
void main() {
  test('only the container is asked, never a measurement of the video', () {
    // `estimated-vf-fps` is an average over the last ten frame
    // durations, and observing it would answer on every stall for the
    // whole film. Feeding that to a family test with a
    // hundredth-of-a-frame tolerance would point the timing panel's
    // speed button off a number the stall invented, so it is not asked:
    // one property, and a container that declares nothing decides
    // nothing.
    expect(MediaKitEngine.frameRateProperty, 'container-fps');
    expect(MediaKitEngine.frameRateFrom('23.976025'), 23.976025);
    expect(MediaKitEngine.frameRateFrom(''), isNull);
  });

  test('nothing that is not a rate is one', () {
    // mpv answers an empty string for a property it has no value for, and
    // a property read that failed reads as null here.
    expect(MediaKitEngine.frameRateFrom(null), isNull);
    expect(MediaKitEngine.frameRateFrom('  '), isNull);
    expect(MediaKitEngine.frameRateFrom('unavailable'), isNull);
    expect(MediaKitEngine.frameRateFrom('nan'), isNull);
    // Zero and a negative are not slow videos; they are no answer.
    expect(MediaKitEngine.frameRateFrom('0'), isNull);
    expect(MediaKitEngine.frameRateFrom('0.000'), isNull);
    expect(MediaKitEngine.frameRateFrom('-25'), isNull);
    // An infinity would pass every tolerance check downstream.
    expect(MediaKitEngine.frameRateFrom('Infinity'), isNull);
    // A rate mpv padded is still a rate.
    expect(MediaKitEngine.frameRateFrom(' 25.000 '), 25.0);
  });
}
