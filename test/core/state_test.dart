import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/dev/dev_streams.dart';

import '../support/fixtures.dart';

void main() {
  group('StreamInfo', () {
    test('classifies every StreamSource variant by its discriminating key', () {
      StreamKind kindOf(Map<String, dynamic> json) => StreamInfo(json).kind;
      expect(kindOf({'url': 'https://x/y.mp4'}), StreamKind.url);
      expect(kindOf({'url': 'magnet:?xt=urn:btih:abc'}), StreamKind.magnet);
      expect(kindOf({'infoHash': 'abc', 'fileIdx': 1}), StreamKind.torrent);
      expect(kindOf({'ytId': 'dQw4w9WgXcQ'}), StreamKind.youtube);
      expect(
        kindOf({'externalUrl': 'https://netflix.com'}),
        StreamKind.external,
      );
      expect(kindOf({'androidTvUrl': 'intent://x'}), StreamKind.external);
      expect(kindOf({'playerFrameUrl': 'https://x'}), StreamKind.playerFrame);
      expect(kindOf({'rarUrls': <Object>[]}), StreamKind.archive);
      expect(
        kindOf({'nzbUrl': 'https://x', 'servers': <Object>[]}),
        StreamKind.archive,
      );
      expect(kindOf({}), StreamKind.unknown);
    });

    test('only server-resolvable and direct streams are playable', () {
      expect(StreamInfo(DevStreams.bigBuckBunnyTorrent).isPlayable, isTrue);
      expect(StreamInfo(DevStreams.bigBuckBunnyHttp).isPlayable, isTrue);
      expect(StreamInfo({'externalUrl': 'https://x'}).isPlayable, isFalse);
      expect(StreamInfo({'url': 'magnet:?xt=x'}).isPlayable, isFalse);
    });

    test('title falls back through name, description/title, kind', () {
      expect(StreamInfo({'name': '1080p', 'title': 'x'}).title, '1080p');
      expect(StreamInfo({'title': 'legacy', 'url': 'u'}).description, 'legacy');
      expect(StreamInfo({'title': 'legacy', 'url': 'u'}).title, 'legacy');
      expect(StreamInfo({'infoHash': 'abc'}).title, 'Torrent');
    });
  });

  group('MetaDetailsState', () {
    final state = MetaDetailsState.fromJson(loadMetaDetailsFixture());

    test('reads the meta item recorded from Cinemeta', () {
      expect(state.metaPath?.id, 'tt0063350');
      expect(state.streamPath?.id, 'tt0063350', reason: 'guessed the movie');
      final meta = state.meta!;
      expect(meta.name, 'Night of the Living Dead');
      expect(meta.type, 'movie');
      expect(meta.releaseInfo, '1968');
      expect(meta.runtime, '96 min');
      expect(meta.poster, startsWith('https://'));
      expect(meta.videos, isEmpty);
      expect(state.metaRequest?.base, kCinemetaManifestUrl);
      expect(state.isLoadingMeta, isFalse);
      expect(state.metaError, isNull);
      expect(state.selectedVideo, isNull);
    });

    test('groups streams per addon and knows which are playable', () {
      expect(state.streamGroups, hasLength(3));
      expect(state.isLoadingStreams, isFalse);

      final watchhub = state.streamGroups[0];
      expect(watchhub.addonLabel, 'watchhub.strem.io');
      expect(watchhub.streams, isNotEmpty);
      expect(watchhub.streams.map((s) => s.kind).toSet(), {
        StreamKind.external,
      });

      final local = state.streamGroups.last;
      expect(local.error?.message, 'EmptyContent');
      expect(local.streams, isEmpty);

      final playable = state.playableStreams;
      expect(playable, hasLength(1));
      final (group, stream) = playable.single;
      expect(group.addonLabel, 'caching.stremio.net');
      expect(stream.kind, StreamKind.torrent);
      expect(stream.infoHash, '11ea02584fa6351956f35671962ab46354d99060');
      expect(stream.fileIdx, 0);
      expect(stream.name, '1080p');
    });

    test('an unloaded model is empty, not an error', () {
      final empty = MetaDetailsState.fromJson({
        'selected': null,
        'metaItems': <Object>[],
        'metaStreams': <Object>[],
        'streams': <Object>[],
      });
      expect(empty.meta, isNull);
      expect(empty.metaError, isNull);
      expect(empty.isLoadingMeta, isFalse);
      expect(empty.playableStreams, isEmpty);
    });
  });

  group('PlayerState', () {
    test('resolves a torrent to the embedded server URL', () {
      final state = PlayerState.fromJson(loadPlayerFixture());
      expect(state.isLoaded, isTrue);
      expect(state.selectedStream?.kind, StreamKind.torrent);
      expect(state.selectedVideoId, 'tt0063350');
      final url = state.streamingUrl!;
      expect(url.host, '127.0.0.1');
      expect(url.path, '/11ea02584fa6351956f35671962ab46354d99060/0');
      expect(state.unplayableReason, isNull);
      expect(state.title, 'Night of the Living Dead');
      expect(state.progress?.timeOffset, 0);
      expect(state.progress?.isResumable, isFalse);
      expect(state.nextVideo, isNull);
      final urls = state.stream!.contentOrNull!;
      expect(urls.magnetUrl?.scheme, 'magnet');
      expect(urls.downloadUrl?.queryParameters['download'], '1');
    });

    test('surfaces a conversion error and unplayable kinds', () {
      final failed = PlayerState.fromJson({
        'selected': {
          'stream': {'infoHash': 'abc'},
        },
        'stream': {
          'type': 'Err',
          'content': {
            'code': 8,
            'message':
                "Can't play Torrents because streaming server is "
                'not running',
          },
        },
      });
      expect(failed.streamingUrl, isNull);
      expect(failed.unplayableReason, contains('streaming server'));

      final external = PlayerState.fromJson({
        'selected': {
          'stream': {'externalUrl': 'https://netflix.com/x'},
        },
        'stream': {
          'type': 'Ready',
          'content': [
            {'streaming_url': null, 'stream': <String, dynamic>{}},
            <String, dynamic>{},
          ],
        },
      });
      expect(external.streamingUrl, isNull);
      expect(external.unplayableReason, contains('external'));

      expect(PlayerState.fromJson({'selected': null}).isLoaded, isFalse);
    });

    test('titles series by episode and resumes from library progress', () {
      final state = PlayerState.fromJson({
        'selected': {
          'stream': {'url': 'https://x/e3.mp4'},
          'streamRequest': {
            'base': 'https://addon/manifest.json',
            'path': {
              'resource': 'stream',
              'type': 'series',
              'id': 'tt1:1:3',
              'extra': <Object>[],
            },
          },
        },
        'metaItem': {
          'request': {
            'base': kCinemetaManifestUrl,
            'path': {
              'resource': 'meta',
              'type': 'series',
              'id': 'tt1',
              'extra': <Object>[],
            },
          },
          'content': {
            'type': 'Ready',
            'content': {
              'id': 'tt1',
              'type': 'series',
              'name': 'Show',
              'videos': [
                {'id': 'tt1:1:3', 'title': 'Third', 'season': 1, 'episode': 3},
              ],
            },
          },
        },
        'libraryItem': {
          'state': {'timeOffset': 120000, 'duration': 3600000},
        },
        'stream': {
          'type': 'Ready',
          'content': [
            {'streaming_url': 'https://x/e3.mp4'},
            <String, dynamic>{},
          ],
        },
      });
      expect(state.title, 'Show · S1E3 Third');
      expect(state.progress?.isResumable, isTrue);
      expect(state.streamingUrl, Uri.parse('https://x/e3.mp4'));
    });
  });

  group('ResourceLoadable', () {
    test('distinguishes not-yet-requested from loading, ready and error', () {
      final request = {
        'base': kCinemetaManifestUrl,
        'path': {'resource': 'meta', 'type': 'movie', 'id': 'x', 'extra': []},
      };
      final pending = ResourceLoadable.fromJson({
        'request': request,
        'content': null,
      }, (c) => c);
      expect(pending.content, isNull);
      expect(pending.isLoading, isTrue);
      final ready = ResourceLoadable.fromJson({
        'request': request,
        'content': {'type': 'Ready', 'content': 42},
      }, (c) => c);
      expect(ready.isLoading, isFalse);
      expect(ready.contentOrNull, 42);
      final failed = ResourceLoadable.fromJson({
        'request': request,
        'content': {
          'type': 'Err',
          'content': {
            'type': 'Env',
            'content': {'code': 1, 'message': 'boom'},
          },
        },
      }, (c) => c);
      expect(failed.error?.message, 'boom');
    });
  });
}
