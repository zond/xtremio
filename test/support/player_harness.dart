import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/cast/cast_client.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_controls.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/tv_density.dart';

import 'fake_core_client.dart';
import 'fake_playback_engine.dart';
import 'fake_subtitle_match_client.dart';
import 'fake_torrent_stats_client.dart';
import 'fixtures.dart';

/// A [PlayerScreen] over a fake core and a fake engine, as the widget tests
/// mount it: scopes above `MaterialApp` (like the app), the recorded
/// public-domain torrent as the `player` state and the anonymous profile
/// (default settings) as `ctx` unless given others.
class PlayerHarness {
  PlayerHarness({
    Map<String, dynamic>? player,
    Map<String, dynamic>? ctx,
    this.stream,
    this.streamRequest,
    this.metaRequest,
    this.subtitlesPath,
    this.configureEngine,
    this.device,
    this.downloads,
    this.cast,
    this.lanMedia,
    this.prefs,
    DhtStatus? dhtStatus,
  }) : dhtStatus = dhtStatus ?? _dhtDisabled,
       fixture = player ?? loadPlayerFixture() {
    core = FakeCoreClient(
      state: {
        CoreField.player: fixture,
        CoreField.ctx: ctx ?? loadCtxLoggedOutFixture(),
      },
    );
  }

  final Map<String, dynamic> fixture;
  late final FakeCoreClient core;

  /// What [PlaybackScope.dhtStatusOf] answers -- disabled (nothing shown
  /// anywhere) unless a test asks for a specific state.
  final DhtStatus dhtStatus;

  /// How many times the screen has asked for [dhtStatus] -- a test's proof
  /// that nothing polls it on a timer of its own.
  int dhtStatusReads = 0;

  static const DhtStatus _dhtDisabled = DhtStatus(
    enabled: false,
    nodes: 0,
    nodesV6: 0,
    everBootstrapped: false,
  );

  /// One per `PlaybackScope.createEngine` call; the first is [engine].
  final List<FakePlaybackEngine> engines = [];
  FakePlaybackEngine get engine => engines.first;
  final FakeFullscreenController fullscreen = FakeFullscreenController();

  /// What the screen asks the display to present at; nothing is ever asked
  /// of it off a television.
  final FakeDisplayFrameRate displayFrameRate = FakeDisplayFrameRate();

  /// What "Match to another subtitle" asks; answers nothing until a test
  /// sets [FakeSubtitleMatchClient.response].
  final FakeSubtitleMatchClient subtitleMatch = FakeSubtitleMatchClient();

  /// What the start-up overlay polls; answers nothing (`null`) until a test
  /// sets [FakeTorrentStatsClient.response].
  late final FakeTorrentStatsClient torrentStats = FakeTorrentStatsClient()
    ..callLog = calls;

  /// Engine opens (`'open'`) and stats fetches (`'stats'`), in the order
  /// they happened.
  final List<String> calls = [];

  /// Applied to every engine before the screen gets it: how a test makes
  /// the first `open` fail, which happens during the first pump.
  final void Function(FakePlaybackEngine engine)? configureEngine;

  final Map<String, dynamic>? stream;
  final ResourceRequest? streamRequest;
  final ResourceRequest? metaRequest;
  final ResourcePath? subtitlesPath;

  /// The device the screen is mounted on; null leaves it to the
  /// `DeviceScope`-less default (a phone or desktop), `tv` (from
  /// `support/tv.dart`) puts it on a television.
  final DeviceProfile? device;

  /// The downloads client above the screen, or null for no
  /// [DownloadsScope] at all -- which is what most players run under and
  /// what the screen has to keep working without.
  final DownloadsClient? downloads;

  /// The cast sender and the LAN media listener above the screen, or null
  /// for no [CastScope] at all -- which is what a player without casting
  /// runs under, and what leaves the button off the bar.
  final CastClient? cast;
  final LanMediaControl? lanMedia;

  /// The app's preferences above the screen ([AppPrefs.bufferAhead] is what
  /// the player reads), or null for no [PrefsScope] at all -- which is what
  /// a player mounted on its own runs under and what it has to keep working
  /// without.
  final AppPrefs? prefs;

  Map<String, dynamic> get selected =>
      fixture['selected'] as Map<String, dynamic>;

  /// Keyed per harness so mounting a second harness in one test builds a
  /// fresh screen instead of updating the first one in place.
  Widget build({Widget? home}) {
    final app = CoreScope(
      client: core,
      child: PlaybackScope(
        createEngine: () {
          final engine = FakePlaybackEngine()..callLog = calls;
          configureEngine?.call(engine);
          engines.add(engine);
          return engine;
        },
        fullscreen: fullscreen,
        torrentStats: torrentStats,
        subtitleMatch: subtitleMatch,
        displayFrameRate: displayFrameRate,
        dhtStatus: () {
          dhtStatusReads++;
          return dhtStatus;
        },
        child: MaterialApp(
          // As `XtremioApp` builds it: the television's text scale and
          // overscan band reach the player through the navigator.
          builder: (this.device?.isTv ?? false) ? TvMediaQuery.builder : null,
          home: home ?? screen(),
        ),
      ),
    );
    final device = this.device;
    final downloads = this.downloads;
    final cast = this.cast;
    final casted = cast == null
        ? app
        : CastScope(client: cast, lanMedia: lanMedia, child: app);
    final scoped = downloads == null
        ? casted
        : DownloadsScope(client: downloads, child: casted);
    final prefs = this.prefs;
    final withPrefs = prefs == null
        ? scoped
        : PrefsScope(prefs: prefs, child: scoped);
    return KeyedSubtree(
      key: ObjectKey(this),
      child: device == null
          ? withPrefs
          : DeviceScope(profile: device, child: withPrefs),
    );
  }

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

  /// The current profile settings of the fake core's `ctx`.
  ProfileSettings get settings =>
      ProfileState.fromCtx(core.stateOf(CoreField.ctx) ?? const {}).settings;

  /// Every dispatched `UpdateSettings` map, in order.
  List<Map<String, dynamic>> settingsUpdates() => [
    for (final action in core.dispatched)
      if (action.field == CoreField.ctx &&
          action.action['args']?['action'] == 'UpdateSettings')
        action.action['args']['args'] as Map<String, dynamic>,
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
///
/// Anchored on the top bar, which is built inside that layer and only
/// there. The stack has other `SafeArea` children -- the stats panel, the
/// up-next card, the subtitle timing panel -- and which of them is last
/// depends on what the test has opened.
double controlsOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find.ancestor(
        of: find.byType(PlayerTopBar),
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
