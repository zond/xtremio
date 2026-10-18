import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/cast/cast_compatibility.dart';
import 'package:xtremio/features/cast/picture_plan.dart';
import 'package:xtremio/features/cast/receiver_table.dart';
import 'package:xtremio/features/player/playback_stats.dart';

/// A stream played by id, which is what a rendition is made from.
final byId = mediaIdUrl('0123456789abcdef0123456789abcdef');

/// A phone like zond's: hardware decoders for all four, HEVC and H.264
/// encoders, and an HEVC encoder that takes the decoder's 10-bit pictures.
const phone = PictureSupport(
  decodes: {'H.264', 'HEVC', 'AV1', 'VP9'},
  encodes: {'H.264', 'HEVC'},
  tenBit: true,
);

/// zond's phone as it is: the player's FFmpeg decodes what its hardware does
/// not.
const softwarePhone = PictureSupport(
  decodes: {'H.264', 'HEVC', 'AV1', 'VP9'},
  encodes: {'H.264', 'HEVC'},
  tenBit: true,
  softwareDecodes: {'MPEG-4 Part 2', 'DivX 3', 'MPEG-2'},
);

/// The same phone without 10-bit encoding.
const eightBitPhone = PictureSupport(
  decodes: {'H.264', 'HEVC', 'AV1', 'VP9'},
  encodes: {'H.264', 'HEVC'},
);

/// What zond's Chromecast with Google TV announces: H.264 at 1080p30 for
/// certain, HEVC and VP9 at 4K60 at best.
final chromecast = ReceiverTable.of(announced: 'Chromecast');
final nestHub = ReceiverTable.of(announced: 'Google Nest Hub');
final ultra = ReceiverTable.of(announced: 'Chromecast Ultra');

/// A receiver whose one model shows 1080p and no more.
final hdOnly = ReceiverTable.googleTvHd.byName(
  'Every receiver that calls itself "Living Room HD"',
);

PlaybackStats film({
  String format = 'mkv',
  String video = 'av1 (libdav1d)',
  String audio = 'eac3',
  int channels = 6,
  int width = 3840,
  int height = 2160,
  double fps = 23.976,
  String? pixels,
  String? transfer,
}) => PlaybackStats(
  fileFormat: format,
  videoCodec: video,
  audioCodec: audio,
  audioChannels: channels,
  width: width,
  height: height,
  containerFps: fps,
  pixelFormat: pixels,
  transfer: transfer,
);

CastCompatibility judge(
  PlaybackStats stats, {
  ReceiverRow? receiver,
  PictureSupport? conversion = phone,
  Set<String> noPicture = const {},
  bool canRepackage = true,
}) => CastCompatibility.of(
  url: byId,
  receiver: receiver ?? chromecast,
  stats: stats,
  canRepackage: canRepackage,
  conversion: conversion,
  noPicture: noPicture,
);

void main() {
  group('the bitrate table', () {
    test('by height, HEVC and H.264, up to 30 frames a second', () {
      for (final (height, hevc, h264) in [
        (480, 2500000, 3500000),
        (576, 2500000, 3500000),
        (720, 4000000, 6000000),
        (1080, 8000000, 12000000),
        (1440, 12000000, 18000000),
        (2160, 16000000, 24000000),
      ]) {
        for (final fps in [23.976, 29.97, 30.00003, null]) {
          expect(
            pictureBitrate(PictureTarget.hevcMain, height: height, fps: fps),
            hevc,
            reason: '$height $fps',
          );
          expect(
            pictureBitrate(PictureTarget.hevcMain10, height: height, fps: fps),
            hevc,
            reason: '$height $fps',
          );
          expect(
            pictureBitrate(PictureTarget.h264High, height: height, fps: fps),
            h264,
            reason: '$height $fps',
          );
        }
      }
    });

    test('1.4 times as much above 30 frames a second, never above 24 M', () {
      for (final (height, hevc, h264) in [
        (576, 3500000, 4900000),
        (720, 5600000, 8400000),
        (1080, 11200000, 16800000),
        (1440, 16800000, 24000000),
        (2160, 22400000, 24000000),
      ]) {
        expect(
          pictureBitrate(PictureTarget.hevcMain, height: height, fps: 59.94),
          hevc,
          reason: '$height',
        );
        expect(
          pictureBitrate(PictureTarget.h264High, height: height, fps: 50),
          h264,
          reason: '$height',
        );
      }
    });

    test('a height mpv has not reported is taken as 1080', () {
      expect(pictureBitrate(PictureTarget.hevcMain), 8000000);
      expect(pictureBitrate(PictureTarget.h264High), 12000000);
    });
  });

  group('a picture this phone converts', () {
    test('AV1 4K to the Google TV is made HEVC, and tried', () {
      final result = judge(film());
      expect(result, isA<CastRendition>());
      result as CastRendition;
      expect(
        result.picture,
        const PicturePlan(PictureTarget.hevcMain, 16000000),
      );
      // The certain row is H.264 at 1080p30: only the best model with the
      // name decodes HEVC at 4K.
      expect(result.tentative, isTrue);
      expect(result.video, 'HEVC');
      expect(result.sourceVideo, 'AV1');
      // The sound rule is the same as for a copy.
      expect(result.convertsSound, isTrue);
    });

    test('VP9 a copy cannot carry is converted too', () {
      final result = judge(
        film(
          video: 'vp9',
          width: 1920,
          height: 1080,
          audio: 'aac',
          channels: 2,
        ),
        receiver: ultra,
      );
      result as CastRendition;
      expect(
        result.picture,
        const PicturePlan(PictureTarget.hevcMain, 8000000),
      );
      expect(result.tentative, isFalse);
      expect(result.convertsSound, isFalse);
    });

    test('10-bit H.264 1080p is made 10-bit HEVC', () {
      final result = judge(
        film(
          video: 'h264 (High 10)',
          width: 1920,
          height: 1080,
          pixels: 'yuv420p10',
        ),
      );
      result as CastRendition;
      expect(
        result.picture,
        const PicturePlan(PictureTarget.hevcMain10, 8000000),
      );
      expect(result.sourceVideo, 'H.264');
      expect(result.video, 'HEVC');
    });

    test('10-bit H.264 on a phone without 10-bit encoding is made 8-bit', () {
      final result = judge(
        film(
          video: 'h264 (High 10)',
          width: 1920,
          height: 1080,
          pixels: 'yuv420p10',
        ),
        conversion: eightBitPhone,
      );
      expect(
        (result as CastRendition).picture,
        const PicturePlan(PictureTarget.hevcMain, 8000000),
      );
    });

    test('8-bit video is never made 10-bit', () {
      final result = judge(film(pixels: 'yuv420p'));
      expect((result as CastRendition).picture?.target, PictureTarget.hevcMain);
    });

    test('HDR up to 1080p is made 10-bit HEVC, with its transfer kept', () {
      for (final transfer in ['pq', 'hlg']) {
        final result = judge(
          film(
            width: 1920,
            height: 1080,
            pixels: 'yuv420p10',
            transfer: transfer,
          ),
        );
        expect(
          (result as CastRendition).picture,
          const PicturePlan(PictureTarget.hevcMain10, 8000000),
          reason: transfer,
        );
      }
    });

    test('HDR above 1080p is refused: the phone is too slow at that size', () {
      for (final (width, height) in [
        (3840, 2160),
        (2560, 1440),
        (1920, 1088),
      ]) {
        final result = judge(
          film(
            width: width,
            height: height,
            pixels: 'yuv420p10',
            transfer: 'pq',
          ),
        );
        expect(
          (result as CastRefused).reason,
          CastRefusal.hdrTooLarge,
          reason: '${width}x$height',
        );
        expect(
          result.explanation,
          "This phone can't convert a 4K HDR picture for casting fast enough, "
          "and xtremio doesn't convert HDR to SDR.",
        );
      }
    });

    test('10-bit ordinary video above 1080p is made 8-bit HEVC', () {
      final result = judge(film(pixels: 'yuv420p10'));
      expect(
        (result as CastRendition).picture,
        const PicturePlan(PictureTarget.hevcMain, 16000000),
      );
    });

    test('HDR to a receiver that shows no HEVC is refused', () {
      final result = judge(
        film(width: 1280, height: 720, transfer: 'pq'),
        receiver: nestHub,
      );
      expect((result as CastRefused).reason, CastRefusal.hdr);
      expect(
        result.explanation,
        'Every receiver that calls itself "Google Nest Hub" can\'t show HDR '
        "pictures, and xtremio doesn't convert HDR to SDR.",
      );
    });

    test('HDR on a phone without 10-bit encoding is refused', () {
      final result = judge(film(transfer: 'pq'), conversion: eightBitPhone);
      expect((result as CastRefused).reason, CastRefusal.hdr);
      expect(
        result.explanation,
        "This phone can't convert HDR pictures for casting, and xtremio "
        "doesn't convert HDR to SDR.",
      );
    });

    test('4K to a receiver that shows 1080p is refused: pictures are never '
        'made smaller', () {
      final result = judge(film(), receiver: hdOnly);
      expect((result as CastRefused).reason, CastRefusal.pictureSize);
      expect(
        result.explanation,
        'Every receiver that calls itself "Living Room HD" plays HEVC up to '
        "1920x1080 at 60 frames a second. This film's picture is 3840x2160 "
        "at 24 frames a second. xtremio doesn't make pictures smaller, so "
        'this receiver cannot show it.',
      );
      // HDR beyond the row's HEVC is the same refusal, not the HDR one.
      expect(
        (judge(film(transfer: 'pq'), receiver: hdOnly) as CastRefused).reason,
        CastRefusal.pictureSize,
      );
    });

    test('a receiver that showed no HEVC picture gets H.264', () {
      final result = judge(
        film(width: 1920, height: 1080),
        noPicture: {'HEVC'},
      );
      result as CastRendition;
      expect(
        result.picture,
        const PicturePlan(PictureTarget.h264High, 12000000),
      );
      // Every model calling itself "Chromecast" decodes H.264 at 1080p24.
      expect(result.tentative, isFalse);
      expect(result.video, 'H.264');
    });

    test('an HEVC copy the receiver showed no picture for is converted to '
        'H.264', () {
      final hevc = film(video: 'hevc (Main)', width: 1920, height: 1080);
      expect(
        (judge(hevc) as CastRendition).picture,
        isNull,
        reason: 'copied while nothing says otherwise',
      );
      final result = judge(hevc, noPicture: {'HEVC'});
      result as CastRendition;
      expect(result.picture?.target, PictureTarget.h264High);
      expect(result.sourceVideo, 'HEVC');
    });

    test('where only the codec without a picture fits, it is that one, for '
        'the player to refuse', () {
      // A Chromecast Ultra decodes H.264 only up to 1080p.
      final result = judge(film(), receiver: ultra, noPicture: {'HEVC'});
      expect((result as CastRendition).video, 'HEVC');
      // And a copy of it stays a copy, refused the same way.
      final copy = judge(
        film(video: 'hevc (Main)'),
        receiver: ultra,
        noPicture: {'HEVC'},
      );
      expect((copy as CastRendition).picture, isNull);
    });

    test("a phone that doesn't encode HEVC makes H.264", () {
      final result = judge(
        film(width: 1920, height: 1080),
        conversion: const PictureSupport(
          decodes: {'AV1'},
          encodes: {'H.264'},
          tenBit: true,
        ),
      );
      expect(
        (result as CastRendition).picture,
        const PicturePlan(PictureTarget.h264High, 12000000),
      );
    });
  });

  group('where nothing is converted, the refusals stand', () {
    const av1Refusal =
        "This film's video is AV1. This receiver can't play it, and xtremio "
        "can't convert it for casting yet.";

    test('a phone that converts nothing', () {
      for (final conversion in [null, PictureSupport.none]) {
        final result = judge(film(), conversion: conversion);
        expect((result as CastRefused).explanation, av1Refusal);
      }
    });

    test("a phone that doesn't decode the film's codec", () {
      final result = judge(
        film(),
        conversion: const PictureSupport(
          decodes: {'H.264', 'HEVC'},
          encodes: {'H.264', 'HEVC'},
        ),
      );
      expect((result as CastRefused).explanation, av1Refusal);
    });

    test('a stream not played by id', () {
      final result = CastCompatibility.of(
        url: Uri.parse('https://cdn.example.com/film.mkv'),
        receiver: chromecast,
        stats: film(),
        canRepackage: true,
        conversion: phone,
      );
      expect((result as CastRefused).reason, CastRefusal.container);
    });

    test('a picture beyond 10 bits or 4:2:0', () {
      for (final (pixels, picture) in [
        ('yuv422p', '4:2:2 H.264'),
        ('yuv444p10', '10-bit 4:4:4 H.264'),
      ]) {
        final result = judge(
          film(video: 'h264', width: 1920, height: 1080, pixels: pixels),
        );
        expect(
          (result as CastRefused).explanation,
          "This film's video is $picture. No Chromecast can play it, and "
          "xtremio can't convert it for casting yet.",
          reason: pixels,
        );
      }
    });

    test('a film a copy carries goes as a copy', () {
      final result = judge(film(video: 'hevc (Main 10)'));
      expect((result as CastRendition).picture, isNull);
      expect(result.sourceVideo, isNull);
    });
  });

  group('a film in another container is converted, picture and sound', () {
    /// An AVI as zond's first try was: Xvid, MP3 in stereo, 720x576 at 25.
    PlaybackStats avi({
      String video = 'mpeg4 (MPEG-4 part 2)',
      String audio = 'mp3',
      int width = 720,
      int height = 576,
      String format = 'avi',
    }) => film(
      format: format,
      video: video,
      audio: audio,
      channels: 2,
      width: width,
      height: height,
      fps: 25,
      pixels: 'yuv420p',
    );

    test('Xvid in an AVI to the Google TV is made HEVC, and tried', () {
      final result = judge(avi(), conversion: softwarePhone);
      expect(result, isA<CastRendition>());
      result as CastRendition;
      expect(
        result.picture,
        const PicturePlan(PictureTarget.hevcMain, 2500000),
      );
      expect(result.sourceVideo, 'MPEG-4 Part 2');
      expect(result.video, 'HEVC');
      expect(result.convertsSound, isTrue, reason: 'MP3 never passes through');
      expect(result.tentative, isTrue);
    });

    test('Xvid at 1920x1080 is made too', () {
      final result = judge(
        avi(width: 1920, height: 1080),
        conversion: softwarePhone,
      );
      expect(
        (result as CastRendition).picture,
        const PicturePlan(PictureTarget.hevcMain, 8000000),
      );
    });

    test(
      'Xvid above 1920x1080 is refused: too slow to decode on the phone',
      () {
        for (final (width, height) in [
          (1920, 1088),
          (2560, 1080),
          (3840, 2160),
        ]) {
          final result = judge(
            avi(width: width, height: height),
            conversion: softwarePhone,
            receiver: ultra,
          );
          expect(result, isA<CastRefused>(), reason: '${width}x$height');
          result as CastRefused;
          expect(result.reason, CastRefusal.tooSlow);
          expect(
            result.explanation,
            "This phone can't convert this film's picture for casting fast "
            'enough.',
          );
        }
      },
    );

    test('DivX 3 and MPEG-2 are decoded the same way', () {
      for (final (video, name) in [
        ('msmpeg4v3 (MPEG-4 part 2 Microsoft variant version 3)', 'DivX 3'),
        ('mpeg2video (MPEG-2 video)', 'MPEG-2'),
      ]) {
        final result = judge(avi(video: video), conversion: softwarePhone);
        expect((result as CastRendition).sourceVideo, name);
        expect(result.picture?.target, PictureTarget.hevcMain);
      }
    });

    test('H.264 in an AVI is converted by the hardware, its sound too', () {
      for (final audio in ['ac3', 'aac']) {
        final result = judge(
          avi(video: 'h264 (High)', audio: audio, width: 1280, height: 720),
          conversion: phone,
        );
        expect(result, isA<CastRendition>(), reason: audio);
        result as CastRendition;
        expect(
          result.picture,
          const PicturePlan(PictureTarget.hevcMain, 4000000),
        );
        expect(result.sourceVideo, 'H.264');
        expect(result.convertsSound, isTrue, reason: audio);
      }
    });

    test('an AVI on a phone without software decoders keeps the container '
        'refusal', () {
      for (final conversion in [phone, null, PictureSupport.none]) {
        final result = judge(avi(), conversion: conversion);
        expect(result, isA<CastRefused>());
        result as CastRefused;
        expect(result.reason, CastRefusal.container);
        expect(
          result.explanation,
          'A Chromecast plays MP4 and WebM files. This stream is an AVI file, '
          "and xtremio can't convert this one for casting.",
        );
      }
    });

    test('a transport stream with H.264 is converted too', () {
      final result = judge(
        avi(
          format: 'mpegts',
          video: 'h264 (High)',
          audio: 'aac',
          width: 1920,
          height: 1080,
        ),
        conversion: phone,
      );
      expect(result, isA<CastRendition>());
      result as CastRendition;
      expect(result.picture?.target, PictureTarget.hevcMain);
      expect(result.convertsSound, isTrue);
    });

    test('software decoding is for 8-bit pictures alone: a deeper one keeps '
        'the container refusal', () {
      final result = judge(
        film(
          format: 'avi',
          video: 'mpeg4',
          width: 720,
          height: 576,
          pixels: 'yuv420p10',
        ),
        conversion: softwarePhone,
      );
      expect((result as CastRefused).reason, CastRefusal.container);
    });
  });

  test('the spec asks the server for the conversion', () {
    const spec = RenditionSpec(
      duration: Duration(minutes: 90),
      start: Duration.zero,
      picture: PicturePlan(PictureTarget.hevcMain10, 16000000),
    );
    expect(spec.toJson()['video'], {
      'convert': {'target': 'hevcMain10', 'bitrate': 16000000},
    });
    expect(
      const RenditionSpec(
        duration: Duration(minutes: 90),
        start: Duration.zero,
      ).toJson()['video'],
      'copy',
    );
    expect(
      [for (final target in PictureTarget.values) target.wire],
      ['h264High', 'hevcMain', 'hevcMain10'],
    );
  });
}
