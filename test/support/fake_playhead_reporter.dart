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

  @override
  Future<void> noteDuration({
    required String infoHash,
    required int fileIdx,
    required double durationSeconds,
  }) async {
    callLog?.add('duration');
    durations.add(durationSeconds);
  }
}
