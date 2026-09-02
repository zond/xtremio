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

  group('PlayerState subtitles and next episode', () {
    const spa = 'https://subs.example/spa.srt';
    const eng = 'https://subs.example/eng.srt';
    Map<String, dynamic> response(String base, Map<String, dynamic> content) =>
        {
          'request': {
            'base': base,
            'path': {
              'resource': 'subtitles',
              'type': 'movie',
              'id': 'tt1',
              'extra': <Object>[],
            },
          },
          'content': content,
        };

    test("unions addon files with the stream's own, deduplicated by URL", () {
      final state = PlayerState.fromJson({
        'selected': {
          'stream': {
            'url': 'https://x/e1.mkv',
            'behaviorHints': {'filename': 'e1.mkv'},
            'subtitles': [
              {'id': 's', 'lang': 'spa', 'url': spa},
            ],
          },
          'streamRequest': {
            'base': 'https://a/manifest.json',
            'path': {'resource': 'stream', 'type': 'movie', 'id': 'tt1'},
          },
          'metaRequest': {
            'base': 'https://m/manifest.json',
            'path': {'resource': 'meta', 'type': 'movie', 'id': 'tt1'},
          },
          'subtitlesPath': {
            'resource': 'subtitles',
            'type': 'movie',
            'id': 'tt1',
          },
        },
        'stream': {
          'type': 'Ready',
          'content': [
            {'streaming_url': 'https://x/e1.mkv'},
            {
              'url': 'https://x/e1.mkv',
              'behaviorHints': {'filename': 'converted.mkv'},
              'subtitles': [
                {'id': 'c', 'lang': 'eng', 'url': eng},
              ],
            },
          ],
        },
        'subtitles': [
          response('https://slow/manifest.json', {'type': 'Loading'}),
          response('https://os/manifest.json', {
            'type': 'Ready',
            'content': [
              {'id': '1', 'lang': 'eng', 'url': eng, 'label': 'English (SDH)'},
              {'id': '2', 'lang': 'spa', 'url': spa},
            ],
          }),
          response('https://broken/manifest.json', {
            'type': 'Err',
            'content': {'type': 'EmptyContent'},
          }),
        ],
        'subtitlePreference': {
          'enabled': true,
          'source': 'external',
          'language': 'eng',
        },
        'nextVideo': {
          'id': 'tt1:1:2',
          'title': 'Two',
          'season': 1,
          'episode': 2,
        },
        'nextStream': {'url': 'https://x/e2.mkv'},
      });
      expect(state.subtitles, hasLength(3));
      expect(state.subtitlesLoading, isTrue);
      final external = state.externalSubtitles;
      expect(external.map((s) => s.url.toString()), [eng, spa]);
      expect(external.first.label, 'English (SDH)');
      expect(external.last.lang, 'spa');
      expect(external.last.id, '2');
      expect(state.subtitlePreference?.enabled, isTrue);
      expect(state.subtitlePreference?.source, 'external');
      expect(state.subtitlePreference?.language, 'eng');
      expect(state.convertedStream?.filename, 'converted.mkv');
      expect(state.nextVideo?.id, 'tt1:1:2');
      expect(state.nextStream?.url, 'https://x/e2.mkv');
      expect(state.streamRequest?.base, 'https://a/manifest.json');
      expect(state.metaRequest?.path.resource, 'meta');
      expect(state.subtitlesPath?.copyWith(id: 'tt1:1:2').id, 'tt1:1:2');
    });

    test('the recorded fixture has no subtitles, preference or next video', () {
      final state = PlayerState.fromJson(loadPlayerFixture());
      expect(state.subtitles, isEmpty);
      expect(state.subtitlesLoading, isFalse);
      expect(state.externalSubtitles, isEmpty);
      expect(state.subtitlePreference, isNull);
      expect(state.nextStream, isNull);
      expect(state.convertedStream?.infoHash, state.selectedStream?.infoHash);
      expect(state.subtitlesPath, isNull);
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

  group('MetaDetailsState.libraryItem', () {
    test('the recorded played-only title is a removed temp item', () {
      final state = MetaDetailsState.fromJson(loadMetaDetailsFixture());
      final item = state.libraryItem;
      expect(item, isNotNull);
      expect(item!.id, 'tt0063350');
      expect(item.removed, isTrue);
      expect(item.temp, isTrue);
      expect(state.isInLibrary, isFalse);
      expect(state.libraryVideoId, item.videoId);
    });

    test('is in the library exactly when removed is false', () {
      final json = loadSeriesMetaDetailsFixture();
      (json['libraryItem'] as Map<String, dynamic>)['removed'] = false;
      expect(MetaDetailsState.fromJson(json).isInLibrary, isTrue);
      json['libraryItem'] = null;
      final unloaded = MetaDetailsState.fromJson(json);
      expect(unloaded.libraryItem, isNull);
      expect(unloaded.isInLibrary, isFalse);
      expect(unloaded.libraryVideoId, isNull);
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
      final episode = LibraryItemView({
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
        LibraryItemView({
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

  group('ProfileState', () {
    test('reads an anonymous profile: official addons, default settings', () {
      final ctx = loadCtxLoggedOutFixture();
      expect(ctx.keys, containsAll(['profile', 'notifications', 'events']));
      expect(ctx['profile'], contains('addonsLocked'), reason: 'camelCase');
      final profile = ProfileState.fromCtx(ctx);
      expect(profile.isLoggedIn, isFalse);
      expect(profile.user, isNull);
      expect(profile.addonsLocked, isFalse);
      expect(profile.addons, hasLength(6));
      final cinemeta = profile.addons.first;
      expect(cinemeta.transportUrl, kCinemetaManifestUrl);
      expect(cinemeta.manifest.id, 'com.linvo.cinemeta');
      expect(cinemeta.manifest.name, 'Cinemeta');
      expect(cinemeta.isOfficial, isTrue);
      expect(cinemeta.isProtected, isTrue);
      expect(cinemeta.configureUrl, isNull);
      expect(cinemeta.manifest.addonCatalogs, isNotEmpty);
      expect(cinemeta.manifest.resourceNames, contains('catalog'));
      expect(profile.isAddonInstalled(kCinemetaManifestUrl), isTrue);
      expect(profile.isAddonInstalled('https://x/manifest.json'), isFalse);
      expect(
        profile.installedAddon(kCinemetaManifestUrl)?.manifest.name,
        'Cinemeta',
      );

      final settings = profile.settings;
      expect(settings.isEmpty, isFalse);
      expect(settings.streamingServerUrl, 'http://127.0.0.1:11470/');
      expect(settings.bingeWatching, isTrue);
      expect(settings.nextVideoNotificationDuration, 35000);
      expect(settings.seekTimeDuration, 10000);
      expect(settings.seekShortTimeDuration, 3000);
      expect(settings.pauseOnMinimize, isFalse);
      expect(settings.hardwareDecoding, isTrue);
      expect(settings.audioLanguage, 'eng');
      expect(settings.subtitlesLanguage, 'eng');
      expect(settings.subtitlesSize, 100);
      expect(settings.subtitlesTextColor, '#FFFFFFFF');
      expect(settings.subtitlesBackgroundColor, '#00000000');
      expect(settings.quitOnClose, isTrue);
      expect(settings.escExitFullscreen, isTrue);
      expect(settings.hideSpoilers, isFalse);
      expect(settings.interfaceLanguage, 'eng');
    });

    test('withValue keeps every other key for UpdateSettings', () {
      final settings = ProfileState.fromCtx(loadCtxLoggedOutFixture()).settings;
      final changed = settings.withValue(
        ProfileSettings.bingeWatchingKey,
        false,
      );
      expect(changed.length, settings.json.length);
      expect(changed['bingeWatching'], isFalse);
      expect(
        Map.of(changed)..remove('bingeWatching'),
        Map.of(settings.json)..remove('bingeWatching'),
      );
      expect(settings.json['bingeWatching'], isTrue, reason: 'a copy');
      expect(ProfileSettings(changed).bingeWatching, isFalse);
      expect(const ProfileSettings({}).isEmpty, isTrue);
      expect(const ProfileSettings({}).seekTimeDuration, 10000);
    });

    test(
      'reads the signed-in user (snake _id, premium_expire, gdpr_consent)',
      () {
        final ctx = loadCtxLoggedInFixture();
        final auth = ctx['profile']['auth'] as Map<String, dynamic>;
        expect(auth.keys, unorderedEquals(['key', 'user']));
        expect(auth['user'], contains('_id'));
        expect(auth['user'], contains('premium_expire'));
        expect(auth['user'], contains('gdpr_consent'));
        final profile = ProfileState.fromCtx(ctx);
        expect(profile.isLoggedIn, isTrue);
        final user = profile.user!;
        expect(user.id, 'fake_user_id');
        expect(user.email, 'user@example.com');
        expect(user.avatar, isNull);
        expect(user.fbId, isNull);
        expect(user.premiumExpire, isNull);
        expect(user.dateRegistered, DateTime.utc(2025, 6, 1, 8));
        expect(user.lastModified, DateTime.utc(2026, 1, 15, 10, 30));
        expect(user.gdprConsent.tos, isTrue);
        expect(user.gdprConsent.marketing, isFalse);
        expect(user.gdprConsent.from, 'xtremio');
        // Same addons as the anonymous profile: only `auth` differs.
        expect(
          profile.addons.length,
          ProfileState.fromCtx(loadCtxLoggedOutFixture()).addons.length,
        );
      },
    );

    test('tolerates a ctx that has not been pulled yet', () {
      final empty = ProfileState.fromCtx({});
      expect(empty.isLoggedIn, isFalse);
      expect(empty.addons, isEmpty);
      expect(empty.addonsLocked, isFalse);
      expect(empty.settings.isEmpty, isTrue);
      expect(empty.settings.streamingServerUrl, isNull);
    });
  });

  group('AddonDescriptor', () {
    test('derives the configure URL only for configurable addons', () {
      final configurable = AddonDescriptor({
        'manifest': {
          'id': 'x',
          'version': '1.2.3',
          'name': 'X',
          'behaviorHints': {'configurable': true},
        },
        'transportUrl': 'https://x.example/abc/manifest.json',
      });
      expect(configurable.configureUrl, 'https://x.example/abc/configure');
      expect(configurable.manifest.version, '1.2.3');
      expect(
        configurable.manifest.behaviorHints.configurationRequired,
        isFalse,
      );
      expect(configurable.isOfficial, isFalse);
      expect(configurable.isProtected, isFalse);
      final required = AddonDescriptor({
        'manifest': {
          'behaviorHints': {'configurationRequired': true},
        },
        'transportUrl': 'stremio://y.example/manifest.json',
      });
      expect(required.configureUrl, 'stremio://y.example/configure');
      expect(
        const AddonDescriptor({
          'manifest': <String, dynamic>{},
          'transportUrl': 'https://z/manifest.json',
        }).configureUrl,
        isNull,
      );
      expect(configurable.isSameAddon(required), isFalse);
      expect(
        configurable.isSameAddon(
          const AddonDescriptor({
            'transportUrl': 'https://x.example/abc/manifest.json',
          }),
        ),
        isTrue,
      );
    });

    test('reads resources in the short and the long form', () {
      final manifest = AddonManifest({
        'resources': [
          'catalog',
          {
            'name': 'stream',
            'types': ['movie'],
          },
          {'types': <Object>[]},
        ],
        'types': ['movie', 'series'],
        'catalogs': [
          {'id': 'top', 'type': 'movie', 'name': 'Top'},
          {'id': 'x', 'type': 'series'},
        ],
      });
      expect(manifest.resourceNames, ['catalog', 'stream']);
      expect(manifest.types, ['movie', 'series']);
      expect(manifest.catalogs.map((c) => c.name), ['Top', null]);
      expect(manifest.catalogs.first.id, 'top');
      expect(manifest.addonCatalogs, isEmpty);
      expect(manifest.name, '');
    });
  });

  group('LibraryState', () {
    final json = loadLibraryFixture();
    final state = LibraryState.fromJson(json);

    test(
      'reads the recorded library: selection, filters, next_page (snake)',
      () {
        final selectable = json['selectable'] as Map<String, dynamic>;
        expect(
          selectable.keys,
          unorderedEquals(['types', 'sorts', 'next_page']),
        );
        expect(selectable, isNot(contains('nextPage')));
        expect(state.isLoaded, isTrue);
        expect(state.selected, const LibraryRequest());
        expect(state.selected?.toJson(), {
          'type': null,
          'sort': 'lastwatched',
          'page': 1,
        });
        expect(state.selectable.types.map((t) => t.type), [
          null,
          'movie',
          'series',
        ]);
        expect(state.selectable.selectedType?.type, isNull);
        expect(state.selectable.types[1].selected, isFalse);
        expect(
          state.selectable.types[1].request,
          const LibraryRequest(type: 'movie'),
        );
        expect(state.selectable.sorts.map((s) => s.sort), [
          LibrarySort.lastWatched,
          LibrarySort.name,
          LibrarySort.nameReverse,
          LibrarySort.timesWatched,
          LibrarySort.watched,
          LibrarySort.notWatched,
        ]);
        expect(state.selectable.selectedSort?.sort, LibrarySort.lastWatched);
        expect(
          state.selectable.sorts[1].request,
          const LibraryRequest(sort: LibrarySort.name),
        );
        expect(state.hasNextPage, isFalse);
        expect(state.nextPage, isNull);
      },
    );

    test('items are LibraryItems, newest first, without progress', () {
      expect(state.isEmpty, isFalse);
      expect(state.items.map((i) => i.id), ['tt26545992', 'tt11561116']);
      final series = state.items.first;
      expect(series.type, 'series');
      expect(series.name, 'Lanterns');
      expect(series.isInLibrary, isTrue);
      expect(series.removed, isFalse);
      expect(series.temp, isFalse);
      expect(series.videoId, isNull);
      expect(series.progress, isNull);
      expect(series.isWatched, isFalse);
      expect(series.timesWatched, 0);
      expect(series.isInContinueWatching, isFalse);
      expect(series.notificationsDisabled, isFalse);
      expect(series.notifications, 0, reason: 'only the preview carries it');
      expect(series.lastWatched, isNotNull, reason: 'added = watched now');
      expect(series.modifiedAt, isNotNull);
      expect(series.posterShape, 'poster');
      expect(state.items.last.name, 'The Whisper Man');
      expect(state.items.last.type, 'movie');
    });

    test('a next page carries its request and an unloaded model is empty', () {
      json['selectable']['next_page'] = {
        'request': {'type': null, 'sort': 'lastwatched', 'page': 2},
      };
      final paged = LibraryState.fromJson(json);
      expect(paged.hasNextPage, isTrue);
      expect(paged.nextPage, const LibraryRequest(page: 2));
      expect(paged.nextPage?.page, 2);

      final empty = LibraryState.fromJson({
        'selected': null,
        'selectable': {
          'types': <Object>[],
          'sorts': <Object>[],
          'next_page': null,
        },
        'catalog': <Object>[],
      });
      expect(empty.isLoaded, isFalse);
      expect(empty.isEmpty, isTrue);
      expect(empty.selectable.selectedSort, isNull);
      expect(LibraryState.fromJson({}).isLoaded, isFalse);
    });

    test('LibraryRequest defaults and round-trips the engine JSON', () {
      expect(
        LibraryRequest.fromJson({'type': 'movie'}),
        const LibraryRequest(type: 'movie'),
      );
      expect(
        LibraryRequest.fromJson({'type': null, 'sort': 'name', 'page': 3})
            .toJson(),
        {'type': null, 'sort': 'name', 'page': 3},
      );
      expect(
        const LibraryRequest().hashCode,
        const LibraryRequest(page: 1).hashCode,
      );
      expect(const LibraryRequest(), isNot(const LibraryRequest(page: 2)));
    });
  });

  group('LibraryItemView', () {
    test('derives continue-watching membership and the watched flag', () {
      final played = LibraryItemView({
        '_id': 'tt1',
        'type': 'movie',
        'removed': true,
        'temp': true,
        'state': {'timeOffset': 5000, 'duration': 10000, 'timesWatched': 1},
      });
      expect(played.isInLibrary, isFalse);
      expect(played.isInContinueWatching, isTrue, reason: 'temp with offset');
      expect(played.isWatched, isTrue);
      expect(played.progress, 0.5);
      final other = LibraryItemView({
        '_id': 'x',
        'type': 'other',
        'removed': false,
        'temp': false,
        'state': {'timeOffset': 5000, 'duration': 10000},
      });
      expect(other.isInContinueWatching, isFalse);
      expect(other.isInLibrary, isTrue);
      final muted = LibraryItemView({
        '_id': 'x',
        'type': 'series',
        'state': {'noNotif': true},
      });
      expect(muted.notificationsDisabled, isTrue);
      expect(muted.lastWatched, isNull);
      expect(muted.modifiedAt, isNull);
    });
  });

  group('InstalledAddonsState', () {
    test('reads the default profile with every type offered', () {
      final json = loadInstalledAddonsFixture();
      expect(json['selectable'], contains('types'));
      expect(json['selected']['request'], {'type': null});
      final state = InstalledAddonsState.fromJson(json);
      expect(state.isLoaded, isTrue);
      expect(state.selected, const InstalledAddonsRequest());
      expect(state.types.map((t) => t.type), [
        null,
        'movie',
        'series',
        'channel',
        'other',
      ]);
      expect(state.selectedType?.type, isNull);
      expect(state.types[1].selected, isFalse);
      expect(
        state.types[1].request,
        const InstalledAddonsRequest(type: 'movie'),
      );
      expect(state.types[1].request.toJson(), {'type': 'movie'});
      expect(state.addons, hasLength(6));
      expect(state.addons.first.manifest.name, 'Cinemeta');
      expect(state.addons.first.isProtected, isTrue);
      expect(state.addons.where((a) => !a.isProtected), isNotEmpty);
      expect(state.addons.every((a) => a.isOfficial), isTrue);
      expect(
        state.addons.map((a) => a.transportUrl),
        contains('https://opensubtitles-v3.strem.io/manifest.json'),
      );
    });

    test('an unloaded model has no selection', () {
      final empty = InstalledAddonsState.fromJson({
        'selected': null,
        'selectable': {'types': <Object>[]},
        'catalog': <Object>[],
      });
      expect(empty.isLoaded, isFalse);
      expect(empty.types, isEmpty);
      expect(empty.addons, isEmpty);
      expect(InstalledAddonsState.fromJson({}).selectedType, isNull);
    });
  });

  group('AddonDetailsState', () {
    test(
      'reads Cinemeta: camel selected.transportUrl, snake transport_url',
      () {
        final json = loadAddonDetailsFixture();
        expect(json['selected'], {'transportUrl': kCinemetaManifestUrl});
        final remote = json['remoteAddon'] as Map<String, dynamic>;
        expect(remote.keys, unorderedEquals(['transport_url', 'content']));
        expect(remote, isNot(contains('transportUrl')));
        final state = AddonDetailsState.fromJson(json);
        expect(state.isLoaded, isTrue);
        expect(state.transportUrl, kCinemetaManifestUrl);
        expect(state.isInstalled, isTrue);
        expect(state.localAddon?.manifest.name, 'Cinemeta');
        expect(state.remoteAddon?.transportUrl, kCinemetaManifestUrl);
        expect(state.isLoadingManifest, isFalse);
        expect(state.manifestError, isNull);
        final fetched = state.remoteDescriptor!;
        expect(fetched.manifest.id, 'com.linvo.cinemeta');
        expect(
          fetched.isProtected,
          isTrue,
          reason: 'flags from OFFICIAL_ADDONS',
        );
        expect(fetched.isOfficial, isTrue);
        expect(state.descriptor?.transportUrl, kCinemetaManifestUrl);
        expect(state.hasUpgrade, isFalse, reason: 'same version');
      },
    );

    test('no upgrade is offered where UpgradeAddon would refuse it', () {
      // Protected Cinemeta (both copies) with a bumped version: Other code 5.
      final protected = loadAddonDetailsFixture();
      protected['remoteAddon']['content']['content']['manifest']['version'] =
          '99.0.0';
      expect(AddonDetailsState.fromJson(protected).hasUpgrade, isFalse);

      // Only the installed copy protected.
      final localProtected = loadAddonDetailsFixture();
      localProtected['remoteAddon']['content']['content']['manifest']['version'] =
          '99.0.0';
      localProtected['remoteAddon']['content']['content']['flags']['protected'] =
          false;
      expect(AddonDetailsState.fromJson(localProtected).hasUpgrade, isFalse);

      // Only the fetched copy protected.
      final remoteProtected = loadAddonDetailsFixture();
      remoteProtected['remoteAddon']['content']['content']['manifest']['version'] =
          '99.0.0';
      remoteProtected['localAddon']['flags']['protected'] = false;
      expect(AddonDetailsState.fromJson(remoteProtected).hasUpgrade, isFalse);

      // A configurationRequired template: Other code 6.
      final template = loadAddonDetailsFixture();
      template['remoteAddon']['content']['content']['manifest']['version'] =
          '99.0.0';
      template['localAddon']['flags']['protected'] = false;
      template['remoteAddon']['content']['content']['flags']['protected'] =
          false;
      template['remoteAddon']['content']['content']['manifest']['behaviorHints']['configurationRequired'] =
          true;
      expect(AddonDetailsState.fromJson(template).hasUpgrade, isFalse);
    });

    test('a newer manifest offers an upgrade; a failed fetch is an error', () {
      // Cinemeta is protected on both sides; clear the flags to get a
      // descriptor the engine would actually upgrade.
      final json = loadAddonDetailsFixture();
      json['remoteAddon']['content']['content']['manifest']['version'] =
          '99.0.0';
      json['localAddon']['flags']['protected'] = false;
      json['remoteAddon']['content']['content']['flags']['protected'] = false;
      final upgradable = AddonDetailsState.fromJson(json);
      expect(upgradable.hasUpgrade, isTrue);
      expect(upgradable.descriptor?.manifest.version, '99.0.0');

      final failed = AddonDetailsState.fromJson({
        'selected': {'transportUrl': 'https://x/manifest.json'},
        'localAddon': null,
        'remoteAddon': {
          'transport_url': 'https://x/manifest.json',
          'content': {
            'type': 'Err',
            'content': {'code': 3, 'message': 'Failed to fetch'},
          },
        },
      });
      expect(failed.isInstalled, isFalse);
      expect(failed.isLoadingManifest, isFalse);
      expect(failed.manifestError?.message, 'Failed to fetch');
      expect(failed.remoteDescriptor, isNull);
      expect(failed.descriptor, isNull);
      expect(failed.hasUpgrade, isFalse);

      final loading = AddonDetailsState.fromJson({
        'selected': {'transportUrl': 'https://x/manifest.json'},
        'localAddon': null,
        'remoteAddon': {
          'transport_url': 'https://x/manifest.json',
          'content': {'type': 'Loading'},
        },
      });
      expect(loading.isLoadingManifest, isTrue);
      expect(loading.manifestError, isNull);

      final unloaded = AddonDetailsState.fromJson({
        'selected': null,
        'localAddon': null,
        'remoteAddon': null,
      });
      expect(unloaded.isLoaded, isFalse);
      expect(unloaded.isLoadingManifest, isFalse);
      expect(unloaded.descriptor, isNull);
    });
  });

  group('RemoteAddonsState', () {
    test('reads the community catalog with Discover\'s selectable shape', () {
      final json = loadRemoteAddonsFixture();
      expect(json['selectable'], contains('nextPage'), reason: 'camelCase');
      final state = RemoteAddonsState.fromJson(json);
      expect(state.isLoaded, isTrue);
      expect(state.selected?.base, kCinemetaManifestUrl);
      expect(state.selected?.path.resource, 'addon_catalog');
      expect(state.selected?.path.id, 'community');
      expect(state.selected?.path.type, 'all');
      expect(state.selectable.catalogs.map((c) => c.label), [
        'Official',
        'Community',
      ]);
      expect(state.selectable.selectedCatalog?.label, 'Community');
      expect(state.selectable.types.map((t) => t.label), contains('all'));
      expect(state.selectable.selectedType?.label, 'all');
      expect(
        state.selectable.types.first.request.path.resource,
        'addon_catalog',
      );
      expect(state.nextPage, isNull);
      expect(state.isLoading, isFalse);
      expect(state.lastError, isNull);
      expect(state.pages, hasLength(1));
      expect(state.addons, hasLength(20), reason: 'trimmed by the recorder');
      for (final addon in state.addons) {
        expect(addon.manifest.id, isNotEmpty);
        expect(addon.transportUrl, startsWith('http'));
        expect(addon.isOfficial, isFalse);
      }
      final configurable = state.addons.where(
        (a) => a.manifest.behaviorHints.configurable,
      );
      expect(configurable, isNotEmpty);
      for (final addon in configurable) {
        expect(addon.configureUrl, endsWith('/configure'));
        expect(addon.configureUrl, isNot(contains('manifest.json')));
      }
      expect(
        state.addons.any((a) => a.manifest.behaviorHints.configurationRequired),
        isTrue,
        reason: 'the fixture carries a configuration-required template',
      );
      // Installed is not part of the model: the profile decides.
      final profile = ProfileState.fromCtx(loadCtxLoggedOutFixture());
      expect(
        state.addons.where((a) => profile.isAddonInstalled(a.transportUrl)),
        isEmpty,
      );
    });

    test('an unloaded model has no pages', () {
      final empty = RemoteAddonsState.fromJson({
        'selected': null,
        'selectable': {
          'types': <Object>[],
          'catalogs': <Object>[],
          'extra': <Object>[],
          'nextPage': null,
        },
        'catalog': <Object>[],
      });
      expect(empty.isLoaded, isFalse);
      expect(empty.addons, isEmpty);
      expect(empty.isLoading, isFalse);
      expect(RemoteAddonsState.fromJson({}).selectable.isEmpty, isTrue);
    });
  });
}
