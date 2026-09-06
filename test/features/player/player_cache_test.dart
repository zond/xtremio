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
  const String directory = '/data/user/0/dev.zond.xtremio/cache/mpv';

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
}
