import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/cast/cast_compatibility.dart';
import 'package:xtremio/features/details/stream_facts.dart';
import 'package:xtremio/features/player/playback_stats.dart';

/// The torrent URL the server serves a stream from: no extension anywhere
/// in it, which is why the filename is what the check reads.
final torrentUrl = Uri.parse(
  'http://127.0.0.1:11470/11ea02584fa6351956f35671962ab46354d99060/0',
);

StreamFacts factsFor(String name, {String? filename}) => StreamFacts.of(
  StreamInfo({
    'name': name,
    'url': 'http://example.com/x',
    'behaviorHints': {'filename': ?filename},
  }),
);

CastCompatibility check({
  Uri? url,
  StreamFacts? facts,
  String? filename,
  PlaybackStats? stats,
}) => CastCompatibility.of(
  url: url ?? torrentUrl,
  facts: facts,
  filename: filename,
  stats: stats,
);

CastRefusal? refusalOf(CastCompatibility result) =>
    result is CastRefused ? result.reason : null;

void main() {
  group('the container decides first', () {
    test('an MP4 with nothing said about its codecs is castable', () {
      final result = check(filename: 'Sintel.2010.1080p.mp4');
      expect(result, isA<CastReady>());
      expect((result as CastReady).contentType, 'video/mp4');
    });

    test('WebM is castable and declares its own type', () {
      final result = check(filename: 'clip.webm');
      expect((result as CastReady).contentType, 'video/webm');
    });

    test('a Matroska file is refused, and the sentence names it', () {
      final result = check(filename: 'Sintel.2010.1080p.mkv');
      expect(refusalOf(result), CastRefusal.container);
      expect((result as CastRefused).explanation, contains('Matroska'));
      // The refusal has to say the conversion is missing, not just "no".
      expect(result.explanation, contains('conversion'));
    });

    test('an unknown container is refused rather than guessed at', () {
      // A torrent URL with no filename anywhere: the common case, and the
      // one where a guess would be a guess about the whole evening.
      final result = check();
      expect(refusalOf(result), CastRefusal.unknownContainer);
      expect((result as CastRefused).explanation, contains('conversion'));
    });

    test('a URL that ends in a file name is read when nothing else does', () {
      final result = check(
        url: Uri.parse('https://cdn.example.com/movies/sintel.mp4'),
      );
      expect(result, isA<CastReady>());
    });

    test('the filename wins over the URL, being about the file itself', () {
      final result = check(
        url: Uri.parse('https://cdn.example.com/play.mp4'),
        filename: 'Sintel.mkv',
      );
      expect(refusalOf(result), CastRefusal.container);
    });
  });

  group('a proxied stream is refused before anything else', () {
    test('a /proxy URL is never cast, MP4 or not', () {
      final result = check(
        url: Uri.parse('http://127.0.0.1:11470/proxy/d/http/host/a.mp4'),
        filename: 'a.mp4',
      );
      expect(refusalOf(result), CastRefusal.proxied);
      expect((result as CastRefused).explanation, contains('local network'));
    });

    test('/ftp goes the same way', () {
      final result = check(
        url: Uri.parse('http://127.0.0.1:11470/ftp/host/a.mp4'),
        filename: 'a.mp4',
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

  group('codecs are believed when they say something is wrong', () {
    test('what mpv reports refuses an MP4 the receiver could not decode', () {
      final result = check(
        filename: 'clip.mp4',
        stats: const PlaybackStats(videoCodec: 'av1 (Main)'),
      );
      expect(refusalOf(result), CastRefusal.videoCodec);
      expect((result as CastRefused).explanation, contains('AV1'));
    });

    test('mpv reporting H.264 and AAC lets it through', () {
      final result = check(
        filename: 'clip.mp4',
        stats: const PlaybackStats(
          videoCodec: 'h264 (High)',
          audioCodec: 'aac',
        ),
      );
      expect(result, isA<CastReady>());
    });

    test('mpv reporting DTS audio refuses it', () {
      final result = check(
        filename: 'clip.mp4',
        stats: const PlaybackStats(videoCodec: 'h264', audioCodec: 'dts'),
      );
      expect(refusalOf(result), CastRefusal.audioCodec);
      expect((result as CastRefused).explanation, contains('DTS'));
    });

    test('what the release claims counts when mpv has not spoken', () {
      final result = check(
        facts: factsFor('Sintel 1080p AV1', filename: 'Sintel.1080p.AV1.mp4'),
        filename: 'Sintel.1080p.AV1.mp4',
      );
      expect(refusalOf(result), CastRefusal.videoCodec);
    });

    test('an AC3 track named in the filename is refused', () {
      final result = check(filename: 'Sintel.1080p.WEB-DL.AC3.x264.mp4');
      expect(refusalOf(result), CastRefusal.audioCodec);
      expect((result as CastRefused).explanation, contains('Dolby Digital'));
    });

    test('mpv overrules a release name that claims otherwise', () {
      // The name says DTS, the file being decoded says AAC: the decoder is
      // reading the actual bytes and the release name is marketing.
      final result = check(
        filename: 'Sintel.1080p.DTS.x264.mp4',
        facts: factsFor('Sintel 1080p DTS x264'),
        stats: const PlaybackStats(videoCodec: 'h264', audioCodec: 'aac'),
      );
      expect(result, isA<CastReady>());
    });

    test('HEVC is castable, being one of the two the receiver decodes', () {
      final result = check(
        filename: 'Sintel.2160p.HEVC.mp4',
        stats: const PlaybackStats(videoCodec: 'hevc (Main 10)'),
      );
      expect(result, isA<CastReady>());
    });
  });
}
