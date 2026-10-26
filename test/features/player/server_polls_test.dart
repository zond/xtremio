import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/stream_numbers_poll.dart';
import 'package:xtremio/features/player/torrent_stats.dart';
import 'package:xtremio/features/player/torrent_stats_poll.dart';

import '../../support/fake_stream_numbers_client.dart';
import '../../support/fake_torrent_stats_client.dart';

/// The player's two polls of the server, on their own. What the panels and
/// the start-up and stall cards show of them is held by the stats OSD,
/// torrent start-up and stall tests.
void main() {
  const tick = Duration(seconds: 1);
  const file = TorrentStatsRequest(infoHash: 'aa', fileIdx: 2);
  const named = TorrentStats(
    phase: TorrentPhase.ready,
    initialWindowReadyBytes: 1,
    initialWindowBytes: 1,
    streamName: 'Film.2026.1080p.mkv',
  );

  group('the torrent stats poll', () {
    ({TorrentStatsPoll poll, FakeTorrentStatsClient client, List<int> changes})
    make() {
      final client = FakeTorrentStatsClient();
      final changes = <int>[];
      final poll = TorrentStatsPoll(client: () => client, startupCadence: tick);
      poll.addListener(() => changes.add(changes.length));
      return (poll: poll, client: client, changes: changes);
    }

    test('starts on the first tick, never at once', () {
      fakeAsync((async) {
        final p = make();
        p.poll.start(file);
        async.flushMicrotasks();
        expect(p.client.requests, isEmpty);
        async.elapse(tick);
        expect(p.client.requests, [file]);
        expect(p.poll.stats, isNotNull);
        p.poll.dispose();
      });
    });

    test('asks for the torrent when the server has nothing for the file', () {
      fakeAsync((async) {
        final p = make();
        p.client.responses[file] = null;
        p.poll.start(file);
        async.elapse(tick);
        expect(p.client.requests, [file, file.torrentLevel]);
        expect(p.poll.stats, isNotNull);
        p.poll.dispose();
      });
    });

    test('a name comes only from an answer about the file, and sticks', () {
      fakeAsync((async) {
        final p = make();
        p.client.response = named;
        p.poll.start(file);
        async.elapse(tick);
        expect(p.poll.serverFilename, 'Film.2026.1080p.mkv');
        p.poll.pause();
        expect(p.poll.serverFilename, 'Film.2026.1080p.mkv');
        p.client.responses[file] = null;
        p.client.response = const TorrentStats(
          phase: TorrentPhase.ready,
          initialWindowReadyBytes: 1,
          initialWindowBytes: 1,
          streamName: 'Guessed.mkv',
        );
        p.poll.run(tick, keepLast: true);
        async.flushMicrotasks();
        expect(p.poll.serverFilename, 'Film.2026.1080p.mkv');
        p.poll.dispose();
      });
    });

    test('a run asks at once, and a pause keeps the last answer', () {
      fakeAsync((async) {
        final p = make();
        p.poll.start(file);
        p.poll.run(const Duration(seconds: 5), keepLast: true);
        async.flushMicrotasks();
        expect(p.client.requests, hasLength(1));
        p.poll.pause();
        async.elapse(const Duration(seconds: 30));
        expect(p.client.requests, hasLength(1));
        expect(p.poll.stats, isNotNull);
        p.poll.dispose();
      });
    });

    test('numbers from before are dropped when nothing kept them', () {
      fakeAsync((async) {
        final p = make();
        p.poll.start(file);
        async.elapse(tick);
        p.poll.pause();
        p.client.holdAnswers = true;
        p.poll.run(tick, keepLast: false);
        expect(p.poll.stats, isNull, reason: 'the past is not the present');
        p.client.answer();
        p.poll.dispose();
      });
    });

    test('a changed pace keeps the answer it had', () {
      fakeAsync((async) {
        final p = make();
        p.poll.start(file);
        async.elapse(tick);
        p.client.holdAnswers = true;
        p.poll.run(const Duration(seconds: 3), keepLast: false);
        expect(p.poll.stats, isNotNull);
        p.client.answer();
        p.poll.dispose();
      });
    });

    test('one ask at a time', () {
      fakeAsync((async) {
        final p = make();
        p.client.holdAnswers = true;
        p.poll.start(file);
        async.elapse(const Duration(seconds: 5));
        expect(p.client.heldCount, 1);
        p.client.answer();
        p.poll.dispose();
      });
    });

    test('an answer about a torrent no longer asked about is dropped', () {
      fakeAsync((async) {
        final p = make();
        p.client.holdAnswers = true;
        p.poll.start(file);
        async.elapse(tick);
        p.poll.stop();
        p.client.answer();
        async.flushMicrotasks();
        expect(p.poll.stats, isNull);
        expect(p.changes, isEmpty);
        p.poll.dispose();
      });
    });

    test('an answer that lands after the polling paused is not shown', () {
      fakeAsync((async) {
        final p = make();
        p.client.holdAnswers = true;
        p.poll.start(file);
        async.elapse(tick);
        p.poll.pause();
        p.client.answer();
        async.flushMicrotasks();
        expect(p.poll.stats, isNull);
        p.poll.dispose();
      });
    });
  });

  group('the stream numbers poll', () {
    const reading = StreamNumbers(sharing: SharingNumbers(committedBytes: 1));

    ({
      StreamNumbersPoll poll,
      FakeStreamNumbersClient reader,
      void Function(Object) stream,
    })
    make({String? id = 'm1'}) {
      final reader = FakeStreamNumbersClient()..response = reading;
      Object stream = 'first';
      final poll = StreamNumbersPoll(
        reader: () => reader,
        interval: const Duration(seconds: 5),
        target: () => (id: id, url: null, stream: stream),
      );
      return (poll: poll, reader: reader, stream: (next) => stream = next);
    }

    test('asks at once, then every interval', () {
      fakeAsync((async) {
        final p = make();
        p.poll.run();
        async.flushMicrotasks();
        expect(p.reader.requests, hasLength(1));
        expect(p.poll.numbers, reading);
        async.elapse(const Duration(seconds: 10));
        expect(p.reader.requests, hasLength(3));
        p.poll.dispose();
      });
    });

    test('a stop forgets the reading', () {
      fakeAsync((async) {
        final p = make();
        p.poll.run();
        async.flushMicrotasks();
        p.poll.stop();
        expect(p.poll.numbers, isNull);
        async.elapse(const Duration(seconds: 10));
        expect(p.reader.requests, hasLength(1));
        p.poll.dispose();
      });
    });

    test('an answer about another stream is dropped', () {
      fakeAsync((async) {
        final p = make();
        p.reader.holdAnswers = true;
        p.poll.run();
        p.stream('second');
        p.reader.answer();
        async.flushMicrotasks();
        expect(p.poll.numbers, isNull);
        p.poll.dispose();
      });
    });

    test('an empty answer is no reading', () {
      fakeAsync((async) {
        final p = make();
        p.reader.response = const StreamNumbers();
        p.poll.run();
        async.flushMicrotasks();
        expect(p.poll.numbers, isNull);
        p.poll.dispose();
      });
    });

    test('asks nothing about nothing', () {
      fakeAsync((async) {
        final p = make(id: null);
        p.poll.run();
        async.elapse(const Duration(seconds: 10));
        expect(p.reader.requests, isEmpty);
        p.poll.dispose();
      });
    });
  });
}
