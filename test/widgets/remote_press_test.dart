import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/widgets/remote_press.dart';

/// A focused button under a [RemotePress] that records what fires.
Widget harness(List<String> events, {bool longPress = true, bool tap = true}) =>
    MaterialApp(
      home: Scaffold(
        body: RemotePress(
          onTap: tap ? () => events.add('tap') : null,
          onLongPress: longPress ? () => events.add('long') : null,
          child: TextButton(
            autofocus: true,
            onPressed: () => events.add('button'),
            child: const Text('press me'),
          ),
        ),
      ),
    );

/// Holds [key] down for [duration], then releases it.
Future<void> hold(
  WidgetTester tester,
  LogicalKeyboardKey key,
  Duration duration,
) async {
  await tester.sendKeyDownEvent(key);
  await tester.pump(duration);
  await tester.sendKeyUpEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a short select taps on release, not on the way down', (
    tester,
  ) async {
    final events = <String>[];
    await tester.pumpWidget(harness(events));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(events, isEmpty);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(events, ['tap']);
  });

  testWidgets('the button\'s own activation no longer fires on select', (
    tester,
  ) async {
    // Without the wrapper the default shortcut would activate the button on
    // the key down and on every repeat: three taps from one held key.
    final events = <String>[];
    await tester.pumpWidget(harness(events));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(events, ['tap']);
  });

  testWidgets('select held past the timeout is one long press and no tap', (
    tester,
  ) async {
    final events = <String>[];
    await tester.pumpWidget(harness(events));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(
      RemotePress.holdDuration - const Duration(milliseconds: 1),
    );
    expect(events, isEmpty);
    await tester.pump(const Duration(milliseconds: 2));
    expect(events, [
      'long',
    ], reason: 'fires when the time is up, not on release');
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.pump(RemotePress.holdDuration);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(events, ['long']);
  });

  testWidgets('a hold with no long-press handler still taps on release', (
    tester,
  ) async {
    final events = <String>[];
    await tester.pumpWidget(harness(events, longPress: false));
    await tester.pumpAndSettle();

    await hold(tester, LogicalKeyboardKey.select, RemotePress.holdDuration * 2);
    expect(events, ['tap']);
  });

  testWidgets('the menu key is a long press', (tester) async {
    final events = <String>[];
    await tester.pumpWidget(harness(events));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(events, ['long']);
  });

  testWidgets('enter, numpad enter and the gamepad\'s A activate like select', (
    tester,
  ) async {
    // Some remotes' centre key is KEYCODE_ENTER or KEYCODE_NUMPAD_ENTER;
    // Flutter's own shortcuts activate on both.
    final events = <String>[];
    await tester.pumpWidget(harness(events));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pumpAndSettle();
    expect(events, ['tap', 'tap', 'tap']);
  });

  testWidgets('after a long press, the held key\'s repeats and release reach '
      'nothing, even what the long press put focus on', (tester) async {
    // The long press opens a dialog that takes focus while the key is still
    // down; Android goes on repeating the key until it comes up. Without
    // the swallow the first repeat presses the dialog's button.
    final events = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: RemotePress(
              onTap: () => events.add('tap'),
              onLongPress: () {
                events.add('long');
                showDialog<void>(
                  context: context,
                  builder: (_) => Dialog(
                    child: TextButton(
                      autofocus: true,
                      onPressed: () => events.add('dialog'),
                      child: const Text('in the dialog'),
                    ),
                  ),
                );
              },
              child: TextButton(
                autofocus: true,
                onPressed: () => events.add('button'),
                child: const Text('press me'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(RemotePress.holdDuration);
    await tester.pumpAndSettle();
    expect(find.text('in the dialog'), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
      await tester.pump();
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(events, ['long']);
    expect(find.text('in the dialog'), findsOneWidget);

    // The swallow ended with the release: the next press is the dialog's.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(events, ['long', 'dialog']);
  });

  testWidgets('a press after a hold whose release never came is not '
      'swallowed', (tester) async {
    final events = <String>[];
    await tester.pumpWidget(harness(events));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(RemotePress.holdDuration);
    expect(events, ['long']);
    // The release is lost (the app was in the background, say): the
    // platform's next word about the key is a fresh press.
    HardwareKeyboard.instance.clearState();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(events, ['long', 'tap']);
  });

  testWidgets('other keys and a release without a press pass through', (
    tester,
  ) async {
    final events = <String>[];
    await tester.pumpWidget(harness(events));
    await tester.pumpAndSettle();

    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    // Space is not a remote key, so the button's own shortcut handles it.
    expect(events, ['button']);
  });

  testWidgets('with neither handler the keys reach the child', (tester) async {
    final events = <String>[];
    await tester.pumpWidget(harness(events, tap: false, longPress: false));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(events, ['button']);
  });

  testWidgets('a release after focus moved away does nothing', (tester) async {
    final events = <String>[];
    final other = FocusNode();
    addTearDown(other.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              RemotePress(
                onTap: () => events.add('tap'),
                onLongPress: () => events.add('long'),
                child: TextButton(
                  autofocus: true,
                  onPressed: () {},
                  child: const Text('press me'),
                ),
              ),
              TextButton(
                focusNode: other,
                onPressed: () {},
                child: const Text('other'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A long press that opens something over the tile moves focus there
    // before the key comes up; the release must not tap the tile.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(RemotePress.holdDuration * 2);
    expect(events, ['long']);
    other.requestFocus();
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(events, ['long']);
  });
}
