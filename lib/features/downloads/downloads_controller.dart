import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/core.dart';

/// The offline downloads as a screen sees them: one full listing when the
/// screen comes up, every progress event folded into it, and a fresh
/// listing after anything the screen itself changed.
///
/// A progress event carries only what moved -- the six numbers of a row,
/// not the entry -- which is why the registry is kept here and updates are
/// laid over it rather than replacing it, and why an entry that was
/// *removed* needs a [refresh], not an event.
///
/// A failed listing is a value ([error]), not a throw: the Rust side
/// answers what is on disk when the server cannot be asked, so the only way
/// here is a genuinely broken bridge, and a screen still has to draw
/// something.
class DownloadsController extends ChangeNotifier {
  DownloadsController(this.client) {
    _listen();
    unawaited(refresh());
  }

  final DownloadsClient client;

  StreamSubscription<DownloadsUpdate>? _updates;
  bool _disposed = false;

  /// Every download known, newest listing merged with the progress since.
  DownloadsRegistry registry = DownloadsRegistry.empty;

  /// Whether a listing has landed. Before the first one the registry is
  /// empty because nothing is known, not because nothing is downloaded.
  bool isLoaded = false;

  /// Why the last listing failed, if it did. Cleared by the next one that
  /// succeeds.
  Object? error;

  /// The download of one video, if there is one.
  DownloadView? forVideo(String metaId, String videoId) =>
      registry.forVideo(metaId, videoId);

  /// Every download of one meta (a series has one per episode).
  List<DownloadView> ofMeta(String metaId) => [
    for (final view in registry.items.values)
      if (view.metaId == metaId) view,
  ];

  /// Asks for the full listing again. Call it after an add or a remove:
  /// those change which entries exist, and the progress feed only reports
  /// the ones that moved.
  Future<void> refresh() async {
    // A feed that ended is picked up again here: the client opens a fresh
    // one on the next look at `updates`, and nothing else would ever look.
    _listen();
    try {
      final listing = await client.list();
      if (_disposed) return;
      registry = listing;
      error = null;
    } catch (failure) {
      if (_disposed) return;
      error = failure;
    }
    isLoaded = true;
    notifyListeners();
  }

  /// Subscribes to the progress feed unless there already is a live
  /// subscription.
  void _listen() {
    if (_disposed || _updates != null) return;
    _updates = client.updates.listen(
      _onUpdate,
      onError: _onFeedError,
      onDone: _onFeedDone,
    );
  }

  void _onUpdate(DownloadsUpdate update) {
    if (_disposed) return;
    registry = update.applyTo(registry);
    notifyListeners();
  }

  /// The feed died (the Rust side handed the sink to another client, or the
  /// bridge broke). Progress stops arriving; what was listed stays on
  /// screen, and every [refresh] still works.
  void _onFeedError(Object failure) {
    if (kDebugMode) debugPrint('downloads progress feed: $failure');
  }

  /// The feed closed -- the Rust side handed its one event sink to another
  /// client. Let go of the dead subscription so the next [refresh] opens a
  /// fresh one; without this, progress would stop arriving for good and
  /// nothing on screen would say so.
  void _onFeedDone() {
    _updates?.cancel();
    _updates = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _updates?.cancel();
    _updates = null;
    super.dispose();
  }
}
