import 'package:xtremio/features/player/playback_engine.dart';

/// [TorrentStatsClient] for widget tests: answers every poll with
/// [response] and records the requests made. No FFI.
class FakeTorrentStatsClient implements TorrentStatsClient {
  /// What the next fetches return; null plays a server with nothing for the
  /// torrent yet (unreachable, or a 404).
  ///
  /// Starts as a live torrent with nothing downloaded yet ("Finding peers…",
  /// a determinate 0 % bar): with a percentage the overlay animates nothing
  /// on its own, so `pumpAndSettle` still settles while it is up. Tests
  /// about the connecting state set this to null and pump by hand.
  TorrentStats? response = const TorrentStats(
    phase: TorrentPhase.buffering,
    initialWindowReadyBytes: 0,
    initialWindowBytes: 4194304,
  );

  /// Answers for particular requests, over [response]: a null value plays
  /// a request the server has no answer for (a file index the torrent does
  /// not have).
  final Map<TorrentStatsRequest, TorrentStats?> responses = {};

  /// Every request made, in order.
  final List<TorrentStatsRequest> requests = [];

  /// When set, `fetch` also appends `'stats'` here: a log shared with other
  /// fakes, for tests about the order of calls across them.
  List<String>? callLog;

  @override
  Future<TorrentStats?> fetch(TorrentStatsRequest request) async {
    requests.add(request);
    callLog?.add('stats');
    return responses.containsKey(request) ? responses[request] : response;
  }
}
