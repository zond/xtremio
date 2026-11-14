import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/video_output.dart';
import 'package:xtremio/features/player/video_surface.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/video_decoders.dart';

/// Where a film's picture goes ([VideoOutput]), and what the engine writes to
/// mpv to put it on the surface and take it off.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the surface is allowed', () {
    test('on Android with hardware decoding on', () {
      expect(
        surfaceAllowed(
          hardwareDecoding: true,
          platform: TargetPlatform.android,
        ),
        isTrue,
      );
    });

    test('and nowhere else', () {
      for (final platform in TargetPlatform.values) {
        for (final hardwareDecoding in [false, true]) {
          expect(
            surfaceAllowed(
              hardwareDecoding: hardwareDecoding,
              platform: platform,
            ),
            platform == TargetPlatform.android && hardwareDecoding,
            reason: '$platform hw=$hardwareDecoding',
          );
        }
      }
    });
  });

  group('a film goes', () {
    final assumed = HardwareDecoders.assumed;

    /// What the Chromecast with Google TV answers: HEVC, H.264 and VP9 in
    /// hardware, and AV1 only in software.
    final chromecast = HardwareDecoders.fromReply({
      'video/hevc': {'maxWidth': 4096, 'maxHeight': 2304},
      'video/avc': {'maxWidth': 4096, 'maxHeight': 2304},
      'video/x-vnd.on2.vp9': {'maxWidth': 4096, 'maxHeight': 2304},
    });

    test('to the surface when mpv sends its codec to MediaCodec', () {
      for (final codec in surfaceCodecs) {
        expect(
          videoOutputForCodec(allowed: true, codec: codec, decoders: assumed),
          VideoOutput.surface,
          reason: codec,
        );
      }
      expect(
        videoOutputForCodec(allowed: true, codec: ' HEVC ', decoders: assumed),
        VideoOutput.surface,
      );
    });

    test('to the texture when mpv decodes its codec in software', () {
      for (final codec in ['mpeg2video', 'mpeg4', 'vc1', 'prores']) {
        expect(
          videoOutputForCodec(allowed: true, codec: codec, decoders: assumed),
          VideoOutput.texture,
          reason: codec,
        );
      }
    });

    test('to the texture when the device has no hardware decoder for its '
        'codec', () {
      expect(
        videoOutputForCodec(
          allowed: true,
          codec: 'av1',
          decoders: chromecast,
          width: 3840,
          height: 2160,
        ),
        VideoOutput.texture,
      );
      expect(
        videoOutputForCodec(
          allowed: true,
          codec: 'hevc',
          decoders: chromecast,
          width: 3840,
          height: 2160,
        ),
        VideoOutput.surface,
      );
    });

    test('to the texture when its picture is larger than the hardware '
        'takes', () {
      final small = HardwareDecoders.fromReply({
        'video/hevc': {'maxWidth': 1920, 'maxHeight': 1088},
      });
      VideoOutput? output(int? w, int? h) => videoOutputForCodec(
        allowed: true,
        codec: 'hevc',
        decoders: small,
        width: w,
        height: h,
      );
      expect(output(3840, 2160), VideoOutput.texture);
      expect(output(1920, 1080), VideoOutput.surface);
      // Portrait fits the other way round.
      expect(output(1080, 1920), VideoOutput.surface);
      // A size mpv has not read is decided by the codec alone.
      expect(output(null, null), VideoOutput.surface);
    });

    test('by today\'s codecs at any size when the device could not be '
        'asked', () async {
      final decoders = await HardwareDecoders.probe(
        channel: const MethodChannel('xtremio/test-unanswered'),
        platform: TargetPlatform.android,
      );
      expect(decoders.codecs, surfaceCodecs);
      expect(
        videoOutputForCodec(
          allowed: true,
          codec: 'av1',
          decoders: decoders,
          width: 7680,
          height: 4320,
        ),
        VideoOutput.surface,
      );
    });

    test('to the texture whatever the codec where the surface is not '
        'allowed', () {
      expect(
        videoOutputForCodec(allowed: false, codec: 'hevc', decoders: assumed),
        VideoOutput.texture,
      );
      expect(
        videoOutputForCodec(allowed: false, codec: null, decoders: assumed),
        VideoOutput.texture,
      );
    });

    test('nowhere yet while mpv has not named the codec', () {
      expect(
        videoOutputForCodec(allowed: true, codec: null, decoders: assumed),
        isNull,
      );
      expect(
        videoOutputForCodec(allowed: true, codec: '', decoders: assumed),
        isNull,
      );
    });

    test('the surface\'s codecs are the ones mpv may send to MediaCodec', () {
      for (final decoders in [assumed, chromecast]) {
        expect(decoders.codecs, decoders.hwdecCodecs.split(',').toSet());
      }
      expect(chromecast.hwdecCodecs, 'h264,hevc,vp9');
    });
  });

  group('the device is asked which codecs it decodes in hardware', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DeviceProfile.channel, null);
    });

    test('on Android, and its answer is the set', () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DeviceProfile.channel, (call) async {
            calls.add(call.method);
            return {
              'video/avc': {'maxWidth': 1920, 'maxHeight': 1088},
              'video/av01': {'maxWidth': 0, 'maxHeight': 0},
            };
          });
      final decoders = await HardwareDecoders.probe(
        platform: TargetPlatform.android,
      );
      expect(calls, ['hwVideoDecoders']);
      expect(decoders.sizes, {
        'h264': const DecoderSize(1920, 1088),
        // A size that is not a size is unknown, not zero.
        'av1': null,
      });
      expect(decoders.hwdecCodecs, 'h264,av1');
    });

    test('and assumed when the answer is an error', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DeviceProfile.channel, (call) async {
            throw PlatformException(code: 'unavailable');
          });
      final decoders = await HardwareDecoders.probe(
        platform: TargetPlatform.android,
      );
      expect(decoders.codecs, surfaceCodecs);
    });

    test('and nowhere but Android', () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DeviceProfile.channel, (call) async {
            calls.add(call.method);
            return {
              'video/avc': {'maxWidth': 1920, 'maxHeight': 1088},
            };
          });
      for (final platform in TargetPlatform.values) {
        if (platform == TargetPlatform.android) continue;
        final decoders = await HardwareDecoders.probe(platform: platform);
        expect(decoders.codecs, surfaceCodecs, reason: '$platform');
      }
      expect(calls, isEmpty);
    });
  });

  group('the surface has no picture', () {
    test('when MediaCodec will not open', () {
      expect(
        surfaceLostPicture(
          prefix: 'vd',
          level: 'error',
          text: 'Could not open codec.',
        ),
        isTrue,
      );
    });

    test('when mpv cannot hand the decoder\'s frames to the surface', () {
      expect(
        surfaceLostPicture(
          prefix: 'vf',
          level: 'fatal',
          text:
              'Cannot convert decoder/filter output to any format supported '
              'by the output.',
        ),
        isTrue,
      );
      expect(
        surfaceLostPicture(
          prefix: 'cplayer',
          level: 'fatal',
          text: 'Could not initialize video chain.',
        ),
        isTrue,
      );
    });

    test('and not for the lines around them', () {
      const lines = [
        (
          'autoconvert',
          'error',
          'Failed to create HW uploader for format '
              'yuv420p10',
        ),
        ('cplayer', 'error', 'Could not initialize video chain.'),
        ('ad', 'error', 'Could not open codec.'),
        (
          'ffmpeg',
          'error',
          'av1_mediacodec: Both surface and native_window '
              'are NULL',
        ),
        ('cplayer', 'fatal', 'Could not initialize audio chain.'),
      ];
      for (final (prefix, level, text) in lines) {
        expect(
          surfaceLostPicture(prefix: prefix, level: level, text: text),
          isFalse,
          reason: '$prefix $level $text',
        );
      }
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

  group('a film too large to decode in software', () {
    const gb = 1024 * 1024 * 1024;

    test('is refused above 1080p on a device with little memory', () {
      // The Chromecast with Google TV reports just under 2 GB.
      expect(
        softwareDecodeTooLarge(
          width: 3840,
          height: 2160,
          memoryBytes: 2030588000,
        ),
        isTrue,
      );
      expect(
        softwareDecodeTooLarge(width: 2560, height: 1440, memoryBytes: 2 * gb),
        isTrue,
      );
    });

    test('is tried at 1080p, or with enough memory', () {
      expect(
        softwareDecodeTooLarge(width: 1920, height: 1080, memoryBytes: 2 * gb),
        isFalse,
      );
      expect(
        softwareDecodeTooLarge(width: 3840, height: 2160, memoryBytes: 4 * gb),
        isFalse,
      );
    });

    test('decides nothing without a size or the memory', () {
      expect(
        softwareDecodeTooLarge(width: null, height: 2160, memoryBytes: gb),
        isFalse,
      );
      expect(
        softwareDecodeTooLarge(width: 3840, height: 2160, memoryBytes: null),
        isFalse,
      );
      expect(
        softwareDecodeTooLarge(width: 3840, height: 2160, memoryBytes: 0),
        isFalse,
      );
    });

    test('the device says how much memory it has', () {
      final decoders = HardwareDecoders.fromReply({
        'video/hevc': {'maxWidth': 4096, 'maxHeight': 4096},
        HardwareDecoders.memoryKey: 2030588000,
      });
      expect(decoders.memoryBytes, 2030588000);
      expect(decoders.codecs, {'hevc'});
      expect(
        HardwareDecoders.fromReply({HardwareDecoders.memoryKey: 0}).memoryBytes,
        isNull,
      );
    });
  });

  test('codecs go by the names the stream list shows', () {
    expect(codecLabel('av1'), 'AV1');
    expect(codecLabel('h264'), 'H.264');
    expect(codecLabel('mpeg2video'), 'MPEG-2');
    expect(codecLabel('theora'), isNull);
    expect(codecLabel(null), isNull);
  });
}
