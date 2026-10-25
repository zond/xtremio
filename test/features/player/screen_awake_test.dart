import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/screen_awake.dart';

void main() {
  late StreamController<bool> playing;
  late List<bool> calls;

  setUp(() {
    playing = StreamController<bool>.broadcast();
    calls = [];
  });

  tearDown(() => playing.close());

  Widget awake({required bool initial}) => ScreenAwakeWhilePlaying(
    playing: playing.stream,
    initial: initial,
    setAwake: (value) async => calls.add(value),
    child: const SizedBox(),
  );

  testWidgets('a film that is playing when the player opens keeps the screen '
      'on', (tester) async {
    await tester.pumpWidget(awake(initial: true));
    expect(calls, [true]);
  });

  testWidgets('the screen follows play and pause, and is let go when the '
      'player closes', (tester) async {
    await tester.pumpWidget(awake(initial: false));
    expect(calls, [false]);

    playing.add(true);
    await tester.pump();
    playing.add(false);
    await tester.pump();
    playing.add(true);
    await tester.pump();
    expect(calls, [false, true, false, true]);

    await tester.pumpWidget(const SizedBox());
    expect(calls, [false, true, false, true, false]);
  });

  testWidgets('a repeat of the same state is not sent again', (tester) async {
    await tester.pumpWidget(awake(initial: true));
    playing.add(true);
    await tester.pump();
    expect(calls, [true]);
  });

  testWidgets('a rebuild keeps the hold, as the player rebuilds the video on '
      'every padding change', (tester) async {
    await tester.pumpWidget(awake(initial: true));
    await tester.pumpWidget(awake(initial: true));
    expect(calls, [true]);
  });
}
