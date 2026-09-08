import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/downloads/offline_play.dart';

/// A finished download of [stream]. `path` is the *name* the torrent
/// backend gives the file: no whole file is ever written there, and it is
/// where the filename hint comes from.
DownloadView viewOf(Map<String, dynamic> stream, {String? path}) =>
    DownloadView({
      'metaId': 'tt0903747',
      'videoId': 'tt0903747:1:1',
      'state': 'complete',
      'stream': stream,
      'path': ?path,
    });

/// Where a kept download plays from: the embedded server's media route for
/// its own torrent and file, off the pieces already on the device.
const url = 'http://127.0.0.1:11470/bb/1';

void main() {
  group('offlineStream', () {
    test('keeps the binge group, so the next episode still resolves', () {
      // `Stream::is_binge_match` answers false unless *both* streams carry a
      // binge group, so a synthesized stream without one makes the player's
      // `nextStream` null for good: a downloaded episode would stop
      // auto-advancing that streaming the same episode advances through.
      final json = offlineStream(
        viewOf(const {
          'infoHash': 'bb',
          'fileIdx': 1,
          'behaviorHints': {'bingeGroup': 'pdm-1080p', 'filename': 'x.mkv'},
        }, path: '/data/rqbit-downloads/Show S01/pilot.mkv'),
        url,
      );

      expect(
        json['behaviorHints'],
        {'filename': 'pilot.mkv', 'bingeGroup': 'pdm-1080p'},
        reason:
            'the name the torrent gives it, and the group the core '
            'binges by',
      );
    });

    /// The URL is a media route now: its last segment is a file index and
    /// names nothing. A build that still read the filename off it would
    /// hand the player "1" as the file it is playing, which is what the
    /// video parameters and every subtitle match are taken from.
    test('the filename comes from the entry, not from the URL', () {
      final json = offlineStream(
        viewOf(const {
          'infoHash': 'bb',
          'fileIdx': 1,
        }, path: r'C:\Torrents\Show S01\pilot.mkv'),
        url,
      );

      expect(json['behaviorHints'], {'filename': 'pilot.mkv'});
    });

    /// Nothing named it: the addon's own hint stands, and no segment of the
    /// URL stands in for one.
    test('an entry with no path falls back to the stream hint', () {
      final json = offlineStream(
        viewOf(const {
          'infoHash': 'bb',
          'behaviorHints': {'filename': 'from-the-addon.mkv'},
        }),
        url,
      );

      expect(json['behaviorHints'], {'filename': 'from-the-addon.mkv'});
    });

    test('keeps the description the source label falls back to', () {
      // `name ?? description` is what the player and the stream picker show;
      // an addon that named only the legacy `title` still gets a label.
      final json = offlineStream(
        viewOf(const {'infoHash': 'bb', 'title': '1080p BluRay'}),
        url,
      );

      expect(json['name'], isNull);
      expect(json['description'], '1080p BluRay');
    });

    test('has no behaviorHints when there is nothing to hint', () {
      final json = offlineStream(viewOf(const {'infoHash': 'bb'}), url);

      expect(json.containsKey('behaviorHints'), isFalse);
      expect(json, {'url': url});
    });
  });
}
