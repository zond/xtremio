import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/torrent_stall_overlay.dart';

import '../../support/player_harness.dart';

/// **The controls fade whenever they may, however they came to be allowed
/// to.**
///
/// They may not fade while something holds them up: a menu, a wait, a
/// scrub, the up-next card. When the last of those goes, the bar fades
/// [PlayerScreen.controlsTimeout] later, without a key or Back. A bar that
/// was up while one of them held it, with no fade armed, stayed up until
/// the viewer put it away.
void main() {
  Future<PlayerHarness> pumpPlaying(WidgetTester tester) async {
    useWideViewport(tester);
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(hours: 2));
    harness.engine.emitPosition(Duration.zero);
    harness.engine.emitPlaying(true);
    harness.engine.emitBuffering(false);
    await pumpEvents(tester);
    return harness;
  }

  testWidgets('the controls fade after a menu closes', (tester) async {
    await pumpPlaying(tester);
    expect(controlsOpacity(tester), 1);

    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controlsOpacity(tester), 1, reason: 'the menu has just closed');

    await tester.pump(PlayerScreen.controlsTimeout);
    await tester.pumpAndSettle();
    expect(controlsOpacity(tester), 0);
  });

  testWidgets('controls brought up while a read waits fade once reads flow '
      'again', (tester) async {
    final harness = await pumpPlaying(tester);
    final card = find.textContaining(TorrentStallOverlay.waiting);

    harness.streamNumbers.readWait = const ReadWait(
      waiting: Duration(milliseconds: 1500),
      offset: 0,
    );
    await tester.pump(PlayerScreen.readWaitInterval * 3);
    expect(card, findsOneWidget);

    // A key while the film waits brings the bar up, with nothing to fade
    // it yet.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();

    harness.streamNumbers.readWait = ReadWait.none;
    harness.engine.emitPosition(const Duration(seconds: 2));
    await tester.pump(PlayerScreen.readWaitInterval);
    await tester.pump();
    expect(card, findsNothing, reason: 'reads are flowing again');
    expect(controlsOpacity(tester), 1);

    await tester.pump(PlayerScreen.controlsTimeout);
    await tester.pumpAndSettle();
    expect(controlsOpacity(tester), 0);
  });
}
