import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/seek_bar.dart';

import '../../support/diagnostics_capture.dart';
import '../../support/player_harness.dart';

/// What the report says about a seek that did not happen.
///
/// mpv does not wait for a position it cannot reach: a demuxer that
/// reports itself unseekable makes it restore the position instead, which
/// from the sofa is the film jumping back on its own. Nothing else the
/// player writes down distinguishes that from a seek that worked.
void main() {
  const total = Duration(minutes: 96);
  const at = Duration(seconds: 65);

  /// The player playing [total] long from [at], wide enough for the whole
  /// control bar.
  Future<PlayerHarness> pumpPlaying(WidgetTester tester) async {
    useWideViewport(tester);
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitDuration(total);
    harness.engine.emitPosition(at);
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);
    return harness;
  }

  /// Taps the seek bar [fraction] of the way along, which is how far the
  /// viewer asked to go.
  Future<void> seekTo(WidgetTester tester, double fraction) async {
    final rect = tester.getRect(find.byType(SeekBar));
    await tester.tapAt(
      Offset(rect.left + rect.width * fraction, rect.center.dy),
    );
    await tester.pump();
  }

  group('mpv is told our own stream is seekable, because it is', () {
    // A demuxer decides seekability from what it could read when the file
    // opened -- a Matroska index sits at the end of the file, which on a
    // torrent arrives last -- and mpv then restores the position instead
    // of seeking. The embedded server serves any byte range and waits for
    // a cold one rather than refusing it, so this is the one place where
    // the caller really does know better than the demuxer.
    test('the embedded server is the claim', () {
      expect(
        MediaKitEngine.forcesSeekable(
          Uri.parse('http://127.0.0.1:11470/abc123/0?tr=udp%3A%2F%2Fx'),
        ),
        isTrue,
      );
      expect(
        MediaKitEngine.forcesSeekable(Uri.parse('http://localhost:43123/a/0')),
        isTrue,
      );
      expect(
        MediaKitEngine.forcesSeekable(Uri.parse('http://[::1]:11470/a/0')),
        isTrue,
      );
    });

    test('an addon answering with its own host is not', () {
      // The claim is about `server/src/routes/stream.rs`, which is not
      // what is at the other end here. A live HLS playlist really cannot
      // be seeked in, and forcing it turns a refusal the viewer sees into
      // a bar sitting at a position no packets will ever arrive for.
      expect(
        MediaKitEngine.forcesSeekable(
          Uri.parse('https://cdn.example.com/live/stream.m3u8'),
        ),
        isFalse,
      );
      expect(
        MediaKitEngine.forcesSeekable(Uri.parse('http://10.0.0.5:8080/f.mkv')),
        isFalse,
      );
      // An offline download is seekable and the demuxer knows it.
      expect(
        MediaKitEngine.forcesSeekable(Uri.parse('file:///downloads/e2.mkv')),
        isFalse,
      );
    });
  });

  testWidgets('a seek that leaves the position where it was is written down', (
    tester,
  ) async {
    final lines = captureDiagnostics();
    final harness = await pumpPlaying(tester);

    await seekTo(tester, 0.75);
    expect(harness.engine.seeks, [const Duration(minutes: 72)]);

    // mpv refused it: the next position report is where playback already
    // was, a second further on.
    harness.engine.emitPosition(const Duration(seconds: 66));
    await pumpEvents(tester);
    // Nothing is concluded until the demuxer has had time to get there.
    expect(lines, isNot(anyElement(contains('did not take'))));

    await tester.pump(PlayerScreen.seekCheckDelay);
    expect(
      lines,
      contains(
        'info player seek to 4320s did not take: the position is back at 66s '
        '(from 65s)',
      ),
    );
  });

  testWidgets('a seek refused while the film is paused is written down', (
    tester,
  ) async {
    // Scrubbing a paused film is where a viewer meets a refusal, and it
    // is the one case that reported nothing: mpv leaves `time-pos` where
    // it was, so no position arrives, and the bar is showing the target
    // because the press put it there. The bar snaps back on the next
    // press of play, long after the check has run.
    final lines = captureDiagnostics();
    useWideViewport(tester);
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitDuration(total);
    harness.engine.emitPosition(at);
    await pumpEvents(tester);

    await seekTo(tester, 0.75);
    expect(harness.engine.seeks, [const Duration(minutes: 72)]);

    await tester.pump(PlayerScreen.seekCheckDelay);
    expect(
      lines,
      contains(
        'info player seek to 4320s did not take: the position is back at 65s '
        '(from 65s)',
      ),
    );
  });

  testWidgets('a seek accepted while paused says nothing', (tester) async {
    // mpv answers a seek with a `time-pos` change whether it is playing or
    // not, so a paused seek that landed is still a report.
    final lines = captureDiagnostics();
    useWideViewport(tester);
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitDuration(total);
    harness.engine.emitPosition(at);
    await pumpEvents(tester);

    await seekTo(tester, 0.75);
    harness.engine.emitPosition(const Duration(minutes: 71, seconds: 58));
    await pumpEvents(tester);
    await tester.pump(PlayerScreen.seekCheckDelay);

    expect(lines, isNot(anyElement(contains('did not take'))));
  });

  testWidgets('a seek that lands says nothing', (tester) async {
    final lines = captureDiagnostics();
    final harness = await pumpPlaying(tester);

    await seekTo(tester, 0.75);
    // The demuxer got there, near enough: mpv seeks to a keyframe.
    harness.engine.emitPosition(const Duration(minutes: 71, seconds: 58));
    await pumpEvents(tester);
    await tester.pump(PlayerScreen.seekCheckDelay);

    expect(lines, isNot(anyElement(contains('did not take'))));
  });

  testWidgets('the report that arrives before the seek does is not it', (
    tester,
  ) async {
    // The first position mpv reports after a seek is routinely the one it
    // had before: the demuxer has not got there yet. Concluding from that
    // one would call every seek in the film a refusal.
    final lines = captureDiagnostics();
    final harness = await pumpPlaying(tester);

    await seekTo(tester, 0.75);
    harness.engine.emitPosition(at);
    await tester.pump(const Duration(milliseconds: 100));
    harness.engine.emitPosition(const Duration(minutes: 72));
    await pumpEvents(tester);
    await tester.pump(PlayerScreen.seekCheckDelay);

    expect(lines, isNot(anyElement(contains('did not take'))));
  });

  testWidgets('a seek shorter than a keyframe landing concludes nothing', (
    tester,
  ) async {
    // A seek of a few seconds lands where it started, near enough, even
    // when it works: the position it leaves behind says nothing either
    // way, and a line about it would be an invention.
    final lines = captureDiagnostics();
    final harness = PlayerHarness();
    useWideViewport(tester);
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(seconds: 60));
    harness.engine.emitPosition(const Duration(seconds: 30));
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);

    await seekTo(tester, 0.55);
    expect(harness.engine.seeks, [const Duration(seconds: 33)]);
    harness.engine.emitPosition(const Duration(seconds: 33));
    await pumpEvents(tester);
    await tester.pump(PlayerScreen.seekCheckDelay);

    expect(lines, isNot(anyElement(contains('did not take'))));
  });

  testWidgets('a position that went somewhere else is not a refusal', (
    tester,
  ) async {
    // A stream that stopped and started over reports position 0, which is
    // not where the seek was going and not where it came from either.
    // Naming that a refused seek would put the wrong cause in the report
    // for the fault that is actually there.
    final lines = captureDiagnostics();
    final harness = await pumpPlaying(tester);

    await seekTo(tester, 0.75);
    harness.engine.emitPosition(Duration.zero);
    await pumpEvents(tester);
    await tester.pump(PlayerScreen.seekCheckDelay);

    expect(lines, isNot(anyElement(contains('did not take'))));
  });

  testWidgets('a run of presses is one line, from where the run began', (
    tester,
  ) async {
    final lines = captureDiagnostics();
    final harness = await pumpPlaying(tester);

    // Three presses of +10 s with no report in between: each one moves
    // the position it shows, so the third press's own idea of where it
    // came from is the second press's target and not anywhere playback
    // has ever been.
    for (var press = 0; press < 3; press++) {
      await tester.tap(find.byTooltip('Forward 10 seconds (→)'));
      await tester.pump();
    }
    expect(harness.engine.seeks, [
      const Duration(seconds: 75),
      const Duration(seconds: 85),
      const Duration(seconds: 95),
    ]);

    harness.engine.emitPosition(const Duration(seconds: 66));
    await pumpEvents(tester);
    await tester.pump(PlayerScreen.seekCheckDelay);

    expect(lines.where((line) => line.contains('did not take')), [
      'info player seek to 95s did not take: the position is back at 66s '
          '(from 65s)',
    ]);
  });
}
