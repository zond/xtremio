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

  group('MetaItem', () {
    final movie = MetaDetailsState.fromJson(loadMetaDetailsFixture()).meta!;
    final series = MetaDetailsState.fromJson(loadSeriesMetaDetailsFixture())
        .meta!;

    test('reads genres, the IMDb rating and the default video from links', () {
      expect(movie.genres.map((g) => g.name), ['Horror', 'Thriller']);
      expect(movie.imdbRating, '7.8');
      expect(movie.defaultVideoId, 'tt0063350');
      expect(series.imdbRating, '9.5');
      expect(series.defaultVideoId, isNull);
      expect(const MetaItem({'id': 'x', 'type': 'movie'}).genres, isEmpty);
      expect(const MetaItem({'id': 'x', 'type': 'movie'}).imdbRating, isNull);
    });

    test('genre links resolve to Discover catalog requests', () {
      final request = movie.genres.first.discoverRequest!;
      expect(request.base, kCinemetaManifestUrl);
      expect(request.path.resource, 'catalog');
      expect(request.path.type, 'movie');
      expect(request.path.id, 'top');
      expect(request.path.extra, [const ExtraValue('genre', 'Horror')]);
      // Search and web links are not catalogs.
      expect(
        MetaLink({
          'category': 'Cast',
          'name': 'x',
          'url': 'stremio:///search?search=x',
        }).discoverRequest,
        isNull,
      );
      expect(
        MetaLink({
          'category': 'imdb',
          'name': '7.8',
          'url': 'https://imdb.com/title/tt0063350',
        }).discoverRequest,
        isNull,
      );
    });

    test('lists seasons ascending with specials last', () {
      expect(series.seasons, [1, 2, 3, 4, 5, 0]);
      expect(movie.seasons, isEmpty);
      expect(series.videosOfSeason(1), hasLength(7));
      expect(series.videosOfSeason(1).first.title, 'Pilot');
      expect(series.videosOfSeason(0), hasLength(5));
      expect(series.videosOfSeason(9), isEmpty);
    });

    test('videos know when they have aired', () {
      final pilot = series.videoById('tt0903747:1:1')!;
      expect(pilot.releasedAt, DateTime.utc(2008, 1, 21, 5));
      expect(pilot.isReleased(DateTime.utc(2010)), isTrue);
      expect(pilot.isReleased(DateTime.utc(2007)), isFalse);
      expect(
        const VideoInfo({'id': 'x', 'title': 'no date'})
            .isReleased(DateTime.utc(2000)),
        isTrue,
        reason: 'undated videos count as released, like MetaItem::next_video',
      );
    });
  });

  group('MetaDetailsState for a series', () {
    final guessing = MetaDetailsState.fromJson(loadSeriesMetaDetailsFixture());
    final episode = MetaDetailsState.fromJson(
      loadSeriesEpisodeMetaDetailsFixture(),
    );

    test('knows when the engine will not guess a stream path', () {
      expect(guessing.hasVideos, isTrue);
      expect(guessing.streamPath, isNull);
      expect(guessing.engineWillGuessStream, isFalse);
      expect(guessing.allStreamGroups, isEmpty);
      expect(guessing.isLoadingStreams, isFalse);
      final movie = MetaDetailsState.fromJson(loadMetaDetailsFixture());
      expect(movie.engineWillGuessStream, isTrue);
      expect(movie.hasVideos, isFalse);
    });

    test('resolves the initial episode by preference', () {
      expect(guessing.initialVideo()?.id, 'tt0903747:1:1');
      expect(
        guessing.initialVideo(preferred: 'tt0903747:3:2')?.id,
        'tt0903747:3:2',
      );
      expect(
        guessing.initialVideo(preferred: 'not-a-video')?.id,
        'tt0903747:1:1',
        reason: 'unknown ids are ignored',
      );
      expect(episode.initialVideo()?.id, 'tt0903747:1:1', reason: 'selected');

      final json = loadSeriesMetaDetailsFixture();
      json['libraryItem']['state']['video_id'] = 'tt0903747:2:4';
      final resumed = MetaDetailsState.fromJson(json);
      expect(resumed.libraryVideoId, 'tt0903747:2:4');
      expect(resumed.initialVideo()?.id, 'tt0903747:2:4');
      expect(
        resumed.initialVideo(preferred: 'tt0903747:5:1')?.id,
        'tt0903747:5:1',
        reason: 'the caller wins over the library',
      );
    });

    test('reads the selected episode, watched ids and addon errors', () {
      expect(episode.streamPath?.id, 'tt0903747:1:1');
      expect(episode.selectedVideo?.title, 'Pilot');
      expect(episode.watchedVideoIds, ['tt0903747:1:1']);
      expect(episode.isWatched(episode.selectedVideo!), isTrue);
      expect(
        episode.isWatched(episode.meta!.videoById('tt0903747:1:2')!),
        isFalse,
      );
      expect(episode.metaStreamGroups, isEmpty);
      expect(episode.streamGroups, hasLength(2));
      expect(episode.streamGroups[0].error?.isEmptyContent, isTrue);
      expect(episode.streamGroups[1].error?.kind, 'Env');
      expect(episode.lastUsedStream, isNull, reason: 'Ready(None)');
      expect(episode.playableStreams, isEmpty);
    });

    test('exposes meta streams and the last used stream', () {
      final json = loadSeriesEpisodeMetaDetailsFixture();
      final stream = {'ytId': 'abc', 'name': 'Trailer'};
      final request = {
        'base': kCinemetaManifestUrl,
        'path': {
          'resource': 'stream',
          'type': 'series',
          'id': 'tt0903747:1:1',
          'extra': <Object>[],
        },
      };
      json['metaStreams'] = [
        {
          'request': request,
          'content': {
            'type': 'Ready',
            'content': [stream],
          },
        },
      ];
      json['lastUsedStream'] = {
        'request': request,
        'content': {'type': 'Ready', 'content': stream},
      };
      final state = MetaDetailsState.fromJson(json);
      expect(state.metaStreamGroups.single.isFromMeta, isTrue);
      expect(state.allStreamGroups.first.isFromMeta, isTrue);
      expect(state.allStreamGroups, hasLength(3));
      final (group, last) = state.lastUsedStream!;
      expect(last.ytId, 'abc');
      expect(group.request.base, kCinemetaManifestUrl);
      expect(group.request.path.id, 'tt0903747:1:1');
      expect(state.playableStreams.single.$2.isSameSource(last), isTrue);
    });
  });

  group('StreamHints', () {
    test('parses resolution, size and seeders out of free text', () {
      final hints = StreamHints.parse('Torrentio\n4k HDR\n👤 120 💾 14.2 GB');
      expect(hints.resolution, '4K');
      expect(hints.size, '14.2 GB');
      expect(hints.seeders, 120);
      expect(hints.chips, ['4K', '14.2 GB', '120 seeders']);
      expect(StreamHints.parse('720P WEB 700MB').chips, ['720p', '700 MB']);
      expect(StreamHints.parse('plain').chips, isEmpty);
      expect(StreamHints.parse('x1080px').resolution, isNull);
    });

    test('reads a stream and strips the parsed markers from text', () {
      final movie = MetaDetailsState.fromJson(loadMetaDetailsFixture());
      final (_, torrent) = movie.playableStreams.single;
      final hints = StreamHints.of(torrent);
      expect(hints.chips, ['1080p', '1.51 GB']);
      expect(hints.strip(torrent.description), isNull);
      expect(hints.filename, isNull);

      final hinted = StreamHints.of(
        StreamInfo({
          'infoHash': 'a',
          'name': 'Torrentio\n1080p',
          'description': 'Show.S01E01.1080p.mkv\n👤 42 💾 1.51 GB ⚙️ RARBG',
          'behaviorHints': {'filename': 'Show.S01E01.1080p.mkv'},
        }),
      );
      expect(hinted.filename, 'Show.S01E01.1080p.mkv');
      expect(
        hinted.strip('Show.S01E01.1080p.mkv\n👤 42 💾 1.51 GB ⚙️ RARBG'),
        'Show.S01E01.1080p.mkv\nRARBG',
      );
      expect(hinted.strip(null), isNull);
    });

    test('same-source streams match on their discriminating keys', () {
      final torrent = StreamInfo({'infoHash': 'a', 'fileIdx': 1});
      expect(
        torrent.isSameSource(StreamInfo({'infoHash': 'a', 'fileIdx': 1})),
        isTrue,
      );
      expect(
        torrent.isSameSource(StreamInfo({'infoHash': 'a', 'fileIdx': 2})),
        isFalse,
      );
      expect(torrent.isSameSource(StreamInfo({'url': 'https://x'})), isFalse);
      expect(
        StreamInfo({'url': 'https://x'})
            .isSameSource(StreamInfo({'url': 'https://x'})),
        isTrue,
      );
      expect(StreamInfo({}).isSameSource(StreamInfo({})), isFalse);
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

  group('CatalogsWithExtraState', () {
    test('aligns labels with rows and tells planned from loaded rows', () {
      final state = CatalogsWithExtraState.fromJson(loadBoardFixture());
      expect(state.isLoaded, isTrue);
      expect(state.selectedType, isNull);
      expect(state.selectedExtra, isEmpty);
      expect(state.rows, hasLength(6));
      expect(state.isLoading, isFalse);

      final popular = state.rows.first;
      expect(popular.index, 0);
      expect(popular.title, 'Popular');
      expect(popular.subtitle, 'Cinemeta · movie');
      expect(popular.firstRequest.base, kCinemetaManifestUrl);
      expect(popular.firstRequest.path.id, 'top');
      expect(popular.isPlanned, isFalse);
      expect(popular.items, hasLength(50));
      expect(popular.posterShape, 'poster');
      expect(popular.error, isNull);

      // A catalog without a manifest name is labelled by its addon.
      final youtube = state.rows.firstWhere((r) => r.label?.type == 'channel');
      expect(youtube.title, 'YouTube');
      expect(youtube.subtitle, 'YouTube · channel');

      // LoadRange {0, 2} left everything past index 2 unrequested.
      for (final row in state.rows) {
        expect(row.isPlanned, row.index > 2, reason: 'row ${row.index}');
        expect(row.isEmpty, isFalse);
      }
      expect(state.visibleRows, hasLength(6));
    });

    test('drops EmptyContent rows from visibleRows, keeps failures', () {
      final state = CatalogsWithExtraState.fromJson(loadSearchFixture());
      expect(state.selectedExtra, const [
        ExtraValue('search', 'night of the living dead'),
      ]);
      expect(state.rows, hasLength(5));
      final failed = state.rows.where((r) => r.error != null).toList();
      expect(failed, hasLength(2));
      expect(failed.first.error?.kind, 'Env');
      expect(failed.first.isEmpty, isFalse);
      expect(state.rows.first.items.map((i) => i.id), contains('tt0063350'));

      final json = loadSearchFixture();
      final pages = json['catalogs'] as List<dynamic>;
      (pages[1] as List<dynamic>)[0]['content'] = {
        'type': 'Err',
        'content': {'type': 'EmptyContent'},
      };
      final withEmpty = CatalogsWithExtraState.fromJson(json);
      expect(withEmpty.rows[1].isEmpty, isTrue);
      expect(withEmpty.visibleRows.map((r) => r.index), [0, 2, 3, 4]);
    });

    test('an unloaded model has no rows and is not loading', () {
      final empty = CatalogsWithExtraState.fromJson({
        'selected': null,
        'catalogs': <Object>[],
        'catalogLabels': <Object>[],
      });
      expect(empty.isLoaded, isFalse);
      expect(empty.rows, isEmpty);
      expect(empty.isLoading, isFalse);
      expect(CatalogsWithExtraState.fromJson({}).rows, isEmpty);
    });
  });

  group('ContinueWatchingState', () {
    test('reads the recorded library item and its progress', () {
      final state = ContinueWatchingState.fromJson(
        loadContinueWatchingFixture(),
      );
      expect(state.isEmpty, isFalse);
      final item = state.items.single;
      expect(item.id, 'tt0063350');
      expect(item.type, 'movie');
      expect(item.name, 'Night of the Living Dead');
      expect(item.poster, startsWith('https://'));
      expect(item.posterShape, 'poster');
      expect(item.videoId, 'tt0063350');
      expect(item.timeOffset, 60000);
      expect(item.duration, 5760000);
      expect(item.progress, closeTo(60000 / 5760000, 1e-9));
      expect(item.notifications, 0);
      expect(item.seasonEpisodeLabel, '');
    });

    test('labels episodes and has no progress without a duration', () {
      final episode = ContinueWatchingItem({
        '_id': 'tt0903747',
        'type': 'series',
        'name': 'Breaking Bad',
        'state': {'video_id': 'tt0903747:2:3', 'timeOffset': 10, 'duration': 0},
        'notifications': 2,
      });
      expect(episode.seasonEpisodeLabel, 'S2E3');
      expect(episode.progress, isNull);
      expect(episode.notifications, 2);
      expect(
        ContinueWatchingItem({
          '_id': 'yt:abc',
          'type': 'channel',
          'state': {'video_id': 'yt:abc:video'},
        }).seasonEpisodeLabel,
        '',
      );
      expect(ContinueWatchingState.fromJson({}).isEmpty, isTrue);
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
