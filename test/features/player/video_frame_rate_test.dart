import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';

/// What the engine will call a frame rate: [MediaKitEngine.frameRateFrom]
/// over the raw mpv property strings [MediaKitEngine.frameRateProperties]
/// answers with.
void main() {
  test('only the container is asked, never a measurement of the video', () {
    // `estimated-vf-fps` is an average over the last ten frame durations,
    // read here at the moment the media loads. Feeding that to a filter
    // with a hundredth-of-a-frame tolerance would hide correct files on a
    // stream whose timestamps are merely imprecise, so it is not asked:
    // a container that declares nothing filters nothing.
    expect(MediaKitEngine.frameRateProperties, ['container-fps']);
    expect(MediaKitEngine.frameRateFrom(['23.976025']), 23.976025);
    expect(MediaKitEngine.frameRateFrom(['']), isNull);
  });

  test('nothing that is not a rate is one', () {
    // mpv answers an empty string for a property it has no value for, and
    // a property read that failed reads as null here.
    expect(MediaKitEngine.frameRateFrom([null]), isNull);
    expect(MediaKitEngine.frameRateFrom(['  ']), isNull);
    expect(MediaKitEngine.frameRateFrom(['unavailable']), isNull);
    expect(MediaKitEngine.frameRateFrom(['nan']), isNull);
    // Zero and a negative are not slow videos; they are no answer.
    expect(MediaKitEngine.frameRateFrom(['0']), isNull);
    expect(MediaKitEngine.frameRateFrom(['0.000']), isNull);
    expect(MediaKitEngine.frameRateFrom(['-25']), isNull);
    // An infinity would pass every tolerance check downstream.
    expect(MediaKitEngine.frameRateFrom(['Infinity']), isNull);
    // A rate mpv padded is still a rate.
    expect(MediaKitEngine.frameRateFrom([' 25.000 ']), 25.0);
  });
}
