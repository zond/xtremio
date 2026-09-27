import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/core.dart';
import '../features/cast/cast_client.dart';
import '../features/downloads/downloads_listings.dart';
import '../features/downloads/downloads_service.dart';
import '../src/rust/api/server.dart' as rust;

/// The one call that moves the embedded server's footprint, behind an
/// interface so a test can record what the app said.
abstract interface class ServerBackgroundControl {
  /// Puts the server into its lean background footprint (`true`) or back to
  /// full (`false`). Answers whether a server was running to be told.
  bool setBackground(bool background);
}

/// [ServerBackgroundControl] over FFI (`server_set_background`). A call
/// that fails is logged and answers "not told": a footprint is a saving,
/// never a reason to break a lifecycle change.
class RustServerBackgroundControl implements ServerBackgroundControl {
  const RustServerBackgroundControl();

  @override
  bool setBackground(bool background) {
    try {
      return rust.serverSetBackground(background: background);
    } catch (error) {
      DiagnosticsLog.warn(
        'server',
        'could not set the background footprint: ${error.runtimeType}',
      );
      return false;
    }
  }
}

/// Decides when the embedded server may go lean, and tells it.
///
/// Lean (stream-server's `ServerHandle::set_background`) keeps every
/// torrent running on a few peers instead of the configured limit, which is
/// the share of a backgrounded server's memory measured to be both the
/// largest and still growing -- and a television's low-memory killer takes
/// the fattest background process first (see `_onHidden` in `lib/app.dart`).
///
/// The server goes lean when the app is hidden or paused, and back to full
/// when it resumes -- **unless something that is still working in the
/// background needs the peers**, which keeps it full whatever the app's
/// state:
///
/// - **a download on its way** ([DownloadsSummary]: unfinished and not in
///   error; an errored pin has no engine for lean to shrink, and counting it
///   would keep the server full for as long as the row stays red);
/// - **a cast session**: the receiver is playing from this server;
/// - **the LAN media listener**, which serves that receiver. It has no feed
///   of its own, so this class stands in front of it as the tree's
///   [LanMediaControl] and keeps its state from every start and stop it
///   passes on: a start that fails leaves nothing listening, a stop that
///   fails is taken to have left the listener up.
///
/// Each of those ending while the app is away sends the server lean then,
/// not at the next resume. Only a change is sent, and a call that finds no
/// server running is not remembered as said.
class ServerFootprint implements LanMediaControl {
  ServerFootprint({
    required this.server,
    required this.downloads,
    required this.cast,
    this.lanMedia = const ServerClient(),
  });

  final ServerBackgroundControl server;
  final DownloadsClient downloads;
  final CastClient cast;

  /// The listener this stands in front of.
  final LanMediaControl lanMedia;

  StreamSubscription<DownloadsUpdate>? _updates;
  StreamSubscription<CastDevice?>? _session;
  final DownloadsListings _listings = DownloadsListings();
  DownloadsRegistry _registry = DownloadsRegistry.empty;
  bool _away = false;
  bool _casting = false;
  bool _lanOn = false;
  bool _disposed = false;

  /// What the server was last told; a fresh server starts full.
  bool _lean = false;

  /// Whether the server was last told to be lean, for tests.
  @visibleForTesting
  bool get isLean => _lean;

  /// Starts watching the downloads and the cast session.
  Future<void> start() async {
    if (_disposed) return;
    try {
      _updates = downloads.updates.listen(_onUpdate, onError: _onFeedError);
    } catch (error) {
      // A client with no feed to give (no bridge behind it) still lists.
      if (kDebugMode) debugPrint('downloads feed for the footprint: $error');
    }
    _session = cast.session.listen((device) {
      _casting = device != null;
      _apply();
    });
    await _refresh();
  }

  /// The app was hidden or paused.
  void appHidden() {
    _away = true;
    _apply();
  }

  /// The app is in the foreground again.
  void appResumed() {
    _away = false;
    _apply();
  }

  void dispose() {
    _disposed = true;
    unawaited(_updates?.cancel());
    unawaited(_session?.cancel());
  }

  bool get _busy =>
      _casting || _lanOn || !DownloadsSummary.of(_registry).isIdle;

  void _apply() {
    if (_disposed) return;
    final lean = _away && !_busy;
    if (lean == _lean) return;
    if (server.setBackground(lean)) _lean = lean;
  }

  Future<void> _refresh() async {
    DownloadsRegistry? listing;
    try {
      listing = await _listings.take(downloads.list);
    } catch (error) {
      if (kDebugMode) debugPrint('downloads listing for the footprint: $error');
      return;
    }
    if (listing == null || _disposed) return;
    _registry = listing;
    _apply();
  }

  void _onUpdate(DownloadsUpdate update) {
    if (_disposed) return;
    _listings.heard(update);
    _registry = update.applyTo(_registry);
    if (update is DownloadsProgressUpdate &&
        update.rows.any((row) => !_registry.items.containsKey(row.key))) {
      // A row for an entry no listing has mentioned: something was added.
      unawaited(_refresh());
      return;
    }
    _apply();
  }

  void _onFeedError(Object error) {
    if (kDebugMode) debugPrint('downloads feed for the footprint: $error');
  }

  @override
  Future<String?> setLanMedia({required bool enabled}) async {
    // Up from the moment a start is asked for, so the server cannot be sent
    // lean while the receiver is being handed its URL.
    if (enabled) _lanOn = true;
    try {
      final address = await lanMedia.setLanMedia(enabled: enabled);
      _lanOn = enabled;
      return address;
    } catch (_) {
      _lanOn = !enabled;
      rethrow;
    } finally {
      _apply();
    }
  }

  @override
  bool get lanMediaRunning => lanMedia.lanMediaRunning;

  @override
  int get lanMediaRequestsServed => lanMedia.lanMediaRequestsServed;

  @override
  Future<Uri?> lanMediaBaseUrl({String? peerIp}) =>
      lanMedia.lanMediaBaseUrl(peerIp: peerIp);
}
