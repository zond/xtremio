import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/fixtures.dart';

/// The keys `rust/src/downloads.rs` writes for one entry. Recorded, not
/// guessed: a rename on the Rust side has to fail here rather than turn a
/// row silently blank.
const _entryKeys = {
  'metaId',
  'videoId',
  'type',
  'name',
  'poster',
  'stream',
  'infoHash',
  'fileIdx',
  'announce',
  'path',
  'size',
  'downloaded',
  'state',
  'error',
  'createdAt',
  'completedAt',
  'lastPlayedAt',
  'meta',
  'streamRequest',
  'metaRequest',
};

void main() {
  final registry = DownloadsRegistry.fromJson(loadDownloadsFixture());

  group('the recorded registry', () {
    test('is version 1 and keyed by meta and video', () {
      expect(registry.version, 1);
      expect(registry.items.keys, [
        'tt0063350:tt0063350',
        'tt0903747:tt0903747:1:1',
        'tt0903747:tt0903747:1:2',
      ]);
      expect(registry.isNotEmpty, isTrue);
      expect(registry.length, 3);
    });

    test('an entry carries exactly the keys the Rust side writes', () {
      for (final download in registry.items.values) {
        expect(download.json.keys.toSet(), _entryKeys, reason: '$download');
      }
    });

    test('the finished movie reads back whole', () {
      final movie = registry['tt0063350:tt0063350']!;
      expect(movie.metaId, 'tt0063350');
      expect(movie.videoId, 'tt0063350');
      expect(movie.key, 'tt0063350:tt0063350');
      expect(movie.type, 'movie');
      expect(movie.name, 'Night of the Living Dead');
      expect(movie.poster, contains('tt0063350'));
      expect(movie.infoHash, 'bbdd47be75282ea36cddf7a48ba5a73e667e57bb');
      expect(movie.fileIdx, 1);
      expect(movie.announce, ['udp://tracker.invalid:1337/announce']);
      expect(movie.path, endsWith('night.of.the.living.dead.1968.1080p.mkv'));
      expect(movie.size, 32768);
      expect(movie.downloaded, 32768);
      expect(movie.state, DownloadState.complete);
      expect(movie.isComplete, isTrue);
      expect(movie.error, isNull);
      expect(movie.progress, 1);
      expect(movie.sizeLabel, '32.8 kB');
      expect(movie.createdAt, DateTime.utc(2026, 9, 3, 6, 52, 48, 292, 426));
      expect(movie.completedAt, movie.createdAt);
      expect(movie.lastPlayedAt, isNull);
    });

    test('the stream, meta and requests come back as they went in', () {
      final movie = registry['tt0063350:tt0063350']!;
      expect(movie.stream.kind, StreamKind.torrent);
      expect(movie.stream.infoHash, movie.infoHash);
      expect(movie.stream.fileIdx, movie.fileIdx);
      expect(movie.stream.filename, endsWith('.mkv'));
      expect(movie.meta!['name'], 'Night of the Living Dead');
      expect(
        movie.streamRequest!['base'],
        'https://public-domain-movies.now.sh/manifest.json',
      );
      expect(
        movie.metaRequest!['base'],
        'https://v3-cinemeta.strem.io/manifest.json',
      );
    });

    test('the half-finished episode is a fraction, not a state', () {
      final episode = registry['tt0903747:tt0903747:1:1']!;
      expect(episode.state, DownloadState.downloading);
      expect(episode.downloaded, 32768);
      expect(episode.size, 49152);
      expect(episode.progress, closeTo(0.667, 0.001));
      expect(episode.downloadedLabel, '32.8 kB');
      expect(episode.sizeLabel, '49.2 kB');
      expect(episode.completedAt, isNull);
    });

    test('the empty episode has a size but nothing of it', () {
      final episode = registry['tt0903747:tt0903747:1:2']!;
      expect(episode.downloaded, 0);
      expect(episode.progress, 0);
      expect(episode.isComplete, isFalse);
    });

    test('a series key is built, never split: the video id has colons', () {
      final episode = registry['tt0903747:tt0903747:1:2']!;
      expect(episode.metaId, 'tt0903747');
      expect(episode.videoId, 'tt0903747:1:2');
      expect(episode.key, 'tt0903747:tt0903747:1:2');
      expect(registry.forVideo('tt0903747', 'tt0903747:1:2'), same(episode));
      expect(registry.forVideo('tt0903747', 'tt0903747:1:9'), isNull);
    });

    test('newest first, and the same order every time', () {
      expect(registry.newestFirst.map((item) => item.key), [
        'tt0903747:tt0903747:1:2',
        'tt0903747:tt0903747:1:1',
        'tt0063350:tt0063350',
      ]);
    });
  });

  group('DownloadState', () {
    test('parses every wire name the Rust side writes', () {
      for (final state in DownloadState.values) {
        expect(DownloadState.parse(state.wireName), state);
      }
    });

    test('a state from a newer build reads as queued, not as an error', () {
      expect(DownloadState.parse('seeding'), DownloadState.queued);
      expect(DownloadState.parse(null), DownloadState.queued);
      expect(DownloadState.parse(7), DownloadState.queued);
    });
  });

  group('DownloadView', () {
    test('an entry with nothing in it answers instead of throwing', () {
      const empty = DownloadView({});
      expect(empty.key, ':');
      expect(empty.name, '');
      expect(empty.state, DownloadState.queued);
      expect(empty.fileIdx, 0);
      expect(empty.size, 0);
      expect(empty.announce, isEmpty);
      expect(empty.path, isNull);
      expect(empty.meta, isNull);
      expect(empty.createdAt, isNull);
      expect(empty.stream.kind, StreamKind.unknown);
    });

    test('no size is no progress bar, not an empty one', () {
      expect(const DownloadView({'size': 0, 'downloaded': 0}).progress, isNull);
      expect(
        const DownloadView({'size': 0, 'state': 'complete'}).progress,
        1,
        reason: 'a finished download is whole whatever the counters say',
      );
      expect(
        const DownloadView({'size': 10, 'downloaded': 40}).progress,
        1,
        reason: 'and a count past the end is still a full bar',
      );
    });

    test('a failed download keeps the reason the server gave', () {
      const failed = DownloadView({
        'state': 'error',
        'error': 'no peer supplied the torrent metadata in time',
      });
      expect(failed.state, DownloadState.error);
      expect(failed.error, 'no peer supplied the torrent metadata in time');
    });

    test('sizes read as storage is sold, decimal and short', () {
      expect(DownloadView.humanSize(0), '0 B');
      expect(DownloadView.humanSize(999), '999 B');
      expect(DownloadView.humanSize(1000), '1.0 kB');
      expect(DownloadView.humanSize(1536), '1.5 kB');
      expect(DownloadView.humanSize(150 * 1000), '150 kB');
      expect(DownloadView.humanSize(1400 * 1000 * 1000), '1.4 GB');
      expect(DownloadView.humanSize(2 * 1000 * 1000 * 1000 * 1000), '2.0 TB');
    });
  });

  group('DownloadsRegistry', () {
    test('an empty or unreadable payload is an empty registry', () {
      expect(DownloadsRegistry.empty.isEmpty, isTrue);
      expect(DownloadsRegistry.fromJson(const {}).items, isEmpty);
      expect(DownloadsRegistry.fromJson(const {}).version, 1);
      expect(
        DownloadsRegistry.fromJson(const {
          'version': 2,
          'items': <String, dynamic>{'a:b': 'not an object'},
        }).items,
        isEmpty,
      );
      expect(
        DownloadsRegistry.fromJson(const {
          'version': 2,
          'items': <String, dynamic>{},
        }).version,
        2,
      );
    });

    test('an event lays only what moved over the full picture', () {
      final moved = DownloadsRegistry.fromJson(const {
        'version': 1,
        'items': <String, dynamic>{
          'tt0903747:tt0903747:1:2': <String, dynamic>{
            'metaId': 'tt0903747',
            'videoId': 'tt0903747:1:2',
            'size': 32768,
            'downloaded': 32768,
            'state': 'complete',
          },
        },
      });
      final merged = registry.merge(moved);

      expect(merged.length, 3, reason: 'nothing was dropped');
      expect(merged['tt0903747:tt0903747:1:2']!.progress, 1);
      expect(
        merged['tt0903747:tt0903747:1:1']!.progress,
        registry['tt0903747:tt0903747:1:1']!.progress,
        reason: 'and what did not move was left alone',
      );
      expect(
        registry['tt0903747:tt0903747:1:2']!.state,
        DownloadState.downloading,
        reason: 'the registry merged into is unchanged',
      );
    });
  });
}
