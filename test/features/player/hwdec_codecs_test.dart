import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';

/// Which codecs the hardware decoder is allowed to have.
///
/// A constant, checked against what it is for: this side of libmpv nothing
/// can open a decoder, so what is testable is the list itself and the
/// reasoning that picked it.
void main() {
  test('the old codecs are not offered to the hardware decoder', () {
    // media_kit's Android controller widens mpv's own list to include
    // mpeg4 and mpeg2video. With the direct `mediacodec` hwdec this app
    // asks for, an MPEG-4 file then fails decoder init ("Both surface and
    // native_window are NULL") and only the player's retry recovers a
    // picture, after seconds of stalling and an error on screen.
    final allowed = MediaKitEngine.hwdecCodecs.split(',');
    expect(allowed, isNot(contains('mpeg4')));
    expect(allowed, isNot(contains('mpeg2video')));
  });

  test('and the ones worth accelerating still are', () {
    // Taking the old two off is only free because these stay: they are the
    // formats a television cannot decode in software at the bitrates this
    // app plays them at, which is what hardware decoding is here for.
    final allowed = MediaKitEngine.hwdecCodecs.split(',');
    expect(allowed, containsAll(['h264', 'hevc', 'vp9', 'av1']));
  });

  test('a Mac asks for VideoToolbox', () {
    // mpv on a Mac has no `mediacodec` decoder, so the Android list would
    // leave it decoding in software.
    expect(
      MediaKitEngine.configurationFor(
        hardwareDecoding: true,
        platform: TargetPlatform.macOS,
      ).hwdec,
      'videotoolbox',
    );
    expect(
      MediaKitEngine.configurationFor(
        hardwareDecoding: false,
        platform: TargetPlatform.macOS,
      ).hwdec,
      'no',
    );
    expect(
      MediaKitEngine.configurationFor(
        hardwareDecoding: true,
        platform: TargetPlatform.android,
      ).hwdec,
      'mediacodec,mediacodec-copy',
    );
  });

  test('every platform but a Mac asks for the Android decoders', () {
    // Android's list is measured. Nobody has measured what Linux, Windows
    // or iOS should ask for, so they share Android's.
    for (final platform in TargetPlatform.values) {
      if (platform == TargetPlatform.macOS) continue;
      expect(
        MediaKitEngine.configurationFor(
          hardwareDecoding: true,
          platform: platform,
        ).hwdec,
        'mediacodec,mediacodec-copy',
        reason: '$platform',
      );
      expect(
        MediaKitEngine.configurationFor(
          hardwareDecoding: false,
          platform: platform,
        ).hwdec,
        'no',
        reason: '$platform',
      );
    }
  });

  test('and the direct decoder is still asked for first', () {
    // `mediacodec` (direct) is asked for before `mediacodec-copy`: the
    // copy path is what causes judder on a Chromecast.
    expect(
      MediaKitEngine.configurationFor(hardwareDecoding: true).hwdec,
      'mediacodec,mediacodec-copy',
    );
    expect(
      MediaKitEngine.configurationFor(hardwareDecoding: false).hwdec,
      'no',
    );
  });
}
