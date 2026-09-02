import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/player_controls.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/seek_bar.dart';

import '../../support/player_harness.dart';

/// Our own controls over the video: visibility, transport, seek bar, time,
/// volume, fullscreen and the keyboard.
void main() {
  const total = Duration(minutes: 96);

  Future<PlayerHarness> pumpPlaying(WidgetTester tester) async {
    useWideViewport(tester);
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitDuration(total);
    harness.engine.emitPosition(const Duration(seconds: 65));
    await pumpEvents(tester);
    return harness;
  }

  testWidgets('controls fade while playing and come back on input', (
    tester,
  ) async {
    final harness = await pumpPlaying(tester);
    final engine = harness.engine;

    // Not playing yet: the controls stay put past the timeout.
    expect(find.byTooltip('Play (Space)'), findsOneWidget);
    expect(find.byType(PlayerTopBar), findsOneWidget);
    await tester.pump(PlayerScreen.controlsTimeout * 2);
    await tester.pumpAndSettle();
    expect(controlsOpacity(tester), 1);
    expect(engine.lastSubtitleBottomPadding, 96);

    // Playing: gone after the idle timeout, subtitles drop to the edge.
    engine.emitPlaying(true);
    await pumpEvents(tester);
    await tester.pump(PlayerScreen.controlsTimeout);
    await tester.pumpAndSettle();
    expect(controlsOpacity(tester), 0);
    expect(engine.lastSubtitleBottomPadding, 24);

    // A tap on the video brings them back, another hides them.
    await tapVideo(tester);
    expect(controlsOpacity(tester), 1);
    await tapVideo(tester);
    expect(controlsOpacity(tester), 0);

    // Mouse movement shows them and restarts the idle timer.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('video surface')));
    await tester.pumpAndSettle();
    expect(controlsOpacity(tester), 1);
    await tester.pump(PlayerScreen.controlsTimeout ~/ 2);
    await mouse.moveBy(const Offset(5, 0));
    await tester.pump(PlayerScreen.controlsTimeout ~/ 2);
    await tester.pumpAndSettle();
    expect(controlsOpacity(tester), 1);
    await tester.pump(PlayerScreen.controlsTimeout);
    await tester.pumpAndSettle();
    expect(controlsOpacity(tester), 0);

    // Any key shows them; pausing keeps them up.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(controlsOpacity(tester), 1);
    engine.emitPlaying(false);
    await pumpEvents(tester);
    await tester.pump(PlayerScreen.controlsTimeout * 2);
    await tester.pumpAndSettle();
    expect(controlsOpacity(tester), 1);
    expect(find.byTooltip('Play (Space)'), findsOneWidget);
  });

  testWidgets('play/pause and skip buttons drive the engine and the core', (
    tester,
  ) async {
    final harness = await pumpPlaying(tester);
    final engine = harness.engine;
    expect(find.text('1:05 / 1:36:00'), findsOneWidget);

    await tester.tap(find.byTooltip('Play (Space)'));
    await tester.pump();
    expect(engine.playOrPauseCalls, 1);
    engine.emitPlaying(true);
    await pumpEvents(tester);
    expect(find.byTooltip('Pause (Space)'), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsOneWidget);

    // +10 s: the engine seeks, the core gets a Seek, the time text follows.
    await tester.tap(find.byTooltip('Forward 10 seconds (→)'));
    await tester.pump();
    expect(engine.seeks, [const Duration(seconds: 75)]);
    expect(harness.lastPlayerArgs('Seek'), {
      'time': 75000,
      'duration': total.inMilliseconds,
      'device': isNotEmpty,
    });
    expect(find.text('1:15 / 1:36:00'), findsOneWidget);

    // The next position report is not throttled away after a seek, even
    // though it lands within a second of the last report.
    engine.emitPosition(const Duration(milliseconds: 75300));
    await pumpEvents(tester);
    expect(harness.lastPlayerArgs('TimeChanged')?['time'], 75300);

    await tester.tap(find.byTooltip('Back 10 seconds (←)'));
    await tester.pump();
    expect(engine.seeks.last, const Duration(milliseconds: 65300));

    // Tapping the time shows what is left.
    await tester.tap(find.text('1:05 / 1:36:00'));
    await tester.pump();
    expect(find.text('-1:34:54 / 1:36:00'), findsOneWidget);
  });

  testWidgets('the seek bar seeks on tap and once at the end of a drag', (
    tester,
  ) async {
    final harness = await pumpPlaying(tester);
    final engine = harness.engine;
    engine.emitBuffer(const Duration(minutes: 30));
    await pumpEvents(tester);
    final bar = find.byType(SeekBar);
    expect(tester.widget<SeekBar>(bar).buffered, const Duration(minutes: 30));
    final rect = tester.getRect(bar);
    Offset at(double fraction) =>
        Offset(rect.left + rect.width * fraction, rect.center.dy);
    Duration expected(double fraction) =>
        Duration(milliseconds: (total.inMilliseconds * fraction).round());

    await tester.tapAt(at(0.25));
    await tester.pump();
    expect(engine.seeks, [expected(0.25)]);
    expect(
      harness.lastPlayerArgs('Seek')?['time'],
      expected(0.25).inMilliseconds,
    );

    // Dragging shows the time under the pointer and seeks nowhere yet.
    final drag = await tester.startGesture(at(0.5));
    await drag.moveTo(at(0.6));
    await drag.moveTo(at(0.75));
    await tester.pump();
    expect(find.text('1:12:00'), findsOneWidget);
    expect(engine.seeks, hasLength(1));
    await drag.up();
    await tester.pump();
    expect(engine.seeks, [expected(0.25), expected(0.75)]);
    expect(find.text('1:12:00'), findsNothing);
    expect(find.text('1:12:00 / 1:36:00'), findsOneWidget);
  });

  testWidgets('volume and mute (wide layout) and fullscreen', (tester) async {
    final harness = await pumpPlaying(tester);
    final engine = harness.engine;
    expect(find.byType(Slider), findsOneWidget);

    await tester.tap(find.byTooltip('Mute (M)'));
    await tester.pump();
    expect(engine.volumes, [0.0]);
    expect(find.byIcon(Icons.volume_off), findsOneWidget);
    await tester.tap(find.byTooltip('Unmute (M)'));
    await tester.pump();
    expect(engine.volumes, [0.0, 100.0]);

    // The engine's own volume drives the icon.
    engine.emitVolume(30);
    await pumpEvents(tester);
    expect(find.byIcon(Icons.volume_down), findsOneWidget);

    await tester.tap(find.byTooltip('Fullscreen (F)'));
    await tester.pump();
    expect(harness.fullscreen.enters, 1);
    expect(find.byTooltip('Exit fullscreen (F)'), findsOneWidget);

    // Leaving the screen while fullscreen restores the window.
    await tester.pumpWidget(const SizedBox());
    expect(harness.fullscreen.exits, 1);
  });

  testWidgets('keyboard shortcuts', (tester) async {
    final harness = await pumpPlaying(tester);
    final engine = harness.engine;
    Future<void> key(LogicalKeyboardKey key, {bool shift = false}) async {
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
    }

    engine.emitPosition(const Duration(minutes: 2));
    await pumpEvents(tester);
    await key(LogicalKeyboardKey.space);
    await key(LogicalKeyboardKey.keyK);
    expect(engine.playOrPauseCalls, 2);

    await key(LogicalKeyboardKey.arrowRight);
    await key(LogicalKeyboardKey.keyJ);
    await key(LogicalKeyboardKey.arrowLeft, shift: true);
    expect(engine.seeks, [
      const Duration(minutes: 2, seconds: 10),
      const Duration(minutes: 2),
      const Duration(minutes: 1),
    ]);
    // Never before the start.
    await key(LogicalKeyboardKey.arrowLeft, shift: true);
    expect(engine.seeks.last, Duration.zero);

    await key(LogicalKeyboardKey.arrowDown);
    await key(LogicalKeyboardKey.arrowUp);
    await key(LogicalKeyboardKey.arrowUp);
    expect(engine.volumes, [95.0, 100.0, 100.0]);
    await key(LogicalKeyboardKey.keyM);
    expect(engine.volumes.last, 0.0);
    await key(LogicalKeyboardKey.keyM);
    expect(engine.volumes.last, 100.0);

    await key(LogicalKeyboardKey.keyF);
    expect(harness.fullscreen.enters, 1);
    // Escape leaves fullscreen first.
    await key(LogicalKeyboardKey.escape);
    expect(harness.fullscreen.exits, 1);
    expect(find.byType(PlayerScreen), findsOneWidget);

    // Modified keys are left alone.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(engine.playOrPauseCalls, 2);
  });

  testWidgets('phones get the transport in the middle and no volume slider', (
    tester,
  ) async {
    usePhoneViewport(tester);
    final harness = PlayerHarness();
    await harness.pump(tester);
    final engine = harness.engine;
    engine.emitDuration(total);
    engine.emitPosition(const Duration(seconds: 30));
    await pumpEvents(tester);

    expect(find.byType(PlayerCenterControls), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(find.byTooltip('Play (Space)'), findsNothing);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    expect(engine.playOrPauseCalls, 1);
    await tester.tap(find.byTooltip('Forward 10 seconds'));
    await tester.pump();
    expect(engine.seeks, [const Duration(seconds: 40)]);

    // Double-tapping the right third of the video skips ahead on touch.
    final right = Offset(380, tester.getCenter(find.text('video surface')).dy);
    await tester.tapAt(right);
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(right);
    await tester.pumpAndSettle();
    expect(engine.seeks.last, const Duration(seconds: 50));

    // While buffering the centre shows the status instead of the buttons.
    engine.emitBuffering(true);
    await pumpEvents(tester);
    expect(find.text('Buffering from the torrent…'), findsOneWidget);
    expect(find.byType(PlayerCenterControls), findsNothing);
  });

  testWidgets('a wide window keeps the transport in the bottom bar', (
    tester,
  ) async {
    final harness = await pumpPlaying(tester);
    expect(find.byType(PlayerCenterControls), findsNothing);
    expect(find.byType(PlayerBottomBar), findsOneWidget);
    expect(harness.engine.lastSubtitleBottomPadding, 96);
  });
}
