import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/core.dart';
import 'features/addons/addon_details_screen.dart';
import 'features/cast/cast_client.dart';
import 'features/cast/google_cast_client.dart';
import 'features/downloads/destination.dart';
import 'features/player/playback_engine.dart';
import 'shell/deep_link.dart';
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
/// route. Deep links come from [deepLinks]: a `stremio://host/manifest.json`
/// link (what every addon site's Install button produces, stremio-addons.net
/// included) opens that addon's [AddonDetailsScreen] with the URL passed
/// through untouched, and *nothing else* — a link never installs an addon,
/// the Install button on that screen does. A link that arrives while a
/// details screen is already up replaces it instead of stacking a second
/// screen over the same core field.
///
/// And the [PrefsScope]: one [AppPrefs] for the whole app, read from the
/// Rust side's preferences file at start-up — before any screen that reads
/// one can be on the stack, so the first list is already laid out the way
/// it was left — and written through on every change.
///
/// And the [CastScope]: one [CastClient] for the whole app, because the Cast
/// SDK is a process-wide singleton behind it. Off Android and iOS the real
/// one reports `isSupported` false and is never asked anything else, so it
/// is built everywhere and costs nothing where it cannot work. The LAN media
/// listener half of the scope is left to its default, the embedded server's
/// own.
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
    this.cast,
    this.prefs,
    this.deepLinks,
    this.defaultDestination = platformDefaultDestination,
    this.device = DeviceProfile.fallback,
  });

  final CoreClient core;
  final CoreInitInfo? initInfo;

  /// The offline downloads, for tests that want a fake. Read once, when the
  /// app comes up: handing over a different client later changes nothing.
  final DownloadsClient? downloads;

  /// The Cast sender, for tests that want a fake. Read once, when the app
  /// comes up, like [downloads].
  final CastClient? cast;

  /// The app's own preferences, for tests that want a fake client behind
  /// them. Read once, when the app comes up, like [downloads].
  final AppPrefs? prefs;

  /// Where `stremio://` links arrive from; tests hand in a fake instead of
  /// the platform's own ([AppLinksDeepLinkSource]).
  final DeepLinkSource? deepLinks;

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

  /// What is on the navigator's stack, so a deep link can tell whether it is
  /// landing on top of a details screen it should replace.
  final _RouteStackObserver _routes = _RouteStackObserver();

  late final AppLifecycleListener _lifecycle;
  StreamSubscription<CoreEvent>? _events;
  StreamSubscription<String>? _links;

  /// The one downloads client, and whether disposing it is ours to do: a
  /// client handed in belongs to whoever handed it in.
  late final DownloadsClient _downloads;
  late final bool _ownsDownloads;

  /// The one preferences value, and whether disposing it is ours to do —
  /// the same rule as [_downloads].
  late final AppPrefs _prefs;
  late final bool _ownsPrefs;

  /// The one Cast sender, and the same rule again.
  late final CastClient _cast;
  late final bool _ownsCast;

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
    _ownsCast = widget.cast == null;
    _cast = widget.cast ?? GoogleCastClient();
    _ownsPrefs = widget.prefs == null;
    _prefs = widget.prefs ?? AppPrefs(client: const RustPrefsClient());
    unawaited(_prefs.load());
    _lifecycle = AppLifecycleListener(
      onExitRequested: _onExitRequested,
      onResume: _onResume,
      onInactive: _onAway,
      onHide: _onAway,
      onPause: _onAway,
    );
    _events = widget.core.events.listen(_onEvent);
    unawaited(_startDeepLinks());
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

  /// Subscribes to the platform's links and handles the one the app was
  /// launched with. A platform with no implementation (or a widget test
  /// without a fake) fails here and the app simply has no deep links.
  Future<void> _startDeepLinks() async {
    final links = widget.deepLinks ?? AppLinksDeepLinkSource();
    try {
      _links = links.links().listen(_onDeepLink, onError: _onDeepLinkError);
      final initial = await links.initialLink();
      // The stream may replay the launch link on its first listen; landing
      // twice on the same addon is a no-op, so no bookkeeping is needed.
      if (initial != null) _onDeepLink(initial);
    } catch (error) {
      _onDeepLinkError(error);
    }
  }

  void _onDeepLinkError(Object error) {
    if (kDebugMode) debugPrint('deep links unavailable: $error');
  }

  /// A `stremio://` link: the manifest URL in it opens that addon's details
  /// screen. Nothing is installed — that stays a press on the Install button
  /// there, so a link cannot add an addon behind the user's back.
  void _onDeepLink(String link) {
    final transportUrl = deepLinkAddonManifestUrl(link);
    if (transportUrl == null) {
      // The URL itself is not logged: an addon's manifest URL can carry the
      // user's API key for a debrid service.
      if (kDebugMode) {
        debugPrint('deep link ignored: ${Uri.tryParse(link)?.scheme} link');
      }
      return;
    }
    _openAddonDetails(transportUrl);
  }

  /// Pushes the details screen for [transportUrl], replacing a details
  /// screen already on top (the `addon_details` field holds one addon at a
  /// time, so two of these stacked would render each other's state) and
  /// doing nothing at all when that screen is already this addon's.
  void _openAddonDetails(String transportUrl, {bool retry = true}) {
    final navigator = _navigator.currentState;
    if (navigator == null) {
      // A link the app was launched with can arrive before the first build.
      if (retry) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _openAddonDetails(transportUrl, retry: false);
        });
      }
      return;
    }
    final top = _routes.top?.settings;
    if (top?.name != AddonDetailsScreen.routeName) {
      navigator.push(AddonDetailsScreen.route(transportUrl));
      return;
    }
    if (top?.arguments == transportUrl) return;
    // The replacement claims the field before the replaced screen is
    // disposed, so `SharedFieldOwnership` leaves it loaded.
    navigator.pushReplacement(AddonDetailsScreen.route(transportUrl));
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
    _links?.cancel();
    // Lets go of the progress stream the client holds open on the Rust side.
    if (_ownsDownloads) _downloads.dispose();
    if (_ownsCast) _cast.dispose();
    if (_ownsPrefs) _prefs.dispose();
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
          child: CastScope(
            client: _cast,
            child: PrefsScope(
              prefs: _prefs,
              child: PlaybackScope(
                createEngine: _createEngine,
                child: MaterialApp(
                  title: 'Xtremio',
                  debugShowCheckedModeBanner: false,
                  navigatorKey: _navigator,
                  theme: isTv ? TvDensity.theme(theme) : theme,
                  builder: isTv ? TvMediaQuery.builder : null,
                  navigatorObservers: [
                    _routes,
                    if (kDebugMode) RouteLogObserver(),
                  ],
                  home: const RootShell(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The navigator's stack, as the observers see it, so the app can ask what
/// is on top without a [BuildContext].
///
/// Every route counts, dialogs and popup menus included: a link arriving
/// while one of those is up is pushed over it rather than replacing it.
class _RouteStackObserver extends NavigatorObserver {
  final List<Route<dynamic>> _stack = [];

  Route<dynamic>? get top => _stack.isEmpty ? null : _stack.last;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _stack.add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _stack.remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _stack.remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (index < 0 || newRoute == null) return;
    _stack[index] = newRoute;
  }
}
