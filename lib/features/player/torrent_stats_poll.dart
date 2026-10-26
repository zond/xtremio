import 'dart:async';

import 'package:flutter/foundation.dart';

import 'torrent_stats.dart';

/// The player's poll of the server's stats for the torrent it plays: the
/// request, the timer and its cadence, and the last answers.
///
/// The screen decides when numbers are wanted and how often ([run],
/// [pause]). This keeps the asking: one ask at a time, the per-file stats or
/// the torrent's own when the server has none for the file, and an answer
/// dropped when it is about a torrent no longer asked about. It notifies when
/// [stats] or [serverFilename] changes.
class TorrentStatsPoll extends ChangeNotifier {
  TorrentStatsPoll({required this.client, required this.startupCadence});

  /// Where the stats come from; none in a build that has no server to ask.
  final TorrentStatsClient? Function() client;

  /// How often a torrent is asked about while it starts up.
  final Duration startupCadence;

  TorrentStatsRequest? _request;
  TorrentStatsRequest? _fallback;
  Timer? _timer;
  Duration? _cadence;
  bool _fetching = false;
  TorrentStats? _stats;
  String? _serverFilename;
  bool _disposed = false;

  /// The torrent asked about, or null when there is none.
  TorrentStatsRequest? get request => _request;

  /// The last answer, while it is one to show.
  TorrentStats? get stats => _stats;

  /// The name of the file the server opened, as the last answer about the
  /// file named it. Which file this is does not go stale.
  String? get serverFilename => _serverFilename;

  /// Starts asking about [request]: at [startupCadence], from the first
  /// tick, never at once. The engine's `open` goes first.
  void start(TorrentStatsRequest request) {
    stop();
    _request = request;
    final fallback = request.torrentLevel;
    _fallback = fallback == request ? null : fallback;
    runStartup();
  }

  /// Arms the start-up cadence, or leaves it running if it already is. The
  /// first request goes out on the first tick, never at once. The app coming
  /// back to the front during start-up re-arms it here.
  void runStartup() {
    if (_timer != null && _cadence == startupCadence) return;
    _timer?.cancel();
    _cadence = startupCadence;
    _timer = Timer.periodic(startupCadence, (_) => poll());
  }

  /// Asks every [cadence], starting now.
  ///
  /// A stall that starts under an open panel (or ends under one) changes only
  /// the pace: the last answer stands until the next one lands. The same goes
  /// for a panel that comes back before the answer does ([keepLast]).
  /// Wanting the numbers again after nothing was showing them is another
  /// matter. Those numbers describe a start-up, or a stall, however long ago,
  /// and the stall card showing them would be stating the past as the
  /// present.
  ///
  /// Unlike the start-up poll, this one goes out at once. The stream request
  /// created the torrent's engine long ago, so there is no ordering to
  /// respect, and whoever just started watching wants numbers now.
  void run(Duration cadence, {required bool keepLast}) {
    if (_timer != null && _cadence == cadence) return;
    if (_timer == null && !keepLast) _stats = null;
    _timer?.cancel();
    _cadence = cadence;
    _timer = Timer.periodic(cadence, (_) => poll());
    poll();
  }

  /// Stops asking but keeps the torrent and the last answer, so a stall or
  /// the stats panel can pick them up again. A pause is often only the
  /// panel going away for a moment (hovering off, on a desktop), and the
  /// numbers it showed are still the numbers to show when it comes back.
  /// [run] is where they are dropped as too old to show.
  void pause() {
    _timer?.cancel();
    _timer = null;
    _cadence = null;
  }

  /// Stops asking for good and forgets the torrent and its answers.
  void stop() {
    pause();
    _stats = null;
    _request = null;
    _fallback = null;
    _serverFilename = null;
  }

  /// One ask: the per-file stats, or the torrent-level ones when the server
  /// has no answer for the file (an index the torrent does not have; a
  /// stopped server fails the second ask as fast as the first).
  Future<void> poll() async {
    final request = _request;
    final fallback = _fallback;
    final client = this.client();
    if (request == null || client == null || _fetching) return;
    _fetching = true;
    TorrentStats? stats;
    // Whether the answer is about the file being streamed rather than the
    // torrent as a whole. It matters for the name below. The torrent-level
    // `streamName` is the file the server *guessed*, which is the streamed one
    // only when the stream carried no `fileIdx`, and then the primary request
    // is the torrent-level one anyway.
    var aboutTheFile = false;
    try {
      stats = await client.fetch(request);
      aboutTheFile = stats != null;
      if (stats == null && fallback != null && _request == request) {
        stats = await client.fetch(fallback);
      }
    } on Object {
      stats = null;
      aboutTheFile = false;
    } finally {
      _fetching = false;
    }
    final opened = aboutTheFile ? stats?.streamName : null;
    if (_disposed || _request != request) return;
    // The numbers describe a moment, so an answer that came back after the
    // polling stopped (a stall that ended while the fetch was out) is not one
    // to show. The name is not a moment, and the poll that carries it is very
    // often the last one there will be, since the polling stops for good once
    // playback is under way. A poll that came back empty says nothing about
    // the file the server opened; only an answer that names one replaces the
    // name.
    final names = opened != null && opened != _serverFilename;
    final counts = _timer != null && stats != _stats;
    if (!names && !counts) return;
    if (counts) _stats = stats;
    if (names) _serverFilename = opened;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    pause();
    super.dispose();
  }
}
