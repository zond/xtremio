import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/shell/device_profile.dart';

import '../../support/player_harness.dart';
import '../../support/tv.dart';

/// The player on a television is fullscreen the whole time it is up, and
/// the controls a remote cannot work are not drawn.
void main() {
  const total = Duration(minutes: 96);

  /// Mounts the player on [device] with the media loaded and playing.
  Future<PlayerHarness> pumpPlayer(
    WidgetTester tester, {
    DeviceProfile? device,
  }) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: device);
    await harness.pump(tester);
    harness.engine.emitDuration(total);
    harness.engine.emitPosition(const Duration(minutes: 2));
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);
    return harness;
  }

  testWidgets('a television is fullscreen from the moment the player opens', (
    tester,
  ) async {
    final harness = await pumpPlayer(tester, device: tv);

    expect(harness.fullscreen.enters, 1);
    expect(harness.fullscreen.exits, 0);
  });

  testWidgets('a window waits to be asked', (tester) async {
    final harness = await pumpPlayer(tester);

    expect(harness.fullscreen.enters, 0);
  });

  testWidgets('nothing on the remote leaves fullscreen', (tester) async {
    final harness = await pumpPlayer(tester, device: tv);
    // Read before a key is touched, or the totals below prove nothing: a
    // player that ignored the television and entered fullscreen *because*
    // of the F key would end on the same 1 enter and 0 exits.
    expect(harness.fullscreen.enters, 1, reason: 'fullscreen already');

    await press(tester, LogicalKeyboardKey.keyF);
    await press(tester, LogicalKeyboardKey.select);

    expect(harness.fullscreen.exits, 0, reason: 'still fullscreen');
    expect(harness.fullscreen.enters, 1, reason: 'and entered only once');
  });

  testWidgets('leaving the player gives the system its bars back', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv);
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
    expect(harness.fullscreen.enters, 1);

    // Back on a television is the way out of the player, and it never
    // stops at "leave fullscreen first" the way Esc does in a window.
    await press(tester, LogicalKeyboardKey.escape);

    expect(find.byType(PlayerScreen), findsNothing);
    expect(find.text('open'), findsOneWidget);
    expect(harness.fullscreen.exits, 1);
  });

  testWidgets('the hand-off to the next episode keeps the television '
      'fullscreen', (tester) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv);
    harness.fixture['nextVideo'] = const {
      'id': 'tt0063350:1:2',
      'title': 'The Cellar',
      'season': 1,
      'episode': 2,
    };
    harness.fixture['nextStream'] = const {
      'url': 'https://x.example/e2.mp4',
      'name': 'Direct',
    };
    await harness.pump(tester);
    harness.engine.emitDuration(total);
    await pumpEvents(tester);
    expect(harness.fullscreen.enters, 1);

    // The next-track key hands over: a second player replaces this one,
    // and this one is disposed once the replacement is in place. Leaving
    // fullscreen on the way out would drop the *new* player out of it.
    await press(tester, LogicalKeyboardKey.mediaTrackNext);
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(harness.engines, hasLength(2), reason: 'a new player took over');
    expect(harness.fullscreen.exits, 0, reason: 'never left fullscreen');
  });

  testWidgets('the controls a remote cannot work are not drawn', (
    tester,
  ) async {
    await pumpPlayer(tester, device: tv);

    expect(find.byType(Slider), findsNothing, reason: 'nothing to drag it');
    expect(find.byTooltip('Fullscreen (F)'), findsNothing);
    expect(find.byTooltip('Exit fullscreen (F)'), findsNothing);
    expect(find.byTooltip('Mute (M)'), findsOneWidget, reason: 'a key does');
  });

  testWidgets('a window keeps them', (tester) async {
    await pumpPlayer(tester);

    expect(find.byType(Slider), findsOneWidget);
    expect(find.byTooltip('Fullscreen (F)'), findsOneWidget);
  });
}
