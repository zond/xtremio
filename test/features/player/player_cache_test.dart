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
    /// [MpvDiskCacheLimit.check], holding the last once they run out.
    (MpvDiskCacheLimit, List<void>) limiterOver(List<String?> readings) {
      final stopped = <void>[];
      var reading = 0;
      final limit = MpvDiskCacheLimit(
        cacheState: () async =>
            readings[reading < readings.length
                ? reading++
                : readings.length - 1],
        stopWritingToDisk: () async => stopped.add(null),
        limitBytes: 1000,
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
          stopWritingToDisk: () async => stopped.add(null),
          limitBytes: 1000,
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
