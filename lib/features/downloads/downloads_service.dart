import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/core.dart';
import '../player/torrent_progress_card.dart';
import 'download_detail.dart';
import 'downloads_listings.dart';

/// What is being fetched right now, as the notification puts it: how many
/// entries are on their way and how far they have got between them.
///
/// On its way is narrower than the registry's own unfinished
/// ([DownloadView.isUnfinished]). A paused or complete download is not a reason
/// to hold a service, and neither is one in the error state. An errored entry
/// is a pin the server refused (a full or missing downloads volume, the
/// commonest case on a TV box) or a torrent whose add failed. In both, the
/// server has nothing in flight for it: no engine, no peers to wait for. So
/// counting it would hold a service (and, on Android 15, burn its `dataSync`
/// time budget) for a notification that never moves. A retry re-adds the entry,
/// and the row that follows is what brings the service up. The Rust ticker
/// still counts an error as unfinished (`Entry::unfinished`), because the
/// boot's re-pin does and the two share the test. That is its question and not
/// this one's.
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
      if (!isOnItsWay(view)) continue;
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

  /// How many downloads are on their way.
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
      return '${formatBytes(downloaded)} of '
          '${formatBytes(size)} · $percent%';
    }
    return downloaded > 0
        ? '${formatBytes(downloaded)} so far'
        : 'Waiting to start';
  }

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

/// What the notification says, collapsed and pulled open: [DownloadsSummary]
/// for the whole, and a [DownloadDetail] per download on its way for what
/// each is doing. Compared whole, so an unchanged tick sends nothing.
@immutable
class DownloadsNotice {
  const DownloadsNotice({
    required this.title,
    required this.text,
    required this.progress,
    this.blocks = const [],
  });

  /// Nothing to say.
  static const DownloadsNotice none = DownloadsNotice(
    title: '',
    text: '',
    progress: -1,
  );

  /// How many downloads get a block of their own when pulled open. The rest
  /// are counted in one line: a notification is not the Downloads screen.
  static const int shownBlocks = 5;

  /// The notice for the downloads on their way in [registry], each described
  /// by [detailOf] (the app's poller; the registry's words alone without
  /// one).
  factory DownloadsNotice.of(
    DownloadsRegistry registry, {
    DownloadDetail Function(DownloadView view)? detailOf,
  }) {
    final summary = DownloadsSummary.of(registry);
    final describe = detailOf ?? DownloadDetail.of;
    final details = [
      for (final view in registry.newestFirst)
        if (isOnItsWay(view)) describe(view),
    ];
    // The whole speed, when anything is arriving. A zero here is left to the
    // expanded lines, where it sits beside the peers it is about.
    final total = details.fold<double>(0, (sum, d) => sum + (d.speed ?? 0));
    final speed = total > 0 ? TorrentProgressCard.formatSpeed(total) : null;
    final percent = summary.percent;
    final single = details.length == 1 ? details.single : null;
    final text = [
      if (single != null && !single.arriving) single.status,
      if (percent != null) '$percent%',
      ?speed,
    ].join(' · ');
    final more = details.length - shownBlocks;
    return DownloadsNotice(
      title: single != null && single.name.isNotEmpty
          ? 'Downloading ${single.name}'
          : summary.title,
      text: text.isEmpty ? summary.text : text,
      progress: percent ?? -1,
      blocks: [
        for (final detail in details.take(shownBlocks))
          (name: detail.name, lines: detail.lines),
        if (more > 0)
          (
            name: more == 1 ? 'And 1 more title' : 'And $more more titles',
            lines: const <String>[],
          ),
      ],
    );
  }

  /// The collapsed notification's two lines: `Downloading A Film` over
  /// `32% · 1.2 MB/s`.
  final String title;
  final String text;

  /// `0..100` of everything on its way, `-1` for the bar with no end.
  final int progress;

  /// One per download when pulled open: its title and its
  /// [DownloadDetail.lines].
  final List<({String name, List<String> lines})> blocks;

  /// What the platform side is handed to draw. `progress` is `-1` for the
  /// indeterminate bar, so the Kotlin side needs no null handling. The
  /// blocks go flat (`names`, `lineCounts`, `lines`) because an intent
  /// carries string lists and not nested ones. Titles and numbers only:
  /// nothing here names a stream or where it comes from.
  Map<String, Object?> toNotification() => {
    'title': title,
    'text': text,
    'progress': progress,
    'cancelLabel': kDownloadsCancelAllAction,
    'names': [for (final block in blocks) block.name],
    'lineCounts': [for (final block in blocks) block.lines.length],
    'lines': [for (final block in blocks) ...block.lines],
  };

  @override
  bool operator ==(Object other) =>
      other is DownloadsNotice &&
      other.title == title &&
      other.text == text &&
      other.progress == progress &&
      listEquals(other.blocks.map((b) => b.name).toList(), [
        for (final block in blocks) block.name,
      ]) &&
      listEquals(other.blocks.expand((b) => b.lines).toList(), [
        for (final block in blocks) ...block.lines,
      ]) &&
      listEquals(other.blocks.map((b) => b.lines.length).toList(), [
        for (final block in blocks) block.lines.length,
      ]);

  @override
  int get hashCode => Object.hash(title, text, progress, blocks.length);

  @override
  String toString() => 'DownloadsNotice($title: $text)';
}

/// The only action on the notification, and the only one the registry can
/// really carry out. There is no pause for a pinned file, so what is left is
/// dropping every unfinished download and the part-file with it. That is what
/// deleting one on the Downloads screen does, for all of them at once.
const String kDownloadsCancelAllAction = 'Cancel all';

/// Keeps Android's downloads foreground service in step with the registry.
///
/// Android freezes a process whose app the user has left, and the whole
/// download stack (the embedded server and librqbit) lives in this one. A
/// `dataSync` foreground service is what keeps the process running and tells
/// the system why; it hosts nothing itself. So it is started as soon as one
/// download is unfinished and stopped the moment none is: playing and seeding
/// are not reasons to hold it.
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
/// **And it has a budget.** From Android 15 a `dataSync` service may run about
/// six hours in twenty-four while the app is not in front. At the end of that
/// the platform side stops itself and says so with `timedOut`. It has to: a
/// service that ignores the call is crashed with its process ten seconds later.
/// This side then forgets it had a service. The download is not moved on,
/// nothing is sent to a service that is gone, and the next change to the
/// registry asks for a start again. The system grants that once the app has
/// been in front, which is what resets the budget. From the background it is
/// refused, and the refusal is already the ordinary "not running, ask next
/// time" path. Nothing is lost meanwhile, for the reasons above. The download
/// simply waits for the app.
///
/// **How it learns what changed.** Progress arrives on the client's feed once a
/// second, and that feed only ever carries rows that *moved*. An entry that has
/// just appeared is not a row it knows. A row for a key no listing has
/// mentioned means something was added, and is answered with a fresh listing. A
/// removal is the client's own event ([DownloadsRemovalUpdate], pushed by
/// [DownloadsClient.remove]), since the Rust side emits nothing for one. That
/// is the whole of it: the listing is taken once at [start], once after a
/// [cancelAll], and once per addition. It is not polled every few seconds to
/// notice a removal. That would parse every entry's `MetaItem` snapshot on the
/// UI isolate twelve times a minute, on top of the progress rows already
/// arriving, for one thing the client can simply say. At rest nothing runs at
/// all.
class DownloadsForegroundService {
  DownloadsForegroundService({
    required this.client,
    this.channel = defaultChannel,
    this.openDownloads,
    this.details,
    this.updateGap = defaultUpdateGap,
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

  /// Whether this platform has a foreground service. False everywhere but
  /// Android, and then nothing here ever touches the channel.
  final bool isSupported;

  /// What each download is doing, for the lines the notification shows
  /// when pulled open. The app's one poller, shared with the Downloads
  /// rows. Without it the notification says what the registry says.
  final DownloadDetailPoller? details;

  /// The least time between two `update`s. The feed moves once a second and
  /// the poller every two, and a notification redrawn faster than it can be
  /// read costs battery for nothing. A start and a stop are never held.
  final Duration updateGap;

  static const Duration defaultUpdateGap = Duration(seconds: 2);

  /// Open while an `update` was sent less than [updateGap] ago.
  Timer? _gate;

  /// A change arrived while [_gate] was open: send it when it closes.
  bool _held = false;

  StreamSubscription<DownloadsUpdate>? _updates;
  DownloadsRegistry _registry = DownloadsRegistry.empty;
  final DownloadsListings _listings = DownloadsListings();

  /// What the notification currently says, so an unchanged tick is not sent
  /// over the channel once a second for nothing.
  DownloadsNotice _shown = DownloadsNotice.none;

  bool _running = false;
  bool _available = true;

  /// The last [_sync] queued. Each runs once the one before has finished:
  /// one can wait on the notification question for as long as the viewer
  /// leaves it on screen, and another running meanwhile decided from a
  /// service the first had not started yet.
  Future<void> _syncs = Future<void>.value();
  bool _asked = false;
  bool _disposed = false;

  /// True until [start]'s own listing has been acted on. A download found
  /// unfinished at launch is not a download starting, and start-up is the
  /// one moment the notification question must not be asked.
  bool _startingUp = true;

  /// True from the platform ending the service at its time limit until a
  /// service is up again or nothing is left to hold one for. The start that
  /// follows is the same download carrying on, not one starting, so like
  /// start-up it asks the notification question of nobody.
  bool _resuming = false;

  /// Whether the service is up as far as this side knows.
  @visibleForTesting
  bool get isRunning => _running;

  /// Subscribes to the progress feed, takes the first listing and acts on
  /// it: an app reopened with a download still unfinished puts the service
  /// back up without waiting for anything to move.
  ///
  /// Also collects the tap that launched the app, if the app was cold started
  /// from the notification. The platform side cannot invoke a handler that Dart
  /// has not installed yet, so it keeps the tap and this asks for it.
  Future<void> start() async {
    if (!isSupported || _disposed) return;
    channel.setMethodCallHandler(_onPlatformCall);
    details?.addListener(_onDetails);
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
    DownloadsRegistry? listing;
    try {
      listing = await _listings.take(client.list);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('downloads listing for the notification: $error');
      }
      return;
    }
    if (listing == null) return;
    _registry = listing;
    await _sync();
  }

  /// Drops every unfinished download, the part-file with it: the notification's
  /// action. A removal that fails is logged and the rest go on, because a
  /// half-cancelled list is worse than a noisy one.
  Future<void> cancelAll() async {
    if (_disposed) return;
    DownloadsRegistry? listing;
    try {
      listing = await _listings.take(client.list);
    } catch (error) {
      if (kDebugMode) debugPrint('downloads listing to cancel: $error');
      return;
    }
    if (listing != null) _registry = listing;
    for (final key in [..._registry.items.keys]) {
      // Asked of the registry the feed keeps current, just before each
      // removal, and not of the listing: every removal is a round trip, and
      // a download finishing during an earlier one would otherwise be
      // deleted with its files off a button that only promised to cancel
      // what was still coming.
      final view = _registry[key];
      if (view == null || !view.isUnfinished) continue;
      try {
        await client.remove(key, deleteFiles: true);
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
    details?.removeListener(_onDetails);
    _gate?.cancel();
    _gate = null;
    await _updates?.cancel();
    _updates = null;
    if (!isSupported) return;
    channel.setMethodCallHandler(null);
    // A start still waiting on the notification question sends its start
    // when the answer comes; a stop sent before that leaves the service up.
    await _syncs;
    if (!_running) return;
    _running = false;
    await _invoke('stop');
  }

  void _onUpdate(DownloadsUpdate update) {
    if (_disposed) return;
    _listings.heard(update);
    _registry = update.applyTo(_registry);
    if (update is DownloadsProgressUpdate &&
        update.rows.any((row) => !_registry.items.containsKey(row.key))) {
      // A row for an entry no listing has mentioned: something was added.
      unawaited(refresh());
      return;
    }
    unawaited(_sync());
  }

  /// The poller has new numbers for a download.
  void _onDetails() {
    if (_disposed || !_running) return;
    unawaited(_sync());
  }

  /// The feed died (the Rust side handed its one sink to another client). The
  /// app builds one client, so this is a broken bridge rather than a rival.
  /// What the notification says stands until the next listing (a cancel from
  /// the notification, or the next launch), and nothing polls for a case the
  /// design rules out.
  void _onFeedError(Object error) {
    if (kDebugMode) debugPrint('downloads feed for the notification: $error');
  }

  /// Brings the service into line with [_registry], after every [_sync] before
  /// it. Out of turn, a stop from one sync could go out after the start from a
  /// later one. That would leave the service running with nothing to hold it,
  /// and every later sync believing it already stopped.
  Future<void> _sync() => _syncs = _syncs.then((_) => _syncNow());

  Future<void> _syncNow() async {
    if (_disposed || !_available) return;
    final summary = DownloadsSummary.of(_registry);
    if (summary.isIdle) {
      _resuming = false;
      _closeGate();
      if (!_running) return;
      _running = false;
      _shown = DownloadsNotice.none;
      await _invoke('stop');
      return;
    }
    final notice = DownloadsNotice.of(_registry, detailOf: details?.detailOf);
    if (_running && notice == _shown) return;
    final starting = !_running;
    if (!starting && _gate != null) {
      // Sent too recently: the gate sends the newest when it closes.
      _held = true;
      return;
    }
    _shown = notice;
    _running = true;
    if (starting && !_resuming) await _requestNotifications();
    _openGate();
    final sent = await _invoke(
      starting ? 'start' : 'update',
      notice.toNotification(),
    );
    // A service the platform refused to start is not running; the next
    // change asks again, by which time the app may be in the foreground.
    if (starting && !sent) _running = false;
    if (starting && sent) _resuming = false;
  }

  /// Holds `update`s back for [updateGap] from now.
  void _openGate() {
    if (updateGap <= Duration.zero) return;
    _gate?.cancel();
    _gate = Timer(updateGap, () {
      _gate = null;
      if (!_held || _disposed) return;
      _held = false;
      unawaited(_sync());
    });
  }

  void _closeGate() {
    _gate?.cancel();
    _gate = null;
    _held = false;
  }

  /// Asks for `POST_NOTIFICATIONS`, once, and only now: a download has actually
  /// started, which is the only moment the question means anything. Never at
  /// launch. A download already unfinished when the app opens puts the service
  /// up silently, and the question waits for one that really begins. The answer
  /// is not acted on either. A refused notification does not stop the service,
  /// it only leaves it invisible, and the download finishes either way.
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

  /// The platform side stopped the service at the end of its running-time
  /// budget. There is no service now, whatever this side last sent it, so
  /// the next change starts one afresh rather than updating a ghost.
  void _onTimedOut() {
    DiagnosticsLog.warn(
      'downloads',
      'the foreground service reached its time limit; the download waits '
          'for the app to be opened',
    );
    _running = false;
    _shown = DownloadsNotice.none;
    _resuming = true;
    _closeGate();
  }

  /// Invokes [method] for its effect: true when the platform side took it.
  Future<bool> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async => await _ask<Object?>(method, arguments) != _refused;

  /// Invokes [method] for its answer, [_refused] when the platform side could
  /// not take it at all. A missing implementation is final (desktop builds and
  /// widget tests have none), so nothing is tried again after one.
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
      case 'timedOut':
        _onTimedOut();
        return null;
      default:
        throw MissingPluginException('downloads: ${call.method}');
    }
  }
}
