import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/cast/cast_client.dart';
import 'package:xtremio/features/cast/cast_widgets.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../../support/fake_cast_client.dart';
import '../../support/fixtures.dart';
import '../../support/player_harness.dart';
import '../../support/tv.dart' show tv;

const livingRoom = CastDevice(
  id: 'device-1',
  name: 'Living Room TV',
  model: 'Chromecast',
);

/// The LAN address the server would answer with for a receiver: what a cast
/// URL is rebuilt on.
final lanBase = Uri.parse('http://192.168.1.20:39271/');

/// The recorded torrent player state with a filename on the stream, which is
/// the only thing that says what the file is: `/{infoHash}/{fileIdx}` does
/// not. `.mp4` is a stream a receiver could take.
Map<String, dynamic> playerWithFilename(String filename) {
  final fixture = loadPlayerFixture();
  final selected = fixture['selected'] as Map<String, dynamic>;
  final stream = selected['stream'] as Map<String, dynamic>;
  stream['behaviorHints'] = {'filename': filename};
  final content =
      (fixture['stream'] as Map<String, dynamic>)['content'] as List<dynamic>;
  (content[1] as Map<String, dynamic>)['behaviorHints'] = {
    'filename': filename,
  };
  return fixture;
}

PlayerHarness castHarness({
  String? filename = 'Night.of.the.Living.Dead.1080p.x264.AAC.mp4',
  FakeCastClient? cast,
  FakeLanMediaControl? lanMedia,
  Map<String, dynamic>? player,
  bool onTv = false,
}) => PlayerHarness(
  player: player ?? (filename == null ? null : playerWithFilename(filename)),
  cast: cast ?? FakeCastClient(devices: const [livingRoom]),
  lanMedia: lanMedia ?? (FakeLanMediaControl()..baseUrl = lanBase),
  device: onTv ? tv : null,
);

Finder get castButton => find.byKey(const ValueKey('cast'));

/// Opens the receiver list and picks the only one on it.
Future<void> castTo(WidgetTester tester, CastDevice device) async {
  await tester.tap(castButton);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('cast-device-${device.id}')));
  await tester.pumpAndSettle();
}

void main() {
  group('the cast button', () {
    testWidgets('is not on the bar until a receiver answers', (tester) async {
      useWideViewport(tester);
      final cast = FakeCastClient();
      final harness = castHarness(cast: cast);
      await harness.pump(tester);
      expect(castButton, findsNothing);

      cast.emitDevices(const [livingRoom]);
      await tester.pumpAndSettle();
      expect(castButton, findsOneWidget);
    });

    testWidgets('is never on a television, which is a receiver', (
      tester,
    ) async {
      useWideViewport(tester);
      final harness = castHarness(onTv: true);
      await harness.pump(tester);
      expect(castButton, findsNothing);
    });

    testWidgets('is absent on a platform that cannot cast', (tester) async {
      useWideViewport(tester);
      final harness = castHarness(
        cast: FakeCastClient(isSupported: false, devices: const [livingRoom]),
      );
      await harness.pump(tester);
      expect(castButton, findsNothing);
    });

    testWidgets('discovery runs only while the player is up', (tester) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final harness = castHarness(cast: cast);
      await harness.pump(tester);
      expect(cast.discoveryStarts, 1);
      expect(cast.discoveryStops, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(cast.discoveryStops, 1);
    });
  });

  group('starting a session', () {
    testWidgets('connects and loads the stream on the LAN URL', (tester) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);
      // Somewhere into the film, which is where the receiver picks it up.
      harness.engine.emitDuration(const Duration(minutes: 90));
      harness.engine.emitPosition(const Duration(minutes: 12));
      await pumpEvents(tester);

      await castTo(tester, livingRoom);

      expect(cast.connectAttempts, [livingRoom]);
      // The listener was started, and its URL asked for.
      expect(lan.toggles, [true]);
      expect(lan.running, isTrue);
      expect(cast.loads, hasLength(1));
      final (media, start) = cast.loads.single;
      // The loopback host and port are replaced by the LAN listener's; the
      // path the server serves the file on is untouched.
      expect(media.url.host, '192.168.1.20');
      expect(media.url.port, 39271);
      expect(media.url.path, '/11ea02584fa6351956f35671962ab46354d99060/0');
      expect(media.contentType, 'video/mp4');
      expect(start, const Duration(minutes: 12));
      // Local playback stopped, so the film is not running twice.
      expect(harness.engine.pauseCalls, greaterThan(0));
      expect(find.byType(CastRemotePanel), findsOneWidget);
      expect(find.text('Casting to Living Room TV'), findsOneWidget);
    });

    testWidgets('an incompatible stream is explained and never loaded', (
      tester,
    ) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(
        cast: cast,
        lanMedia: lan,
        filename: 'Night.of.the.Living.Dead.1080p.x264.DTS.mkv',
      );
      await harness.pump(tester);

      await castTo(tester, livingRoom);

      expect(find.byType(CastRefusedDialog), findsOneWidget);
      expect(find.textContaining('Matroska'), findsOneWidget);
      expect(find.textContaining('conversion'), findsOneWidget);
      expect(cast.loads, isEmpty);
      expect(cast.connectAttempts, isEmpty);
      // Nothing was opened to the network for a cast that never happened.
      expect(lan.toggles, isEmpty);
      expect(find.byType(CastRemotePanel), findsNothing);
    });

    testWidgets('a torrent nothing has named yet is a "not yet"', (
      tester,
    ) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      // The recorded fixture as it is: a torrent URL, no filename anywhere,
      // and a server that has not said what it opened. That is a question
      // still open, not a stream that cannot be cast.
      final harness = castHarness(cast: cast, filename: null);
      await harness.pump(tester);

      await castTo(tester, livingRoom);

      expect(find.byType(CastRefusedDialog), findsOneWidget);
      expect(find.text(CastRefusedDialog.defaultTitle), findsNothing);
      expect(find.textContaining('try again'), findsOneWidget);
      expect(cast.loads, isEmpty);
    });

    testWidgets('the server naming the file makes it castable, in place', (
      tester,
    ) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan, filename: null);
      await harness.pump(tester);

      await castTo(tester, livingRoom);
      expect(find.byType(CastRefusedDialog), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // The server answers the next poll with the file it actually opened.
      // Nothing is reopened and no screen is left: the same player learns
      // what it is playing.
      harness.torrentStats.response = const TorrentStats(
        phase: TorrentPhase.buffering,
        streamName: 'Night.of.the.Living.Dead.1080p.mp4',
        initialWindowReadyBytes: 0,
        initialWindowBytes: 4194304,
      );
      await tester.pump(PlayerScreen.torrentStatsInterval);
      await tester.pump();

      await castTo(tester, livingRoom);

      expect(find.byType(CastRefusedDialog), findsNothing);
      expect(cast.loads, hasLength(1));
      expect(cast.loads.single.$1.contentType, 'video/mp4');
    });

    testWidgets('a later answer with no name does not take the name back', (
      tester,
    ) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan, filename: null);
      harness.torrentStats.response = const TorrentStats(
        phase: TorrentPhase.buffering,
        streamName: 'Night.of.the.Living.Dead.1080p.mp4',
        initialWindowReadyBytes: 0,
        initialWindowBytes: 4194304,
      );
      await harness.pump(tester);
      await tester.pump(PlayerScreen.torrentStatsInterval);
      await tester.pump();

      // A restarted engine, a torrent-level answer, a server that has
      // forgotten: whatever the reason, an answer that names nothing says
      // nothing about which file this is. Which file it is does not expire.
      harness.torrentStats.response = const TorrentStats(
        phase: TorrentPhase.buffering,
        initialWindowReadyBytes: 1024,
        initialWindowBytes: 4194304,
      );
      await tester.pump(PlayerScreen.torrentStatsInterval);
      await tester.pump();

      await castTo(tester, livingRoom);

      expect(find.byType(CastRefusedDialog), findsNothing);
      expect(cast.loads.single.$1.contentType, 'video/mp4');
    });

    testWidgets('a torrent-level answer never names the file', (tester) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final harness = castHarness(cast: cast, filename: null);
      // The server has nothing for this file and answers only about the
      // torrent, where `streamName` is the file it *guessed* -- the largest
      // one, which is not what `/{infoHash}/0` streams. Judging the
      // container by it would be the same mistake in mirror image.
      harness.torrentStats
        ..response = null
        ..responses[const TorrentStatsRequest(
          infoHash: '11ea02584fa6351956f35671962ab46354d99060',
        )] = const TorrentStats(
          phase: TorrentPhase.buffering,
          streamName: 'The.Biggest.File.mp4',
          initialWindowReadyBytes: 0,
          initialWindowBytes: 4194304,
        );
      // Mounted by hand: until the fallback answers, the start-up overlay
      // is an indeterminate spinner and `pumpAndSettle` never settles.
      await tester.pumpWidget(harness.build());
      await tester.pump();
      await tester.pump(PlayerScreen.torrentStatsInterval);
      await tester.pump();

      await castTo(tester, livingRoom);

      expect(find.byType(CastRefusedDialog), findsOneWidget);
      expect(find.textContaining('try again'), findsOneWidget);
      expect(cast.loads, isEmpty);
    });

    testWidgets('the server outranks the addon about the container', (
      tester,
    ) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      // The addon claims a Matroska file; the server opened an MP4. The
      // addon is guessing about a torrent it linked to, the server has the
      // file open.
      final harness = castHarness(
        cast: cast,
        lanMedia: lan,
        filename: 'Night.of.the.Living.Dead.1080p.mkv',
      );
      harness.torrentStats.response = const TorrentStats(
        phase: TorrentPhase.buffering,
        streamName: 'Night.of.the.Living.Dead.1080p.mp4',
        initialWindowReadyBytes: 0,
        initialWindowBytes: 4194304,
      );
      await harness.pump(tester);
      // One poll: the server's answer lands before anything is cast.
      await tester.pump(PlayerScreen.torrentStatsInterval);
      await tester.pump();

      await castTo(tester, livingRoom);

      expect(find.byType(CastRefusedDialog), findsNothing);
      expect(cast.loads.single.$1.contentType, 'video/mp4');
    });

    testWidgets('a proxied stream is refused', (tester) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final fixture = playerWithFilename('clip.mp4');
      // What stremio-core resolves for a source the server has to fetch on
      // the player's behalf. The LAN listener does not serve /proxy at all.
      const proxied = 'http://127.0.0.1:39661/proxy/d/http/host/clip.mp4';
      final content =
          (fixture['stream'] as Map<String, dynamic>)['content'] as List;
      (content[0] as Map<String, dynamic>)['streaming_url'] = proxied;
      final harness = castHarness(cast: cast, lanMedia: lan, player: fixture);
      await harness.pump(tester);

      await castTo(tester, livingRoom);

      expect(find.textContaining('proxy'), findsOneWidget);
      expect(cast.loads, isEmpty);
      expect(lan.toggles, isEmpty);
    });

    testWidgets('a receiver with no route to this device is not cast to', (
      tester,
    ) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      // The listener runs, but no local interface can reach the receiver.
      final lan = FakeLanMediaControl();
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);

      await castTo(tester, livingRoom);

      expect(find.textContaining('cannot reach this device'), findsOneWidget);
      expect(cast.loads, isEmpty);
      // The session and the listener are both undone again.
      expect(cast.disconnects, 1);
      expect(lan.toggles, [true, false]);
      expect(lan.running, isFalse);
    });
  });

  group('while a receiver has the stream', () {
    testWidgets('the remote controls drive the receiver', (tester) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final harness = castHarness(cast: cast);
      await harness.pump(tester);
      harness.engine.emitDuration(const Duration(minutes: 90));
      await pumpEvents(tester);
      await castTo(tester, livingRoom);

      cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.playing,
          position: Duration(minutes: 5),
          duration: Duration(minutes: 90),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('cast-play-pause')));
      await tester.pumpAndSettle();
      expect(cast.pauses, 1);

      cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.paused,
          position: Duration(minutes: 5),
          duration: Duration(minutes: 90),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cast-play-pause')));
      await tester.pumpAndSettle();
      expect(cast.plays, 1);

      await tester.tap(find.byKey(const ValueKey('cast-forward')));
      await tester.pumpAndSettle();
      expect(cast.seeks, [const Duration(minutes: 5, seconds: 10)]);
      // The local engine was not touched by any of it.
      expect(harness.engine.playCalls, 0);
      expect(harness.engine.seeks, isEmpty);
    });

    testWidgets('the receiver keeps continue-watching moving', (tester) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final harness = castHarness(cast: cast);
      await harness.pump(tester);
      harness.engine.emitDuration(const Duration(minutes: 90));
      await pumpEvents(tester);
      await castTo(tester, livingRoom);
      final before = harness.playerActions().length;

      cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.playing,
          position: Duration(minutes: 5),
          duration: Duration(minutes: 90),
        ),
      );
      cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.paused,
          position: Duration(minutes: 6),
          duration: Duration(minutes: 90),
        ),
      );
      cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.idle,
          position: Duration(minutes: 90),
          duration: Duration(minutes: 90),
          ended: true,
        ),
      );
      await tester.pumpAndSettle();

      final actions = harness.playerActions().skip(before).toList();
      expect(actions, contains('TimeChanged'));
      expect(actions, contains('PausedChanged'));
      expect(actions, contains('Ended'));
      expect(
        harness.lastPlayerArgs('TimeChanged')?['time'],
        const Duration(minutes: 90).inMilliseconds,
      );
    });

    testWidgets('a repeated end report is only told to the core once', (
      tester,
    ) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final harness = castHarness(cast: cast);
      await harness.pump(tester);
      harness.engine.emitDuration(const Duration(minutes: 90));
      await pumpEvents(tester);
      await castTo(tester, livingRoom);

      const finished = CastStatus(
        state: CastPlayerState.idle,
        position: Duration(minutes: 90),
        duration: Duration(minutes: 90),
        ended: true,
      );
      cast.emitStatus(finished);
      cast.emitStatus(finished.at(const Duration(minutes: 90, seconds: 1)));
      await tester.pumpAndSettle();

      expect(
        harness.playerActions().where((name) => name == 'Ended'),
        hasLength(1),
      );
    });
  });

  group('ending a session', () {
    testWidgets('Stop brings playback back where the receiver got to', (
      tester,
    ) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);
      harness.engine.emitDuration(const Duration(minutes: 90));
      await pumpEvents(tester);
      await castTo(tester, livingRoom);
      cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.playing,
          position: Duration(minutes: 20),
          duration: Duration(minutes: 90),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('cast-stop-button')));
      await tester.pumpAndSettle();

      expect(cast.disconnects, 1);
      // The listener goes with the session; nothing is left on the LAN.
      expect(lan.toggles, [true, false]);
      expect(lan.running, isFalse);
      // Local playback resumes at the receiver's position.
      expect(harness.engine.seeks, [const Duration(minutes: 20)]);
      expect(harness.engine.playCalls, 1);
      expect(find.byType(CastRemotePanel), findsNothing);
      expect(find.text('video surface'), findsOneWidget);
    });

    testWidgets('a session ended elsewhere brings playback back too', (
      tester,
    ) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);
      harness.engine.emitDuration(const Duration(minutes: 90));
      await pumpEvents(tester);
      await castTo(tester, livingRoom);
      cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.playing,
          position: Duration(minutes: 3),
          duration: Duration(minutes: 90),
        ),
      );
      await tester.pumpAndSettle();

      // Someone stopped it from the television, or another phone took over.
      await cast.disconnect();
      await tester.pumpAndSettle();

      expect(find.byType(CastRemotePanel), findsNothing);
      expect(lan.running, isFalse);
      expect(harness.engine.seeks, [const Duration(minutes: 3)]);
      expect(harness.engine.playCalls, 1);
    });

    testWidgets('leaving the player takes the session and the listener', (
      tester,
    ) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);
      await castTo(tester, livingRoom);
      expect(lan.running, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      expect(cast.disconnects, 1);
      expect(lan.toggles, [true, false]);
      expect(lan.running, isFalse);
    });
  });
}
