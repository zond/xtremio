import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/core.dart';
import 'features/addons/addon_details_screen.dart';
import 'features/addons/addon_health_client.dart';
import 'features/cast/cast_client.dart';
import 'features/cast/google_cast_client.dart';
import 'features/downloads/downloads_screen.dart';
import 'features/downloads/downloads_service.dart';
import 'features/player/playback_engine.dart';
import 'features/player/player_screen.dart';
import 'features/diagnostics/diagnostics_trace.dart';
import 'features/sharing/idle_sharing.dart';
import 'features/drive/drive_native_pair_screen.dart';
import 'features/sharing/sharing_activity.dart';
import 'features/update/app_updates.dart';
import 'features/update/update_dialog.dart';
import 'shell/deep_link.dart';
import 'shell/device_profile.dart';
import 'shell/focus_theme.dart';
import 'shell/root_shell.dart';
import 'shell/route_log_observer.dart';
import 'shell/server_footprint.dart';
import 'shell/tv_density.dart';
import 'features/local/local_media.dart';
import 'widgets/focusable_tile.dart';

/// Builds a [PlaybackEngine] for a player with the profile's
/// `hardwareDecoding` and this device's "Verbose diagnostics"
/// ([AppPrefs.verboseDiagnostics], read as the player opens);
/// [MediaKitEngine.new] fits.
typedef PlaybackEngineBuilder = PlaybackEngine Function({
  required bool hardwareDecoding,
  required bool verboseLog,
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
/// And the [DriveAccountScope]: one [DriveAccount], which is this device's
/// Google Drive pairing — the refresh token in the platform's secure store,
/// the list of linked files in the preferences beside it. Loaded after the
/// preferences and not beside them, because half of what it answers is in
/// them: asked first it would report an unlinked device that is linked.
///
/// And the [CastScope]: one [CastClient] for the whole app, because the Cast
/// SDK is a process-wide singleton behind it. Off Android and iOS the real
/// one reports `isSupported` false and is never asked anything else, so it
/// is built everywhere and costs nothing where it cannot work. The LAN media
/// listener half of the scope is the embedded server's own, seen through
/// the [ServerFootprint], which has to hear it start and stop.
///
/// That [ServerFootprint] is what puts the embedded server into its lean
/// background footprint when the app is hidden or paused, and back when it
/// resumes -- except while a download is on its way, a cast is up or the
/// LAN listener serves one. It tells the server through [serverBackground].
///
/// On Android it also runs the downloads foreground service
/// ([DownloadsForegroundService]): while anything is unfinished the process
/// is held up by a `dataSync` service with an ongoing notification, so a
/// download goes on after the user leaves the app. Its notification opens
/// the [DownloadsScreen] from here, the way a deep link opens an addon.
///
/// It also decides whether the embedded server may keep a title in the
/// swarm between sessions ([IdleSharingPolicy]): one policy for the whole
/// app, because there is one server and one answer, started once the
/// preferences are in so that the first thing the server hears is the
/// viewer's own choice rather than the default it overrides.
///
/// And the [SharingScope], which is that policy and one
/// [SharingActivityMonitor] where the shell can reach them: what the light
/// in the corner is drawn from, and what its popup presses. The monitor
/// reads the embedded server over FFI ([RustSharingActivityClient]) unless
/// [sharingActivity] hands it a fake.
///
/// And the [DownloadsScope]: one [DownloadsClient] for the whole app, since
/// the Rust side keeps a single progress sink. The app builds a
/// [RustDownloadsClient] unless [downloads] hands it one, and disposes only
/// the one it built itself. Nothing here settles where the files go: there
/// is one torrent-data root, the embedded server's, named where the server
/// is started and moved from Settings.
///
/// And the [AppUpdatesScope]: one [AppUpdates], which looks for a newer
/// release once a day, [updateCheckDelay] after start-up, and offers it in
/// a dialog -- never while a player is on the stack: the look and the offer
/// both wait for the player to be gone. A build that does not check by
/// itself (`BuildIdentity.checksByItself`: debug and profile builds,
/// unstamped and modified ones) asks nothing then; Settings' "Check for
/// updates" asks for any build.
class XtremioApp extends StatefulWidget {
  const XtremioApp({
    super.key,
    required this.core,
    this.initInfo,
    this.engineBuilder,
    this.downloads,
    this.cast,
    this.prefs,
    this.drive,
    this.localMedia,
    this.addonHealth = const RustAddonHealthClient(),
    this.deepLinks,
    this.device = DeviceProfile.fallback,
    this.serverSettings = const ServerClient(),
    this.sharingActivity = const RustSharingActivityClient(),
    this.serverBackground = const RustServerBackgroundControl(),
    this.sharingHold = const RustIdleSharingHold(),
    this.updates,
  });

  /// How long after the preferences are in the daily update look waits:
  /// out of the way of start-up, and of a viewer who opened the app to
  /// press play.
  static const Duration updateCheckDelay = Duration(seconds: 20);

  /// The app's updates, for tests that want one over fakes. Read once,
  /// when the app comes up, like [downloads].
  final AppUpdates? updates;

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

  /// This device's Drive pairing, for tests that want one over fakes. Read
  /// once, when the app comes up, like [downloads]. The one built here
  /// reaches the platform's secure store, which a widget test has no
  /// implementation of — that reads as a device nobody has paired, which
  /// is what a test that has not paired anything wants.
  final DriveAccount? drive;

  /// This device's videos, for tests that want them over a fake source.
  /// Read once, like [drive]. The one built here reads the platform's own
  /// source ([platformLocalMediaSource]); a platform with none has no Local.
  final LocalMedia? localMedia;

  /// How the installed addons have been answering, for the Addons screen.
  /// Null shows no verdicts at all, which is what a test that does not care
  /// about them wants.
  final AddonHealthClient? addonHealth;

  /// Where `stremio://` links arrive from; tests hand in a fake instead of
  /// the platform's own ([AppLinksDeepLinkSource]).
  final DeepLinkSource? deepLinks;

  /// The device the app runs on; tests put the app on a TV through it.
  final DeviceProfile device;

  /// Where that policy is written, which is the embedded server's settings
  /// over FFI unless a test hands over a recorder.
  final ServerSettingsWriter serverSettings;

  /// Whether the embedded server is moving bytes over the connection while
  /// nothing is playing, for the status light ([SharingLight]): the
  /// server's own reading over FFI unless a test hands over a fake.
  final SharingActivityClient sharingActivity;

  /// Where the server's footprint is set ([ServerFootprint]): the embedded
  /// server over FFI unless a test hands over a recorder.
  final ServerBackgroundControl serverBackground;

  /// Where the idle-sharing hold of a phone or a tablet in the background
  /// is set ([IdleSharingPolicy]): the embedded server over FFI unless a
  /// test hands over a recorder.
  final IdleSharingHold sharingHold;

  /// Builds the [PlaybackEngine] for one player. Tests inject a recorder
  /// here to see what the app asked for without touching libmpv.
  final PlaybackEngineBuilder? engineBuilder;

  /// The theme the whole app runs under: the dark scheme it has always
  /// had, the ten-foot density on a television ([TvDensity.theme]), and on
  /// one the focus floor for [emphasis] ([FocusTheme.apply]).
  ///
  /// A static so that a widget test can mount one screen under exactly the
  /// theme the app would have given it. A test that builds its own
  /// `ThemeData` is testing a screen the viewer never sees, which for
  /// anything about focus is the whole question.
  static ThemeData themeFor({
    required bool isTv,
    FocusEmphasis emphasis = FocusEmphasis.standard,
  }) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF7B5BF5),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xFF0E0B16),
      // Every chip in the app is a pill: the selected fill, the outline and
      // the ink a press or a focus spreads are all drawn in the chip's
      // shape, and the focus ring a television puts round one is a stadium
      // too (`FocusMarked.stadium`). Material 3's own chip is a rectangle
      // with 8 px corners, which drew a squared-off fill inside the ring.
      chipTheme: const ChipThemeData(shape: StadiumBorder()),
    );
    return isTv ? FocusTheme.apply(TvDensity.theme(base), emphasis) : base;
  }

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

  /// Android's downloads foreground service, kept in step with that client.
  /// Built everywhere and inert off Android.
  late final DownloadsForegroundService _downloadsService;

  /// The one preferences value, and whether disposing it is ours to do —
  /// the same rule as [_downloads].
  late final AppPrefs _prefs;
  late final bool _ownsPrefs;

  /// The one Drive pairing, and the same rule again.
  late final DriveAccount _drive;
  late final bool _ownsDrive;
  late final LocalMedia? _localMedia;
  late final bool _ownsLocalMedia;

  /// The one Cast sender, and the same rule again.
  late final CastClient _cast;
  late final bool _ownsCast;

  /// The one sharing policy, built here and disposed here: it belongs to
  /// nobody else, since what it reads (the preferences, the device) is the
  /// app's own.
  late final IdleSharingPolicy _sharing;
  late final DiagnosticsTraceSync _trace;

  /// The one activity monitor, on the same terms: one server to ask, so one
  /// thing asking it. The shell turns it on and off with what is on screen.
  late final SharingActivityMonitor _activity;

  /// The one footprint decision, built here and disposed here, on the
  /// downloads client and the cast sender above.
  late final ServerFootprint _footprint;

  /// The `ctx` field, for the settings a new player is created with.
  /// Created in [initState] so its first pull is in flight from start-up;
  /// created lazily it would come into being — empty — inside the first
  /// player's `_createEngine`, which would then see the defaults.
  late final CoreFieldNotifier _ctx;

  /// The update look and offer: see [XtremioApp.updates].
  late final AppUpdates _updates;
  Timer? _updateTimer;

  /// An update step waiting for the player to leave the stack.
  VoidCallback? _afterPlayer;

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
    _downloadsService = DownloadsForegroundService(
      client: _downloads,
      openDownloads: _openDownloads,
    );
    unawaited(_downloadsService.start());
    _ownsCast = widget.cast == null;
    _cast = widget.cast ?? GoogleCastClient();
    _ownsPrefs = widget.prefs == null;
    _prefs = widget.prefs ?? AppPrefs(client: const RustPrefsClient());
    _ownsLocalMedia = widget.localMedia == null;
    _localMedia =
        widget.localMedia ??
        switch (platformLocalMediaSource(_prefs)) {
          null => null,
          final source => LocalMedia(prefs: _prefs, source: source),
        };
    _updates = widget.updates ?? AppUpdates(prefs: _prefs);
    _routes.onChanged = _onRoutesChanged;
    _ownsDrive = widget.drive == null;
    _drive =
        widget.drive ??
        DriveAccount(
          prefs: _prefs,
          secrets: const SecureStorageSecretStore(),
          grantSink: rustDriveGrantSink,
        );
    _sharing = IdleSharingPolicy(
      prefs: _prefs,
      server: widget.serverSettings,
      hold: widget.sharingHold,
      pausesInBackground: widget.device.isHandheld,
    );
    _trace = DiagnosticsTraceSync(prefs: _prefs, server: widget.serverSettings);
    _activity = SharingActivityMonitor(client: widget.sharingActivity);
    _footprint = ServerFootprint(
      server: widget.serverBackground,
      downloads: _downloads,
      cast: _cast,
    );
    unawaited(_footprint.start());
    // After the load, not beside it: a stored choice arriving a moment
    // later would otherwise be preceded by a push of the default it was
    // made to override, and the server would hear both.
    unawaited(
      _prefs.load().whenComplete(() {
        _sharing.start();
        _trace.start();
        // After the preferences and not beside them: the pairing's state
        // is half the secure store and half this file, and a read of one
        // half before the other is an answer about neither.
        unawaited(_drive.load());
        // A scan only where access is already there: the first launch asks
        // nothing, and the Local list is where the asking happens.
        unawaited(_localMedia?.refresh());
        // After the preferences, because the last look's time is one.
        _scheduleUpdateCheck();
      }),
    );
    _lifecycle = AppLifecycleListener(
      onExitRequested: _onExitRequested,
      onResume: _onResume,
      onInactive: _onAway,
      onHide: _onHidden,
      onPause: _onHidden,
    );
    _events = widget.core.events.listen(_onEvent);
    unawaited(_startDeepLinks());
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

  /// The pairing sessions a screen has been opened for this run: see
  /// [_openDrivePairing].
  final Set<String> _drivePairingsOpened = {};

  void _onDeepLinkError(Object error) {
    if (kDebugMode) debugPrint('deep links unavailable: $error');
  }

  /// A link the platform handed over. Two shapes reach this app and they
  /// are told apart by [drivePairingSessionOfLink] first, because it is the
  /// stricter test: an `https` URL on **this project's own domain**, claimed
  /// through `assetlinks.json` and a signing certificate Google checks.
  /// Everything else falls through to the `stremio://` reading below.
  void _onDeepLink(String link) {
    final session = drivePairingSessionOfLink(link);
    if (session != null) {
      _openDrivePairing(session);
      return;
    }
    _onAddonDeepLink(link);
  }

  /// The Drive pairing a television is waiting on, picked natively because
  /// this phone has the app — see [DriveNativePairScreen]. Pushed rather
  /// than replacing anything: the viewer came from their camera and will go
  /// back to their television, so what was on screen before should still be
  /// there afterwards.
  ///
  /// **Once per session, per run.** `app_links` hands the same link over
  /// more than once -- the launch link comes both as [DeepLinkSource.initialLink]
  /// and as the stream's first event, and a link can be replayed as the
  /// picker's activity hands back to this one. An addon link landing twice
  /// is a no-op; without this guard, a pairing link landing twice would push
  /// a second screen whose pick fails with "A pick is already on screen",
  /// over a first pick that already worked. A session is single-use on the
  /// service's side as well, so a link for one already opened is never
  /// worth a second screen.
  void _openDrivePairing(String session, {bool retry = true}) {
    if (_drivePairingsOpened.contains(session)) return;
    final navigator = _navigator.currentState;
    if (navigator == null) {
      // A link the app was *launched* with arrives before the first build,
      // which is the ordinary case here: the camera opened the app.
      if (retry) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _openDrivePairing(session, retry: false),
        );
      }
      return;
    }
    _drivePairingsOpened.add(session);
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => DriveNativePairScreen(sessionId: session),
      ),
    );
  }

  /// A `stremio://` link: the manifest URL in it opens that addon's details
  /// screen. Nothing is installed — that stays a press on the Install button
  /// there, so a link cannot add an addon behind the user's back.
  void _onAddonDeepLink(String link) {
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

  /// Brings up the Downloads screen: what the downloads notification does
  /// when it is tapped. A screen already on top is left where it is rather
  /// than stacked over, and a tap that arrives before the first build (the
  /// app was cold started by the notification) waits for the navigator.
  ///
  /// Over a running player the list only shows and removes
  /// ([DownloadsScreen.canPlay] false), as the player's own way in already
  /// has it: a title played from here would push a second [PlayerScreen]
  /// over the first, and both load the one shared `player` field -- the
  /// first, still mounted and still listening, opens the second's stream
  /// on its own engine too. Two mpv instances decoding at once is what a
  /// television box cannot afford, and the film silently replaced is what
  /// the viewer gets on any device. The whole stack is asked, not the top:
  /// a sheet or a dialog over the player is still over the player.
  void _openDownloads({bool retry = true}) {
    final navigator = _navigator.currentState;
    if (navigator == null) {
      if (retry) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _openDownloads(retry: false);
        });
      }
      return;
    }
    if (_routes.top?.settings.name == DownloadsScreen.routeName) return;
    navigator.push(
      DownloadsScreen.route(canPlay: !_routes.contains(PlayerScreen.routeName)),
    );
  }

  void _scheduleUpdateCheck() {
    if (!mounted) return;
    _updateTimer = Timer(
      XtremioApp.updateCheckDelay,
      () => _whenNotPlaying(_checkForUpdate),
    );
  }

  /// Runs [step] now, or once no player is on the stack: an update's look
  /// and its offer stay out of the way of playback, and a dialog over a
  /// film is the last thing a viewer wants.
  void _whenNotPlaying(VoidCallback step) {
    if (!mounted) return;
    if (_routes.contains(PlayerScreen.routeName)) {
      _afterPlayer = step;
      return;
    }
    step();
  }

  void _onRoutesChanged() {
    final step = _afterPlayer;
    if (step == null || _routes.contains(PlayerScreen.routeName)) return;
    _afterPlayer = null;
    // Not inside the navigator's own pop: a dialog is a push.
    WidgetsBinding.instance.addPostFrameCallback((_) => _whenNotPlaying(step));
  }

  Future<void> _checkForUpdate() async {
    final result = await _updates.checkIfDue();
    if (result is! UpdateAvailable) return;
    _whenNotPlaying(() {
      final context = _navigator.currentContext;
      if (context == null) return;
      unawaited(
        showUpdateDialog(context, updates: _updates, release: result.release),
      );
    });
  }

  void _onAway() => _away = true;

  /// The app is in the background (`hidden`, and `paused` after it on
  /// Android), as opposed to merely interrupted (`inactive`: a dialog, the
  /// notification shade, a call).
  ///
  /// A background app is judged on the memory it holds, not on what it is
  /// doing, and Android's low-memory killer takes the fattest process on
  /// the box first (see `XtremioBootstrap.imageCacheCeilingBytes` for the
  /// measurement). So what goes here is what a background app should not
  /// be holding.
  ///
  /// The decoded images are the part that is the app's own to drop, and
  /// they are dropped whole: everything no widget is showing goes
  /// (`ImageCache.clear`; a picture still on a screen in the stack is kept
  /// alive by that screen and comes back with it), and it is not done on
  /// `inactive`, where a settings dialog would cost the board its posters
  /// every time it opened. The ceiling that bounds the same cache in the
  /// foreground is `XtremioBootstrap.imageCacheCeilingBytes`.
  ///
  /// The server's part is its lean footprint ([ServerFootprint]), which
  /// decides for itself whether anything still needs the full one. And on a
  /// phone or a tablet the idle sharing is held off ([IdleSharingPolicy])
  /// until the app is back, while a download on its way goes on sharing.
  void _onHidden() {
    _away = true;
    PaintingBinding.instance.imageCache.clear();
    _footprint.appHidden();
    _sharing.appHidden();
  }

  Future<void> _onResume() async {
    _footprint.appResumed();
    _sharing.appResumed();
    if (!_away) return;
    _away = false;
    // A video deleted or added while the app was away -- from a file
    // manager, a download -- is in the Local list by the time it is looked
    // at again. Only where access is already there: this never asks.
    unawaited(_localMedia?.refresh());
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
        verboseLog: _prefs.verboseDiagnostics,
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
    _updateTimer?.cancel();
    _routes.onChanged = null;
    // Before the downloads client and the cast sender it listens to.
    _footprint.dispose();
    // Takes the foreground service down before the client it reports on:
    // without this side there is nobody to move the notification on.
    unawaited(_downloadsService.dispose());
    // Lets go of the progress stream the client holds open on the Rust side.
    if (_ownsDownloads) _downloads.dispose();
    if (_ownsCast) _cast.dispose();
    // Before the preferences it listens to, and without telling the server
    // anything: the app going away is what ends the sharing, and it ends
    // it by taking the server with it.
    _sharing.dispose();
    _trace.dispose();
    // Stops the polling with it; nothing else holds the timer.
    _activity.dispose();
    if (_ownsDrive) _drive.dispose();
    if (_ownsLocalMedia) _localMedia?.dispose();
    if (_ownsPrefs) _prefs.dispose();
    _ctx.dispose();
    _lifecycle.dispose();
    super.dispose();
  }

  /// [child] under [AlwaysShowFocus] on a television and untouched
  /// anywhere else: the pin is about a device with no pointer on it, and
  /// off one the app is one window among many that should mark focus the
  /// way the rest of the machine does.
  Widget _showingFocus({required bool isTv, required Widget child}) =>
      isTv ? AlwaysShowFocus(child: child) : child;

  @override
  Widget build(BuildContext context) {
    final isTv = widget.device.isTv;

    return DeviceScope(
      profile: widget.device,
      child: CoreScope(
        client: widget.core,
        initInfo: widget.initInfo,
        child: _AddonHealth(
          client: widget.addonHealth,
          child: DownloadsScope(
            client: _downloads,
            child: CastScope(
              client: _cast,
              lanMedia: _footprint,
              child: PrefsScope(
                prefs: _prefs,
                // Under the preferences, because it reads them: the list of
                // linked files and the dead-token flag are preferences, and
                // only the token itself is anywhere else.
                child: DriveAccountScope(
                  account: _drive,
                  child: LocalMediaScope(
                    media: _localMedia,
                    child: SharingScope(
                      policy: _sharing,
                      monitor: _activity,
                      child: AppUpdatesScope(
                        updates: _updates,
                        child: PlaybackScope(
                          createEngine: _createEngine,
                          // Under the [PrefsScope] rather than above it, so that
                          // the focus floor is rebuilt when the Bold switch is
                          // flipped: the scope is an [InheritedNotifier] and this
                          // builder reads it. Every other part of the theme is
                          // settled before the app is built.
                          child: Builder(
                            builder: (context) => _showingFocus(
                              isTv: isTv,
                              child: MaterialApp(
                                title: 'Xtremio',
                                debugShowCheckedModeBanner: false,
                                navigatorKey: _navigator,
                                theme: XtremioApp.themeFor(
                                  isTv: isTv,
                                  emphasis: FocusHighlight.emphasisOf(context),
                                ),
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
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The [AddonHealthScope], when there is a client to put in one. No client
/// is no scope at all rather than an empty one, so the Addons screen can
/// tell "nothing has answered yet" from "nothing can be asked".
class _AddonHealth extends StatelessWidget {
  const _AddonHealth({required this.client, required this.child});

  final AddonHealthClient? client;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final client = this.client;
    if (client == null) return child;
    return AddonHealthScope(client: client, child: child);
  }
}

/// The navigator's stack, as the observers see it, so the app can ask what
/// is on top without a [BuildContext].
///
/// Every route counts, dialogs and popup menus included: a link arriving
/// while one of those is up is pushed over it rather than replacing it.
class _RouteStackObserver extends NavigatorObserver {
  final List<Route<dynamic>> _stack = [];

  /// Told after a route leaves the stack.
  VoidCallback? onChanged;

  Route<dynamic>? get top => _stack.isEmpty ? null : _stack.last;

  /// Whether a route named [name] is anywhere on the stack, under whatever
  /// has been pushed over it since.
  bool contains(String name) =>
      _stack.any((route) => route.settings.name == name);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _stack.add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    onChanged?.call();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    onChanged?.call();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (index < 0 || newRoute == null) return;
    _stack[index] = newRoute;
  }
}
