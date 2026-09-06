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
    test('the player never writes into the floor the server holds', () {
      // The one number a reader can check against `df`: Available on the
      // app's volume never goes below this because of anything the app
      // writes. The server's cleaner caps its torrent cache at
      // `occupied + available - floor`; the player stops at the same line.
      // They have to be the same number, and the server's is the source of
      // truth (`CACHE_FREE_SPACE_FLOOR`, `server/src/cache_cleaner.rs` at
      // the pinned rev).
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
