import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/core.dart';

/// What is being fetched right now, as the notification puts it: how many
/// entries are unfinished and how far they have got between them.
///
/// Unfinished is the registry's own test ([DownloadView.isUnfinished]), so
/// this counts exactly what the Rust ticker still polls for. A paused or
/// complete download is not a reason to hold a service.
@immutable
class DownloadsSummary {
  const DownloadsSummary({
    required this.active,
    required this.downloaded,
    required this.size,
  });

  /// Nothing is on its way.
  static const DownloadsSummary idle = DownloadsSummary(
    active: 0,
    downloaded: 0,
    size: 0,
  );

  /// Sums the unfinished entries of [registry].
  ///
  /// A magnet whose metadata has not resolved reports no length, and a
  /// total built from only the entries that know theirs would be a
  /// percentage of the wrong number. One such entry makes the whole
  /// summary unmeasured ([size] zero), which the notification shows as a
  /// bar with no end rather than a wrong one.
  factory DownloadsSummary.of(DownloadsRegistry registry) {
    var active = 0;
    var downloaded = 0;
    var size = 0;
    var measured = true;
    for (final view in registry.items.values) {
      if (!view.isUnfinished) continue;
      active++;
      downloaded += view.downloaded;
      size += view.size;
      if (view.size <= 0) measured = false;
    }
    return DownloadsSummary(
      active: active,
      downloaded: downloaded,
      size: measured ? size : 0,
    );
  }

  /// How many downloads are unfinished.
  final int active;

  /// Bytes on the device of them, and how many there are in all. [size] is
  /// zero when any one of them does not know its length yet.
  final int downloaded;
  final int size;

  /// Nothing to hold a service for.
  bool get isIdle => active == 0;

  /// `0..100` of the whole, or null while [size] is unknown.
  int? get percent =>
      size > 0 ? ((downloaded / size) * 100).clamp(0, 100).round() : null;

  /// The notification's first line.
  String get title =>
      active == 1 ? 'Downloading 1 title' : 'Downloading $active titles';

  /// Its second line: the bytes when they are known, and what little there
  /// is to say when they are not.
  String get text {
    if (size > 0) {
      return '${DownloadView.humanSize(downloaded)} of '
          '${DownloadView.humanSize(size)} · $percent%';
    }
    return downloaded > 0
        ? '${DownloadView.humanSize(downloaded)} so far'
        : 'Waiting to start';
  }

  /// What the platform side is handed to draw. `progress` is `-1` for the
  /// indeterminate bar, so the Kotlin side needs no null handling.
  Map<String, Object?> toNotification() => {
    'title': title,
    'text': text,
    'progress': percent ?? -1,
    'cancelLabel': kDownloadsCancelAllAction,
  };

  @override
  bool operator ==(Object other) =>
      other is DownloadsSummary &&
      other.active == active &&
      other.downloaded == downloaded &&
      other.size == size;

  @override
  int get hashCode => Object.hash(active, downloaded, size);

  @override
  String toString() =>
      'DownloadsSummary($active active, $downloaded/$size bytes)';
}

/// The only action on the notification, and the only one the registry can
/// really carry out: there is no pause for a pinned file, so what is left
/// is dropping every unfinished download and the part-file with it — what
/// "Delete the file" on the Downloads screen does, for all of them at once.
const String kDownloadsCancelAllAction = 'Cancel all';

/// Keeps Android's downloads foreground service in step with the registry.
///
/// Android freezes a process whose app the user has left, and the whole
/// download stack — the embedded server and librqbit — lives in this one.
/// A `dataSync` foreground service is what keeps the process running and
/// tells the system why; it hosts nothing itself. So it is started as soon
/// as one download is unfinished and stopped the moment none is: playing
/// and seeding are not reasons to hold it.
///
/// Only Android has such a thing. Everywhere else this is inert: no channel
/// is installed, no listing is taken, and nothing is ever invoked.
///
/// **What it does not promise.** A foreground service is not a guarantee of
/// life: the system may still kill the process under memory pressure, Doze
/// and the per-app battery optimisation can throttle or park the sockets,
/// and swiping the app out of the recents list takes the service with it
/// (`android:stopWithTask`, since the Flutter engine goes at the same time
/// and nothing would be left to report progress or stop). None of that
/// loses anything: librqbit keeps its verified pieces, the server keeps its
/// pin set, and start-up re-pins every unfinished entry.
///
/// **How it learns what changed.** Progress arrives on the client's feed
/// once a second, but that feed only ever carries rows that *moved* — an
/// entry that has just appeared or has just been removed is not a row. A
/// row for a key no listing has mentioned means something was added, and is
/// answered with a fresh listing; a removal has no event at all, so while
/// the service runs the listing is re-read every [listingInterval]. At rest
/// neither costs anything: nothing ticks when nothing is unfinished.
class DownloadsForegroundService {
  DownloadsForegroundService({
    required this.client,
    this.channel = defaultChannel,
    this.openDownloads,
    this.listingInterval = const Duration(seconds: 5),
    TargetPlatform? platform,
  }) : isSupported =
           (platform ?? defaultTargetPlatform) == TargetPlatform.android;

  /// The channel `MainActivity` answers on, a sibling of `xtremio/device`
  /// and a separate concern from it.
  static const MethodChannel defaultChannel = MethodChannel(
    'xtremio/downloads',
  );

  /// The registry this reports on, and the one a cancel acts through.
  final DownloadsClient client;

  final MethodChannel channel;

  /// Brings up the Downloads screen: what the notification's body does when
  /// it is tapped.
  final VoidCallback? openDownloads;

  /// How often the listing is re-read while the service runs; see the class
  /// comment for why it has to be read at all.
  final Duration listingInterval;

  /// Whether this platform has a foreground service. False everywhere but
  /// Android, and then nothing here ever touches the channel.
  final bool isSupported;

  StreamSubscription<DownloadsUpdate>? _updates;
  Timer? _listings;
  DownloadsRegistry _registry = DownloadsRegistry.empty;

  /// What the notification currently says, so an unchanged tick is not sent
  /// over the channel once a second for nothing.
  DownloadsSummary _shown = DownloadsSummary.idle;

  bool _running = false;
  bool _available = true;
  bool _asked = false;
  bool _disposed = false;

  /// True until [start]'s own listing has been acted on. A download found
  /// unfinished at launch is not a download starting, and start-up is the
  /// one moment the notification question must not be asked.
  bool _startingUp = true;

  /// Whether the service is up as far as this side knows.
  @visibleForTesting
  bool get isRunning => _running;

  /// Subscribes to the progress feed, takes the first listing and acts on
  /// it: an app reopened with a download still unfinished puts the service
  /// back up without waiting for anything to move.
  ///
  /// Also collects the tap that launched the app, if the app was cold
  /// started from the notification — the platform side cannot invoke a
  /// handler that Dart has not installed yet, so it keeps the tap and this
  /// asks for it.
  Future<void> start() async {
    if (!isSupported || _disposed) return;
    channel.setMethodCallHandler(_onPlatformCall);
    try {
      _updates = client.updates.listen(_onUpdate, onError: _onFeedError);
    } catch (error) {
      // A client with no feed to give (no bridge behind it) still lists.
      if (kDebugMode) debugPrint('downloads feed for the notification: $error');
    }
    await refresh();
    _startingUp = false;
    await _takePendingOpen();
  }

  /// Reads the whole listing again and brings the service into line with
  /// it. A listing that cannot be taken changes nothing: what is on the
  /// notification stays, and the next one decides.
  Future<void> refresh() async {
    if (!isSupported || _disposed) return;
    try {
      _registry = await client.list();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('downloads listing for the notification: $error');
      }
      return;
    }
    await _sync();
  }

  /// Drops every unfinished download, the part-file with it: the
  /// notification's action. A removal that fails is logged and the rest go
  /// on — a half-cancelled list is worse than a noisy one.
  Future<void> cancelAll() async {
    if (_disposed) return;
    DownloadsRegistry listing;
    try {
      listing = await client.list();
    } catch (error) {
      if (kDebugMode) debugPrint('downloads listing to cancel: $error');
      return;
    }
    for (final view in listing.items.values) {
      if (!view.isUnfinished) continue;
      try {
        await client.remove(view.key, deleteFiles: true);
      } catch (error) {
        if (kDebugMode) debugPrint('cancelling a download: $error');
      }
    }
    await refresh();
  }

  /// Lets go of the feed and takes the service down with it: without this
  /// side there is nobody to move the notification on or stop it.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _stopListings();
    await _updates?.cancel();
    _updates = null;
    if (!isSupported) return;
    channel.setMethodCallHandler(null);
    if (!_running) return;
    _running = false;
    await _invoke('stop');
  }

  void _onUpdate(DownloadsUpdate update) {
    if (_disposed) return;
    _registry = update.applyTo(_registry);
    if (update is DownloadsProgressUpdate &&
        update.rows.any((row) => !_registry.items.containsKey(row.key))) {
      // A row for an entry no listing has mentioned: something was added.
      unawaited(refresh());
      return;
    }
    unawaited(_sync());
  }

  /// The feed died (the Rust side handed its one sink to another client).
  /// The listing timer still runs while the service is up, so the numbers
  /// go stale rather than wrong, and a removal is still noticed.
  void _onFeedError(Object error) {
    if (kDebugMode) debugPrint('downloads feed for the notification: $error');
  }

  Future<void> _sync() async {
    if (_disposed || !_available) return;
    final summary = DownloadsSummary.of(_registry);
    if (summary.isIdle) {
      _stopListings();
      if (!_running) return;
      _running = false;
      _shown = DownloadsSummary.idle;
      await _invoke('stop');
      return;
    }
    _startListings();
    if (_running && summary == _shown) return;
    final starting = !_running;
    _shown = summary;
    _running = true;
    if (starting) await _requestNotifications();
    final sent = await _invoke(
      starting ? 'start' : 'update',
      summary.toNotification(),
    );
    // A service the platform refused to start is not running; the next
    // change asks again, by which time the app may be in the foreground.
    if (starting && !sent) _running = false;
  }

  /// Asks for `POST_NOTIFICATIONS`, once, and only now — a download has
  /// actually started, which is the only moment the question means
  /// anything. Never at launch: a download already unfinished when the app
  /// opens puts the service up silently, and the question waits for one
  /// that really begins. The answer is not acted on either — a refused
  /// notification does not stop the service, it only leaves it invisible,
  /// and the download finishes either way.
  Future<void> _requestNotifications() async {
    if (_asked || _startingUp) return;
    _asked = true;
    await _invoke('requestNotificationPermission');
  }

  Future<void> _takePendingOpen() async {
    if (await _ask<bool>('takePendingOpen') == true && !_disposed) {
      openDownloads?.call();
    }
  }

  /// Invokes [method] for its effect: true when the platform side took it.
  Future<bool> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async => await _ask<Object?>(method, arguments) != _refused;

  /// Invokes [method] for its answer, [_refused] when the platform side
  /// could not take it at all. A missing implementation is final — desktop
  /// builds and widget tests have none — so nothing is tried again after
  /// one.
  Future<Object?> _ask<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    if (!_available) return _refused;
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      _available = false;
      if (kDebugMode) debugPrint('no downloads service on this platform');
      return _refused;
    } on PlatformException catch (error) {
      if (kDebugMode) debugPrint('downloads service $method: ${error.code}');
      return _refused;
    }
  }

  /// Stands for "the platform side never took the call", which a null
  /// answer (what every call but `takePendingOpen` gives) does not.
  static const Object _refused = Object();

  Future<Object?> _onPlatformCall(MethodCall call) async {
    switch (call.method) {
      case 'open':
        openDownloads?.call();
        return null;
      case 'cancelAll':
        await cancelAll();
        return null;
      default:
        throw MissingPluginException('downloads: ${call.method}');
    }
  }

  void _startListings() => _listings ??= Timer.periodic(
    listingInterval,
    (_) => unawaited(refresh()),
  );

  void _stopListings() {
    _listings?.cancel();
    _listings = null;
  }
}
