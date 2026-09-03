import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/core.dart';
import 'features/downloads/destination.dart';
import 'features/player/playback_engine.dart';
import 'shell/device_profile.dart';
import 'shell/root_shell.dart';
import 'shell/route_log_observer.dart';
import 'shell/tv_density.dart';

/// Builds a [PlaybackEngine] for a player with the profile's
/// `hardwareDecoding`; [MediaKitEngine.new] fits.
typedef PlaybackEngineBuilder = PlaybackEngine Function({
  required bool hardwareDecoding,
});

/// Root of the Xtremio application.
///
/// The UI is a thin layer: discovery/library/addon logic comes from
/// `stremio-core` (Rust, over FFI, reached through [core]) and playback
/// bytes from an embedded `stream-server`, with `media_kit`/libmpv doing the
/// actual video.
///
/// Account housekeeping lives here, as stremio-web does it on window focus:
/// `PullAddonsFromAPI` once at startup regardless of login (it upgrades the
/// bundled official addons for an anonymous profile), and for a signed-in
/// profile also `PullUserFromAPI`, `SyncLibraryWithAPI` and
/// `PullNotifications` — at startup, after `UserAuthenticated`, and when the
/// app resumes after having been inactive, hidden or paused.
///
/// It also supplies the [PlaybackScope]: every player gets an engine from
/// [engineBuilder] ([MediaKitEngine.new] by default) configured from
/// `profile.settings.hardwareDecoding` as it stands when that player opens.
///
/// And the [DeviceScope]: [device] is what start-up detected
/// ([DeviceProfile.detect] in `main.dart`), so every screen can ask
/// `DeviceScope.isTv(context)` for the remote-driven layout.
///
/// It holds the app's one navigator key too, so something outside the widget
/// tree — a `stremio://` deep link arriving from the platform — can push a
/// route.
///
/// And the [DownloadsScope]: one [DownloadsClient] for the whole app, since
/// the Rust side keeps a single progress sink. The app builds a
/// [RustDownloadsClient] unless [downloads] hands it one, and disposes only
/// the one it built itself. Start-up also settles where the files go, once:
/// on a platform with a default of its own ([defaultDestination]) and no
/// destination configured yet, the server is pointed there
/// ([applyDefaultDestination]).
class XtremioApp extends StatefulWidget {
  const XtremioApp({
    super.key,
    required this.core,
    this.initInfo,
    this.engineBuilder,
    this.downloads,
    this.defaultDestination = platformDefaultDestination,
    this.device = DeviceProfile.fallback,
  });

  final CoreClient core;
  final CoreInitInfo? initInfo;

  /// The offline downloads, for tests that want a fake. Read once, when the
  /// app comes up: handing over a different client later changes nothing.
  final DownloadsClient? downloads;

  /// Where the downloads go on a first run: on Android the app's external
  /// files directory, which the OS does not purge, and null -- leave it to
  /// the server -- everywhere else. Applied only while the registry says
  /// the question is still open, so an answer already given (including
  /// "back with the cache", which is a null `downloadsDir`) is never
  /// overridden.
  final DownloadDestinationResolver defaultDestination;

  /// The device the app runs on; tests put the app on a TV through it.
  final DeviceProfile device;

  /// Builds the [PlaybackEngine] for one player. Tests inject a recorder
  /// here to see what the app asked for without touching libmpv.
  final PlaybackEngineBuilder? engineBuilder;

  @override
  State<XtremioApp> createState() => _XtremioAppState();
}

class _XtremioAppState extends State<XtremioApp> {
  /// The one navigator, reachable without a [BuildContext]: a deep link is
  /// delivered by the platform, not by a widget, so it has nothing else to
  /// navigate with.
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();

  late final AppLifecycleListener _lifecycle;
  StreamSubscription<CoreEvent>? _events;

  /// The one downloads client, and whether disposing it is ours to do: a
  /// client handed in belongs to whoever handed it in.
  late final DownloadsClient _downloads;
  late final bool _ownsDownloads;

  /// The `ctx` field, for the settings a new player is created with.
  /// Created in [initState] so its first pull is in flight from start-up;
  /// created lazily it would come into being — empty — inside the first
  /// player's `_createEngine`, which would then see the defaults.
  late final CoreFieldNotifier _ctx;

  /// The app left the resumed state at some point, so the next resume is a
  /// real return to the foreground. Without this the first `resumed` a
  /// platform reports after launch would repeat the startup pull.
  bool _away = false;

  @override
  void initState() {
    super.initState();
    _ctx = CoreFieldNotifier(widget.core, CoreField.ctx);
    _ownsDownloads = widget.downloads == null;
    _downloads = widget.downloads ?? RustDownloadsClient();
    _lifecycle = AppLifecycleListener(
      onExitRequested: _onExitRequested,
      onResume: _onResume,
      onInactive: _onAway,
      onHide: _onAway,
      onPause: _onAway,
    );
    _events = widget.core.events.listen(_onEvent);
    unawaited(
      applyDefaultDestination(_downloads, resolve: widget.defaultDestination),
    );
    _startupHousekeeping();
  }

  Future<void> _startupHousekeeping() async {
    // Regardless of login: upgrades the bundled official addons.
    await _dispatch(CoreActions.pullAddonsFromAPI());
    if (await _isLoggedIn()) await _pullAccount(addons: false);
  }

  void _onAway() => _away = true;

  Future<void> _onResume() async {
    if (!_away) return;
    _away = false;
    if (await _isLoggedIn()) await _pullAccount();
  }

  void _onEvent(CoreEvent event) {
    if (event is RuntimeCoreEvent && event.name == 'UserAuthenticated') {
      _pullAccount();
    }
  }

  /// What stremio-web dispatches on focus for a signed-in profile, in its
  /// order; [addons] false when `PullAddonsFromAPI` just went out.
  Future<void> _pullAccount({bool addons = true}) async {
    if (addons) await _dispatch(CoreActions.pullAddonsFromAPI());
    await _dispatch(CoreActions.pullUserFromAPI());
    await _dispatch(CoreActions.syncLibraryWithAPI());
    await _dispatch(CoreActions.pullNotifications());
  }

  ProfileSettings get _settings {
    final ctx = _ctx.value;
    return ctx == null
        ? const ProfileSettings({})
        : ProfileState.fromCtx(ctx).settings;
  }

  PlaybackEngine _createEngine() =>
      (widget.engineBuilder ?? MediaKitEngine.new)(
        hardwareDecoding: _settings.hardwareDecoding,
      );

  Future<bool> _isLoggedIn() async {
    try {
      final ctx = await widget.core.state(CoreField.ctx);
      return ProfileState.fromCtx(ctx).isLoggedIn;
    } catch (error) {
      if (kDebugMode) debugPrint('ctx unavailable for housekeeping: $error');
      return false;
    }
  }

  Future<void> _dispatch(CoreAction action) async {
    if (!mounted) return;
    try {
      await widget.core.dispatch(action);
    } catch (error) {
      // Only the action's name: Ctx action args can carry credentials.
      if (kDebugMode) {
        debugPrint('housekeeping ${action.action['args']?['action']}: $error');
      }
    }
  }

  Future<AppExitResponse> _onExitRequested() async {
    if (kDebugMode) debugPrint('exit requested by platform');
    // Stop the engine and the embedded server before the process goes away
    // so library progress is flushed and the port is released.
    try {
      await widget.core.shutdown();
    } catch (_) {
      // Exiting anyway; nothing useful to do with the failure here.
    }
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    _events?.cancel();
    // Lets go of the progress stream the client holds open on the Rust side.
    if (_ownsDownloads) _downloads.dispose();
    _ctx.dispose();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF7B5BF5),
      brightness: Brightness.dark,
    );
    final isTv = widget.device.isTv;
    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: const Color(0xFF0E0B16),
    );

    return DeviceScope(
      profile: widget.device,
      child: CoreScope(
        client: widget.core,
        initInfo: widget.initInfo,
        child: DownloadsScope(
          client: _downloads,
          child: PlaybackScope(
            createEngine: _createEngine,
            child: MaterialApp(
              title: 'Xtremio',
              debugShowCheckedModeBanner: false,
              navigatorKey: _navigator,
              theme: isTv ? TvDensity.theme(theme) : theme,
              builder: isTv ? TvMediaQuery.builder : null,
              navigatorObservers: [if (kDebugMode) RouteLogObserver()],
              home: const RootShell(),
            ),
          ),
        ),
      ),
    );
  }
}
