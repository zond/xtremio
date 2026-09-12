import 'package:xtremio/core/server_client.dart';

/// A [PlayheadReporter] that records instead of telling the server.
///
/// What a test reads it for is the thing the server cannot work out on its
/// own: that the app said where the player was, for the film on screen, and
/// with the player's own two numbers rather than a guess derived from one
/// of them.
class FakePlayheadReporter implements PlayheadReporter {
  final List<PlayheadCall> reports = [];

  /// When set, `notePlayhead` also appends `'playhead'` here: the log
  /// shared with the other fakes.
  List<String>? callLog;

  @override
  Future<void> notePlayhead({
    required String infoHash,
    required int fileIdx,
    required int offset,
    required double filmSeconds,
    required bool playing,
  }) async {
    callLog?.add('playhead');
    reports.add(
      PlayheadCall(
        infoHash: infoHash,
        fileIdx: fileIdx,
        offset: offset,
        filmSeconds: filmSeconds,
        playing: playing,
      ),
    );
  }
}

/// One call to [FakePlayheadReporter.notePlayhead].
class PlayheadCall {
  const PlayheadCall({
    required this.infoHash,
    required this.fileIdx,
    required this.offset,
    required this.filmSeconds,
    required this.playing,
  });

  final String infoHash;
  final int fileIdx;
  final int offset;
  final double filmSeconds;
  final bool playing;
}
