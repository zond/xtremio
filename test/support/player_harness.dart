import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';

import 'fake_core_client.dart';
import 'fake_playback_engine.dart';
import 'fixtures.dart';

/// A [PlayerScreen] over a fake core and a fake engine, as the widget tests
/// mount it: scopes above `MaterialApp` (like the app), the recorded
/// public-domain torrent as the `player` state unless given another.
class PlayerHarness {
  PlayerHarness({
    Map<String, dynamic>? player,
    this.stream,
    this.streamRequest,
    this.metaRequest,
    this.subtitlesPath,
  }) : fixture = player ?? loadPlayerFixture() {
    core = FakeCoreClient(state: {CoreField.player: fixture});
  }

  final Map<String, dynamic> fixture;
  late final FakeCoreClient core;

  /// One per `PlaybackScope.createEngine` call; the first is [engine].
  final List<FakePlaybackEngine> engines = [];
  FakePlaybackEngine get engine => engines.first;
  final FakeFullscreenController fullscreen = FakeFullscreenController();
  final ValueNotifier<SubtitleStyle> subtitleStyle = ValueNotifier(
    const SubtitleStyle(),
  );

  final Map<String, dynamic>? stream;
  final ResourceRequest? streamRequest;
  final ResourceRequest? metaRequest;
  final ResourcePath? subtitlesPath;

  Map<String, dynamic> get selected =>
      fixture['selected'] as Map<String, dynamic>;

  /// Keyed per harness so mounting a second harness in one test builds a
  /// fresh screen instead of updating the first one in place.
  Widget build({Widget? home}) => KeyedSubtree(
    key: ObjectKey(this),
    child: CoreScope(
      client: core,
      child: PlaybackScope(
        createEngine: () {
          final engine = FakePlaybackEngine();
          engines.add(engine);
          return engine;
        },
        fullscreen: fullscreen,
        subtitleStyle: subtitleStyle,
        child: MaterialApp(home: home ?? screen()),
      ),
    ),
  );

  PlayerScreen screen() => PlayerScreen(
    stream: stream ?? selected['stream'] as Map<String, dynamic>,
    streamRequest: streamRequest,
    metaRequest: metaRequest,
    subtitlesPath: subtitlesPath,
  );

  /// Mounts the screen and lets it open the stream.
  Future<void> pump(WidgetTester tester, {Widget? home}) async {
    await tester.pumpWidget(build(home: home));
    await tester.pumpAndSettle();
  }

  /// Every dispatched `Player` sub-action name, in order.
  List<String> playerActions() => [
    for (final action in core.dispatched)
      if (action.action['action'] == 'Player')
        action.action['args']['action'] as String,
  ];

  /// The `args` of the last dispatched `Player` sub-action named [name].
  Map<String, dynamic>? lastPlayerArgs(String name) {
    for (final action in core.dispatched.reversed) {
      if (action.action['action'] == 'Player' &&
          action.action['args']['action'] == name) {
        return action.action['args']['args'] as Map<String, dynamic>?;
      }
    }
    return null;
  }
}

/// Desktop-sized window (the wide layout).
void useWideViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Portrait phone (the narrow layout).
void usePhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// The opacity of the controls layer: 1 while shown, 0 once faded.
double controlsOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find.ancestor(
        of: find.byType(SafeArea).last,
        matching: find.byType(AnimatedOpacity),
      ),
    )
    .opacity;

/// Delivers pending engine events (one frame) and draws the result (the
/// next), like the existing player tests do.
Future<void> pumpEvents(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

/// A touch tap on the video surface. Single taps compete with the
/// double-tap recognizer, so the tap only fires after the double-tap window.
Future<void> tapVideo(WidgetTester tester, {Offset? at}) async {
  await tester.tapAt(at ?? tester.getCenter(find.text('video surface')));
  await tester.pump(kDoubleTapTimeout);
  await tester.pumpAndSettle();
}
