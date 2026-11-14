import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../../support/player_harness.dart';

/// What the player says when this device decodes the film too slowly for
/// its picture to keep up.
void main() {
  testWidgets('says so over the picture for a while', (tester) async {
    useWideViewport(tester);
    final harness = PlayerHarness();
    await harness.pump(tester);
    const notice =
        "This device can't play this video smoothly. Try another stream.";
    expect(find.text(notice), findsNothing);

    harness.engine.emitCannotKeepUp();
    await pumpEvents(tester);
    expect(find.text(notice), findsOneWidget);

    await tester.pump(PlayerScreen.noticeShown);
    expect(find.text(notice), findsNothing);
  });

  test('names a television as one', () {
    expect(
      PlayerScreen.cannotKeepUpNotice(tv: true),
      "This TV can't play this video smoothly. Try another stream.",
    );
  });
}
