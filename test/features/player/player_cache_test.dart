import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';

/// What the app tells mpv about its own cache.
///
/// The owner's Chromecast logged `mpv: mkv: Failed to create file cache.` on
/// every open: Android hands an app no writable temp path, so mpv's own
/// default cache directory does not exist there and the demuxer's file cache
/// is never created. Everything mpv could seek within was then whatever fit
/// in the 32 MiB memory cache media_kit configures -- on a 2.3 Mbps film,
/// the two islands (1465-1601s and 516-551s) he could not scan between.
///
/// The engine itself cannot be built without libmpv, so what is checked here
/// is the set of properties it applies and the directory they name. That the
/// set really lands before the first `loadfile` is the `await _overrides` in
/// `MediaKitEngine.open`, which no test on this side of libmpv can reach.
void main() {
  const String directory = '/data/user/0/com.zond.xtremio/cache/mpv';

  test('the file cache is pointed at a directory mpv may write in', () {
    final overrides = MediaKitEngine.overridesFor(directory);

    expect(overrides['demuxer-cache-dir'], directory);
    // mpv unlinks the file as soon as it has made it, so nothing of ours
    // has to delete it and a crash cannot leave it behind.
    expect(overrides['demuxer-cache-unlink-files'], 'immediate');
    // The overrides that were already there are still there.
    expect(
      overrides['network-timeout'],
      MediaKitEngine.mpvOverrides['network-timeout'],
    );
  });

  test('nothing is set where mpv has nowhere to write', () {
    final overrides = MediaKitEngine.overridesFor(null);

    expect(overrides.containsKey('demuxer-cache-dir'), isFalse);
    expect(overrides.containsKey('demuxer-cache-unlink-files'), isFalse);
    expect(overrides, MediaKitEngine.mpvOverrides);
  });

  test('a platform with no cache directory of its own is answered, not '
      'thrown at', () async {
    // No path_provider channel in a test host, which stands in for the
    // platform having nothing to offer: the engine still has to come up,
    // with mpv keeping its own default directory (right on a desktop,
    // missing on Android).
    TestWidgetsFlutterBinding.ensureInitialized();

    expect(await platformMpvCacheDirectory(), isNull);
  });

  /// `demuxer-cache-state` as a running libmpv 0.41.0 answered it for the
  /// same two minutes of the same stream, once with the file cache working
  /// and once without. The pair is also the measurement behind the option:
  /// the payload costs 21 MB of the byte budget, the metadata for it 818 KB.
  const String withFileCache =
      '{"cache-end":119.960000,"reader-pts":3.680000,"cache-duration":116.280000,"eof":true,"underrun":false,"idle":true,"total-bytes":818048,"fw-bytes":790704,"file-cache-bytes":19435901,"raw-input-rate":9503029,"debug-low-level-seeks":0,"debug-byte-level-seeks":0,"debug-ts-last":119.960000,"ts-per-stream":[{"type":"video","cache-duration":116.280000,"reader-pts":3.680000,"cache-end":119.960000}],"bof-cached":true,"eof-cached":true,"seekable-ranges":[{"start":0.000000,"end":119.960000}]}';
  const String withoutFileCache =
      '{"cache-end":119.960000,"reader-pts":3.680000,"cache-duration":116.280000,"eof":true,"underrun":false,"idle":true,"total-bytes":21056304,"fw-bytes":20417984,"raw-input-rate":9504576,"debug-low-level-seeks":0,"debug-byte-level-seeks":0,"debug-ts-last":119.960000,"ts-per-stream":[{"type":"video","cache-duration":116.280000,"reader-pts":3.680000,"cache-end":119.960000}],"bof-cached":true,"eof-cached":true,"seekable-ranges":[{"start":0.000000,"end":119.960000}]}';

  /// A cache state reporting a file of [bytes].
  String stateOf(int bytes) => withFileCache.replaceAll(
    '"file-cache-bytes":19435901',
    '"file-cache-bytes":$bytes',
  );

  group('the size of the file mpv is writing', () {
    test('is read out of the cache state', () {
      expect(PlaybackStats.fileCacheBytesOf(withFileCache), 19435901);
    });

    test('is absent when there is no file, which is the fault itself', () {
      // mpv leaves the key out of the map when it has no disk cache, so an
      // absent reading is the `Failed to create file cache` state and a
      // present one is the proof the directory took.
      expect(PlaybackStats.fileCacheBytesOf(withoutFileCache), isNull);
      expect(PlaybackStats.fileCacheBytesOf(null), isNull);
      expect(PlaybackStats.fileCacheBytesOf('not json'), isNull);
    });
  });

  /// What a running libmpv did when `cache-on-disk` was set to `no` part
  /// way through a stream, and then back to `yes`.
  ///
  /// The doubt this settles was written into this app's own comments: that
  /// mpv reads the option once, when it builds the demuxer, in which case
  /// turning it off on a player being left is decoration and
  /// [MpvDiskCacheLimit] cannot limit the media it is watching. It reads
  /// it per packet, out of options the demuxer thread refreshes every
  /// cycle ([MpvDiskCacheLimit.stopWritingToDisk] names the two lines of
  /// `demux/demux.c`), and this is what that looks like from outside.
  ///
  /// libmpv 0.41.0 over a 155 MB Matroska served from localhost through a
  /// 2,000,000 B/s throttle, so the demuxer is input-bound and the file
  /// climbs at a readable rate; `demuxer-cache-state` polled every 250 ms,
  /// with the cache file `stat`ed from outside the process as ground truth
  /// (it agreed byte for byte). Seconds since the open, the file, what the
  /// memory cache held, and how far ahead the demuxer had read.
  const List<(double, int, int, double)> aroundTheSwitch = [
    (14.52, 29113962, 1123376, 56.27),
    // `cache-on-disk=no` at 15.02
    (15.27, 30102820, 1707120, 59.20),
    (20.28, 30102820, 12449600, 78.47),
    (25.29, 30102820, 23240784, 97.87),
    (27.29, 30102820, 27548352, 105.57),
    // `cache-on-disk=yes` at 28.04
    (29.04, 32123609, 29264160, 112.43),
    (34.06, 42151449, 29652992, 131.90),
    (39.07, 52179769, 30035968, 151.17),
  ];

  /// The same switch in media_kit's real shape -- both byte limits at its
  /// 32 MiB and `demuxer-cache-unlink-files=immediate` -- carried far
  /// enough past the write to see what happens once the memory cache is
  /// full. Seconds, the file, the memory cache, and `raw-input-rate`.
  const List<(double, int, int, int)> afterTheMemoryCacheFills = [
    // `cache-on-disk=no` at 15.02
    (20.28, 30102820, 12449600, 2000114),
    (30.29, 30102820, 34029568, 2000049),
    (31.30, 30102820, 34195232, 1588497),
    (33.30, 30102820, 34231696, 597759),
    (35.30, 30102820, 34267424, 18038),
    (44.32, 30102820, 34446240, 18471),
  ];

  group('what mpv does with cache-on-disk mid-stream', () {
    /// The samples taken while the option was `no`.
    final off = aroundTheSwitch.sublist(1, 5);

    test('a running demuxer stops writing the moment it is told to', () {
      // Within one 250 ms sample of the write, and for the thirteen
      // seconds it was left off. This is the whole of what lets a limiter
      // bound a media it is already half way through, and what lets a
      // screen on its way out end the growth without waiting for a
      // teardown.
      expect(off.map((sample) => sample.$2).toSet(), {30102820});
    });

    test('while the demuxer goes on reading as hard as ever', () {
      // The reading that separates "the option took" from "the player
      // stalled": the read-ahead ran on from 59 s to 105 s of the film
      // across those same samples, and the payload that had been going to
      // disk went into memory instead.
      expect(off.first.$4, lessThan(off.last.$4 - 40));
      expect(off.first.$3, lessThan(off.last.$3));
    });

    test('and starts again the moment it is told to', () {
      // Both directions, which is what makes it an option mpv reads rather
      // than a demuxer it configured once: the next sample after
      // `cache-on-disk=yes` was already growing.
      final resumed = aroundTheSwitch.sublist(5);
      expect(resumed.first.$2, greaterThan(30102820));
      expect(resumed.last.$2, greaterThan(resumed.first.$2));
    });

    test('but it never gives a byte back', () {
      // The file froze; it did not shrink. Those 30 MB stayed allocated
      // for the whole thirteen seconds and came back only when the demuxer
      // went away. So the limiter is a bound on growth and never a way to
      // recover space, and a player that will not die is holding its file
      // whatever the option says.
      for (var i = 1; i < aroundTheSwitch.length; i++) {
        expect(
          aroundTheSwitch[i].$2,
          greaterThanOrEqualTo(aroundTheSwitch[i - 1].$2),
        );
      }
    });

    test('and once the memory cache is full it stops downloading too', () {
      // What the option buys a player that has been left. With nowhere to
      // put the payload, the demuxer fills media_kit's 32 MiB and then
      // reads at about one per cent of the link: 2,000,000 B/s down to
      // 18,000 within a second of the memory cache filling, sixteen
      // seconds after the write on a 2 MB/s stream and about eight on the
      // owner's 32 Mbps one. That is the 32 Mbps drain the Chromecast
      // measured, and this is what ends it.
      final filled = afterTheMemoryCacheFills.last;
      expect(
        filled.$3,
        greaterThan(MpvDiskCacheLimit.mediaKitMemoryCacheBytes),
      );
      expect(filled.$4, lessThan(2000000 ~/ 50));
      // And before it filled, the link was running at the full throttle:
      // the collapse is the cache filling up, not the server slowing down.
      expect(afterTheMemoryCacheFills.first.$4, greaterThan(2000000 - 1000));
    });
  });

  group('the limit on what mpv writes', () {
    /// A limiter answering [readings] in turn, one reading per
    /// [MpvDiskCacheLimit.check], holding the last once they run out, on a
    /// volume with [free] bytes left above a floor of 100.
    (MpvDiskCacheLimit, List<void>) limiterOver(
      List<String?> readings, {
      int? free = 10000,
    }) {
      final stopped = <void>[];
      var reading = 0;
      final limit = MpvDiskCacheLimit(
        cacheState: () async =>
            readings[reading < readings.length
                ? reading++
                : readings.length - 1],
        freeBytes: () async => free,
        stopWritingToDisk: () async => stopped.add(null),
        limitBytes: 1000,
        floorBytes: 100,
      );
      return (limit, stopped);
    }

    test('leaves a cache under it alone', () async {
      final (limit, stopped) = limiterOver([stateOf(999)]);

      await limit.check();

      expect(stopped, isEmpty);
      expect(limit.reached, isFalse);
    });

    test('stops mpv writing once the file is over it', () async {
      final (limit, stopped) = limiterOver([stateOf(1001)]);

      await limit.check();

      expect(stopped, hasLength(1));
      expect(limit.reached, isTrue);
    });

    test('asks once and then leaves the playback alone', () async {
      // The file cannot shrink, so a second answer cannot differ; the point
      // is that a five-second timer does not go on writing the property for
      // the rest of the film.
      final (limit, stopped) = limiterOver([stateOf(1001)]);

      await limit.check();
      await limit.check();
      await limit.check();

      expect(stopped, hasLength(1));
    });

    test('a limiter that has been stopped leaves the playback alone', () async {
      // It belongs to one media. The player stops it before the next
      // `loadfile`, and a tick that fires between the two must not answer
      // for a file that is already gone.
      final (limit, stopped) = limiterOver([stateOf(1001)]);

      limit.stop();
      await limit.check();

      expect(stopped, isEmpty);
      expect(limit.reached, isFalse);
    });

    test(
      'a reading still in flight when it is stopped writes nothing',
      () async {
        // The real window: `check` awaits an `mpv_get_property_string` in the
        // middle, so a reading begun for the previous media can come back
        // after `open` has set `cache-on-disk=yes` for the next one. Writing
        // then would leave the media just opened with no disk cache for its
        // whole length, and its own limiter -- seeing no file -- would never
        // turn one back on.
        final answer = Completer<String>();
        final stopped = <void>[];
        final limit = MpvDiskCacheLimit(
          cacheState: () => answer.future,
          freeBytes: () async => 10000,
          stopWritingToDisk: () async => stopped.add(null),
          limitBytes: 1000,
          floorBytes: 100,
        );

        final checking = limit.check();
        limit.stop();
        answer.complete(stateOf(1001));
        await checking;

        expect(stopped, isEmpty);
      },
    );

    test('never fires while there is no file to bound', () async {
      // Nothing on disk (a desktop mpv that could not make one either, or a
      // backend that is not libmpv): the memory cache is already bounded,
      // and turning the disk cache off would be turning off the fix.
      final (limit, stopped) = limiterOver([withoutFileCache, null]);

      await limit.check();
      await limit.check();

      expect(stopped, isEmpty);
      expect(limit.reached, isFalse);
    });

    test('stops mpv writing once the volume is down to the floor', () async {
      // The file is well under its own limit; the volume is not. Something
      // else is writing -- the embedded server's torrent cache is the whole
      // reason there is a floor -- and mpv going on would take the space
      // the server holds open so that streaming can carry on at all.
      final (limit, stopped) = limiterOver([stateOf(500)], free: 100);

      await limit.check();

      expect(stopped, hasLength(1));
      expect(limit.reached, isTrue);
    });

    test('leaves a volume that still has room above the floor alone', () async {
      final (limit, stopped) = limiterOver([stateOf(500)], free: 101);

      await limit.check();

      expect(stopped, isEmpty);
      expect(limit.reached, isFalse);
    });

    test('a volume nobody can measure is not a full one', () async {
      // An unreadable reading must leave the cache exactly as it would have
      // been. Read as zero it would take the file cache away from every
      // device whose filesystem will not answer -- which is the fix itself,
      // withdrawn for a fault that is not a full disk.
      final (limit, stopped) = limiterOver([stateOf(500)], free: null);

      await limit.check();

      expect(stopped, isEmpty);
      expect(limit.reached, isFalse);
    });

    test('a full volume with no file to bound is left to the server', () async {
      // mpv has no disk cache (a desktop that could not make one, or an
      // `open` that already refused it): there is nothing to turn off, and
      // the free space is then the server cleaner's business alone.
      final (limit, stopped) = limiterOver([withoutFileCache], free: 0);

      await limit.check();

      expect(stopped, isEmpty);
      expect(limit.reached, isFalse);
    });
  });

  group('whether a media gets a cache file at all', () {
    // What `MediaKitEngine.open` asks before it turns `cache-on-disk` on.
    // Five seconds is a couple of megabytes of a television stream and
    // forty of a remux, and on a device this close to full those are the
    // megabytes that matter, so the question is asked before the first
    // packet rather than on the first tick.
    test('a volume at the line gets none', () {
      expect(
        MpvDiskCacheLimit.hasRoomForCache(
          MpvDiskCacheLimit.leastFreeSpaceForCache,
        ),
        isFalse,
      );
    });

    test('a volume above the line gets one', () {
      expect(
        MpvDiskCacheLimit.hasRoomForCache(
          MpvDiskCacheLimit.leastFreeSpaceForCache + 1,
        ),
        isTrue,
      );
    });

    test('the outgoing media\'s own cache file is not room the next one '
        'lacks', () async {
      // Binge watching, which is what makes this the ordinary case rather
      // than an edge. `open` asks before the `loadfile` because that is
      // where the answer is wanted, and the `loadfile` is what closes the
      // outgoing file's fd and gives its blocks back. Asked without them,
      // the reading is the floor and episode two is refused a cache file
      // on the strength of space it is about to be handed.
      final limit = MpvDiskCacheLimit(
        cacheState: () async => stateOf(480 * 1024 * 1024),
        freeBytes: () async => MpvDiskCacheLimit.leastFreeSpaceForCache,
        stopWritingToDisk: () async {},
      );
      await limit.check();

      // What episode one's file weighs is what comes back, and the limiter
      // is what knows it.
      expect(limit.fileCacheBytes, 480 * 1024 * 1024);

      // The reading `open` takes while those blocks are still allocated.
      const int freeWhileItIsStillHeld =
          MpvDiskCacheLimit.leastFreeSpaceForCache;
      expect(
        MpvDiskCacheLimit.hasRoomForCache(freeWhileItIsStillHeld),
        isFalse,
        reason: 'the reading on its own says the volume is at the line',
      );
      expect(
        MpvDiskCacheLimit.hasRoomForCache(
          freeWhileItIsStillHeld,
          heldByOutgoingCache: limit.fileCacheBytes,
        ),
        isTrue,
        reason: 'and it is at the line only because of what is leaving',
      );
    });

    test('a volume that is genuinely full is still refused', () {
      // The Chromecast again, with a media that never got a cache file at
      // all: nothing is coming back, so nothing changes. A limiter that
      // read no file answers 0, which is what keeps this true.
      expect(
        MpvDiskCacheLimit.hasRoomForCache(
          523 * 1024 * 1024,
          heldByOutgoingCache: 0,
        ),
        isFalse,
      );
      expect(
        MpvDiskCacheLimit(
          cacheState: () async => null,
          freeBytes: () async => null,
          stopWritingToDisk: () async {},
        ).fileCacheBytes,
        0,
      );
    });

    test('a cache too small to beat the memory one is not worth having', () {
      // Exactly at the server's floor plus the memory budget the file cache
      // replaces: room for a file, but not for a file that buys anything.
      expect(
        MpvDiskCacheLimit.leastFreeSpaceForCache,
        MpvDiskCacheLimit.serverFreeSpaceFloorBytes +
            MpvDiskCacheLimit.mediaKitMemoryCacheBytes,
      );
      // media_kit 1.2.6's `PlayerConfiguration.bufferSize`, which it sets
      // on both `demuxer-max-bytes` and `demuxer-max-back-bytes`.
      expect(MpvDiskCacheLimit.mediaKitMemoryCacheBytes, 32 * 1024 * 1024);
    });

    test('a volume nobody can measure gets one', () {
      expect(MpvDiskCacheLimit.hasRoomForCache(null), isTrue);
    });

    test('the device that found this gets none', () {
      // The owner's Chromecast, mid-film: 4.0G total, 3.4G used, 523M
      // available, and the file being streamed is 1.4 GB. A player cache of
      // half a gigabyte is the second writer that volume has no room for --
      // and the 11 MB it does have above the server's floor is less than
      // the memory cache a file would be traded for.
      const int availableOnTheChromecast = 523 * 1024 * 1024;

      expect(
        MpvDiskCacheLimit.hasRoomForCache(availableOnTheChromecast),
        isFalse,
      );
    });
  });

  group('the two budgets on one device', () {
    test('the player stops at the same line the server\'s cleaner does', () {
      // The one number a reader can check against `df`, and what it means:
      // the two caches share the room above it instead of each taking a
      // budget on top of the other. The server's cleaner caps its torrent
      // cache at `occupied + available - floor`; the player stops at the
      // same line. They have to be the same number, and the server's is the
      // source of truth (`CACHE_FREE_SPACE_FLOOR`,
      // `server/src/cache_cleaner.rs` at the pinned rev).
      //
      // It is not a promise that Available never goes below it. The cleaner
      // deletes and cannot throttle, so librqbit writes the film through
      // the floor to ENOSPC between passes -- the failure this whole change
      // came from -- and offline downloads are admitted against
      // `PIN_FREE_SPACE_MARGIN` (500 MiB), a different constant, into a
      // directory the cleaner never walks.
      expect(MpvDiskCacheLimit.serverFreeSpaceFloorBytes, 512 * 1024 * 1024);
    });

    test('the player\'s own budget fits inside the allowance, not on top of '
        'it', () {
      // The two are equal today, which is the case worth pinning: on a
      // volume with exactly one budget's worth of room above the floor, the
      // player may take all of it and the server is then capped at nothing
      // rather than at another 512 MiB. A player limit larger than the
      // floor would mean a device could be a whole budget short of the
      // number above before either limiter noticed.
      expect(
        MpvDiskCacheLimit.defaultLimitBytes,
        lessThanOrEqualTo(MpvDiskCacheLimit.serverFreeSpaceFloorBytes),
      );
    });
  });

  group('what the app\'s players hold together', () {
    /// A limiter for [owner] reading a file of [bytes], over [holdings],
    /// with a cap of 1000 on a volume that is not the question.
    (MpvDiskCacheLimit, List<void>) playerHolding(
      MpvCacheHoldings holdings,
      Object owner,
      int bytes,
    ) {
      final stopped = <void>[];
      return (
        MpvDiskCacheLimit(
          cacheState: () async => stateOf(bytes),
          freeBytes: () async => 10000,
          stopWritingToDisk: () async => stopped.add(null),
          holdings: holdings,
          owner: owner,
          limitBytes: 1000,
          floorBytes: 100,
        ),
        stopped,
      );
    }

    test('the cap is on the sum, not on each player\'s own file', () async {
      // How 512 MiB became 928 MB. A hand-over runs two demuxers at once
      // and each limiter is right about its own media throughout, so a cap
      // that is only ever asked one media at a time never fires -- while
      // the device fills up at the sum of them.
      final holdings = MpvCacheHoldings();
      final first = Object();
      final second = Object();
      final (one, stoppedOne) = playerHolding(holdings, first, 600);
      final (two, stoppedTwo) = playerHolding(holdings, second, 600);

      await one.check();
      expect(stoppedOne, isEmpty, reason: '600 of 1000, and alone in it');
      expect(holdings.heldBytes, 600);

      await two.check();
      expect(holdings.heldBytes, 1200, reason: 'one number, both players');
      expect(
        stoppedTwo,
        hasLength(1),
        reason: 'the second file is what takes the app over its own cap',
      );
    });

    test('a player is not counted against itself, and a released one is not '
        'counted at all', () async {
      final holdings = MpvCacheHoldings();
      final first = Object();
      final second = Object();
      final (one, _) = playerHolding(holdings, first, 600);
      final (two, _) = playerHolding(holdings, second, 300);
      await one.check();
      await two.check();

      // What `MediaKitEngine.open` asks: the file it is about to be given
      // is not among the reasons to refuse it one.
      expect(holdings.heldByOthers(first), 300);
      expect(holdings.heldByOthers(second), 600);
      expect(holdings.openFiles, 2);

      // A teardown that closed the fd, or one that failed to: either way
      // the app stops claiming an allowance for a player that is gone.
      holdings.release(first);
      expect(holdings.heldBytes, 300);
      expect(holdings.openFiles, 1);
    });

    test('a new media is refused a cache file the app cannot fund', () {
      // The volume has room and the answer is still no: those blocks are
      // already out of the free reading, so plenty free means only that
      // somebody else is holding the allowance rather than that there is
      // one to give.
      expect(
        MpvDiskCacheLimit.hasRoomForCache(
          10 * 1024 * 1024 * 1024,
          heldByOtherPlayers: MpvDiskCacheLimit.defaultLimitBytes,
        ),
        isFalse,
      );
      // And with nothing else holding anything, nothing changes: this is
      // the state every single-player session is in.
      expect(
        MpvDiskCacheLimit.hasRoomForCache(10 * 1024 * 1024 * 1024),
        isTrue,
      );
    });
  });

  group('the size of mpv\'s own budget', () {
    test('the size it holds to is one a television can spare', () {
      // Not asserted exactly, only that it is on the right side of both
      // walls: far more than the 64 MiB of memory cache it replaces, and
      // well under a gigabyte on a box whose whole storage is 8 GB and
      // whose torrent data shares it. It counts bytes demuxed, not minutes
      // played -- mpv reads ahead at the link's rate, so this much of the
      // 2.3 Mbps film is written early rather than half way through.
      expect(
        MpvDiskCacheLimit.defaultLimitBytes,
        greaterThan(128 * 1024 * 1024),
      );
      expect(
        MpvDiskCacheLimit.defaultLimitBytes,
        lessThanOrEqualTo(1024 * 1024 * 1024),
      );
    });
  });
}
