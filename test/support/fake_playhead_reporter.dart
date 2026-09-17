import 'package:xtremio/core/server_client.dart';

/// A [PlayheadReporter] that records instead of telling the server.
///
/// What a test reads it for is the one thing the server cannot work out on
/// its own: how long the film is. Where the player *is* it works out from
/// what the reads do, so nothing reports that any more.
class FakePlayheadReporter implements PlayheadReporter {
  /// When set, `noteDuration` also appends `'duration'` here: the log
  /// shared with the other fakes.
  List<String>? callLog;

  /// Every duration-only report, in order: what a cast sends.
  final List<double> durations = [];

  /// Which file each report named, as the player URL spelled it: the
  /// segment (`-1` for a file the server picks) and the `f=` filters.
  final List<({int fileIdx, List<String> filters})> files = [];

  /// Every torrent a player was reported opened on, in order.
  final List<String> opened = [];

  /// Every stall reported, as the torrent it was reported for, in order.
  final List<String> stalls = [];

  @override
  Future<void> noteDuration({
    required String infoHash,
    required int fileIdx,
    required List<String> filters,
    required double durationSeconds,
  }) async {
    callLog?.add('duration');
    durations.add(durationSeconds);
    files.add((fileIdx: fileIdx, filters: filters));
  }

  @override
  Future<void> notePlayerOpened({required String infoHash}) async {
    callLog?.add('opened');
    opened.add(infoHash);
  }

  @override
  Future<void> notePlayerStalled({required String infoHash}) async {
    callLog?.add('stalled');
    stalls.add(infoHash);
  }
}
