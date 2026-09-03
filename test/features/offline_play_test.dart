import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/downloads/offline_play.dart';

/// A finished download of [stream].
DownloadView viewOf(Map<String, dynamic> stream) => DownloadView({
  'metaId': 'tt0903747',
  'videoId': 'tt0903747:1:1',
  'state': 'complete',
  'stream': stream,
});

const url = 'file:///downloads/abc/pilot.mkv';

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
        }),
        url,
      );

      expect(json['behaviorHints'], {
        'filename': 'pilot.mkv',
        'bingeGroup': 'pdm-1080p',
      }, reason: 'the file on disk, and the group the core binges by');
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
      final json = offlineStream(viewOf(const {'infoHash': 'bb'}), 'file:///');

      expect(json.containsKey('behaviorHints'), isFalse);
      expect(json, {'url': 'file:///'});
    });
  });
}
