import 'dart:async';

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

  /// Holds every answer until [answer] is called, instead of returning one
  /// in the same microtask the poll went out in. A poll that is out and
  /// unanswered leaves frames a test can draw and look at, which is how a
  /// test sees what the screen shows *while* it waits for the server.
  bool holdAnswers = false;

  final List<(TorrentStatsRequest, Completer<TorrentStats?>)> _held = [];

  /// How many polls are out and waiting for [answer].
  int get heldCount => _held.length;

  /// Answers every held poll with what this client would return now, so a
  /// test can change [response] after the poll went out and still say when
  /// the new numbers land.
  void answer() {
    final held = List.of(_held);
    _held.clear();
    for (final (request, completer) in held) {
      completer.complete(_responseFor(request));
    }
  }

  @override
  Future<TorrentStats?> fetch(TorrentStatsRequest request) async {
    requests.add(request);
    callLog?.add('stats');
    if (!holdAnswers) return _responseFor(request);
    final completer = Completer<TorrentStats?>();
    _held.add((request, completer));
    return completer.future;
  }

  TorrentStats? _responseFor(TorrentStatsRequest request) =>
      responses.containsKey(request) ? responses[request] : response;
}
