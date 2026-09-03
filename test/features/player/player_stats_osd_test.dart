import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/playback_stats_overlay.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_playback_engine.dart';
import '../../support/fake_torrent_stats_client.dart';
import '../../support/fixtures.dart';

/// The stats OSD over a stream the core has already resolved, so the video
/// surface (and with it the overlay's anchor) is on screen.
void main() {
  const softwareStats = PlaybackStats(
    outputFps: 23.98,
    containerFps: 23.98,
    droppedFrames: 0,
    hwdec: 'no',
    videoCodec: 'h264 (High)',
    width: 1280,
    height: 720,
    videoBitrate: 4200000,
    cacheDuration: Duration(seconds: 12),
    pausedForCache: false,
  );

  /// The streaming-server URL the recorded player state resolved its
  /// torrent stream to, which is what the panel's last row shows.
  String playedUrl(Map<String, dynamic> fixture) {
    final content =
        (fixture['stream'] as Map<String, dynamic>)['content'] as List<dynamic>;
    return (content.first as Map<String, dynamic>)['streaming_url'] as String;
  }

  Future<FakePlaybackEngine> pumpPlayer(WidgetTester tester) async {
    final fixture = loadPlayerFixture();
    final selected = fixture['selected'] as Map<String, dynamic>;
    final core = FakeCoreClient(state: {CoreField.player: fixture});
    final engine = FakePlaybackEngine();
    await tester.pumpWidget(
      CoreScope(
        client: core,
        child: PlaybackScope(
          createEngine: () => engine,
          torrentStats: FakeTorrentStatsClient(),
          child: MaterialApp(
            home: PlayerScreen(
              stream: selected['stream'] as Map<String, dynamic>,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('video surface'), findsOneWidget);
    return engine;
  }

  final overlay = find.byType(PlaybackStatsOverlay);

  Future<void> pressShiftI(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
  }

  testWidgets('is hidden by default and samples nothing', (tester) async {
    final engine = await pumpPlayer(tester);
    expect(overlay, findsNothing);
    expect(engine.sampling, isFalse);
    await tester.pump(PlayerScreen.statsHoverTimeout * 2);
    expect(overlay, findsNothing);
  });

  testWidgets('hover shows it with the engine stats, resting hides it', (
    tester,
  ) async {
    final engine = await pumpPlayer(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('video surface')));
    await tester.pump();

    // Visible, and only now is the engine asked for samples.
    expect(overlay, findsOneWidget);
    expect(engine.sampling, isTrue);
    expect(find.text('stats: collecting…'), findsOneWidget);

    engine.emitStats(softwareStats);
    await tester.pump();
    await tester.pump();
    expect(find.text('hwdec    software (hwdec-current: no)'), findsOneWidget);
    expect(find.text('fps      23.98 out / 23.98 container'), findsOneWidget);
    expect(find.text('video    h264 (High) 1280x720'), findsOneWidget);
    expect(find.text('bitrate  4.2 Mbps'), findsOneWidget);
    expect(find.text('cache    12.0s'), findsOneWidget);

    // Keeps moving: stays up past the timeout measured from the first move.
    await tester.pump(PlayerScreen.statsHoverTimeout ~/ 2);
    await mouse.moveBy(const Offset(10, 0));
    await tester.pump(PlayerScreen.statsHoverTimeout ~/ 2);
    expect(overlay, findsOneWidget);

    // Pointer rests: gone after the timeout, and sampling stops with it.
    await tester.pump(PlayerScreen.statsHoverTimeout);
    await tester.pump();
    expect(overlay, findsNothing);
    expect(engine.sampling, isFalse);

    // Moving again brings it straight back; leaving hides it at once.
    await mouse.moveBy(const Offset(-10, 0));
    await tester.pump();
    expect(overlay, findsOneWidget);
    expect(engine.sampling, isTrue);
    await mouse.moveTo(const Offset(-1, -1));
    await tester.pump();
    expect(overlay, findsNothing);
    expect(engine.sampling, isFalse);
  });

  testWidgets('Shift+I pins it on and off regardless of hover', (tester) async {
    final engine = await pumpPlayer(tester);

    // Plain `i` is not bound.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.pump();
    expect(overlay, findsNothing);

    await pressShiftI(tester);
    expect(overlay, findsOneWidget);
    expect(engine.sampling, isTrue);
    engine.emitStats(softwareStats);
    await tester.pump();
    await tester.pump();
    expect(find.text('hwdec    software (hwdec-current: no)'), findsOneWidget);
    // The URL libmpv is playing sits at the bottom of the panel. It is
    // read out of the fixture rather than written down here: the recorder
    // runs the embedded server on an ephemeral port, so the number changes
    // every time the fixture is re-recorded.
    expect(
      find.textContaining('url      ${playedUrl(loadPlayerFixture())}'),
      findsOneWidget,
    );

    // Pinned: the hover timeout does not apply.
    await tester.pump(PlayerScreen.statsHoverTimeout * 2);
    expect(overlay, findsOneWidget);
    expect(engine.sampling, isTrue);

    // Pinned off: hovering no longer shows it.
    await pressShiftI(tester);
    expect(overlay, findsNothing);
    expect(engine.sampling, isFalse);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('video surface')));
    await tester.pump();
    expect(overlay, findsNothing);
    expect(engine.sampling, isFalse);

    // And back on.
    await pressShiftI(tester);
    expect(overlay, findsOneWidget);
    expect(engine.sampling, isTrue);
  });

  testWidgets('leaving the screen stops sampling', (tester) async {
    final engine = await pumpPlayer(tester);
    await pressShiftI(tester);
    expect(engine.sampling, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(engine.sampling, isFalse);
    // The key handler is gone with the screen.
    await pressShiftI(tester);
    expect(engine.statsListeners, 0);
  });
}
