import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/up_next_card.dart';

import '../../support/diagnostics_capture.dart';
import '../../support/player_harness.dart';

/// What the player does when the stream stops instead of ending.
///
/// libmpv is started by media_kit with `network-timeout=5` and
/// `keep-open=yes`: a read that makes no progress for five seconds arrives
/// as an end of file rather than an error, and our own server routinely
/// takes longer than that to produce the next piece of a torrent on a thin
/// swarm. Believed, that "ending" marks a film watched ten seconds in and
/// media_kit's next `play()` seeks back to 0 -- so without this, a stall
/// plays ten seconds of the film and starts it over.
void main() {
  /// Every `Ended` the core was told about.
  int endings(PlayerHarness harness) => harness.core.dispatched
      .where((action) => action.action['args']?['action'] == 'Ended')
      .length;

  test('the mpv properties this app overrides', () {
    // media_kit 1.2.6 sets `network-timeout=5`; a torrent legitimately
    // takes minutes. The value is not asserted exactly, only that it is
    // long enough to outlast a slow swarm.
    final timeout = MediaKitEngine.mpvOverrides['network-timeout'];
    expect(timeout, isNotNull);
    expect(int.parse(timeout!), greaterThanOrEqualTo(120));
  });

  testWidgets('an end of file early in the film is not the end of the film', (
    tester,
  ) async {
    final lines = captureDiagnostics();
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(hours: 2));
    harness.engine.emitPosition(const Duration(seconds: 10));
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);

    harness.engine.emitCompleted();
    await pumpEvents(tester);

    // Nothing is reported to the core: `Ended` writes the library item to
    // the end of the film, and no later correction takes that back.
    expect(endings(harness), 0);
    expect(find.byType(UpNextCard), findsNothing);
    // The stream is re-opened where playback stopped -- mpv sits at the end
    // of the file and will not go on by itself -- and the report says so.
    expect(harness.engine.opened, hasLength(2));
    expect(harness.engine.opened[1].$2, const Duration(seconds: 10));
    expect(lines, contains('info player completed at 10s of 7200s'));
    expect(
      lines.where((line) => line.contains('is not the end of the media')),
      hasLength(1),
    );
  });

  testWidgets('an end of file at the end of the film is the end of it', (
    tester,
  ) async {
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(hours: 2));
    harness.engine.emitPosition(
      const Duration(hours: 2) - const Duration(seconds: 4),
    );
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);

    harness.engine.emitCompleted();
    await pumpEvents(tester);

    expect(endings(harness), 1);
    expect(harness.engine.opened, hasLength(1));
  });

  testWidgets('a stream that keeps ending early is re-opened for as long '
      'as it takes, waiting longer each time', (tester) async {
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(hours: 2));
    harness.engine.emitPosition(const Duration(seconds: 10));
    await pumpEvents(tester);

    // The first at once; then one more multiple of the backoff each, to
    // the cap -- never a spin, and never a give-up.
    for (var n = 1; n <= 25; n++) {
      final before = harness.engine.opened.length;
      harness.engine.emitCompleted();
      await pumpEvents(tester);
      if (n > 1) {
        final wait = PlayerScreen.torrentOpenRetryBackoff * (n - 1);
        final expected = wait < PlayerScreen.openRetryBackoffCap
            ? wait
            : PlayerScreen.openRetryBackoffCap;
        await tester.pump(expected - const Duration(milliseconds: 1));
        expect(harness.engine.opened, hasLength(before), reason: 'end $n');
        await tester.pump(const Duration(milliseconds: 1));
        await pumpEvents(tester);
      }
      expect(harness.engine.opened, hasLength(before + 1), reason: 'end $n');
      expect(harness.engine.opened.last.$2, const Duration(seconds: 10));
    }
    expect(endings(harness), 0);
    expect(find.textContaining('Playback failed'), findsNothing);
  });

  testWidgets('a re-open still waiting is dropped when the screen goes', (
    tester,
  ) async {
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(hours: 2));
    harness.engine.emitPosition(const Duration(seconds: 10));
    await pumpEvents(tester);
    harness.engine.emitCompleted();
    await pumpEvents(tester);
    harness.engine.emitCompleted();
    await pumpEvents(tester);
    final opens = harness.engine.opened.length;

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(harness.engine.opened, hasLength(opens));
    // Ended here, with the wait not run out: a timer still pending at the
    // end of a test fails it, so this is the proof the wait was dropped.
  });

  testWidgets('mpv\'s own error log is captured for the report', (
    tester,
  ) async {
    final lines = captureDiagnostics();
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitEngineLog('ffmpeg/demuxer: tcp: Connection timed out');
    await pumpEvents(tester);
    expect(
      lines,
      contains('warn mpv ffmpeg/demuxer: tcp: Connection timed out'),
    );
  });
}
