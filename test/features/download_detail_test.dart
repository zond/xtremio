import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/downloads/download_detail.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/torrent_startup_overlay.dart';

import '../support/fake_downloads_client.dart';
import '../support/fake_torrent_stats_client.dart';

const torrentHash = 'abcdabcdabcdabcdabcdabcdabcdabcdabcdabcd';
const linkKey =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

/// A torrent download of 1.9 GB, [downloaded] bytes of it here.
DownloadView torrent(
  String id, {
  int downloaded = 612000000,
  int size = 1900000000,
  String state = 'downloading',
}) => DownloadView({
  'metaId': id,
  'videoId': id,
  'infoHash': torrentHash,
  'fileIdx': 3,
  'announce': ['udp://tracker.example:1337'],
  'name': 'A Film',
  'size': size,
  'downloaded': downloaded,
  'state': state,
});

/// A link download: the server's 64-hex key and file 0.
DownloadView link(
  String id, {
  int downloaded = 0,
  String state = 'downloading',
}) => DownloadView({
  'metaId': id,
  'videoId': id,
  'infoHash': linkKey,
  'fileIdx': 0,
  'name': 'A Link',
  'size': 10000000,
  'downloaded': downloaded,
  'state': state,
});

DownloadsRegistry registryOf(Iterable<DownloadView> views) =>
    DownloadsRegistry(items: {for (final view in views) view.key: view});

Map<String, dynamic> rowOf(DownloadView view) => {
  'key': view.key,
  'downloaded': view.downloaded,
  'size': view.size,
  'state': view.state.wireName,
  'path': null,
  'error': null,
  'completedAt': null,
};

const connected = TorrentStats(
  phase: TorrentPhase.buffering,
  downloadSpeed: 1200000,
  peers: 14,
  swarmSeeders: 137,
  swarmLeechers: 402,
  peerDiscovery: PeerDiscovery(live: 14, seen: 80),
);

void main() {
  group('what a torrent download says', () {
    test('downloading: the speed, the swarm and the bytes', () {
      final detail = DownloadDetail.of(torrent('tt1'), stats: connected);

      expect(
        detail.line,
        'Downloading 32% · 1.2 MB/s · connected 14 · seeds 137 · swarm 539 '
        '· 612 MB of 1.9 GB',
      );
      expect(detail.lines, [
        'Downloading 32%',
        '1.2 MB/s · connected 14 · seeds 137 · swarm 539',
        '612 MB of 1.9 GB',
      ]);
      expect(detail.percent, 32);
      expect(detail.speed, 1200000);
    });

    test('nothing connected yet: the search, in the card\'s words', () {
      const stats = TorrentStats(
        phase: TorrentPhase.buffering,
        peerDiscovery: PeerDiscovery(seen: 12, connecting: 3),
        swarmSeeders: 40,
        swarmLeechers: 2,
      );
      final detail = DownloadDetail.of(
        torrent('tt1', downloaded: 0),
        stats: stats,
      );

      expect(
        detail.line,
        'Finding peers · 12 found · 3 connecting · 40 seeds in the swarm '
        '· 0 B of 1.9 GB',
      );
      // The card over the player says the same about the same numbers.
      final card = TorrentStartupOverlay.describe(stats);
      expect(card.label, 'Finding peers…');
      expect(card.detail, '12 found · 3 connecting · 40 seeds in the swarm');
    });

    test('no peer found at all says so', () {
      final detail = DownloadDetail.of(
        torrent('tt1', downloaded: 0),
        stats: const TorrentStats(phase: TorrentPhase.buffering),
      );
      expect(detail.line, 'Finding peers · No peers found yet · 0 B of 1.9 GB');
    });

    test('a magnet still resolving', () {
      final detail = DownloadDetail.of(
        torrent('tt1', downloaded: 0, size: 0, state: 'queued'),
        stats: const TorrentStats(phase: TorrentPhase.resolvingMetadata),
      );
      expect(detail.line, 'Fetching torrent metadata · 0 B so far');
      expect(detail.percent, isNull);
    });

    test('checking what is already here, with the check\'s percentage', () {
      final detail = DownloadDetail.of(
        torrent('tt1', state: 'queued'),
        stats: const TorrentStats(
          phase: TorrentPhase.checking,
          checkedBytes: 400,
          checkTotalBytes: 1000,
        ),
      );
      expect(detail.status, 'Checking existing data 40%');
      expect(
        TorrentStartupOverlay.describe(
          const TorrentStats(
            phase: TorrentPhase.checking,
            checkedBytes: 400,
            checkTotalBytes: 1000,
          ),
        ).label,
        'Checking existing data… 40%',
      );
    });

    test('a piece a reader waits on leads the row and closes the block', () {
      const stats = TorrentStats(
        phase: TorrentPhase.buffering,
        downloadSpeed: 0,
        peers: 3,
        inFlightPiece: InFlightPiece(
          index: 412,
          downloadedBytes: 6606029,
          totalBytes: 16777216,
        ),
      );
      final detail = DownloadDetail.of(torrent('tt1'), stats: stats);

      expect(
        detail.line,
        'Waiting for piece 412, 6.3 of 16.0 MiB · 0 B/s · connected 3 '
        '· 612 MB of 1.9 GB',
      );
      expect(detail.lines.first, 'Downloading 32%');
      expect(detail.lines.last, 'Waiting for piece 412, 6.3 of 16.0 MiB');
    });

    test('a verified piece is not a wait', () {
      final detail = DownloadDetail.of(
        torrent('tt1'),
        stats: const TorrentStats(
          phase: TorrentPhase.ready,
          peers: 3,
          inFlightPiece: InFlightPiece(
            index: 412,
            downloadedBytes: 16777216,
            totalBytes: 16777216,
            verified: true,
          ),
        ),
      );
      expect(detail.piece, isNull);
      expect(detail.status, 'Downloading 32%');
    });

    test('stopped by the server, with its reason', () {
      final detail = DownloadDetail.of(
        torrent('tt1'),
        stats: const TorrentStats(
          phase: TorrentPhase.error,
          error: 'stopped for want of disk space',
        ),
      );
      expect(
        detail.line,
        'Stopped · stopped for want of disk space · 612 MB of 1.9 GB',
      );
    });

    test('before the first answer, what the row knows', () {
      expect(
        DownloadDetail.of(torrent('tt1')).line,
        'Downloading 32% · 612 MB of 1.9 GB',
      );
      expect(
        DownloadDetail.of(torrent('tt1', downloaded: 0, state: 'queued')).line,
        'Waiting to start · 0 B of 1.9 GB',
      );
    });
  });

  group('what a link download says', () {
    test('the bytes, the percentage and the measured speed', () {
      final detail = DownloadDetail.of(
        link('l1', downloaded: 2500000),
        measuredSpeed: 850000,
      );
      expect(detail.line, 'Downloading 25% · 850 kB/s · 2.5 MB of 10.0 MB');
      expect(detail.speed, 850000);
    });

    test('no speed until one was measured, and none while queued', () {
      expect(
        DownloadDetail.of(link('l1', downloaded: 2500000)).line,
        'Downloading 25% · 2.5 MB of 10.0 MB',
      );
      expect(
        DownloadDetail.of(
          link('l1', state: 'queued'),
          measuredSpeed: 5000,
        ).line,
        'Waiting to start · 0 B of 10.0 MB',
      );
    });
  });

  group('the poller', () {
    late FakeDownloadsClient client;
    late FakeTorrentStatsClient stats;

    setUp(() {
      client = FakeDownloadsClient();
      stats = FakeTorrentStatsClient()..response = connected;
    });

    test('asks nothing while nothing is on its way', () {
      fakeAsync((async) {
        client.registry = registryOf([
          torrent('tt1', downloaded: 1900000000, state: 'complete'),
          torrent('tt2', state: 'error'),
        ]);
        final poller = DownloadDetailPoller(client: client, stats: stats);
        unawaited(poller.start());
        async.elapse(const Duration(seconds: 10));

        expect(poller.isPolling, isFalse);
        expect(stats.requests, isEmpty);
        expect(poller.details, isEmpty);
        poller.dispose();
      });
    });

    test('starts with a download, ticks at the cadence, and stops with the '
        'last one', () {
      fakeAsync((async) {
        final poller = DownloadDetailPoller(client: client, stats: stats);
        unawaited(poller.start());
        async.flushMicrotasks();
        expect(poller.isPolling, isFalse);

        // A download begins: its first row is the only hint.
        final added = torrent('tt1');
        client.registry = registryOf([added]);
        client.emitProgress([rowOf(added)]);
        async.flushMicrotasks();

        expect(poller.isPolling, isTrue);
        expect(stats.requests, [
          const TorrentStatsRequest(
            infoHash: torrentHash,
            fileIdx: 3,
            trackers: ['udp://tracker.example:1337'],
          ),
        ]);
        expect(
          poller['tt1:tt1']?.line,
          startsWith('Downloading 32% · 1.2 MB/s · connected 14'),
        );

        async.elapse(DownloadDetailPoller.cadence * 5);
        expect(stats.requests, hasLength(6));

        client.emitProgress([
          rowOf(torrent('tt1', downloaded: 1900000000, state: 'complete')),
        ]);
        async.flushMicrotasks();
        expect(poller.isPolling, isFalse);
        expect(poller.details, isEmpty);

        async.elapse(DownloadDetailPoller.cadence * 5);
        expect(stats.requests, hasLength(6));
        poller.dispose();
      });
    });

    test('the cadence is the stall card\'s', () {
      expect(DownloadDetailPoller.cadence, const Duration(seconds: 2));
    });

    test('a link\'s speed is what its bytes grew by between two polls', () {
      fakeAsync((async) {
        var now = DateTime(2026, 10, 16);
        client.registry = registryOf([link('l1', downloaded: 1000000)]);
        final poller = DownloadDetailPoller(
          client: client,
          stats: stats,
          now: () => now,
        );
        unawaited(poller.start());
        async.flushMicrotasks();
        expect(poller['l1:l1']?.speed, isNull);

        client.emitProgress([rowOf(link('l1', downloaded: 2700000))]);
        now = now.add(DownloadDetailPoller.cadence);
        async.elapse(DownloadDetailPoller.cadence);

        expect(poller['l1:l1']?.speed, 850000);
        expect(poller['l1:l1']?.line, contains('850 kB/s'));
        expect(stats.requests, isEmpty, reason: 'a link has no swarm');
        poller.dispose();
      });
    });

    test('the row\'s bytes move with the feed, between polls', () {
      fakeAsync((async) {
        client.registry = registryOf([torrent('tt1')]);
        final poller = DownloadDetailPoller(client: client, stats: stats);
        var heard = 0;
        poller.addListener(() => heard++);
        unawaited(poller.start());
        async.flushMicrotasks();
        final before = heard;

        client.emitProgress([rowOf(torrent('tt1', downloaded: 700000000))]);
        async.flushMicrotasks();

        expect(heard, before + 1);
        expect(poller['tt1:tt1']?.bytes, '700 MB of 1.9 GB');
        poller.dispose();
      });
    });
  });
}
