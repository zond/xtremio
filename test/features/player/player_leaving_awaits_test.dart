import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/cast/cast_client.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/subtitle_match.dart';
import 'package:xtremio/features/player/subtitle_timing.dart';
import 'package:xtremio/features/player/track_menus.dart';

import '../../support/fake_cast_client.dart';
import '../../support/fake_downloads_client.dart';
import '../../support/fixtures.dart';
import '../../support/player_harness.dart';

/// The awaits that were already in flight when the viewer left.
///
/// `player_leaving_test.dart` is about what *arrives* during the teardown
/// wait, and `PlayerScreen._detach` is the answer to all of it: a screen
/// with no subscriptions, no listeners and no timers cannot be reached by
/// an event. It cannot reach a continuation that is already suspended.
/// An `await` that was out when the press landed is neither a
/// subscription nor a timer, and it resumes into the middle of the wait --
/// into a screen that is *more* alive than the one its `mounted` guard was
/// written against, since the player now stays until mpv has stopped
/// instead of popping at the press. Every such guard passes exactly when
/// it used to fail.
///
/// So this file is the other half, and it is a list rather than a handful
/// of cases: one row per await in `PlayerScreen` whose continuation can
/// reach the engine, the core, the cast client or the navigator. Each row
/// puts its await in flight, leaves the player, and then lets the await
/// answer.
///
/// The three awaits not listed here are listed for the next reader
/// instead. `_pollTorrentStats` is deliberately absent: its continuation
/// reaches none of the four -- a poll that lands late only rebuilds a
/// screen that is drawing the picture anyway. `_leave`'s own
/// `_endPlayback` is the teardown, which is the one thing that *is*
/// supposed to run. And the `showModalBottomSheet` inside `_showSheet` is
/// covered from the rows that open one.
/// A player with an await of its own out and unanswered.
typedef Suspended = ({
  PlayerHarness harness,
  FakeCastClient? cast,
  FakeLanMediaControl? lan,
  void Function() answer,
});

/// One await: what it is, what its continuation can reach, and how to
/// leave a player in the middle of it.
typedef InFlight = ({
  String what,
  String reaches,
  Future<Suspended> Function(WidgetTester, Completer<void> wedged) suspend,
});

void main() {
  const livingRoom = CastDevice(
    id: 'device-1',
    name: 'Living Room TV',
    model: 'Chromecast',
  );

  const plainUrl = 'https://subs.example.org/en-plain.srt';
  const otherUrl = 'https://subs.example.org/en-other.srt';

  Map<String, dynamic> upload(String id, String url, String group) => {
    'id': id,
    'lang': 'eng',
    'url': url,
    'releaseGroup': group,
  };

  /// Two English files from one addon, and no session preference: what
  /// the subtitle menu, the match picker and the timing panel all need
  /// something to work on.
  void offerSubtitles(PlayerHarness harness, {Map<String, dynamic>? prefer}) {
    harness.fixture['subtitlePreference'] = prefer;
    harness.fixture['subtitles'] = [
      {
        'request': {
          'base': 'https://subs.example.org/manifest.json',
          'path': {
            'resource': 'subtitles',
            'type': 'movie',
            'id': 'tt0063350',
            'extra': <Object>[],
          },
        },
        'content': {
          'type': 'Ready',
          'content': [
            upload('en-1', plainUrl, 'PLAIN'),
            upload('en-2', otherUrl, 'OTHER'),
          ],
        },
      },
    ];
  }

  /// Opens the timing panel, which is a row of the subtitle menu.
  Future<void> openTimingPanel(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(SubtitleMenu.adjustTimingLabel));
    await tester.pumpAndSettle();
  }

  /// Applies the upload named [group] from the subtitle menu.
  Future<void> playSubtitle(WidgetTester tester, String group) async {
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 other English file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(group));
    await tester.pumpAndSettle();
  }

  /// The recorded fixture with a filename a receiver would accept, which
  /// is what the compatibility check wants before any session starts.
  Map<String, dynamic> castableFixture() {
    final fixture = loadPlayerFixture();
    final selected =
        (fixture['selected'] as Map<String, dynamic>)['stream']
            as Map<String, dynamic>;
    selected['behaviorHints'] = {'filename': 'film.mp4'};
    final content =
        (fixture['stream'] as Map<String, dynamic>)['content'] as List<dynamic>;
    (content[1] as Map<String, dynamic>)['behaviorHints'] = {
      'filename': 'film.mp4',
    };
    return fixture;
  }

  /// Everything a screen that still thought it was in charge would move.
  ///
  /// Read once after the press that leaves and again after the await
  /// answers: what is *not* here is the unwinding a leave is entitled to
  /// do -- a session ended, a listener closed, the quit and the release
  /// themselves -- and everything else is a player being acted on after
  /// the viewer asked to stop watching.
  Map<String, int> footprint(WidgetTester tester, Suspended scene) {
    final engine = scene.harness.engine;
    return {
      'players on screen': tester.widgetList(find.byType(PlayerScreen)).length,
      // The one thing the screen is still *for* while it waits, and so
      // the one entry here that a leave may not shrink: the teardown is
      // awaited with the video in the tree so the sinks stay alive and
      // draining while mpv stops ([PlayerScreen._leave]). A continuation
      // that rebuilds the picture away takes the drain with it, and the
      // teardown being waited for is what can then block.
      'video surface': tester.widgetList(find.text('video surface')).length,
      'engines built': scene.harness.engines.length,
      'opens': engine.opened.length,
      'seeks': engine.seeks.length,
      'plays': engine.playCalls,
      'pauses': engine.pauseCalls,
      'subtitle files added': engine.externalSubtitles.length,
      'subtitle tracks set': engine.setSubtitleTrackIds.length,
      'sub-speed writes': engine.subtitleSpeeds.length,
      'sub-delay writes': engine.subtitleDelays.length,
      'core actions': scene.harness.core.dispatched.length,
      'cast loads': scene.cast?.loads.length ?? 0,
      'cast plays': scene.cast?.plays ?? 0,
      'cast seeks': scene.cast?.seeks.length ?? 0,
      'LAN listener starts': scene.lan?.toggles.where((on) => on).length ?? 0,
    };
  }

  final inFlight = <InFlight>[
    (
      what: 'an open on the engine',
      reaches: 'the engine and the core',
      suspend: (tester, wedged) async {
        // `open` is a `loadfile` and a first read from the server, and
        // what follows it puts the subtitle file and its timing back and
        // tells the core what the file is called.
        final answered = Completer<void>();
        final harness = PlayerHarness(
          configureEngine: (engine) {
            engine.openPending = answered.future;
            engine.disposeGate = wedged;
          },
        );
        await harness.pumpPushed(tester);
        expect(harness.engine.opened, hasLength(1), reason: 'and it is out');
        return (
          harness: harness,
          cast: null,
          lan: null,
          answer: answered.complete,
        );
      },
    ),
    (
      what: 'a refusal to keep the whole file',
      reaches: 'the engine',
      suspend: (tester, wedged) async {
        // The registry is a round trip, and a refusal re-opens the stream
        // with the widest window instead -- a whole `open` on the engine
        // being released.
        final answered = Completer<void>();
        final downloads = FakeDownloadsClient()
          ..pending = answered.future
          ..addError = StateError('the registry could not answer');
        addTearDown(downloads.dispose);
        final harness = PlayerHarness(
          downloads: downloads,
          configureEngine: (engine) => engine.disposeGate = wedged,
        );
        await harness.pumpPushed(tester);
        await tester.tap(find.byTooltip('Playback settings'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(PlayerSettingsSheet.bufferChipKey(BufferAhead.wholeFile)),
        );
        await tester.pumpAndSettle();
        expect(downloads.added, hasLength(1), reason: 'the pin is out');
        // The sheet goes; the pin it asked for is still unanswered.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        return (
          harness: harness,
          cast: null,
          lan: null,
          answer: answered.complete,
        );
      },
    ),
    (
      what: 'a mark on the timing panel',
      reaches: 'the engine',
      suspend: (tester, wedged) async {
        // "This is right" reads `sub-start` and then writes the line
        // through the marks onto `sub-speed` and `sub-delay`.
        final answered = Completer<void>();
        final harness = PlayerHarness(
          configureEngine: (engine) => engine.disposeGate = wedged,
        );
        offerSubtitles(harness);
        await harness.pumpPushed(tester);
        await playSubtitle(tester, 'PLAIN');
        await openTimingPanel(tester);
        harness.engine
          ..cueStart = 60
          ..cueStartPending = answered.future;
        await tester.tap(find.byKey(const ValueKey('subtitle-mark')));
        await tester.pumpAndSettle();
        expect(harness.engine.cueStartReads, 1, reason: 'the read is out');
        await tester.tap(find.byKey(const ValueKey('subtitle-timing-close')));
        await tester.pumpAndSettle();
        return (
          harness: harness,
          cast: null,
          lan: null,
          answer: answered.complete,
        );
      },
    ),
    (
      what: 'a subtitle match',
      reaches: 'the engine',
      suspend: (tester, wedged) async {
        // Two files fetched and scored in Rust: seconds, and a convincing
        // answer is applied to `sub-speed` and `sub-delay` on the way back.
        final answered = Completer<void>();
        final harness = PlayerHarness(
          configureEngine: (engine) => engine.disposeGate = wedged,
        );
        offerSubtitles(harness);
        await harness.pumpPushed(tester);
        await playSubtitle(tester, 'PLAIN');
        harness.subtitleMatch
          ..pending = answered.future
          ..response = const SubtitleMatch(
            ratio: 1.0424,
            offset: 1.5,
            score: 0.74,
            cues: 694,
            referenceCues: 683,
            convincing: true,
          );
        await openTimingPanel(tester);
        await tester.tap(find.text(SubtitleTimingOverlay.matchLabel));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OTHER'));
        await tester.pumpAndSettle();
        expect(harness.subtitleMatch.calls, hasLength(1));
        await tester.tap(find.byKey(const ValueKey('subtitle-timing-close')));
        await tester.pumpAndSettle();
        return (
          harness: harness,
          cast: null,
          lan: null,
          answer: answered.complete,
        );
      },
    ),
    (
      what: "the auto-pick's refusal",
      reaches: 'the engine',
      suspend: (tester, wedged) async {
        // `sub-add` is mpv fetching a URL under `network-timeout`, so a
        // rejection can land minutes after the call; putting the file
        // back is a whole reset of the timing.
        final answered = Completer<void>();
        final harness = PlayerHarness(
          configureEngine: (engine) => engine.disposeGate = wedged,
        );
        offerSubtitles(
          harness,
          prefer: {'enabled': true, 'source': 'external', 'language': 'eng'},
        );
        await harness.pumpPushed(tester);
        harness.engine
          ..subtitleError = StateError('mpv: no')
          ..subtitleGate = answered;
        harness.engine.emitDuration(const Duration(minutes: 96));
        harness.engine.emitPlaying(true);
        await pumpEvents(tester);
        expect(
          harness.engine.externalSubtitles,
          hasLength(1),
          reason: 'the pick is out and unanswered',
        );
        return (
          harness: harness,
          cast: null,
          lan: null,
          answer: answered.complete,
        );
      },
    ),
    (
      what: 'a hand-over from the disk',
      reaches: 'the navigator',
      suspend: (tester, wedged) async {
        // The registry answers, and a second player takes this one's
        // place: a second engine and a fresh open, over a screen that is
        // waiting for its own teardown.
        final answered = Completer<void>();
        final downloads = FakeDownloadsClient()..pending = answered.future;
        addTearDown(downloads.dispose);
        final ctx = loadCtxLoggedOutFixture();
        ctx['profile']['settings']['nextVideoNotificationDuration'] = 10000;
        final harness = PlayerHarness(
          ctx: ctx,
          downloads: downloads,
          configureEngine: (engine) => engine.disposeGate = wedged,
        );
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
        await harness.pumpPushed(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
        await tester.pumpAndSettle();
        expect(downloads.opens, hasLength(1), reason: 'the ask is out');
        return (
          harness: harness,
          cast: null,
          lan: null,
          answer: answered.complete,
        );
      },
    ),
    (
      what: 'a cast start',
      reaches: 'the engine, the cast client and the LAN listener',
      suspend: (tester, wedged) async {
        // Measured with a `connect` that takes two seconds: the engine is
        // paused, the listener is opened, and the receiver is handed the
        // film -- the viewer pressed Back and the film started on their
        // television.
        final answered = Completer<void>();
        final cast = FakeCastClient(devices: const [livingRoom]);
        cast.connectPending = answered.future;
        final lan = FakeLanMediaControl()
          ..baseUrl = Uri.parse('http://192.168.1.20:39271/');
        final harness = PlayerHarness(
          player: castableFixture(),
          cast: cast,
          lanMedia: lan,
          configureEngine: (engine) => engine.disposeGate = wedged,
        );
        await harness.pumpPushed(tester);
        await tester.tap(find.byKey(const ValueKey('cast')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('cast-device-device-1')));
        await tester.pumpAndSettle();
        expect(cast.connectAttempts, hasLength(1), reason: 'the start is out');
        expect(cast.loads, isEmpty, reason: 'and nothing has been handed over');
        return (
          harness: harness,
          cast: cast,
          lan: lan,
          answer: answered.complete,
        );
      },
    ),
    (
      what: "a cast start's pause",
      reaches: 'the cast client and the tree the picture is in',
      suspend: (tester, wedged) async {
        // The step after the session and the URL: local playback stops
        // before the receiver starts. mpv answers a `pause` when its
        // command queue gets to it, and what came back then handed the
        // receiver the film -- and, worse, wrote `_castingTo` from inside
        // a `setState`, which takes the video out of the tree for the
        // rest of the teardown wait and leaves nothing draining the sinks
        // mpv is still being stopped through.
        final answered = Completer<void>();
        // A receiver accepting the media is its own round trip, and it is
        // long enough for a frame: without it every step of the fall-through
        // runs in one turn of the microtask queue and the picture the
        // `setState` took away is back before anything is drawn. The
        // measurement is about what is on screen *during* the load.
        final cast = FakeCastClient(devices: const [livingRoom])
          ..loadDelay = const Duration(milliseconds: 200);
        final lan = FakeLanMediaControl()
          ..baseUrl = Uri.parse('http://192.168.1.20:39271/');
        final harness = PlayerHarness(
          player: castableFixture(),
          cast: cast,
          lanMedia: lan,
          configureEngine: (engine) => engine
            ..pausePending = answered.future
            ..disposeGate = wedged,
        );
        await harness.pumpPushed(tester);
        await tester.tap(find.byKey(const ValueKey('cast')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('cast-device-device-1')));
        await tester.pumpAndSettle();
        expect(harness.engine.pauseCalls, 1, reason: 'the pause is out');
        expect(cast.loads, isEmpty, reason: 'and nothing has been handed over');
        return (
          harness: harness,
          cast: cast,
          lan: lan,
          answer: answered.complete,
        );
      },
    ),
    (
      what: 'a cast being stopped',
      reaches: 'the engine',
      suspend: (tester, wedged) async {
        // Ending a session brings the film back to this device: a seek to
        // where the receiver got to, and a play, on the engine that is
        // being released.
        final answered = Completer<void>();
        final cast = FakeCastClient(devices: const [livingRoom]);
        final lan = FakeLanMediaControl()
          ..baseUrl = Uri.parse('http://192.168.1.20:39271/');
        final harness = PlayerHarness(
          player: castableFixture(),
          cast: cast,
          lanMedia: lan,
          configureEngine: (engine) => engine.disposeGate = wedged,
        );
        await harness.pumpPushed(tester);
        await tester.tap(find.byKey(const ValueKey('cast')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('cast-device-device-1')));
        await tester.pumpAndSettle();
        expect(cast.loads, hasLength(1), reason: 'the receiver has it');
        cast.disconnectPending = answered.future;
        await tester.tap(find.byKey(const ValueKey('cast')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('cast-stop')));
        await tester.pumpAndSettle();
        return (
          harness: harness,
          cast: cast,
          lan: lan,
          answer: answered.complete,
        );
      },
    ),
  ];

  for (final row in inFlight) {
    testWidgets('${row.what}, answered after the viewer leaves, does not '
        'reach ${row.reaches}', (tester) async {
      final wedged = Completer<void>();
      final scene = await row.suspend(tester, wedged);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        scene.harness.engine.disposeAsked,
        isTrue,
        reason: 'the teardown has begun and is being waited for',
      );
      final before = footprint(tester, scene);

      scene.answer();
      await tester.pumpAndSettle();

      expect(footprint(tester, scene), before);

      wedged.complete();
      await tester.pumpAndSettle();
      expect(find.byType(PlayerScreen), findsNothing);
      expect(scene.harness.engine.disposed, isTrue);
    });
  }
}
