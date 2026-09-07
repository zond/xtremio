import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/up_next_card.dart';
import 'package:xtremio/shell/device_profile.dart';

/// The card the player offers when an episode ends. Its layout, which is
/// the whole of it: what it says is a countdown and two buttons.
void main() {
  const tv = DeviceProfile(isTv: true, hasTouch: false);

  /// A title long enough to take the card out to its full width, so that
  /// where the buttons sit inside it is a question with an answer.
  const title = 'The One With All The Rest Of The Words In The Episode Name';
  Future<void> pump(WidgetTester tester, {DeviceProfile device = tv}) =>
      tester.pumpWidget(
        DeviceScope(
          profile: device,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: UpNextCard(
                  label: 'S1E2',
                  title: title,
                  secondsLeft: 5,
                  onPlay: () {},
                  onDismiss: () {},
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('Cancel and Play sit at the card\'s trailing edge', (
    tester,
  ) async {
    // Where they were when the row was a [Row]: a card that is a question
    // puts its answers where an answer is looked for, at the end of the
    // line the reading finishes on. A [Wrap] under a [Column]'s cross
    // axis is handed loose constraints and takes the width of its
    // children, so `WrapAlignment.end` has nothing to distribute and the
    // buttons come out flush left, under the "Up next" label.
    await pump(tester);

    final text = tester.getRect(find.text('S1E2 · $title'));
    final play = tester.getRect(find.widgetWithText(FilledButton, 'Play now'));
    final cancel = tester.getRect(find.widgetWithText(TextButton, 'Cancel'));
    expect(play.right, moreOrLessEquals(text.right, epsilon: 0.5));
    expect(cancel.right, lessThan(play.left));
  });

  testWidgets('and on a phone, where the card is narrower', (tester) async {
    await pump(tester, device: DeviceProfile.fallback);

    final text = tester.getRect(find.text('S1E2 · $title'));
    final play = tester.getRect(find.widgetWithText(FilledButton, 'Play now'));
    expect(play.right, moreOrLessEquals(text.right, epsilon: 0.5));
  });
}
