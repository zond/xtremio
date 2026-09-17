import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/core.dart';

/// Keeps the embedded server's `diagnosticsTrace` equal to
/// [AppPrefs.verboseDiagnostics], for as long as the app is running.
///
/// The server's half of "Verbose diagnostics": its retention trace -- one
/// line per file every ten seconds on what its cache decided and why, and
/// the line on what a file's reads look like -- is behind a setting of its
/// own, because it is in the server's log filter and nothing else can
/// reach that. The player's half ([MediaKitEngine.verboseLog]) reads the
/// same preference directly when a player opens.
///
/// One of these for the whole app, built by `XtremioApp`, on the pattern
/// of `IdleSharingPolicy` and for the same reason: nothing else in the app
/// writes this key, so the server's belief has one author. It pushes as
/// soon as it starts -- the server's default is off and so is the
/// preference's, but a viewer who turned it on has to be heard before the
/// first pass that would have said something -- and again whenever the
/// preference moves.
class DiagnosticsTraceSync {
  DiagnosticsTraceSync({required this.prefs, required this.server});

  /// The server settings key this writes (`POST /settings`).
  static const String serverKey = 'diagnosticsTrace';

  static const String title = 'Verbose logging';

  /// What turning it on buys, on the tile, in one line: the two logs it
  /// opens up. (A longer version said why and when; on a settings tile
  /// about verbosity that read as a joke.)
  static const String description =
      'Adds server cache decisions and player stream logs to the report.';

  /// The viewer's choice, and what tells this when it changes.
  final AppPrefs prefs;

  /// Where the answer goes: one key of the embedded server's settings.
  final ServerSettingsWriter server;

  /// What the server was last told, or null when it has been told nothing
  /// (or when the telling failed, so the next change tries again).
  bool? _sent;

  /// The writes so far, chained so the server is never told two things at
  /// once. Also what a test waits on to see what was written.
  Future<void> _writes = Future<void>.value();

  bool _stopped = false;

  /// Starts watching. Safe to call after [dispose]; it does nothing then.
  void start() {
    if (_stopped) return;
    prefs.addListener(_reconsider);
    _reconsider();
  }

  /// Everything written so far has landed. For tests; nothing in the app
  /// waits on this.
  @visibleForTesting
  Future<void> get settled => _writes;

  void _reconsider() {
    if (_stopped) return;
    final wanted = prefs.verboseDiagnostics;
    if (wanted == _sent) return;
    _sent = wanted;
    _writes = _writes.then((_) => _push(wanted));
  }

  Future<void> _push(bool on) async {
    try {
      await server.updateSettings({serverKey: on});
    } catch (error) {
      // A server that is not up yet, or that refused: not recorded as
      // sent, so the next change writes it again. Nothing retries on its
      // own -- the server persists the last value it was told, so the
      // cost of a lost push is one run at the previous setting.
      if (kDebugMode) debugPrint('diagnostics trace not applied: $error');
      if (_sent == on) _sent = null;
    }
  }

  /// Stops watching. The server is left holding whatever it was last told,
  /// which it also persisted; the next start pushes the preference again.
  void dispose() {
    if (_stopped) return;
    _stopped = true;
    prefs.removeListener(_reconsider);
  }
}
