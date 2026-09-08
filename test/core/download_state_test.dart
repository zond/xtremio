import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/fixtures.dart';

/// The keys `rust/src/downloads.rs` writes for one entry, mirroring the set
/// `offline_downloads_lifecycle` in `rust/tests/downloads.rs` asserts on the
/// live `downloads_list` output. That test is what a rename over there has
/// to fail; this one guards the recording, so every expectation below is
/// read off a whole row rather than a truncated one.
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

    test('every recorded entry is whole, not a truncated row', () {
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
      expect(movie.createdAt, DateTime.utc(2026, 1, 1, 0, 0, 0, 123, 456));
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

    test('a size that rounds up to a whole unit is shown as that unit', () {
      expect(DownloadView.humanSize(999999), '1.0 MB');
      expect(DownloadView.humanSize(999999999), '1.0 GB');
      expect(
        DownloadView.humanSize(999499),
        '999 kB',
        reason: 'and one that rounds down stays where it is',
      );
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

    /// The keys a build with a downloads folder of its own wrote are not
    /// read and not carried: there is one torrent-data root, the server
    /// owns it, and a second answer here could only contradict it.
    test('a recorded downloads folder is not read back', () {
      final registry = DownloadsRegistry.fromJson(const {
        'version': 1,
        'items': <String, dynamic>{},
        'destinationSettled': true,
        'destinationChoice': '/sdcard/files/downloads',
      });
      expect(registry.isEmpty, isTrue);
      expect(registry.toString(), isNot(contains('/sdcard/files/downloads')));
    });
  });

  group('a progress event', () {
    /// The listing a screen already has.
    DownloadsRegistry listed() => DownloadsRegistry(
      items: {
        'tt1:tt1': const DownloadView({
          'metaId': 'tt1',
          'videoId': 'tt1',
          'name': 'A Film',
          'infoHash': 'abcdabcd',
          'meta': {'id': 'tt1'},
          'size': 100,
          'downloaded': 10,
          'state': 'downloading',
        }),
      },
    );

    test('is read as rows, and a listing envelope still as a listing', () {
      final update = DownloadsUpdate.fromJson(const {
        'version': 1,
        'progress': [
          {
            'key': 'tt1:tt1',
            'downloaded': 100,
            'size': 100,
            'state': 'complete',
            'path': '/downloads/a.mkv',
            'error': null,
            'completedAt': '2026-01-01T00:00:00Z',
          },
        ],
      });
      final row = (update as DownloadsProgressUpdate).rows.single;
      expect(row.key, 'tt1:tt1');
      expect(row.downloaded, 100);
      expect(row.size, 100);
      expect(row.state, DownloadState.complete);
      expect(row.path, '/downloads/a.mkv');
      expect(row.error, isNull);
      expect(row.completedAt, DateTime.utc(2026));

      expect(
        DownloadsUpdate.fromJson(const {
          'version': 1,
          'items': {
            'tt1:tt1': {'metaId': 'tt1', 'videoId': 'tt1'},
          },
        }),
        isA<DownloadsListingUpdate>(),
        reason: 'the shape every build before the narrow rows pushed',
      );
    });

    test('is laid over the entry it names, not put in its place', () {
      final merged = DownloadsUpdate.fromJson(const {
        'version': 1,
        'progress': [
          {
            'key': 'tt1:tt1',
            'downloaded': 100,
            'size': 100,
            'state': 'complete',
            'path': '/downloads/a.mkv',
            'error': null,
            'completedAt': '2026-01-01T00:00:00Z',
          },
        ],
      }).applyTo(listed());

      final view = merged['tt1:tt1']!;
      expect(view.downloaded, 100);
      expect(view.isComplete, isTrue);
      expect(view.path, '/downloads/a.mkv');
      expect(view.completedAt, DateTime.utc(2026));
      expect(view.name, 'A Film', reason: 'the row carries none of this');
      expect(view.meta, isNotNull);
      expect(view.infoHash, 'abcdabcd');
    });

    test('says nothing about a field it leaves out', () {
      final merged = DownloadsUpdate.fromJson(const {
        'version': 1,
        'progress': [
          {'key': 'tt1:tt1', 'downloaded': 50},
        ],
      }).applyTo(listed());

      final view = merged['tt1:tt1']!;
      expect(view.downloaded, 50);
      expect(view.size, 100, reason: 'a field not in the row is not a null');
      expect(view.state, DownloadState.downloading);
    });

    test('a removed array drops the entries it names, and nothing else', () {
      final update = DownloadsUpdate.fromJson(const {
        'version': 1,
        'removed': ['tt1:tt1', 'tt9:tt9'],
      });
      expect(update, isA<DownloadsRemovalUpdate>());
      expect((update as DownloadsRemovalUpdate).keys, ['tt1:tt1', 'tt9:tt9']);

      final before = listed().merge(
        DownloadsRegistry(
          items: {
            'tt2:tt2': DownloadView(const {'metaId': 'tt2', 'videoId': 'tt2'}),
          },
        ),
      );
      final after = update.applyTo(before);
      expect(after['tt1:tt1'], isNull);
      expect(after['tt2:tt2'], isNotNull, reason: 'only what was named goes');
      expect(after.length, 1, reason: 'a key nothing held changes nothing');
      expect(after.version, before.version);
    });

    test('for an entry nothing has listed yet is dropped', () {
      final merged = DownloadsUpdate.fromJson(const {
        'version': 1,
        'progress': [
          {'key': 'tt9:tt9', 'downloaded': 5},
        ],
      }).applyTo(listed());

      expect(merged.length, 1);
      expect(merged['tt9:tt9'], isNull);
    });
  });
}
