import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/cast/cast_compatibility.dart';
import 'package:xtremio/features/cast/direct_cast.dart';

/// A debrid link of the kind this exists for: its key in the path, an MP4
/// the receiver plays as it is.
const link = 'https://dl.debrid.example/d/KEY123/Night.of.the.Living.Dead.mp4';

const ready = CastReady(contentType: 'video/mp4');

StreamInfo urlStream({String url = link, Map<String, dynamic>? hints}) =>
    StreamInfo({'url': url, 'name': 'Debrid', 'behaviorHints': ?hints});

Uri? judge({
  String opened = link,
  StreamInfo? stream,
  MediaResolution? resolution = const MediaResolution(),
  CastCompatibility compatibility = ready,
}) => directCastUrl(
  opened: Uri.parse(opened),
  stream: stream ?? urlStream(url: opened),
  resolution: resolution,
  compatibility: compatibility,
);

void main() {
  test('a plain link the receiver plays as it is is handed over as it is', () {
    expect(judge(), Uri.parse(link));
    expect(
      judge(opened: 'http://cdn.example.com/a/clip.mp4'),
      Uri.parse('http://cdn.example.com/a/clip.mp4'),
    );
    // A public address is somebody's host on the internet like any other.
    expect(
      judge(opened: 'http://203.0.113.9/clip.mp4'),
      Uri.parse('http://203.0.113.9/clip.mp4'),
    );
  });

  group('is relayed instead', () {
    test('a stream the receiver cannot play as it is', () {
      expect(judge(compatibility: const CastRendition()), isNull);
    });

    test('a torrent, an archive or any stream that is not a link', () {
      final torrent = StreamInfo({
        'infoHash': '11ea02584fa6351956f35671962ab46354d99060',
        'fileIdx': 0,
      });
      expect(judge(stream: torrent), isNull);
      final archive = StreamInfo({
        'rarUrls': [
          {'url': link},
        ],
      });
      expect(judge(stream: archive), isNull);
    });

    test('a link with request headers the receiver could not send', () {
      expect(
        judge(
          stream: urlStream(
            hints: {
              'proxyHeaders': {
                'request': {'Referer': 'https://addon.example/'},
              },
            },
          ),
        ),
        isNull,
      );
    });

    test('a link the addon says is not web ready', () {
      expect(judge(stream: urlStream(hints: {'notWebReady': true})), isNull);
      // Said false, it is no objection.
      expect(
        judge(stream: urlStream(hints: {'notWebReady': false})),
        Uri.parse(link),
      );
    });

    test('anything that is not http or https', () {
      expect(judge(opened: 'xtremio-drive:1AbC'), isNull);
      expect(judge(opened: 'file:///sdcard/Movies/clip.mp4'), isNull);
      expect(judge(opened: 'content://media/external/video/1'), isNull);
      expect(judge(opened: 'ftp://files.example.com/clip.mp4'), isNull);
    });

    test('a link carrying credentials', () {
      expect(judge(opened: 'https://user:pass@cdn.example.com/a.mp4'), isNull);
    });

    test('a route on this device: the embedded server, a kept download', () {
      expect(judge(opened: 'http://127.0.0.1:39661/abc/0/clip.mp4'), isNull);
      expect(judge(opened: 'http://localhost:39661/clip.mp4'), isNull);
      expect(judge(opened: 'http://[::1]:39661/clip.mp4'), isNull);
    });

    test('a private, link-local or local-only name', () {
      for (final host in [
        '0.0.0.0',
        '10.0.0.5',
        '172.16.4.1',
        '172.31.255.1',
        '192.168.1.20',
        '169.254.10.1',
        '100.64.0.1',
        '[fd00::1]',
        '[fe80::1]',
        '[::ffff:192.168.1.20]',
        'nas.local',
        'nas.lan',
        'nas.home.arpa',
        'app.localhost',
        'nas',
      ]) {
        expect(judge(opened: 'http://$host/clip.mp4'), isNull, reason: host);
      }
      // The edges of the ranges are somebody else's.
      expect(judge(opened: 'http://172.32.0.1/clip.mp4'), isNotNull);
      expect(judge(opened: 'http://100.128.0.1/clip.mp4'), isNotNull);
      expect(judge(opened: 'http://172.15.0.1/clip.mp4'), isNotNull);
      expect(judge(opened: 'http://100.63.0.1/clip.mp4'), isNotNull);
    });

    test('a link the server has not resolved, or refused', () {
      expect(judge(resolution: null), isNull);
      expect(
        judge(
          resolution: const MediaResolution.refused(
            MediaRefusal('notFound', 'Gone.'),
          ),
        ),
        isNull,
      );
    });

    test('a link to an archive, played as the film inside it', () {
      expect(
        judge(
          resolution: const MediaResolution(
            name: 'Film.mp4',
            memberName: 'Feature/Film.mp4',
          ),
        ),
        isNull,
      );
    });

    test('a link the server reads only forward', () {
      expect(
        judge(resolution: const MediaResolution(inProcess: false)),
        isNull,
      );
    });
  });
}
