import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'core/core.dart';
import 'features/addons/addon_health_client.dart';
import 'features/cast/cast_client.dart';
import 'features/sharing/sharing_activity.dart';
import 'shell/deep_link.dart';
import 'shell/device_profile.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before anything that could fail: an unhandled error is the one line a
  // report most needs, and until the core is up there is nowhere to put it
  // (`DiagnosticsLog` drops what it cannot write).
  captureUnhandledErrors();
  // libmpv must be loaded before the first Player is constructed.
  MediaKit.ensureInitialized();
  // Once, before the first frame: whether this is a TV decides the layout
  // of every screen, and the answer never changes while the app runs.
  final device = await DeviceProfile.detect();
  runApp(XtremioBootstrap(device: device));
}

/// Boots the core: the client to use and what its init reported.
typedef CoreBoot = Future<(CoreClient, CoreInitInfo)> Function();

/// Where the core and the embedded server keep what they write: the
/// server's torrent data above all, since that is the one root everything a
/// torrent puts on this device shares -- the streaming cache and the kept
/// downloads alike.
///
/// It is the *default*. The server persists a `cacheRoot` of its own once
/// anything sets one, and that wins from then on; this is what a device
/// with none gets, and it is where Settings' "Server storage" starts from.
///
/// **On Android that must not be the app cache directory.** `getCacheDir()`
/// is the system's to reclaim whenever it wants room, and with one root
/// there is nowhere else for a kept download to be -- half a film reclaimed
/// mid-download is not a download. The app's own external files directory
/// is left alone until the app is uninstalled, is world-readable over adb
/// (which is how a download is looked at from a workstation), and needs no
/// permission at all on `minSdk` 24. Everywhere else the cache directory is
/// the right place and there is nothing to choose; and a device with no
/// external storage at all falls back to it too, because a purgeable root
/// still beats no server.
@visibleForTesting
Future<Directory> dataDirectory({
  required bool isAndroid,
  Future<Directory?> Function() externalFiles = getExternalStorageDirectory,
  Future<Directory> Function() appCache = getApplicationCacheDirectory,
}) async => (isAndroid ? await externalFiles() : null) ?? await appCache();

/// Loads the Rust library and boots stremio-core (with the embedded
/// stream-server) before showing the app; shows the failure otherwise.
///
/// It is also where the process-wide ceilings go that must be in place
/// before the first screen draws: the image cache's ([imageCacheCeilingBytes]).
///
/// Everything else [XtremioApp] can be handed -- the clients it would
/// otherwise build over FFI, and how a player's engine is made -- passes
/// through unchanged, defaulting to what [XtremioApp] itself defaults to.
/// [main] sets only [device]; a test that mounts the bootstrap hands in
/// the same fakes it would hand the app, so that nothing under it reaches
/// for a Rust library the test never loaded.
class XtremioBootstrap extends StatefulWidget {
  const XtremioBootstrap({
    super.key,
    this.device = DeviceProfile.fallback,
    this.boot = bootCore,
    this.engineBuilder,
    this.downloads,
    this.cast,
    this.prefs,
    this.addonHealth = const RustAddonHealthClient(),
    this.deepLinks,
    this.serverSettings = const ServerClient(),
    this.sharingActivity = const RustSharingActivityClient(),
  });

  /// What [DeviceProfile.detect] found, handed to [XtremioApp].
  final DeviceProfile device;

  /// What decoded images Flutter may keep for pictures no widget is showing:
  /// 32 MiB, in place of the framework's 100 MiB (`ImageCache`, 1000
  /// images / 100 MiB).
  ///
  /// Every poster, backdrop and episode thumbnail is decoded at the box it
  /// is drawn in (`cacheWidth`), so no single picture is large any more; a
  /// catalog is. The Board alone walks a few hundred posters past the
  /// viewer, and Flutter keeps each one until the cache is full -- and the
  /// default is full at 100 MiB. On the owner's Chromecast with Google TV
  /// (2 GB of RAM for the whole system, about 650 MB of it ever available)
  /// Android's low-memory killer took the app twice in one day at
  /// 311-379 MB resident the moment it went to the background, and that
  /// latent 100 MiB is the second-largest single number in the
  /// attribution after the torrent engine. What the ceiling costs is a
  /// re-decode when a row is scrolled back to, from a bounded-size source
  /// that is already on disk in the HTTP cache: cheap, and visible only as
  /// a poster fading in a second time.
  ///
  /// One number on every device rather than a television's own. A phone
  /// decodes at three times the density, so 32 MiB there is a few dozen
  /// posters rather than a hundred, which is still more than one screen
  /// shows; nothing this app does on a desktop needs a bigger cache either.
  /// If re-decoding on a phone ever shows, raise it through the device
  /// profile rather than here.
  ///
  /// The other half is `XtremioApp`, which empties the cache when the app
  /// goes to the background: a ceiling bounds what a foreground app holds,
  /// and the kill is of a background one.
  static const int imageCacheCeilingBytes = 32 * 1024 * 1024;

  /// How the core comes up; [bootCore] (the Rust library) unless a test
  /// hands in a fake.
  final CoreBoot boot;

  /// Passed through to [XtremioApp.engineBuilder].
  final PlaybackEngineBuilder? engineBuilder;

  /// Passed through to [XtremioApp.downloads].
  final DownloadsClient? downloads;

  /// Passed through to [XtremioApp.cast].
  final CastClient? cast;

  /// Passed through to [XtremioApp.prefs].
  final AppPrefs? prefs;

  /// Passed through to [XtremioApp.addonHealth].
  final AddonHealthClient? addonHealth;

  /// Passed through to [XtremioApp.deepLinks].
  final DeepLinkSource? deepLinks;

  /// Passed through to [XtremioApp.serverSettings].
  final ServerSettingsWriter serverSettings;

  /// Passed through to [XtremioApp.sharingActivity].
  final SharingActivityClient sharingActivity;

  /// Loads the Rust library and initializes stremio-core with the app's
  /// support and cache directories.
  static Future<(CoreClient, CoreInitInfo)> bootCore() async {
    await RustLib.init();
    // The ring exists as soon as the library does: from here the Dart side
    // logs into the same one the Rust side fills.
    DiagnosticsLog.useCoreRing();
    final client = RustCoreClient();
    final Directory support = await getApplicationSupportDirectory();
    final info = await client.init(
      support: support,
      cache: await dataDirectory(isAndroid: Platform.isAndroid),
    );
    return (client, info);
  }

  @override
  State<XtremioBootstrap> createState() => _XtremioBootstrapState();
}

class _XtremioBootstrapState extends State<XtremioBootstrap> {
  late final Future<(CoreClient, CoreInitInfo)> _boot = widget.boot();

  @override
  void initState() {
    super.initState();
    // Before the first image resolves: the framework's default is the
    // ceiling until somebody says otherwise, and the splash is the last
    // frame with no picture on it.
    PaintingBinding.instance.imageCache.maximumSizeBytes =
        XtremioBootstrap.imageCacheCeilingBytes;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _boot,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _BootFailed(error: snapshot.error!);
        }
        final data = snapshot.data;
        if (data == null) return const _BootSplash();
        return XtremioApp(
          core: data.$1,
          initInfo: data.$2,
          device: widget.device,
          engineBuilder: widget.engineBuilder,
          downloads: widget.downloads,
          cast: widget.cast,
          prefs: widget.prefs,
          addonHealth: widget.addonHealth,
          deepLinks: widget.deepLinks,
          serverSettings: widget.serverSettings,
          sharingActivity: widget.sharingActivity,
        );
      },
    );
  }
}

class _BootSplash extends StatelessWidget {
  const _BootSplash();

  @override
  Widget build(BuildContext context) => const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: ColoredBox(
      color: Color(0xFF0E0B16),
      child: Center(child: CircularProgressIndicator()),
    ),
  );
}

class _BootFailed extends StatelessWidget {
  const _BootFailed({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 64),
              const SizedBox(height: 16),
              const Text('Xtremio could not start its core'),
              const SizedBox(height: 8),
              SelectableText('$error', textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    ),
  );
}
