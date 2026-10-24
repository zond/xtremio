import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/video_output.dart';
import 'package:xtremio/features/player/video_surface.dart';

/// Where a film's picture goes ([VideoOutput]), and what the engine writes to
/// mpv to put it on the surface and take it off.
void main() {
  group('the surface is allowed', () {
    test('on Android with hardware decoding and "Direct video" on', () {
      expect(
        surfaceAllowed(
          hardwareDecoding: true,
          directVideo: true,
          platform: TargetPlatform.android,
        ),
        isTrue,
      );
    });

    test('and nowhere else', () {
      for (final platform in TargetPlatform.values) {
        for (final hardwareDecoding in [false, true]) {
          for (final directVideo in [false, true]) {
            final expected =
                platform == TargetPlatform.android &&
                hardwareDecoding &&
                directVideo;
            expect(
              surfaceAllowed(
                hardwareDecoding: hardwareDecoding,
                directVideo: directVideo,
                platform: platform,
              ),
              expected,
              reason: '$platform hw=$hardwareDecoding direct=$directVideo',
            );
          }
        }
      }
    });
  });

  group('a film goes', () {
    test('to the surface when mpv sends its codec to MediaCodec', () {
      for (final codec in surfaceCodecs) {
        expect(
          videoOutputForCodec(allowed: true, codec: codec),
          VideoOutput.surface,
          reason: codec,
        );
      }
      expect(
        videoOutputForCodec(allowed: true, codec: ' HEVC '),
        VideoOutput.surface,
      );
    });

    test('to the texture when mpv decodes its codec in software', () {
      for (final codec in ['mpeg2video', 'mpeg4', 'vc1', 'prores']) {
        expect(
          videoOutputForCodec(allowed: true, codec: codec),
          VideoOutput.texture,
          reason: codec,
        );
      }
    });

    test('to the texture whatever the codec where the surface is not '
        'allowed', () {
      expect(
        videoOutputForCodec(allowed: false, codec: 'hevc'),
        VideoOutput.texture,
      );
      expect(
        videoOutputForCodec(allowed: false, codec: null),
        VideoOutput.texture,
      );
    });

    test('nowhere yet while mpv has not named the codec', () {
      expect(videoOutputForCodec(allowed: true, codec: null), isNull);
      expect(videoOutputForCodec(allowed: true, codec: ''), isNull);
    });

    test('the surface\'s codecs are the ones mpv may send to MediaCodec', () {
      expect(surfaceCodecs, MediaKitEngine.hwdecCodecs.split(',').toSet());
    });
  });

  group('a film on the surface fell back to software decoding', () {
    test('when mpv says its decoder is "no"', () {
      expect(surfaceDecodingFellBack('no'), isTrue);
    });

    test('and not while it says MediaCodec, or nothing yet', () {
      expect(surfaceDecodingFellBack('mediacodec'), isFalse);
      expect(surfaceDecodingFellBack(''), isFalse);
      expect(surfaceDecodingFellBack(null), isFalse);
    });
  });

  group('mpv is told', () {
    test('to start with no video output and no video decoding, and to '
        'decode straight into the surface', () {
      expect(MediaKitEngine.surfaceStartOverrides, {
        'vo': 'null',
        'vid': 'no',
        'hwdec': 'mediacodec',
      });
    });

    test('the surface in media_kit\'s order', () {
      const surface = VideoSurfaceInfo(wid: 42, width: 2304, height: 960);
      expect(MediaKitEngine.surfaceAttach(surface), [
        ('vo', 'null'),
        ('android-surface-size', '2304x960'),
        ('wid', '42'),
        ('vo', 'mediacodec_embed'),
        ('vid', 'auto'),
      ]);
    });

    test('to stop drawing into a surface that is going away', () {
      expect(MediaKitEngine.surfaceDetach, [
        ('vo', 'null'),
        ('vid', 'no'),
        ('wid', '0'),
      ]);
    });
  });

  group('the surface\'s channel', () {
    test('passes on a surface and its going away', () async {
      final seen = <String>[];
      final events = VideoSurfaceEvents(
        onSurface: (s) => seen.add('surface ${s.wid} ${s.width}x${s.height}'),
        onGone: () => seen.add('gone'),
      );

      await events.handle(
        const MethodCall('surface', {'wid': 7, 'width': 1920, 'height': 800}),
      );
      await events.handle(const MethodCall('gone'));
      await events.handle(const MethodCall('something else'));

      expect(seen, ['surface 7 1920x800', 'gone']);
    });
  });
}
