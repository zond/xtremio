import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';

/// What the engine will call a frame rate: [MediaKitEngine.frameRateFrom]
/// over the raw mpv property strings [MediaKitEngine.frameRateProperties]
/// answers with (`container-fps` first, `estimated-vf-fps` behind it).
void main() {
  test('the container is asked first, the filter chain second', () {
    expect(MediaKitEngine.frameRateProperties, [
      'container-fps',
      'estimated-vf-fps',
    ]);
    expect(MediaKitEngine.frameRateFrom(['23.976025', '24.001']), 23.976025);
    // A container that declares nothing falls through to what is really
    // being drawn.
    expect(MediaKitEngine.frameRateFrom(['', '23.974']), 23.974);
  });

  test('nothing that is not a rate is one', () {
    // mpv answers an empty string for a property it has no value for, and
    // a property read that failed reads as null here.
    expect(MediaKitEngine.frameRateFrom([null, null]), isNull);
    expect(MediaKitEngine.frameRateFrom(['', '  ']), isNull);
    expect(MediaKitEngine.frameRateFrom(['unavailable', 'nan']), isNull);
    // Zero and a negative are not slow videos; they are no answer.
    expect(MediaKitEngine.frameRateFrom(['0', '0.000']), isNull);
    expect(MediaKitEngine.frameRateFrom(['-25']), isNull);
    // An infinity would pass every tolerance check downstream.
    expect(MediaKitEngine.frameRateFrom(['Infinity']), isNull);
    // A rate mpv padded is still a rate.
    expect(MediaKitEngine.frameRateFrom([' 25.000 ']), 25.0);
  });
}
