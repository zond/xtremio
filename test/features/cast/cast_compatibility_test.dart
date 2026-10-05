import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/cast/cast_compatibility.dart';
import 'package:xtremio/features/cast/receiver_table.dart';
import 'package:xtremio/features/player/playback_stats.dart';

/// The torrent URL the server serves a stream from: no extension anywhere
/// in it, and nothing the check would read if there were.
final torrentUrl = Uri.parse(
  'http://127.0.0.1:11470/11ea02584fa6351956f35671962ab46354d99060/0',
);

/// A stream played by id, which is what a rendition is made from.
final byId = mediaIdUrl('0123456789abcdef0123456789abcdef');

/// mpv's `file-format` for the two families: libavformat's one reader for
/// MP4, M4V and QuickTime, and mpv's own Matroska reader.
const mp4Format = 'mov,mp4,m4a,3gp,3g2,mj2';
const mkvFormat = 'mkv';

PlaybackStats mp4({
  String? video = 'h264 (High)',
  String? audio = 'aac',
  int? channels,
}) => PlaybackStats(
  fileFormat: mp4Format,
  videoCodec: video,
  audioCodec: audio,
  audioChannels: channels,
);

PlaybackStats mkv({
  String? video = 'h264 (High)',
  String? audio = 'aac',
  int? channels,
}) => PlaybackStats(
  fileFormat: mkvFormat,
  videoCodec: video,
  audioCodec: audio,
  audioChannels: channels,
);

/// A receiver announcing "Chromecast Ultra", a name only that model
/// announces: the row that decodes H.264, HEVC, VP8 and VP9 alike, with
/// nothing to try.
final ultraByName = ReceiverTable.of(announced: 'Chromecast Ultra');

/// [CastCompatibility.of] for a "Chromecast Ultra" unless [receiver] says
/// otherwise, so the tests of the container and sound rules are not about
/// the receiver.
CastCompatibility check({
  Uri? url,
  PlaybackStats? stats,
  bool canRepackage = false,
  ReceiverRow? receiver,
}) => CastCompatibility.of(
  url: url ?? torrentUrl,
  receiver: receiver ?? ultraByName,
  stats: stats,
  canRepackage: canRepackage,
);

/// A `player` state whose selected stream carries [claimed] as the addon's
/// `behaviorHints.filename`, and whose converted stream carries [converted]:
/// the two ends of the chain [castFilename] walks.
PlayerState playerState({String? claimed, String? converted}) =>
    PlayerState.fromJson({
      'selected': {
        'stream': {
          'infoHash': '11ea02584fa6351956f35671962ab46354d99060',
          'fileIdx': 0,
          'behaviorHints': {'filename': ?claimed},
        },
      },
      'stream': {
        'type': 'Ready',
        'content': [
          {'streaming_url': torrentUrl.toString()},
          if (converted != null)
            {
              'infoHash': '11ea02584fa6351956f35671962ab46354d99060',
              'behaviorHints': {'filename': converted},
            },
        ],
      },
    });

CastRefusal? refusalOf(CastCompatibility result) =>
    result is CastRefused ? result.reason : null;

void main() {
  group('mpv says what the file is, and nothing else does', () {
    test('an MP4 mpv reads as H.264 and AAC is castable', () {
      final result = check(stats: mp4());
      expect((result as CastReady).contentType, 'video/mp4');
    });

    test('the field: a debrid link that names no file, read as Matroska', () {
      // No filename from the addon, no extension on the URL: the cast was
      // refused as "nothing here says what kind of file this is" while mpv
      // was playing it.
      final result = check(
        url: byId,
        stats: mkv(video: 'hevc (Main 10)', audio: 'eac3'),
        canRepackage: true,
      );
      expect((result as CastRendition).convertsSound, isTrue);
    });

    test('a name on the URL is not read: mpv calls this .mp4 a Matroska', () {
      final url = Uri.parse('https://cdn.example.com/movies/sintel.mp4');
      expect(refusalOf(check(url: url, stats: mkv())), CastRefusal.container);
      // And the other way: named .mkv, an MP4 inside.
      expect(
        check(
          url: Uri.parse('https://cdn.example.com/movies/sintel.mkv'),
          stats: mp4(),
        ),
        isA<CastReady>(),
      );
    });

    test("libavformat's name for Matroska is the same family", () {
      final result = check(
        url: byId,
        stats: const PlaybackStats(
          fileFormat: 'matroska,webm',
          videoCodec: 'h264 (High)',
          audioCodec: 'aac',
        ),
        canRepackage: true,
      );
      expect(result, isA<CastRendition>());
    });

    test('before mpv has reported, the answer is a "not yet"', () {
      for (final stats in [
        null,
        const PlaybackStats(),
        // The reader known, the picture not yet.
        const PlaybackStats(fileFormat: mkvFormat),
        // The codecs known, the reader not: no guessing the container.
        const PlaybackStats(videoCodec: 'h264 (High)', audioCodec: 'aac'),
      ]) {
        final result = check(url: byId, stats: stats, canRepackage: true);
        expect(refusalOf(result), CastRefusal.pending, reason: '$stats');
        final refused = result as CastRefused;
        expect(
          refused.explanation,
          'The player has not said yet what kind of file this is, and that '
          'is what decides whether a Chromecast can play it. Try again once '
          'it has started playing.',
        );
        expect(refused.title, 'Still working out what this file is');
      }
    });

    test('a film with no sound track is not waiting for one', () {
      expect(check(stats: mp4(audio: null)), isA<CastReady>());
      final rendition = check(
        url: byId,
        stats: mkv(audio: null),
        canRepackage: true,
      );
      expect((rendition as CastRendition).convertsSound, isFalse);
    });
  });

  group('a Matroska file with what a WebM carries is a WebM', () {
    test('VP8 or VP9 with Opus or Vorbis goes as video/webm', () {
      for (final video in ['vp9', 'vp8']) {
        for (final audio in ['opus', 'vorbis', null]) {
          final result = check(
            stats: mkv(video: video, audio: audio),
          );
          expect(
            (result as CastReady).contentType,
            'video/webm',
            reason: '$video/$audio',
          );
        }
      }
    });

    test('with any other sound it is a Matroska file', () {
      final result = check(
        stats: mkv(video: 'vp9', audio: 'mp3'),
      );
      expect(refusalOf(result), CastRefusal.container);
    });

    test('a Matroska file is refused, and the sentence names it', () {
      final result = check(stats: mkv()) as CastRefused;
      expect(result.reason, CastRefusal.container);
      expect(
        result.explanation,
        'A Chromecast plays MP4 and WebM files; this stream is a Matroska '
        '(.mkv) file. Casting it would need conversion, which this app '
        'cannot do yet.',
      );
    });
  });

  group('a Matroska H.264 or HEVC film played by id is a rendition', () {
    test('when this device can repackage, and mpv says H.264 and AAC', () {
      final result = check(url: byId, stats: mkv(), canRepackage: true);
      expect(result, isA<CastRendition>());
    });

    test('a device that cannot repackage still refuses the container', () {
      final result = check(url: byId, stats: mkv());
      expect(refusalOf(result), CastRefusal.container);
    });

    test('HEVC is copied too, Main 10 included: the receiver decodes it', () {
      // zond's Chromecast with Google TV 4K decodes HEVC Main and Main 10.
      for (final video in ['hevc (Main 10)', 'hevc (Main)', 'hevc']) {
        final result = check(
          url: byId,
          stats: mkv(video: video),
          canRepackage: true,
        );
        expect(result, isA<CastRendition>(), reason: video);
      }
    });

    test('its sound is copied when it is AAC', () {
      final result = check(url: byId, stats: mkv(), canRepackage: true);
      expect((result as CastRendition).convertsSound, isFalse);
    });

    test('AAC is copied in one or two channels and converted in more', () {
      for (final (channels, converts) in [
        (1, false),
        (2, false),
        (6, true),
        (8, true),
        // mpv silent about the count: copied, as before it was asked.
        (null, false),
      ]) {
        final result = check(
          url: byId,
          stats: mkv(channels: channels),
          canRepackage: true,
        );
        expect(
          (result as CastRendition).convertsSound,
          converts,
          reason: '$channels channels',
        );
      }
    });

    test('any other sound is converted to stereo AAC (the field: E-AC3)', () {
      // Dolby cast to zond's television plays silent over its Bluetooth
      // sound, so surround is converted whatever the receiver claims.
      for (final codec in [
        'eac3',
        'ac3',
        'dts',
        'truehd',
        'opus',
        'flac',
        'mp3',
        'pcm_s24le',
        'vorbis',
      ]) {
        final result = check(
          url: byId,
          stats: mkv(video: 'hevc (Main 10)', audio: codec),
          canRepackage: true,
        );
        expect(result, isA<CastRendition>(), reason: codec);
        expect((result as CastRendition).convertsSound, isTrue, reason: codec);
      }
    });

    test('video the receiver cannot play is named, and why', () {
      final result = check(
        url: byId,
        stats: mkv(video: 'av1 (Main)'),
        canRepackage: true,
      );
      expect(refusalOf(result), CastRefusal.renditionVideo);
      expect(
        (result as CastRefused).explanation,
        "This film's video is AV1, which this receiver can't play, and "
        "xtremio can't convert it for casting yet.",
      );
    });

    test('video the receiver plays but a copy cannot carry yet says so', () {
      final result = check(
        url: byId,
        stats: mkv(video: 'vp9'),
        canRepackage: true,
      );
      expect(refusalOf(result), CastRefusal.renditionVideo);
      expect(
        (result as CastRefused).explanation,
        "This film's video is VP9, which xtremio can't repackage for casting "
        'yet.',
      );
    });

    test('picture a copy cannot carry is named alone: the sound converts', () {
      final result = check(
        url: byId,
        stats: mkv(video: 'mpeg4', audio: 'dts'),
        canRepackage: true,
      );
      expect(refusalOf(result), CastRefusal.renditionVideo);
      expect(
        (result as CastRefused).explanation,
        "This film's video is MPEG-4 Part 2, which this receiver can't play, "
        "and xtremio can't convert it for casting yet.",
      );
    });

    test('an MP4 whose sound the receiver will not take has it converted', () {
      // Dolby Digital in an MP4: a Chromecast takes the file, and zond's
      // plays it silent. The picture is copied, the sound converted.
      for (final codec in ['ac3', 'eac3', 'dts', 'opus']) {
        final result = check(
          url: byId,
          stats: mp4(audio: codec),
          canRepackage: true,
        );
        expect(result, isA<CastRendition>(), reason: codec);
        expect((result as CastRendition).convertsSound, isTrue, reason: codec);
      }
      // Not by id, or on a device that cannot: refused.
      expect(
        refusalOf(check(stats: mp4(audio: 'ac3'), canRepackage: true)),
        CastRefusal.audioCodec,
      );
      expect(
        refusalOf(
          check(
            url: byId,
            stats: mp4(audio: 'ac3'),
          ),
        ),
        CastRefusal.audioCodec,
      );
    });

    test('an MP4 whose sound needs converting but whose picture a copy '
        'cannot carry is refused for its sound', () {
      // VP9 plays out of an MP4, but a rendition copies only H.264 and
      // HEVC: there is no rendition to make, so the sound is the refusal.
      final result = check(
        url: byId,
        stats: mp4(video: 'vp9', audio: 'ac3'),
        canRepackage: true,
      );
      expect(refusalOf(result), CastRefusal.audioCodec);
    });

    test('only the two families, and only a stream played by id', () {
      expect(
        refusalOf(
          check(
            url: byId,
            stats: const PlaybackStats(
              fileFormat: 'avi',
              videoCodec: 'h264 (High)',
              audioCodec: 'aac',
            ),
            canRepackage: true,
          ),
        ),
        CastRefusal.container,
      );
      expect(
        refusalOf(check(stats: mkv(), canRepackage: true)),
        CastRefusal.container,
        reason: 'a URL the server serves is not an id it reads',
      );
    });

    test('an MP4 the receiver takes as it is stays as it is', () {
      final result = check(url: byId, stats: mp4(), canRepackage: true);
      expect(result, isA<CastReady>());
      expect(
        check(url: byId, stats: mp4(channels: 2), canRepackage: true),
        isA<CastReady>(),
      );
    });

    test('an MP4 with AAC in more than two channels has it mixed down', () {
      final result = check(
        url: byId,
        stats: mp4(channels: 6),
        canRepackage: true,
      );
      expect((result as CastRendition).convertsSound, isTrue);
      // No rendition to be had -- not by id, a device that cannot, a
      // picture a copy cannot carry -- and it goes as it is: AAC is a sound
      // the receiver decodes.
      for (final (url, canRepackage, video) in [
        (torrentUrl, true, 'h264 (High)'),
        (byId, false, 'h264 (High)'),
        (byId, true, 'vp9'),
      ]) {
        expect(
          check(
            url: url,
            stats: mp4(video: video, channels: 6),
            canRepackage: canRepackage,
          ),
          isA<CastReady>(),
          reason: '$url $canRepackage $video',
        );
      }
    });
  });

  group('the sentences of the refusals that are not about a rendition', () {
    test('a container no receiver takes, named by what it is', () {
      final result = check(
        stats: const PlaybackStats(fileFormat: 'avi', videoCodec: 'mpeg4'),
      ) as CastRefused;
      expect(result.reason, CastRefusal.container);
      expect(
        result.explanation,
        'A Chromecast plays MP4 and WebM files; this stream is an AVI file. '
        'Casting it would need conversion, which this app cannot do yet.',
      );
    });

    test('every reader no receiver takes is named by what it opens', () {
      const named = {
        'avi': 'an AVI file',
        'mpegts': 'an MPEG transport stream',
        'mpeg': 'an MPEG program stream',
        'asf': 'a Windows Media file',
        'flv': 'a Flash video file',
        'ogg': 'an Ogg file',
        'rm': 'a RealMedia file',
      };
      for (final MapEntry(key: reader, value: name) in named.entries) {
        final result = check(
          stats: PlaybackStats(fileFormat: reader, videoCodec: 'h264'),
        ) as CastRefused;
        expect(result.reason, CastRefusal.container, reason: reader);
        expect(
          result.explanation,
          contains('this stream is $name.'),
          reason: reader,
        );
      }
    });

    test("a reader with no name here is called by mpv's", () {
      final result = check(
        stats: const PlaybackStats(fileFormat: 'nut', videoCodec: 'h264'),
      ) as CastRefused;
      expect(result.reason, CastRefusal.container);
      expect(result.explanation, contains('a file of a kind mpv calls "nut"'));
    });

    test('video in an MP4 the receiver cannot decode', () {
      final result = check(stats: mp4(video: 'av1 (Main)')) as CastRefused;
      expect(result.reason, CastRefusal.videoCodec);
      expect(
        result.explanation,
        'Every receiver that calls itself "Chromecast Ultra" plays H.264, '
        "VP8, HEVC or VP9 video; this film's video is AV1. Casting it would "
        'need conversion, which this app cannot do yet.',
      );
    });

    test('sound in an MP4 the receiver cannot decode', () {
      final result = check(stats: mp4(audio: 'eac3')) as CastRefused;
      expect(result.reason, CastRefusal.audioCodec);
      expect(
        result.explanation,
        'A Chromecast decodes AAC or MP3 audio in an MP4 file; this stream is '
        'Dolby Digital Plus (E-AC3). Casting it would need conversion, which '
        'this app cannot do yet.',
      );
    });
  });

  group('what the receiver decodes is its row\'s to say', () {
    final chromecastByName = ReceiverTable.of(announced: 'Chromecast');
    final nestHubByName = ReceiverTable.of(announced: 'Google Nest Hub');

    test('HEVC is a rendition, and no trial, on a name whose one model '
        'decodes it', () {
      final result = check(
        url: byId,
        stats: mkv(video: 'hevc (Main 10)'),
        canRepackage: true,
        receiver: ultraByName,
      );
      expect((result as CastRendition).tentative, isFalse);
    });

    test('HEVC where only some models with the name decode it is tried, '
        'not refused', () {
      // Every "Chromecast" decodes H.264; the best of them HEVC too. The
      // cast is a trial, which the receiver's report of its picture ends.
      final rendition = check(
        url: byId,
        stats: mkv(video: 'hevc (Main)'),
        canRepackage: true,
        receiver: chromecastByName,
      );
      expect((rendition as CastRendition).tentative, isTrue);
      expect(rendition.video, 'HEVC');
      final ready = check(
        url: byId,
        stats: mp4(video: 'hevc'),
        receiver: chromecastByName,
      );
      expect((ready as CastReady).tentative, isTrue);
      // H.264 is no trial: every "Chromecast" decodes it.
      final h264 = check(url: byId, stats: mp4(), receiver: chromecastByName);
      expect((h264 as CastReady).tentative, isFalse);
      expect(h264.video, 'H.264');
    });

    test(
      'what no model with the name decodes is refused, in so many words',
      () {
        final result = check(
          url: byId,
          stats: mp4(video: 'av1 (Main)'),
          receiver: chromecastByName,
        );
        expect(refusalOf(result), CastRefusal.videoCodec);
        expect(
          (result as CastRefused).explanation,
          'The best of the receivers that call themselves "Chromecast" plays '
          "H.264, VP8, HEVC or VP9 video; this film's video is AV1. Casting it "
          'would need conversion, which this app cannot do yet.',
        );
      },
    );

    test('a name whose one model cannot decode the film is refused, not '
        'tried', () {
      final result = check(
        url: byId,
        stats: mkv(video: 'hevc (Main)'),
        canRepackage: true,
        receiver: nestHubByName,
      );
      expect(refusalOf(result), CastRefusal.videoCodec);
      expect(
        (result as CastRefused).explanation,
        'Every receiver that calls itself "Google Nest Hub" plays H.264 or '
        "VP9 video; this film's video is HEVC. Casting it would need "
        'conversion, which this app cannot do yet.',
      );
    });

    test('a WebM the receiver does not decode is refused, not handed over', () {
      final result = check(
        stats: mkv(video: 'vp8', audio: 'opus'),
        receiver: nestHubByName,
      );
      expect(refusalOf(result), CastRefusal.videoCodec);
      // Where only some models with the name decode it, tried.
      final tried = check(
        stats: mkv(video: 'vp9', audio: 'opus'),
        receiver: chromecastByName,
      );
      expect((tried as CastReady).contentType, 'video/webm');
      expect(tried.tentative, isTrue);
    });

    test('a film bigger than the one model with the name shows is refused '
        'with its size', () {
      const stats = PlaybackStats(
        fileFormat: mp4Format,
        videoCodec: 'h264 (High)',
        audioCodec: 'aac',
        width: 1920,
        height: 1080,
        containerFps: 23.976,
      );
      final result = check(stats: stats, receiver: nestHubByName);
      expect(refusalOf(result), CastRefusal.pictureSize);
      expect(
        (result as CastRefused).explanation,
        'Every receiver that calls itself "Google Nest Hub" plays H.264 up '
        "to 1280x720 at 60 frames a second; this film's picture is "
        '1920x1080 at 24 frames a second. xtremio sends the picture as it '
        'is, so this receiver cannot show it.',
      );
    });

    test('a film bigger than the best model with the name shows is refused '
        'with its size; within it, tried', () {
      const film4k = PlaybackStats(
        fileFormat: mkvFormat,
        videoCodec: 'hevc (Main 10)',
        audioCodec: 'eac3',
        width: 3840,
        height: 2160,
        containerFps: 23.976,
      );
      expect(
        (check(
          url: byId,
          stats: film4k,
          canRepackage: true,
          receiver: chromecastByName,
        ) as CastRendition).tentative,
        isTrue,
      );
      const film8k = PlaybackStats(
        fileFormat: mkvFormat,
        videoCodec: 'hevc (Main 10)',
        audioCodec: 'eac3',
        width: 7680,
        height: 4320,
        containerFps: 23.976,
      );
      final result = check(
        url: byId,
        stats: film8k,
        canRepackage: true,
        receiver: chromecastByName,
      );
      expect(refusalOf(result), CastRefusal.pictureSize);
      expect(
        (result as CastRefused).explanation,
        'The best of the receivers that call themselves "Chromecast" plays '
        "HEVC up to 3840x2160 at 60 frames a second; this film's picture is "
        '7680x4320 at 24 frames a second. xtremio sends the picture as it '
        'is, so this receiver cannot show it.',
      );
    });

    test('a row that names two limits is held to either', () {
      // "Chromecast": H.264 at 720p60 or 1080p30 for certain, and at its
      // best 4K30 or 1080p60.
      PlaybackStats h264({
        required int width,
        required int height,
        required double fps,
      }) => PlaybackStats(
        fileFormat: mp4Format,
        videoCodec: 'h264 (High)',
        audioCodec: 'aac',
        width: width,
        height: height,
        containerFps: fps,
      );
      for (final (width, height, fps) in [
        (1920, 1080, 29.97),
        (1280, 720, 59.94),
      ]) {
        final certain = check(
          stats: h264(width: width, height: height, fps: fps),
          receiver: chromecastByName,
        );
        expect((certain as CastReady).tentative, isFalse, reason: '$height');
      }
      for (final (width, height, fps) in [
        (1920, 1080, 59.94),
        (3840, 2160, 29.97),
      ]) {
        final tried = check(
          stats: h264(width: width, height: height, fps: fps),
          receiver: chromecastByName,
        );
        expect((tried as CastReady).tentative, isTrue, reason: '$height');
      }
      final result = check(
        stats: h264(width: 3840, height: 2160, fps: 59.94),
        receiver: chromecastByName,
      );
      expect(
        (result as CastRefused).explanation,
        contains(
          'plays H.264 up to 3840x2160 at 30 frames a second, or 1920x1080 at '
          '60 frames a second;',
        ),
      );
    });
  });

  group('a picture no Cast receiver decodes is refused up front', () {
    // Google's table: H.264 High, 8-bit 4:2:0, on every receiver; HEVC Main
    // and Main 10 on those that decode HEVC. mpv says which by the picture
    // its decoder hands out (`video-params/pixelformat`): the libmpv this
    // app ships names no profile anywhere -- its `video-codec` is
    // "h264 (H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10)".
    const h264 = 'h264 (H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10)';
    const hevc = 'hevc (H.265 / HEVC (High Efficiency Video Coding))';

    PlaybackStats film(
      String format, {
      String video = h264,
      String? pixels,
      String? hwPixels,
    }) => PlaybackStats(
      fileFormat: format,
      videoCodec: video,
      audioCodec: 'aac',
      pixelFormat: pixels,
      hwPixelFormat: hwPixels,
    );

    String refusal(String picture) =>
        "This film's video is $picture, which no Chromecast can play, and "
        "xtremio can't convert it for casting yet.";

    final receivers = [
      ultraByName,
      ReceiverTable.of(announced: 'Chromecast'),
      ReceiverTable.of(announced: 'Google TV Streamer'),
      ReceiverTable.unknown,
    ];

    /// Every way the film could have gone: as it is or repackaged, to
    /// every kind of receiver.
    void refusedEverywhere(
      PlaybackStats Function(String format) stats,
      String picture,
    ) {
      for (final receiver in receivers) {
        for (final format in [mp4Format, mkvFormat]) {
          for (final repackage in [false, true]) {
            final result = check(
              url: byId,
              stats: stats(format),
              canRepackage: repackage,
              receiver: receiver,
            );
            final reason = '${receiver.subject} $format $repackage';
            expect(result, isA<CastRefused>(), reason: reason);
            result as CastRefused;
            expect(result.reason, CastRefusal.pictureFormat, reason: reason);
            expect(result.explanation, refusal(picture), reason: reason);
          }
        }
      }
    }

    test('H.264 that is not 8-bit 4:2:0, as mpv names its pixels', () {
      for (final (pixels, picture) in [
        // High 10 and High 10 Intra ("Hi10P"), as mpv and as ffmpeg name it.
        ('yuv420p10', '10-bit H.264'),
        ('yuv420p10le', '10-bit H.264'),
        // High 4:2:2 and High 4:2:2 Intra, 8 and 10 bits.
        ('yuv422p', '4:2:2 H.264'),
        ('yuv422p10', '10-bit 4:2:2 H.264'),
        // High 4:4:4 Predictive, High 4:4:4 Intra, CAVLC 4:4:4 Intra.
        ('yuv444p', '4:4:4 H.264'),
        ('yuv444p10', '10-bit 4:4:4 H.264'),
        ('gbrp', '4:4:4 H.264'),
      ]) {
        refusedEverywhere((format) => film(format, pixels: pixels), picture);
      }
    });

    test('a hardware decoder\'s picture is judged by what it holds', () {
      refusedEverywhere(
        (format) => film(format, pixels: 'mediacodec', hwPixels: 'p010'),
        '10-bit H.264',
      );
      // A surface that says nothing of what it holds is not held against
      // the film: the receiver's report of its picture is the check then.
      expect(
        check(stats: film(mp4Format, pixels: 'mediacodec')),
        isA<CastReady>(),
      );
    });

    test('8-bit 4:2:0 H.264 goes as it did', () {
      for (final pixels in ['yuv420p', 'yuvj420p', 'nv12', 'nv21', null]) {
        expect(
          check(stats: film(mp4Format, pixels: pixels)),
          isA<CastReady>(),
          reason: '$pixels',
        );
        expect(
          check(
            url: byId,
            stats: film(mkvFormat, pixels: pixels),
            canRepackage: true,
          ),
          isA<CastRendition>(),
          reason: '$pixels',
        );
      }
      // The names the tests elsewhere use, profile and all, and none.
      for (final video in ['h264 (High)', 'h264 (Main)', 'h264']) {
        expect(check(stats: mp4(video: video)), isA<CastReady>());
      }
    });

    test('HEVC Main 10 goes as it did; 12 bits, 4:2:2 and 4:4:4 do not', () {
      for (final pixels in ['yuv420p', 'yuv420p10', 'p010', null]) {
        expect(
          check(
            stats: film(mp4Format, video: hevc, pixels: pixels),
          ),
          isA<CastReady>(),
          reason: '$pixels',
        );
        expect(
          check(
            url: byId,
            stats: film(mkvFormat, video: hevc, pixels: pixels),
            canRepackage: true,
          ),
          isA<CastRendition>(),
          reason: '$pixels',
        );
      }
      for (final (pixels, picture) in [
        ('yuv420p12', '12-bit HEVC'),
        ('yuv422p10', '10-bit 4:2:2 HEVC'),
        ('yuv444p', '4:4:4 HEVC'),
      ]) {
        refusedEverywhere(
          (format) => film(format, video: hevc, pixels: pixels),
          picture,
        );
      }
    });
  });

  group('a file of sound alone', () {
    PlaybackStats sound(String format, String audio, {String? track}) =>
        PlaybackStats(fileFormat: format, audioCodec: audio, videoTrack: track);

    test('goes as it is when its container may carry its sound', () {
      expect(
        (check(stats: sound(mp4Format, 'aac')) as CastReady).contentType,
        'video/mp4',
      );
      expect(
        (check(stats: sound('matroska,webm', 'opus')) as CastReady).contentType,
        'video/webm',
      );
      expect(
        (check(stats: sound(mp4Format, 'aac')) as CastReady).video,
        isNull,
      );
    });

    test('is refused when it may not, or the container is no receiver\'s', () {
      expect(
        refusalOf(check(stats: sound(mp4Format, 'flac'))),
        CastRefusal.audioCodec,
      );
      expect(
        refusalOf(check(stats: sound('mkv', 'flac'))),
        CastRefusal.audioCodec,
      );
      expect(
        refusalOf(check(stats: sound('ogg', 'vorbis'))),
        CastRefusal.container,
      );
    });

    test('a video track whose decoder has not reported is still a not yet', () {
      expect(
        refusalOf(check(stats: sound(mp4Format, 'aac', track: 'h264'))),
        CastRefusal.pending,
      );
      // And no sound either: nothing has been read yet.
      expect(
        refusalOf(check(stats: const PlaybackStats(fileFormat: mp4Format))),
        CastRefusal.pending,
      );
    });
  });

  group('a proxied stream is refused before anything else', () {
    test('a /proxy URL is never cast, MP4 or not', () {
      final result = check(
        url: Uri.parse('http://127.0.0.1:11470/proxy/d/http/host/a.mp4'),
        stats: mp4(),
      );
      expect(refusalOf(result), CastRefusal.proxied);
      expect((result as CastRefused).explanation, contains('local network'));
    });

    test('/ftp goes the same way', () {
      final result = check(
        url: Uri.parse('http://127.0.0.1:11470/ftp/host/a.mp4'),
        stats: mp4(),
      );
      expect(refusalOf(result), CastRefusal.proxied);
    });

    test('a proxy on someone else\'s server is still a proxy', () {
      final result = check(
        url: Uri.parse('http://192.168.1.9:11470/proxy/d/http/host/a.mp4'),
      );
      expect(refusalOf(result), CastRefusal.proxied);
    });
  });

  group('what an MP4 may carry', () {
    test('HEVC is castable, being one the receiver decodes', () {
      expect(check(stats: mp4(video: 'hevc (Main 10)')), isA<CastReady>());
    });

    test('MP3 audio is castable: the developer torrent, from the field', () {
      // Big Buck Bunny.mp4 carries H.264 and an MP3 track.
      expect(check(stats: mp4(audio: 'mp3')), isA<CastReady>());
    });

    test('DTS and Opus are refused, each by name', () {
      for (final (codec, name) in [('dts', 'DTS'), ('opus', 'Opus')]) {
        final result = check(stats: mp4(audio: codec));
        expect(refusalOf(result), CastRefusal.audioCodec, reason: codec);
        expect((result as CastRefused).explanation, contains(name));
      }
    });
  });

  group('the best name for the file: the server outranks the addon', () {
    test('the server name is used when the addon claimed nothing', () {
      expect(
        castFilename(playerState(), serverFilename: 'Big Buck Bunny.mp4'),
        'Big Buck Bunny.mp4',
      );
    });

    test('the server wins when the two disagree', () {
      // The addon linked to what it thinks is an mkv; the server opened an
      // mp4. Only one of them has the file open.
      final filename = castFilename(
        playerState(claimed: 'Sintel.2010.1080p.mkv'),
        serverFilename: 'Sintel.2010.1080p.mp4',
      );
      expect(filename, 'Sintel.2010.1080p.mp4');
    });

    test('and it outranks the converted stream, which is the same claim', () {
      // `Stream::to_converted` clones `behavior_hints` verbatim, so for a
      // torrent the converted stream's filename *is* the addon's. Only the
      // server has the file open.
      expect(
        castFilename(
          playerState(claimed: 'claimed.mkv', converted: 'claimed.mkv'),
          serverFilename: 'opened.mp4',
        ),
        'opened.mp4',
      );
    });

    test('an offline play reads the file on disk, having no server name', () {
      // The offline stream the app builds is a `url` stream with the real
      // on-disk name; there is no torrent behind it, so nothing outranks it.
      expect(
        castFilename(
          playerState(claimed: 'on-disk.mp4', converted: 'on-disk.mp4'),
        ),
        'on-disk.mp4',
      );
    });

    test('no server name falls back to what the addon claimed', () {
      expect(castFilename(playerState(claimed: 'claimed.mp4')), 'claimed.mp4');
    });
  });
}
