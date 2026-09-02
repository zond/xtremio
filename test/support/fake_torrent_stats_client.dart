import 'package:xtremio/features/player/playback_engine.dart';

/// [TorrentStatsClient] for widget tests: answers every poll with
/// [response] and records the URLs asked for. No HTTP.
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

  /// Every URL polled, in order.
  final List<Uri> requests = [];

  @override
  Future<TorrentStats?> fetch(Uri statsUrl) async {
    requests.add(statsUrl);
    return response;
  }
}
