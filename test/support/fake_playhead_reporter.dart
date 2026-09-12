import 'package:xtremio/core/server_client.dart';

/// A [PlayheadReporter] that records instead of telling the server.
///
/// What a test reads it for is the thing the server cannot work out on its
/// own: that the app said where the player was, for the film on screen, and
/// in the picture rather than in the file.
class FakePlayheadReporter implements PlayheadReporter {
  final List<PlayheadCall> reports = [];

  /// When set, `notePlayhead` also appends `'playhead'` here: the log
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

  @override
  Future<void> notePlayhead({
    required String infoHash,
    required int fileIdx,
    required double filmSeconds,
    required double durationSeconds,
  }) async {
    callLog?.add('playhead');
    reports.add(
      PlayheadCall(
        infoHash: infoHash,
        fileIdx: fileIdx,
        filmSeconds: filmSeconds,
        durationSeconds: durationSeconds,
      ),
    );
  }
}

/// One call to [FakePlayheadReporter.notePlayhead].
class PlayheadCall {
  const PlayheadCall({
    required this.infoHash,
    required this.fileIdx,
    required this.filmSeconds,
    required this.durationSeconds,
  });

  final String infoHash;
  final int fileIdx;
  final double filmSeconds;
  final double durationSeconds;
}
