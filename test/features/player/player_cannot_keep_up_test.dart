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
        "This device can't decode this AV1 video in hardware. "
        'Its processor is too slow to decode it in software. '
        'Try another stream.';
    expect(find.text(notice), findsNothing);

    harness.engine.emitCannotKeepUp('av1');
    await pumpEvents(tester);
    expect(find.text(notice), findsOneWidget);

    await tester.pump(PlayerScreen.noticeShown);
    expect(find.text(notice), findsNothing);
  });

  test('names a television as one, and a codec it does not know as none', () {
    expect(
      PlayerScreen.cannotKeepUpNotice(tv: true),
      "This TV can't decode this video in hardware. "
      'Its processor is too slow to decode it in software. '
      'Try another stream.',
    );
  });

  testWidgets('a film too large to decode here is said to be unplayable', (
    tester,
  ) async {
    useWideViewport(tester);
    final harness = PlayerHarness();
    await harness.pump(tester);
    const notice =
        "This device can't decode this AV1 video in hardware. "
        'Decoding it in software needs more memory than this device has. '
        'Try a 1080p stream or another format.';
    // The engine refuses once the film has loaded and said what it is.
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);
    expect(find.text(notice), findsNothing);

    harness.engine.emitTooLargeForSoftware('av1');
    await pumpEvents(tester);
    expect(find.text(notice), findsOneWidget);

    // It is the end of trying, not a notice that fades.
    await tester.pump(PlayerScreen.noticeShown);
    expect(find.text(notice), findsOneWidget);
  });

  test('a television says so of itself', () {
    expect(
      PlayerScreen.tooLargeForSoftwareNotice(tv: true, codec: 'av1'),
      "This TV can't decode this AV1 video in hardware. "
      'Decoding it in software needs more memory than this TV has. '
      'Try a 1080p stream or another format.',
    );
  });
}
