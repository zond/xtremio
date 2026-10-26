import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_stats.dart';
import 'package:xtremio/features/player/playback_watchdog.dart';

/// The waits mpv does not report, on their own. What the viewer sees of them
/// is held by player_stuck_test, player_read_wait_test and the stall card's
/// tests.
const _tick = Duration(seconds: 1);

/// A watched playback whose facts the test sets.
final class _Playback {
  Duration position = Duration.zero;
  bool moving = true;
  bool loaded = true;
  String? askable = 'media';
  String? playing = 'media';
  ReadWait answer = ReadWait.none;
  Completer<ReadWait>? pending;
  int asks = 0;
  int changes = 0;
  final stats = StreamController<PlaybackStats>.broadcast();

  late final PlaybackWatchdog watchdog = PlaybackWatchdog(
    stuckInterval: _tick,
    stuckAfter: const Duration(seconds: 5),
    stuckTwitch: const Duration(milliseconds: 500),
    readWaitInterval: const Duration(seconds: 2),
    readWaitShown: const Duration(seconds: 3),
    position: () => position,
    shouldMove: () => moving,
    playingLoaded: () => loaded,
    readWaitId: () => askable,
    playingId: () => playing,
    askReadWait: (id) {
      asks++;
      final wait = pending;
      return wait == null ? Future.value(answer) : wait.future;
    },
    stats: () => stats.stream,
  )..addListener(() => changes++);
}

void main() {
  const waited = ReadWait(waiting: Duration(seconds: 4), offset: 1024);

  group('a position standing still', () {
    test('counts only after a first position, then after the wait', () {
      fakeAsync((async) {
        final p = _Playback()..askable = null;
        p.watchdog.start();
        async.elapse(const Duration(seconds: 10));
        expect(p.watchdog.positionStuck, isFalse, reason: 'nothing seen yet');

        p.watchdog.sawPosition();
        async.elapse(const Duration(seconds: 4));
        expect(p.watchdog.positionStuck, isFalse);
        async.elapse(_tick);
        expect(p.watchdog.positionStuck, isTrue);
        expect(p.changes, 1);
      });
    });

    test('is not counted while it should not move', () {
      fakeAsync((async) {
        final p = _Playback()..askable = null;
        p.watchdog
          ..start()
          ..sawPosition();
        p.moving = false;
        async.elapse(const Duration(seconds: 10));
        expect(p.watchdog.positionStuck, isFalse);
        p.moving = true;
        async.elapse(const Duration(seconds: 4));
        expect(p.watchdog.positionStuck, isFalse, reason: 'counts from 0');
      });
    });

    test('ends when the film moves far enough, not for a twitch', () {
      fakeAsync((async) {
        final p = _Playback()..askable = null;
        p.watchdog
          ..start()
          ..sawPosition();
        async.elapse(const Duration(seconds: 5));
        expect(p.watchdog.positionStuck, isTrue);
        p.watchdog.positionMoved(const Duration(milliseconds: 200));
        expect(p.watchdog.positionStuck, isTrue);
        p.watchdog.positionMoved(const Duration(seconds: 2));
        expect(p.watchdog.positionStuck, isFalse);
        expect(p.changes, 2);
      });
    });

    test('takes one sample of what mpv does, and lets it go', () {
      fakeAsync((async) {
        final p = _Playback()..askable = null;
        p.watchdog
          ..start()
          ..sawPosition();
        async.elapse(const Duration(seconds: 5));
        expect(p.stats.hasListener, isTrue);
        p.stats.add(const PlaybackStats());
        async.flushMicrotasks();
        expect(p.stats.hasListener, isFalse);
      });
    });
  });

  group('a read the server says waits', () {
    test('holds when the read waited and the picture stood still', () {
      fakeAsync((async) {
        final p = _Playback()..answer = waited;
        p.watchdog.start();
        async.elapse(const Duration(seconds: 2));
        expect(p.watchdog.readStalled, isFalse, reason: 'nothing to compare');
        async.elapse(const Duration(seconds: 2));
        expect(p.watchdog.readStalled, isTrue);
        expect(p.asks, 2);
      });
    });

    test('does not hold while the picture moves between asks', () {
      fakeAsync((async) {
        final p = _Playback()..answer = waited;
        p.watchdog.start();
        async.elapse(const Duration(seconds: 2));
        p.position = const Duration(seconds: 2);
        async.elapse(const Duration(seconds: 2));
        expect(p.watchdog.readStalled, isFalse);
      });
    });

    test('ends at the first ask that finds reads flowing', () {
      fakeAsync((async) {
        final p = _Playback()..answer = waited;
        p.watchdog.start();
        async.elapse(const Duration(seconds: 4));
        expect(p.watchdog.readStalled, isTrue);
        p.answer = ReadWait.none;
        async.elapse(const Duration(seconds: 2));
        expect(p.watchdog.readStalled, isFalse);
      });
    });

    test('ends when the film moves', () {
      fakeAsync((async) {
        final p = _Playback()..answer = waited;
        p.watchdog.start();
        async.elapse(const Duration(seconds: 4));
        expect(p.watchdog.readStalled, isTrue);
        p.watchdog.positionMoved(const Duration(seconds: 3));
        expect(p.watchdog.readStalled, isFalse);
      });
    });

    test('asks nobody when nobody may be asked', () {
      fakeAsync((async) {
        final p = _Playback()..askable = null;
        p.watchdog.start();
        async.elapse(const Duration(seconds: 10));
        expect(p.asks, 0);
      });
    });

    test('asks once at a time', () {
      fakeAsync((async) {
        final p = _Playback()..pending = Completer<ReadWait>();
        p.watchdog.start();
        async.elapse(const Duration(seconds: 10));
        expect(p.asks, 1);
      });
    });

    test('drops an answer about a media no longer playing', () {
      fakeAsync((async) {
        final p = _Playback()..answer = waited;
        p.watchdog.start();
        async.elapse(const Duration(seconds: 2));
        final answer = p.pending = Completer<ReadWait>();
        async.elapse(const Duration(seconds: 2));
        p.playing = 'another';
        answer.complete(waited);
        async.flushMicrotasks();
        expect(p.watchdog.readStalled, isFalse);
      });
    });

    test('keeps an answer when only the asking stopped meanwhile', () {
      fakeAsync((async) {
        final p = _Playback()..answer = waited;
        p.watchdog.start();
        async.elapse(const Duration(seconds: 2));
        final answer = p.pending = Completer<ReadWait>();
        async.elapse(const Duration(seconds: 2));
        p.askable = null;
        answer.complete(waited);
        async.flushMicrotasks();
        expect(p.watchdog.readStalled, isTrue);
      });
    });

    test('does not hold for a player that is not playing loaded media', () {
      fakeAsync((async) {
        final p = _Playback()
          ..answer = waited
          ..loaded = false;
        p.watchdog.start();
        async.elapse(const Duration(seconds: 6));
        expect(p.watchdog.readStalled, isFalse);
      });
    });
  });

  test('stopped, it watches nothing', () {
    fakeAsync((async) {
      final p = _Playback()..answer = waited;
      p.watchdog
        ..start()
        ..sawPosition()
        ..stop();
      async.elapse(const Duration(seconds: 20));
      expect(p.asks, 0);
      expect(p.watchdog.positionStuck, isFalse);
      p.watchdog.start();
      async.elapse(const Duration(seconds: 20));
      expect(p.asks, 0, reason: 'a stopped watchdog does not start again');
    });
  });
}
