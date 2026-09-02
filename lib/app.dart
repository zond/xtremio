import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/core.dart';
import 'shell/root_shell.dart';
import 'shell/route_log_observer.dart';

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
class XtremioApp extends StatefulWidget {
  const XtremioApp({super.key, required this.core, this.initInfo});

  final CoreClient core;
  final CoreInitInfo? initInfo;

  @override
  State<XtremioApp> createState() => _XtremioAppState();
}

class _XtremioAppState extends State<XtremioApp> {
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<CoreEvent>? _events;

  /// The app left the resumed state at some point, so the next resume is a
  /// real return to the foreground. Without this the first `resumed` a
  /// platform reports after launch would repeat the startup pull.
  bool _away = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: _onExitRequested,
      onResume: _onResume,
      onInactive: _onAway,
      onHide: _onAway,
      onPause: _onAway,
    );
    _events = widget.core.events.listen(_onEvent);
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
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF7B5BF5),
      brightness: Brightness.dark,
    );

    return CoreScope(
      client: widget.core,
      initInfo: widget.initInfo,
      child: MaterialApp(
        title: 'Xtremio',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: colorScheme,
          scaffoldBackgroundColor: const Color(0xFF0E0B16),
        ),
        navigatorObservers: [if (kDebugMode) RouteLogObserver()],
        home: const RootShell(),
      ),
    );
  }
}
