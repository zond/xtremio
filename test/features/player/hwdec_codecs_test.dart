import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';

/// Which codecs the hardware decoder is allowed to have.
///
/// A constant, checked against what it is for: this side of libmpv nothing
/// can open a decoder, so what is testable is the list itself and the
/// reasoning that picked it.
void main() {
  test('the old codecs are not offered to the hardware decoder', () {
    // The bug, on a real phone, on a file linked from Drive:
    //
    //     mpeg4_mediacodec: Both surface and native_window are NULL
    //     mpeg4_mediacodec: MediaCodec 0x0 failed to start
    //     vd: Could not open codec.
    //
    // media_kit's Android controller widens mpv's own list to include
    // these two, and with the direct `mediacodec` hwdec this app asks for,
    // an MPEG-4 file fails at decoder init and only the player's retry gets
    // a picture -- after seconds of stalling and an error on screen.
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

  test('and the direct decoder is still asked for first', () {
    // The reason the old codecs had to go rather than the direct path: the
    // copy path is what made the Chromecast judder, and this is that fix.
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
