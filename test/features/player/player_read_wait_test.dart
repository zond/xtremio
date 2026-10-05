import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/torrent_stall_overlay.dart';

import '../../support/diagnostics_capture.dart';
import '../../support/fixtures.dart';
import '../../support/player_harness.dart';

/// **The stall card comes from the server's word that a read is parked.**
///
/// mpv blocked in a `stream_cb` read reports neither a stall nor a cache to
/// wait for: its picture stops. On a phone, resuming a torrent film at
/// 152 s, mpv read the head (38 s), the index at the end (26 s), then the
/// resume point, piece by piece -- and after the first the card was gone
/// while the picture stood still. The server knows when a read is waiting
/// ([ReadWait]); the player shows "Buffering from the torrent…" from it,
/// whichever read it is, and takes it down when reads flow again.
void main() {
  /// The recorded torrent, as a film half watched: resumed at 152 s of a
  /// two-hour film the last playback reported.
  Map<String, dynamic> resumed() {
    final fixture = loadPlayerFixture();
    final item = fixture['libraryItem'] as Map<String, dynamic>;
    final state = Map<String, dynamic>.of(item['state'] as Map<String, dynamic>)
      ..['timeOffset'] = 152000
      ..['duration'] = 7200000;
    item['state'] = state;
    return fixture;
  }

  final card = find.textContaining(TorrentStallOverlay.waiting);

  /// A player mpv says is playing at [at], with the server saying a read
  /// at [offset] has waited a second and a half -- and then that reads
  /// flow again.
  Future<void> parkedThenFlowing(
    WidgetTester tester, {
    required PlayerHarness harness,
    required Duration at,
    required int offset,
  }) async {
    final lines = captureDiagnostics();
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(hours: 2));
    harness.engine.emitPlaying(true);
    harness.engine.emitBuffering(false);
    harness.engine.emitPosition(at);
    await pumpEvents(tester);
    expect(card, findsNothing, reason: 'nothing waits yet');

    harness.streamNumbers.readWait = ReadWait(
      waiting: const Duration(milliseconds: 1500),
      offset: offset,
    );
    await tester.pump(PlayerScreen.readWaitInterval * 3);
    expect(
      card,
      findsOneWidget,
      reason: 'mpv says it is playing, and a read is parked',
    );
    expect(
      lines.where((line) => line.contains('at byte $offset')),
      isNotEmpty,
      reason: 'the log says which read: $lines',
    );
    expect(harness.streamNumbers.readWaitAsks.toSet(), {'m1'});

    harness.streamNumbers.readWait = ReadWait.none;
    await tester.pump(PlayerScreen.readWaitInterval);
    await tester.pump();
    expect(card, findsNothing, reason: 'reads are flowing again');
  }

  testWidgets('a read parked on the file head at the start brings the card '
      'up, and reads flowing take it down', (tester) async {
    await parkedThenFlowing(
      tester,
      harness: PlayerHarness(),
      at: Duration.zero,
      offset: 0,
    );
  });

  testWidgets('a read parked in the container index brings the card up, and '
      'reads flowing take it down', (tester) async {
    await parkedThenFlowing(
      tester,
      harness: PlayerHarness(player: resumed()),
      at: const Duration(seconds: 152),
      offset: 3999 * 1000 * 1000,
    );
  });

  testWidgets('a read parked at the resume point brings the card up, and '
      'reads flowing take it down', (tester) async {
    await parkedThenFlowing(
      tester,
      harness: PlayerHarness(player: resumed()),
      at: const Duration(seconds: 152),
      offset: 84 * 1000 * 1000,
    );
  });

  testWidgets('a read waiting while the picture moves is mpv playing out its '
      'own buffer, not a wait', (tester) async {
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(hours: 2));
    harness.engine.emitPlaying(true);
    harness.engine.emitBuffering(false);
    harness.streamNumbers.readWait = const ReadWait(
      waiting: Duration(seconds: 3),
      offset: 1 << 30,
    );
    var at = const Duration(seconds: 600);
    for (var tick = 0; tick < 6; tick++) {
      harness.engine.emitPosition(at);
      await tester.pump(PlayerScreen.readWaitInterval);
      at += PlayerScreen.readWaitInterval;
    }
    expect(card, findsNothing);
  });

  testWidgets('a paused player with a read waiting is not waiting', (
    tester,
  ) async {
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(hours: 2));
    harness.engine.emitPlaying(true);
    harness.engine.emitPosition(const Duration(seconds: 600));
    await pumpEvents(tester);
    harness.engine.emitPlaying(false);
    harness.streamNumbers.readWait = const ReadWait(
      waiting: Duration(seconds: 3),
      offset: 1 << 30,
    );
    await tester.pump(PlayerScreen.readWaitInterval * 4);
    expect(card, findsNothing);
  });

  testWidgets('a resumed film tells the server where it resumes and how long '
      'it is, before mpv is handed the id', (tester) async {
    final harness = PlayerHarness(player: resumed());
    await harness.pump(tester);
    expect(harness.mediaIds.resumes, [
      (
        id: 'm1',
        at: const Duration(seconds: 152),
        runtime: const Duration(hours: 2),
      ),
    ]);
    expect(harness.engine.opened.single.$2, const Duration(seconds: 152));
  });

  testWidgets('leaving tells the server where the viewer left the film', (
    tester,
  ) async {
    useWideViewport(tester);
    final harness = PlayerHarness(player: resumed());
    await harness.pump(
      tester,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => harness.screen())),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    harness.engine.emitDuration(const Duration(hours: 2));
    harness.engine.emitPlaying(true);
    harness.engine.emitPosition(const Duration(seconds: 1000));
    await pumpEvents(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(harness.hints.positions, [('m1', 1000.0)]);
  });
}
