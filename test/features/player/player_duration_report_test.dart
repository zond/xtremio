import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/dev/dev_streams.dart';

import '../../support/player_harness.dart';

/// **Telling the server how long the film is.**
///
/// It is the one fact about playback the server cannot work out from what
/// it serves. A film's length with its size is its bitrate, and every
/// stream's lookahead is sized from that -- because a player that is behind
/// asks for more the instant it is answered, so its reads measure the
/// server's delivery rather than its own consumption. Without a length
/// there is no honest absolute number anywhere in the retention.
///
/// This test exists because deleting the playhead report (2026-09-13) took
/// the length with it: it had been riding along in the same call, the cast
/// path had its own, and nothing here noticed. The field log that followed
/// measured a consumer at twenty-six gigabytes a second.
void main() {
  testWidgets('the player says how long the film is, without being asked', (
    tester,
  ) async {
    final harness = PlayerHarness();
    await harness.pump(tester);

    expect(
      harness.playhead.durations,
      isEmpty,
      reason: 'nothing is stated before the file says what it is',
    );

    harness.engine.emitDuration(const Duration(seconds: 6669));
    await pumpEvents(tester);

    expect(
      harness.playhead.durations,
      contains(6669),
      reason: "the film's length, which with the file's size is its bitrate",
    );
  });

  testWidgets('and says it once, not on a clock', (tester) async {
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(seconds: 6669));
    await pumpEvents(tester);
    await tester.pump(const Duration(seconds: 5));
    await pumpEvents(tester);

    expect(harness.playhead.durations, [
      6669,
    ], reason: 'a length does not go stale, so repeating it buys nothing');
  });

  testWidgets('and says it for a stream whose addon named no file', (
    tester,
  ) async {
    // The core writes `-1` when the addon gave no fileIdx and the server
    // picks the file, narrowed by the URL's `f=` filters. That is most
    // streams, and a report that treated `-1` as "no file" never reached
    // the server for any of them.
    final harness = PlayerHarness(
      player: {
        'selected': {'stream': DevStreams.bigBuckBunnyTorrent},
        'stream': {
          'type': 'Ready',
          'content': [
            {
              'streaming_url':
                  '${PlayerHarness.recordedServerBaseUrl}'
                  '/${DevStreams.bigBuckBunnyTorrent['infoHash']}/-1'
                  '?f=mkv&f=mp4',
            },
            DevStreams.bigBuckBunnyTorrent,
          ],
        },
      },
      stream: DevStreams.bigBuckBunnyTorrent,
    );
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(seconds: 6669));
    await pumpEvents(tester);

    expect(
      harness.playhead.durations,
      contains(6669),
      reason: 'the length was dropped because the URL says -1',
    );
    final file = harness.playhead.files.single;
    expect(
      file.fileIdx,
      -1,
      reason: "the URL's own spelling, for the server to resolve",
    );
    expect(file.filters, ['mkv', 'mp4'], reason: 'and its filters, in order');
  });
}
