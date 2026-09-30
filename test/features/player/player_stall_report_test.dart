import 'package:flutter/services.dart';
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

    // By the torrent's media id, once it has resolved: the server knows
    // which torrent that is, and nothing is taken apart from a URL.
    expect(harness.mediaIds.registered.single.pathSegments.first, infoHash);
    expect(harness.hints.mediaOpened, ['m1']);
    expect(harness.hints.opened, isEmpty);
    expect(harness.hints.mediaStalls, isEmpty);
  });

  testWidgets('buffering counts as a stall only once the video has played', (
    tester,
  ) async {
    final harness = bunny();
    await harness.pump(tester);

    harness.engine.emitBuffering(true);
    await pumpEvents(tester);
    expect(
      harness.hints.mediaStalls,
      isEmpty,
      reason: "the open's own wait, before a frame, is not a stall",
    );
    harness.engine.emitBuffering(false);
    // On load mpv reports zero and then the resume point: a jump, not
    // playback. Counting it as playback would report the open's own wait
    // as a stall.
    harness.engine.emitPosition(const Duration(seconds: 897));
    harness.engine.emitBuffering(true);
    await pumpEvents(tester);
    expect(
      harness.hints.mediaStalls,
      isEmpty,
      reason: 'a jump to the resume point is a load, not playback',
    );
    harness.engine.emitBuffering(false);
    harness.engine.emitPosition(const Duration(milliseconds: 897_250));
    harness.engine.emitBuffering(true);
    await pumpEvents(tester);
    expect(
      harness.hints.mediaStalls,
      isEmpty,
      reason: 'a quarter of a second of film is not yet watching',
    );

    // Two seconds of it is, and the popup after that is a stall.
    harness.engine.emitBuffering(false);
    harness.engine.emitPosition(const Duration(milliseconds: 898_250));
    harness.engine.emitPosition(const Duration(milliseconds: 899_250));
    await pumpEvents(tester);

    harness.engine.emitBuffering(true);
    await pumpEvents(tester);
    expect(harness.hints.mediaStalls, [
      'm1',
    ], reason: 'the popup, after the film has actually been playing');

    harness.engine.emitBuffering(false);
    harness.engine.emitPosition(const Duration(milliseconds: 899_500));
    harness.engine.emitBuffering(true);
    await pumpEvents(tester);
    expect(harness.hints.mediaStalls, [
      'm1',
      'm1',
    ], reason: 'every stall is one report; the server counts them');
  });

  testWidgets('buffering after a seek is not a stall', (tester) async {
    final harness = bunny();
    await harness.pump(tester);
    harness.engine.emitPosition(const Duration(seconds: 897));
    harness.engine.emitPosition(const Duration(milliseconds: 898_000));
    harness.engine.emitPosition(const Duration(milliseconds: 899_000));
    await pumpEvents(tester);

    // A ten-second step with the arrow key: the buffering that follows is
    // the new window filling, which the server sizes on its own.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    harness.engine.emitPosition(const Duration(milliseconds: 907_250));
    harness.engine.emitBuffering(true);
    await pumpEvents(tester);
    expect(
      harness.hints.mediaStalls,
      isEmpty,
      reason: 'a seek deepens nothing, whatever it waits for',
    );

    // Watching again -- two seconds of film -- and the next popup is a
    // stall.
    harness.engine.emitBuffering(false);
    harness.engine.emitPosition(const Duration(milliseconds: 908_250));
    await pumpEvents(tester);
    harness.engine.emitPosition(const Duration(milliseconds: 909_250));
    await pumpEvents(tester);
    harness.engine.emitBuffering(true);
    await pumpEvents(tester);
    expect(harness.hints.mediaStalls, ['m1']);
  });

  testWidgets('a scrub back is not a run of stalls', (tester) async {
    // The remote's rewind key reaches mpv directly, so this player never
    // sees a seek: it sees the position jump backwards, and without this
    // rule a few frames playing between two rewinds would re-arm the
    // report as a stall each time.
    final harness = bunny();
    await harness.pump(tester);
    harness.engine.emitPosition(const Duration(seconds: 6200));
    await pumpEvents(tester);
    harness.engine.emitPosition(const Duration(seconds: 6201));
    await pumpEvents(tester);
    harness.engine.emitPosition(const Duration(seconds: 6202));
    await pumpEvents(tester);
    expect(
      harness.hints.mediaStalls,
      isEmpty,
      reason: 'nothing has buffered yet',
    );

    for (final at in const [6190, 6180, 6170, 6157, 6145, 6133]) {
      // The rewind, seen only as the position moving back...
      harness.engine.emitPosition(Duration(seconds: at));
      await pumpEvents(tester);
      // ...the frames that play while the next one is pressed...
      harness.engine.emitPosition(Duration(milliseconds: at * 1000 + 300));
      await pumpEvents(tester);
      // ...and the buffering the rewind itself caused.
      harness.engine.emitBuffering(true);
      await pumpEvents(tester);
      harness.engine.emitBuffering(false);
      await pumpEvents(tester);
    }
    expect(
      harness.hints.mediaStalls,
      isEmpty,
      reason: 'a rewind is a seek, whoever asked mpv for it',
    );

    // And once the viewer settles down to watch, a stall counts again.
    harness.engine.emitPosition(const Duration(milliseconds: 6134_300));
    await pumpEvents(tester);
    harness.engine.emitPosition(const Duration(milliseconds: 6135_300));
    await pumpEvents(tester);
    harness.engine.emitBuffering(true);
    await pumpEvents(tester);
    expect(harness.hints.mediaStalls, ['m1']);
  });
}
