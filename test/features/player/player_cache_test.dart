import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';

/// What the app tells mpv about its own cache, which is now one sentence:
/// keep nothing on disk.
///
/// There is one cache on this device and it is the embedded server's --
/// named files, a configured limit, a free-space floor, a cleaner that
/// evicts, and survival across a crash. mpv's was the other one, and it was
/// everything the server's is not: `cache-on-disk=yes` is media_kit's own
/// default, and the file it makes is unlinked the moment it is created, so
/// no `du`, no `dumpsys diskstats` and no walk the server's cleaner
/// performs can find it. On the owner's Chromecast a single 90-second title
/// held 928 MB that way while three separate instruments reported the app
/// was using 46 MB, and nothing but killing the process gave it back.
///
/// So the app writes `cache-on-disk=no` and never writes it again. Every
/// stream now reaches the player through the server (`stream_proxy.dart`),
/// which is where a read-ahead worth keeping belongs.
///
/// The engine itself cannot be built without libmpv, so what is checked
/// here is the property set it applies. That the set really lands before
/// the first `loadfile` is the `await _overrides` in `MediaKitEngine.open`,
/// which no test on this side of libmpv can reach.
void main() {
  test('the player is told to keep nothing on disk', () {
    expect(MediaKitEngine.mpvOverrides['cache-on-disk'], 'no');
  });

  test('and nothing tells it where a cache file would go', () {
    // The directory was the other half of the file cache: without one, mpv
    // on Android cannot create the file at all. It is not set, it is not
    // asked for, and the app no longer has a cache directory of its own --
    // which is what makes "no disk cache" a property of the build rather
    // than of the device it happens to be running on.
    for (final property in const [
      'demuxer-cache-dir',
      'demuxer-cache-unlink-files',
    ]) {
      expect(
        MediaKitEngine.mpvOverrides.containsKey(property),
        isFalse,
        reason: '$property belongs to a cache this app does not keep',
      );
    }
  });

  test('while everything else the player sets is still set', () {
    expect(MediaKitEngine.mpvOverrides['network-timeout'], '300');
  });

  test('what it keeps instead is 32 MiB of memory, each way', () {
    // media_kit 1.2.6 puts `PlayerConfiguration.bufferSize` on both
    // `demuxer-max-bytes` and `demuxer-max-back-bytes`, so this is the
    // window ahead and the window behind, and the player's ceiling is twice
    // it. Written out rather than inherited: it is the only buffer the
    // player has now, and the only buffer should not be a dependency's
    // default.
    expect(MediaKitEngine.memoryCacheBytes, 32 * 1024 * 1024);
    expect(
      MediaKitEngine.playerConfiguration.bufferSize,
      MediaKitEngine.memoryCacheBytes,
    );
  });

  /// What a running libmpv did once the memory cache filled and there was
  /// nowhere else to put the payload -- which is every playback now.
  ///
  /// libmpv 0.41.0 over a 155 MB Matroska served from localhost through a
  /// 2,000,000 B/s throttle, both byte limits at media_kit's 32 MiB and the
  /// disk cache off. Seconds since the open, the file (frozen: the disk
  /// cache had been turned off at 15.02), the memory cache, and
  /// `raw-input-rate`.
  const List<(double, int, int, int)> afterTheMemoryCacheFills = [
    (20.28, 30102820, 12449600, 2000114),
    (30.29, 30102820, 34029568, 2000049),
    (31.30, 30102820, 34195232, 1588497),
    (33.30, 30102820, 34231696, 597759),
    (35.30, 30102820, 34267424, 18038),
    (44.32, 30102820, 34446240, 18471),
  ];

  test('a demuxer with nowhere to write stops racing ahead of the film', () {
    // The reading the memory budget is judged against, and the reason a
    // player that keeps nothing on disk is not a player that downloads
    // without bound. mpv fills media_kit's 32 MiB and then reads at what
    // playback consumes: 2,000,000 B/s down to 18,000 within a second of
    // the cache filling. On the owner's 32 Mbps link that is about eight
    // seconds after the write.
    //
    // It is also the shape of what a viewer gets: the window ahead is
    // whatever those bytes are worth -- about two minutes of a 2.3 Mbps
    // film -- and everything past it comes from the server, which is where
    // this design puts the read-ahead on purpose.
    final filled = afterTheMemoryCacheFills.last;
    expect(filled.$3, greaterThan(MediaKitEngine.memoryCacheBytes));
    expect(filled.$4, lessThan(2000000 ~/ 50));
    // And before it filled, the link was running at the full throttle: the
    // collapse is the cache filling up, not the server slowing down.
    expect(afterTheMemoryCacheFills.first.$4, greaterThan(2000000 - 1000));
  });
}
