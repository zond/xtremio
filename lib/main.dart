import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'core/core.dart';
import 'features/addons/addon_health_client.dart';
import 'features/cast/cast_client.dart';
import 'features/downloads/destination.dart';
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

/// Loads the Rust library and boots stremio-core (with the embedded
/// stream-server) before showing the app; shows the failure otherwise.
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
    this.defaultDestination = platformDefaultDestination,
    this.serverSettings = const ServerClient(),
    this.sharingActivity = const RustSharingActivityClient(),
  });

  /// What [DeviceProfile.detect] found, handed to [XtremioApp].
  final DeviceProfile device;

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

  /// Passed through to [XtremioApp.defaultDestination].
  final DownloadDestinationResolver defaultDestination;

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
    final Directory cache = await getApplicationCacheDirectory();
    final info = await client.init(support: support, cache: cache);
    return (client, info);
  }

  @override
  State<XtremioBootstrap> createState() => _XtremioBootstrapState();
}

class _XtremioBootstrapState extends State<XtremioBootstrap> {
  late final Future<(CoreClient, CoreInitInfo)> _boot = widget.boot();

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
          defaultDestination: widget.defaultDestination,
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
