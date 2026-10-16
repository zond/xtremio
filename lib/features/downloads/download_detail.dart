import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../core/core.dart';
import '../player/player_screen.dart';
import '../player/torrent_progress_card.dart';
import '../player/torrent_stats.dart';
import 'download_labels.dart';
import 'downloads_listings.dart';

/// Whether [view] is a download on its way: one the server is working on
/// now. That is narrower than [DownloadView.isUnfinished]. An entry in the
/// error state is a pin the server refused or a torrent whose add failed, and
/// nothing is in flight for it. It is what holds the downloads foreground
/// service up (`DownloadsSummary`) and what the [DownloadDetailPoller] asks
/// the server about.
bool isOnItsWay(DownloadView view) =>
    view.isUnfinished && view.state != DownloadState.error;

/// What one download on its way is doing, in the words the buffering card
/// over the player uses for the same facts: the phase, the speed, who is on
/// the other end, the bytes, and the piece a waiting reader sits on.
///
/// A Downloads row shows it as one [line]. The notification shows it as
/// [lines], one fact per line. Both come from here, and every phrase in it
/// comes from [TorrentProgressCard] or `download_labels.dart`, so the card,
/// the row and the notification cannot disagree.
@immutable
final class DownloadDetail {
  const DownloadDetail({
    required this.key,
    required this.name,
    required this.status,
    required this.bytes,
    this.transfer,
    this.piece,
    this.speed,
    this.percent,
  });

  /// What [view] is doing, given the server's latest `stats.json` for its
  /// torrent ([stats], null for a link or Drive download and before the first
  /// answer) and, for a link or Drive download, the rate its bytes arrived at
  /// over the last poll ([measuredSpeed]).
  factory DownloadDetail.of(
    DownloadView view, {
    TorrentStats? stats,
    double? measuredSpeed,
  }) {
    final percent = switch (view.progress) {
      final progress? => (progress * 100).round(),
      null => null,
    };
    final bytes = view.size > 0
        ? '${view.downloadedLabel} of ${view.sizeLabel}'
        : '${view.downloadedLabel} so far';
    if (stats == null) {
      final speed = view.state == DownloadState.downloading
          ? measuredSpeed
          : null;
      return DownloadDetail(
        key: view.key,
        name: view.name,
        status: downloadStateLabel(view),
        bytes: bytes,
        transfer: speed == null ? null : TorrentProgressCard.formatSpeed(speed),
        speed: speed,
        percent: percent,
      );
    }
    final speed = stats.downloadSpeed;
    final moving = speed > 0 ? TorrentProgressCard.formatSpeed(speed) : null;
    final swarm = stats.peers > 0
        ? TorrentProgressCard.formatSwarm(stats)
        : null;
    String? joined(List<String?> parts) {
      final kept = parts.nonNulls.toList();
      return kept.isEmpty ? null : kept.join(' · ');
    }

    DownloadDetail as(String status, String? transfer, {String? piece}) =>
        DownloadDetail(
          key: view.key,
          name: view.name,
          status: status,
          bytes: bytes,
          transfer: transfer,
          piece: piece,
          speed: speed,
          percent: percent,
        );

    switch (stats.phase) {
      case TorrentPhase.error:
        // The server's own reason, which is client-safe: a full disk, a
        // download folder that went away, a magnet nobody had.
        return as(kDownloadStoppedLabel, stats.error);
      case TorrentPhase.resolvingMetadata:
        return as(
          TorrentProgressCard.fetchingMetadata,
          joined([moving, swarm]),
        );
      case TorrentPhase.checking:
        return as(
          TorrentProgressCard.withPercent(
            TorrentProgressCard.checking,
            stats.checkProgress,
          ),
          joined([moving, swarm]),
        );
      case TorrentPhase.buffering:
      case TorrentPhase.ready:
      case TorrentPhase.unknown:
        if (TorrentProgressCard.searchingForPeers(stats)) {
          return as(
            TorrentProgressCard.findingPeers,
            TorrentProgressCard.peerSearch(stats).join(' · '),
          );
        }
        // A piece is named only while a reader waits on it: the server
        // knows one only while something is playing this file.
        final waiting = stats.inFlightPiece;
        return as(
          TorrentProgressCard.withPercent(kDownloadingLabel, view.progress),
          // The speed even at zero: with peers connected and nothing
          // arriving, `0 B/s` is the answer, as on the stall card.
          joined([TorrentProgressCard.formatSpeed(speed), swarm]),
          piece: waiting == null || waiting.verified
              ? null
              : TorrentProgressCard.pieceWaitOf(waiting),
        );
    }
  }

  /// The registry key of the download.
  final String key;

  /// The title, as the row names it. Never a URL.
  final String name;

  /// The phase, with the percentage when there is one: `Downloading 32%`,
  /// `Finding peers`, `Checking existing data 40%`, `Stopped`.
  final String status;

  /// Speed and who is on the other end (`1.2 MB/s · connected 14 · seeds
  /// 137`), the peer search while nothing is connected, or the server's
  /// reason a download stopped. Null when there is nothing to say.
  final String? transfer;

  /// `612 MB of 1.9 GB`, or `40 MB so far` while the length is not known.
  final String bytes;

  /// The piece a reader of this file is waiting for, when one is
  /// (`Waiting for piece 412, 6.3 of 16.0 MiB`).
  final String? piece;

  /// Bytes per second, when anything measured one.
  final double? speed;

  /// `0..100` of the file, or null while its length is not known.
  final int? percent;

  /// What a Downloads row says under its bar: the piece when a reader waits
  /// on one, else the phase, then the transfer and the bytes.
  String get line => [piece ?? status, ?transfer, bytes].join(' · ');

  /// The same facts one per line, for the expanded notification.
  List<String> get lines => [status, ?transfer, bytes, ?piece];

  @override
  bool operator ==(Object other) =>
      other is DownloadDetail &&
      other.key == key &&
      other.name == name &&
      other.status == status &&
      other.transfer == transfer &&
      other.bytes == bytes &&
      other.piece == piece &&
      other.speed == speed &&
      other.percent == percent;

  @override
  int get hashCode =>
      Object.hash(key, name, status, transfer, bytes, piece, speed, percent);

  @override
  String toString() => 'DownloadDetail($key: $line)';
}

/// Polls what the downloads on their way are doing, for the Downloads rows
/// and the downloads notification alike. There is one, built by the app and
/// handed down through [DownloadDetailScope].
///
/// It follows the registry the way the foreground service does: one listing
/// at [start], the client's feed folded in, and a fresh listing when a row
/// names a key no listing has. While any download is on its way
/// ([isOnItsWay]) it asks the server for each torrent's `stats.json` every
/// [interval], the cadence the player's stall card polls at. A link or Drive
/// download has no swarm and no stats. Its speed is the rate the server's
/// own byte count grew at between two polls. When nothing is on its way the
/// timer stops and nothing is asked.
///
/// A torrent in the error state is never asked about. The server refused
/// its pin or its add failed, and a stats call is only safe for a torrent
/// the server already holds.
class DownloadDetailPoller extends ChangeNotifier {
  DownloadDetailPoller({
    required this.client,
    TorrentStatsClient? stats,
    this.interval = cadence,
    DateTime Function()? now,
  }) : stats = stats ?? const RustTorrentStatsClient(),
       _now = now ?? DateTime.now;

  /// The stall card's cadence: slow enough that nothing waits on it, quick
  /// enough that the numbers move.
  static const Duration cadence = PlayerScreen.torrentStallStatsInterval;

  final DownloadsClient client;
  final TorrentStatsClient stats;
  final Duration interval;
  final DateTime Function() _now;

  final DownloadsListings _listings = DownloadsListings();
  StreamSubscription<DownloadsUpdate>? _updates;
  DownloadsRegistry _registry = DownloadsRegistry.empty;
  Timer? _timer;
  bool _fetching = false;
  bool _disposed = false;

  /// The latest stats per download key.
  final Map<String, TorrentStats> _stats = {};

  /// The byte count each link or Drive download had at the last poll, and
  /// when, for its speed.
  final Map<String, ({int bytes, DateTime at})> _samples = {};
  final Map<String, double> _speeds = {};

  Map<String, DownloadDetail> _details = const {};

  /// What each download on its way is doing, by key.
  Map<String, DownloadDetail> get details => _details;

  /// The detail for [key], or null when it is not on its way.
  DownloadDetail? operator [](String key) => _details[key];

  /// What [view] is doing, from this poller's latest numbers for it. The
  /// notification asks with the view its own registry holds, so the bytes it
  /// shows are the newest it has heard.
  DownloadDetail detailOf(DownloadView view) => DownloadDetail.of(
    view,
    stats: _stats[view.key],
    measuredSpeed: _speeds[view.key],
  );

  /// Whether the timer runs, which is exactly while a download is on its way.
  @visibleForTesting
  bool get isPolling => _timer != null;

  /// Subscribes to the feed and takes the first listing.
  Future<void> start() async {
    if (_disposed || _updates != null) return;
    try {
      _updates = client.updates.listen(_onUpdate, onError: _onFeedError);
    } catch (error) {
      // A client with no feed to give (no bridge behind it) still lists.
      if (kDebugMode) debugPrint('downloads feed for the detail: $error');
    }
    await refresh();
  }

  /// Takes the whole listing again. A listing that fails changes nothing.
  Future<void> refresh() async {
    if (_disposed) return;
    DownloadsRegistry? listing;
    try {
      listing = await _listings.take(client.list);
    } catch (error) {
      if (kDebugMode) debugPrint('downloads listing for the detail: $error');
      return;
    }
    if (listing == null || _disposed) return;
    _registry = listing;
    _follow();
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
    _follow();
  }

  void _onFeedError(Object error) {
    if (kDebugMode) debugPrint('downloads feed for the detail: $error');
  }

  /// Starts or stops the timer to match the registry, and redraws the
  /// details from the bytes it now holds.
  void _follow() {
    final running = _running();
    if (running.isEmpty) {
      _timer?.cancel();
      _timer = null;
      _stats.clear();
      _samples.clear();
      _speeds.clear();
    } else if (_timer == null) {
      _timer = Timer.periodic(interval, (_) => unawaited(_poll()));
      unawaited(_poll());
    }
    final keys = {for (final view in running) view.key};
    _stats.removeWhere((key, _) => !keys.contains(key));
    _samples.removeWhere((key, _) => !keys.contains(key));
    _speeds.removeWhere((key, _) => !keys.contains(key));
    _publish(running);
  }

  List<DownloadView> _running() => [
    for (final view in _registry.newestFirst)
      if (isOnItsWay(view)) view,
  ];

  /// One round: every torrent on its way asked at once, and every link's
  /// bytes compared with the round before.
  Future<void> _poll() async {
    if (_fetching || _disposed) return;
    _fetching = true;
    try {
      final now = _now();
      final running = _running();
      for (final view in running) {
        if (view.isTorrent) continue;
        final before = _samples[view.key];
        _samples[view.key] = (bytes: view.downloaded, at: now);
        if (before == null) continue;
        final seconds = now.difference(before.at).inMicroseconds / 1e6;
        final grown = view.downloaded - before.bytes;
        if (seconds > 0 && grown >= 0) _speeds[view.key] = grown / seconds;
      }
      final answers = await Future.wait([
        for (final view in running)
          if (view.isTorrent)
            stats
                .fetch(
                  TorrentStatsRequest(
                    infoHash: view.infoHash,
                    fileIdx: view.fileIdx,
                    trackers: view.announce,
                  ),
                )
                .then((answer) => (view.key, answer)),
      ]);
      if (_disposed) return;
      for (final (key, answer) in answers) {
        if (answer == null) continue;
        _stats[key] = answer;
      }
      _publish(_running());
    } finally {
      _fetching = false;
    }
  }

  void _publish(List<DownloadView> running) {
    final next = {for (final view in running) view.key: detailOf(view)};
    if (mapEquals(next, _details)) return;
    _details = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    unawaited(_updates?.cancel());
    _updates = null;
    super.dispose();
  }
}

/// Hands the app's one [DownloadDetailPoller] down to the Downloads rows,
/// and rebuilds what reads it on every change.
class DownloadDetailScope extends InheritedNotifier<DownloadDetailPoller> {
  const DownloadDetailScope({
    super.key,
    required DownloadDetailPoller poller,
    required super.child,
  }) : super(notifier: poller);

  /// The poller, or null where nothing provides one (a widget test that is
  /// not about it). The rows then say what the registry alone says.
  static DownloadDetailPoller? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<DownloadDetailScope>()
      ?.notifier;
}
