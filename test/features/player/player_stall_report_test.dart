import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/dev/dev_streams.dart';

import '../../support/player_harness.dart';

/// **Telling the server when the player stalls, and when a new one opens.**
///
/// The server splits the pieces just ahead of the reader into claims any
/// faster peer may join, and sizes how many from the film's rate and how
/// long its split pieces have been taking. What it cannot see is the one
/// thing that says the arithmetic was not enough: the buffering popup, up
/// after the video had been playing. Each such stall has it split one more
/// piece for the rest of the video; a new player starts the count again.
///
/// The open's own wait is not a stall -- every torrent buffers before its
/// first frame, and counting that would deepen the split on every film.
void main() {
  final infoHash = DevStreams.bigBuckBunnyTorrent['infoHash'] as String;

  /// A player on a named torrent, served by the recorded local server, so
  /// the reports can be checked against a hash the test can see.
  PlayerHarness bunny() => PlayerHarness(
    player: {
      'selected': {'stream': DevStreams.bigBuckBunnyTorrent},
      'stream': {
        'type': 'Ready',
        'content': [
          {
            'streaming_url':
                '${PlayerHarness.recordedServerBaseUrl}/$infoHash/-1',
          },
          DevStreams.bigBuckBunnyTorrent,
        ],
      },
    },
    stream: DevStreams.bigBuckBunnyTorrent,
  );

  testWidgets('opening a torrent stream says so, before anything plays', (
    tester,
  ) async {
    final harness = bunny();
    await harness.pump(tester);

    expect(harness.playhead.opened, [infoHash]);
    expect(harness.playhead.stalls, isEmpty);
  });

  testWidgets('buffering counts as a stall only once the video has played', (
    tester,
  ) async {
    final harness = bunny();
    await harness.pump(tester);

    harness.engine.emitBuffering(true);
    await pumpEvents(tester);
    expect(
      harness.playhead.stalls,
      isEmpty,
      reason: "the open's own wait, before a frame, is not a stall",
    );
    harness.engine.emitBuffering(false);
    // On load mpv reports zero and then the resume point: a jump, not
    // playback. The first field log had the open's wait counted as a
    // stall because of it.
    harness.engine.emitPosition(const Duration(seconds: 897));
    harness.engine.emitBuffering(true);
    await pumpEvents(tester);
    expect(
      harness.playhead.stalls,
      isEmpty,
      reason: 'a jump to the resume point is a load, not playback',
    );
    harness.engine.emitBuffering(false);
    harness.engine.emitPosition(const Duration(milliseconds: 897_250));
    await pumpEvents(tester);

    harness.engine.emitBuffering(true);
    await pumpEvents(tester);
    expect(harness.playhead.stalls, [
      infoHash,
    ], reason: 'the popup, after the position advanced by a tick');

    harness.engine.emitBuffering(false);
    harness.engine.emitPosition(const Duration(milliseconds: 897_500));
    harness.engine.emitBuffering(true);
    await pumpEvents(tester);
    expect(harness.playhead.stalls, [
      infoHash,
      infoHash,
    ], reason: 'every stall is one report; the server counts them');
  });
}
