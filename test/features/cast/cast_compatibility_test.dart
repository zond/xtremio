import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/cast/cast_compatibility.dart';
import 'package:xtremio/features/details/stream_facts.dart';
import 'package:xtremio/features/dev/dev_streams.dart';
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
  bool containerPending = false,
}) => CastCompatibility.of(
  url: url ?? torrentUrl,
  facts: facts,
  filename: filename,
  stats: stats,
  containerPending: containerPending,
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

    test('a torrent whose server has not answered is a "not yet"', () {
      // The first seconds of a torrent: nothing names the file, but the
      // server is about to. That is a wait, not the verdict below it.
      final result = check(containerPending: true);
      expect(refusalOf(result), CastRefusal.containerPending);
      expect((result as CastRefused).explanation, contains('try again'));
      // Never the sentence that says conversion is what is missing: what is
      // missing here is an answer.
      expect(result.explanation, isNot(contains('conversion')));
    });

    test('a pending answer cannot rescue a container that is known', () {
      // The server has not spoken, but the addon has, and it named a
      // Matroska file. Waiting would not change it.
      final result = check(filename: 'Sintel.mkv', containerPending: true);
      expect(refusalOf(result), CastRefusal.container);
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

    test('HEVC is castable, being one the receiver decodes', () {
      final result = check(
        filename: 'Sintel.2160p.HEVC.mp4',
        stats: const PlaybackStats(videoCodec: 'hevc (Main 10)'),
      );
      expect(result, isA<CastReady>());
    });

    test('the video refusal names every codec the gate does take', () {
      // Read off the same table the check reads, so the sentence cannot go
      // on naming two codecs after the table grew to four.
      final result = check(
        filename: 'clip.mp4',
        stats: const PlaybackStats(videoCodec: 'av1'),
      ) as CastRefused;
      expect(result.explanation, contains('H.264, HEVC, VP8 or VP9 video'));
    });
  });

  group('what audio a receiver takes depends on the container', () {
    test('an MP4 with MP3 audio is castable', () {
      final result = check(
        filename: 'clip.mp4',
        stats: const PlaybackStats(videoCodec: 'h264', audioCodec: 'mp3'),
      );
      expect(result, isA<CastReady>());
    });

    test('an MP4 with Opus audio is refused', () {
      // Opus is a codec a Chromecast decodes, but not out of this box.
      final result = check(
        filename: 'clip.mp4',
        stats: const PlaybackStats(videoCodec: 'h264', audioCodec: 'opus'),
      );
      expect(refusalOf(result), CastRefusal.audioCodec);
      expect((result as CastRefused).explanation, contains('Opus'));
    });

    test('a WebM with Opus audio is castable', () {
      final result = check(
        filename: 'clip.webm',
        stats: const PlaybackStats(audioCodec: 'opus'),
      );
      expect(result, isA<CastReady>());
    });

    test('a WebM with Vorbis audio is castable', () {
      final result = check(
        filename: 'clip.webm',
        stats: const PlaybackStats(audioCodec: 'vorbis'),
      );
      expect(result, isA<CastReady>());
    });

    test('a WebM carrying the video WebM actually carries is castable', () {
      // The audio table above is unreachable for a real WebM unless the
      // video check lets VP8 and VP9 through: no WebM in the wild carries
      // H.264, so a gate that took only H.264 and HEVC refused every one
      // of them before their audio was ever looked at.
      for (final codec in ['vp9', 'vp8']) {
        final result = check(
          filename: 'clip.webm',
          stats: PlaybackStats(videoCodec: codec, audioCodec: 'opus'),
        );
        expect(result, isA<CastReady>(), reason: codec);
      }
    });

    test('a WebM with MP3 audio is refused', () {
      final result = check(
        filename: 'clip.webm',
        stats: const PlaybackStats(audioCodec: 'mp3'),
      );
      expect(refusalOf(result), CastRefusal.audioCodec);
    });

    test('the refusal names this container\'s set and no other', () {
      // A sentence that names the wrong reason is worse than a vague one,
      // so each container's refusal recites its own list.
      final mp4 = check(
        filename: 'clip.mp4',
        stats: const PlaybackStats(audioCodec: 'vorbis'),
      ) as CastRefused;
      expect(mp4.explanation, contains('AAC or MP3 audio in an MP4 file'));
      expect(mp4.explanation, isNot(contains('Opus')));

      final webm = check(
        filename: 'clip.webm',
        stats: const PlaybackStats(audioCodec: 'aac'),
      ) as CastRefused;
      expect(webm.explanation, contains('Opus or Vorbis audio in a WebM file'));
      expect(webm.explanation, isNot(contains('MP3')));
    });
  });

  group('the server outranks the addon about the file it opened', () {
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
      expect(check(filename: filename), isA<CastReady>());
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

  group('the developer torrent', () {
    test('is judged castable without waiting for the server', () {
      // The file inside dd8255ec… really is `Big Buck Bunny.mp4`, and it is
      // the largest, which is the one the server picks for a stream with no
      // fileIdx.
      final stream = StreamInfo(DevStreams.bigBuckBunnyTorrent);
      expect(stream.filename, 'Big Buck Bunny.mp4');
      expect(check(filename: stream.filename), isA<CastReady>());
    });

    test(
      'its MP3 track does not refuse it, which is the bug from the field',
      () {
        // The stream the owner tried to cast: an MP4 carrying H.264 video and
        // an MP3 audio track, which is what mpv reports once it is playing.
        final stream = StreamInfo(DevStreams.bigBuckBunnyTorrent);
        final result = check(
          filename: stream.filename,
          stats: const PlaybackStats(
            videoCodec: 'h264 (High)',
            audioCodec: 'mp3',
          ),
        );
        expect(result, isA<CastReady>());
      },
    );
  });
}
