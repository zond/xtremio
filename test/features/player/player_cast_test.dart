import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/cast/cast_client.dart';
import 'package:xtremio/features/cast/cast_widgets.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/up_next_card.dart';

import '../../support/diagnostics_capture.dart';
import '../../support/fake_cast_client.dart';
import '../../support/fixtures.dart';
import '../../support/player_harness.dart';
import '../../support/tv.dart' show tv;

const livingRoom = CastDevice(
  id: 'device-1',
  name: 'Living Room TV',
  model: 'Chromecast',
);

/// A second receiver, for the switch mid-cast: the count the never-fetched
/// check reads belongs to whichever session is running now.
const kitchen = CastDevice(
  id: 'device-2',
  name: 'Kitchen Display',
  model: 'Nest Hub',
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

    testWidgets('a torrent that played before it was named is still named', (
      tester,
    ) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan, filename: null);
      await harness.pump(tester);
      harness.torrentStats.response = const TorrentStats(
        phase: TorrentPhase.ready,
        streamName: 'Night.of.the.Living.Dead.1080p.mp4',
      );

      // Playback begins before a poll has come back with a name -- a
      // torrent already on this disk starts in well under the start-up
      // interval -- and the start-up polling stops there for good: nothing
      // is stalled and no stats panel is up. The name is asked for once
      // more anyway, because "try again in a moment" is a promise nothing
      // else would keep.
      harness.engine.emitPlaying(true);
      await pumpEvents(tester);

      await castTo(tester, livingRoom);

      expect(find.byType(CastRefusedDialog), findsNothing);
      expect(cast.loads.single.$1.contentType, 'video/mp4');
    });

    testWidgets('a name that arrives after the polling stopped still counts', (
      tester,
    ) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan, filename: null);
      final stats = harness.torrentStats;
      await harness.pump(tester);

      // A poll goes out and the server takes its time over it.
      stats.holdAnswers = true;
      await tester.pump(PlayerScreen.torrentStatsInterval);
      expect(stats.heldCount, 1);

      // The media loads while that poll is still out, which stops the
      // polling: the numbers it comes back with describe a moment that has
      // passed, but the name of the file the server opened does not expire,
      // and this is the only answer there will ever be.
      stats.response = const TorrentStats(
        phase: TorrentPhase.ready,
        streamName: 'Night.of.the.Living.Dead.1080p.mp4',
      );
      harness.engine.emitPlaying(true);
      await pumpEvents(tester);
      stats.answer();
      await pumpEvents(tester);

      await castTo(tester, livingRoom);

      expect(find.byType(CastRefusedDialog), findsNothing);
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

    testWidgets('the receiver\'s own address is what the server is asked', (
      tester,
    ) async {
      useWideViewport(tester);
      // Android knows where the receiver is, and says so as the session
      // starts. That address is the whole point of the exercise: it is
      // what lets the server name the interface on the receiver's subnet
      // rather than rank its own and hope.
      final cast = FakeCastClient(
        devices: const [livingRoom],
        addresses: const {'device-1': '192.168.1.44'},
      );
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);

      await castTo(tester, livingRoom);

      expect(lan.baseUrlRequests, ['192.168.1.44']);
      expect(cast.loads, hasLength(1));
    });

    testWidgets('a platform that says nothing asks with nothing', (
      tester,
    ) async {
      useWideViewport(tester);
      // iOS, or a route that has gone stale: the server is asked all the
      // same, and answers with its best-ranked interface.
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);

      await castTo(tester, livingRoom);

      expect(lan.baseUrlRequests, [null]);
      expect(cast.loads, hasLength(1));
    });

    testWidgets('a session that will not start is said so and nothing else', (
      tester,
    ) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom])
        ..connectFails = true;
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);

      await castTo(tester, livingRoom);

      expect(find.textContaining('Could not start a session'), findsOneWidget);
      expect(cast.loads, isEmpty);
      // Nothing was put on the LAN for a session that never began.
      expect(lan.toggles, isEmpty);
    });

    testWidgets('what the receiver was handed is in the report', (
      tester,
    ) async {
      final lines = captureDiagnostics();
      useWideViewport(tester);
      final cast = FakeCastClient(
        devices: const [livingRoom],
        addresses: const {'device-1': '192.168.1.44'},
      );
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);

      await castTo(tester, livingRoom);

      // A cast that goes nowhere leaves nothing else behind to read, so
      // the URL and the peer it was chosen for are the whole of the
      // evidence -- and the receiver's name is deliberately not in it.
      expect(
        lines,
        anyElement(
          allOf(
            contains('casting http://192.168.1.20:39271/'),
            contains('192.168.1.44'),
            isNot(contains('Living Room')),
          ),
        ),
      );
    });

    testWidgets('a receiver there is no address for says so in the report', (
      tester,
    ) async {
      final lines = captureDiagnostics();
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      // The listener runs and the server still has nothing to offer.
      final harness = castHarness(cast: cast, lanMedia: FakeLanMediaControl());
      await harness.pump(tester);

      await castTo(tester, livingRoom);

      expect(lines, anyElement(contains('no address to give a receiver')));
      expect(lines, isNot(anyElement(contains('casting http'))));
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

    testWidgets('a stream off another server on this device is not rebuilt', (
      tester,
    ) async {
      // The LAN listener serves the embedded server's routes. A stream off
      // another server on this machine -- the standard one on 11470, say --
      // was rebuilt on the listener anyway, and the receiver was handed a
      // path on a server that does not serve it.
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final fixture = playerWithFilename('clip.mp4');
      final content =
          (fixture['stream'] as Map<String, dynamic>)['content'] as List;
      (content[0] as Map<String, dynamic>)['streaming_url'] =
          'http://127.0.0.1:11470/11ea02584fa6351956f35671962ab46354d99060/0';
      final harness = castHarness(cast: cast, lanMedia: lan, player: fixture);
      await harness.pump(tester);

      await castTo(tester, livingRoom);

      expect(cast.loads, isEmpty);
      expect(lan.toggles, isEmpty);
      expect(find.byType(CastRefusedDialog), findsOneWidget);
    });

    testWidgets('a second receiver with no route ends the cast it replaced', (
      tester,
    ) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom, kitchen]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);
      await castTo(tester, livingRoom);
      cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.playing,
          position: Duration(minutes: 7),
        ),
      );
      await tester.pumpAndSettle();

      // The second receiver is on a network this device cannot reach, so
      // there is no address to give it -- and the first receiver's session
      // is already gone by then, ended to make room for one that cannot
      // start.
      lan.baseUrl = null;
      await castTo(tester, kitchen);

      expect(find.textContaining('cannot reach this device'), findsOneWidget);
      expect(cast.loads, hasLength(1));
      // Nothing is casting: the screen is the player again, the listener is
      // down, and the film is back where the first receiver had got to.
      expect(find.byType(CastRemotePanel), findsNothing);
      expect(lan.running, isFalse);
      expect(lan.toggles, [true, true, false]);
      expect(harness.engine.seeks, [const Duration(minutes: 7)]);
      expect(harness.engine.playCalls, 1);
    });
  });

  group('switching receivers', () {
    testWidgets('the first session\'s end does not undo the second', (
      tester,
    ) async {
      // Starting a session on the second receiver ends the first, and the
      // platform reports that end the way it reports one from the
      // receiver's own remote. Taken for that, it closed the listener, put
      // the film back on this screen and then cast it anyway.
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom, kitchen]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);
      await castTo(tester, livingRoom);
      cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.playing,
          position: Duration(minutes: 7),
        ),
      );
      await tester.pumpAndSettle();

      await castTo(tester, kitchen);

      expect(find.text('Casting to ${kitchen.name}'), findsOneWidget);
      expect(cast.loads, hasLength(2));
      expect(cast.loads.last.$2, const Duration(minutes: 7));
      // The listener was started on top of itself, and never stopped.
      expect(lan.toggles, [true, true]);
      expect(lan.running, isTrue);
      // And the film never came back here in between.
      expect(harness.engine.seeks, isEmpty);
      expect(harness.engine.playCalls, 0);
      expect(cast.disconnects, 0);
    });

    testWidgets('an end while a refusal is on screen is still heard', (
      tester,
    ) async {
      // What a switch ignores is its own doing, and only while it runs. A
      // dialog saying the second receiver would not start stays up for as
      // long as the viewer leaves it, and the first session ending from its
      // own remote meanwhile is an end like any other.
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom, kitchen]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);
      await castTo(tester, livingRoom);
      cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.playing,
          position: Duration(minutes: 9),
        ),
      );
      await tester.pumpAndSettle();

      cast.connectFails = true;
      await castTo(tester, kitchen);
      expect(find.byType(CastRefusedDialog), findsOneWidget);
      cast.emitSession(null);
      await tester.pumpAndSettle();

      expect(lan.running, isFalse);
      expect(harness.engine.seeks, [const Duration(minutes: 9)]);
      expect(harness.engine.playCalls, 1);
    });

    testWidgets('Stop pressed while the listener starts ends it all', (
      tester,
    ) async {
      // Stop is still on the bar while the second receiver is being set
      // up. Pressed while the listener was being switched on for it, the
      // switch carried on regardless: the film went to the new receiver
      // after the viewer had asked for it back.
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom, kitchen]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);
      await castTo(tester, livingRoom);
      cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.playing,
          position: Duration(minutes: 11),
        ),
      );
      await tester.pumpAndSettle();

      final enabled = Completer<void>();
      lan.enablePending = enabled.future;
      await castTo(tester, kitchen);
      await tester.tap(find.byKey(const ValueKey('cast-stop-button')));
      await tester.pumpAndSettle();
      enabled.complete();
      await tester.pumpAndSettle();

      expect(cast.loads, hasLength(1));
      expect(find.byType(CastRemotePanel), findsNothing);
      // The session the switch started goes, and the listener with it,
      // whichever order the Stop's disable and the enable ran in.
      expect(lan.toggles.last, isFalse);
      expect(lan.running, isFalse);
      expect(harness.engine.seeks, [const Duration(minutes: 11)]);
      expect(harness.engine.playCalls, 1);
    });

    testWidgets('Stop pressed while the session starts ends it all', (
      tester,
    ) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom, kitchen]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);
      await castTo(tester, livingRoom);

      final connected = Completer<void>();
      cast.connectPending = connected.future;
      await castTo(tester, kitchen);
      await tester.tap(find.byKey(const ValueKey('cast-stop-button')));
      await tester.pumpAndSettle();
      connected.complete();
      await tester.pumpAndSettle();

      expect(cast.loads, hasLength(1));
      expect(find.byType(CastRemotePanel), findsNothing);
      // The Stop's own disconnect, and the one for the session the switch
      // had started behind it.
      expect(cast.disconnects, 2);
      expect(lan.toggles, [true, false]);
    });

    testWidgets('a load refused after Stop is not explained', (tester) async {
      // The viewer asked for the film back; a dialog saying the receiver
      // would not take it answers a question nobody is asking any more.
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom, kitchen]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);
      await castTo(tester, livingRoom);

      cast
        ..loadDelay = const Duration(seconds: 2)
        ..loadError = PlatformException(code: 'loadMedia');
      await tester.tap(castButton);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('cast-device-${kitchen.id}')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('cast-stop-button')));
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(find.byType(CastRefusedDialog), findsNothing);
      expect(find.byType(CastRemotePanel), findsNothing);
      expect(lan.running, isFalse);
    });

    testWidgets('a session moved to another receiver ends the cast here', (
      tester,
    ) async {
      // The system's own output switcher can move the session without this
      // screen picking anything. The receiver that had the stream is no
      // longer the one connected, and the screen went on naming it.
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom, kitchen]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);
      await castTo(tester, livingRoom);
      cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.playing,
          position: Duration(minutes: 5),
        ),
      );
      await tester.pumpAndSettle();

      cast.emitSession(kitchen);
      await tester.pumpAndSettle();

      expect(find.byType(CastRemotePanel), findsNothing);
      expect(lan.running, isFalse);
      expect(harness.engine.seeks, [const Duration(minutes: 5)]);
      expect(harness.engine.playCalls, 1);
    });
  });

  group('a load the platform throws out of', () {
    testWidgets('ends the session and puts the film back here', (tester) async {
      // Nothing awaits `_startCast`, so an error out of `load` used to land
      // nowhere: the screen stayed a remote with the engine paused and the
      // listener open, no wait armed, and only Stop left to press.
      final lines = captureDiagnostics();
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom])
        ..loadError = PlatformException(
          code: 'loadMedia',
          message: 'no session to load into',
        );
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);
      harness.engine.emitPosition(const Duration(minutes: 4));
      await pumpEvents(tester);

      await castTo(tester, livingRoom);

      // The load was tried once, and then everything it had built is gone.
      expect(cast.loads, hasLength(1));
      expect(find.byType(CastRemotePanel), findsNothing);
      expect(cast.disconnects, 1);
      expect(lan.running, isFalse);
      expect(lan.toggles, [true, false]);
      expect(harness.engine.pauseCalls, 1);
      expect(harness.engine.seeks, [const Duration(minutes: 4)]);
      expect(harness.engine.playCalls, 1);
      expect(find.byType(CastRefusedDialog), findsOneWidget);
      expect(
        find.textContaining('${livingRoom.name} did not accept the stream'),
        findsOneWidget,
      );
      expect(lines, anyElement(contains('did not take the media')));
      // Nothing is left waiting to end a session that is already over.
      await tester.pump(PlayerScreen.castFetchTimeout);
      await tester.pumpAndSettle();
      expect(cast.disconnects, 1);
    });
  });

  group('a receiver that never fetches', () {
    // What the receiver says about itself, which this check must take no
    // notice of at all. The receiver the whole feature exists for reports a
    // healthy session and `Unknown player state:` in its own log, which
    // `GoogleCastClient` folds into [CastPlayerState.idle] -- so a check
    // that disarmed on anything but buffering disarmed on the one case it
    // was written for. Silence is on the list because it is what a fake
    // that emits nothing reports, and so is the only case the old tests
    // ever reached.
    for (final reported in <CastPlayerState?>[
      null,
      ...CastPlayerState.values,
    ]) {
      testWidgets(
        'is stopped and explained, reporting ${reported?.name ?? 'nothing'}',
        (tester) async {
          final lines = captureDiagnostics();
          useWideViewport(tester);
          final cast = FakeCastClient(devices: const [livingRoom]);
          // The listener runs and nothing ever reaches it: the address the
          // receiver was given is one it cannot route to, and a hanging
          // connect is not an error anybody is ever told about.
          final lan = FakeLanMediaControl()..baseUrl = lanBase;
          final harness = castHarness(cast: cast, lanMedia: lan);
          await harness.pump(tester);
          harness.engine.emitPosition(const Duration(minutes: 4));
          await pumpEvents(tester);
          await castTo(tester, livingRoom);
          expect(find.byType(CastRemotePanel), findsOneWidget);

          // At position zero, which is what the real client's first report
          // carries: the SDK's position stream has not ticked for a
          // receiver that never fetched, and the status is folded with the
          // zero it was seeded with.
          if (reported != null) {
            cast.emitStatus(CastStatus(state: reported));
            await tester.pumpAndSettle();
          }
          await tester.pump(PlayerScreen.castFetchTimeout);
          await tester.pumpAndSettle();

          expect(
            find.textContaining('never asked for the stream'),
            findsOneWidget,
          );
          expect(
            lines,
            anyElement(contains('asked the LAN listener for nothing')),
          );
          // The session is over and the film is back here, at the position
          // the receiver was given it at.
          expect(cast.disconnects, 1);
          expect(lan.toggles, [true, false]);
          expect(harness.engine.seeks, [const Duration(minutes: 4)]);
          expect(harness.engine.playCalls, 1);
          await tester.tap(find.text('OK'));
          await tester.pumpAndSettle();
          expect(find.byType(CastRemotePanel), findsNothing);
        },
      );
    }

    testWidgets('one that did fetch is left alone, and told nothing', (
      tester,
    ) async {
      final lines = captureDiagnostics();
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);
      await castTo(tester, livingRoom);
      // Said after the session started, because that is when a receiver's
      // requests arrive and because starting one zeroes the count.
      lan.requestsServed = 3;

      // Still buffering, and reporting nothing else -- which is exactly
      // what a cold torrent twenty seconds in looks like. It has reached
      // this device, so the network is not what to talk about, and nothing
      // that can be known at this point is worth a dialog blaming the file.
      await tester.pump(PlayerScreen.castFetchTimeout);
      await tester.pumpAndSettle();

      expect(find.byType(CastRefusedDialog), findsNothing);
      expect(lines, anyElement(contains('asked the LAN listener for 3')));
      expect(cast.disconnects, 0);
      expect(lan.running, isTrue);
      expect(find.byType(CastRemotePanel), findsOneWidget);
    });

    testWidgets('the receiver picked mid-cast is the one asked about', (
      tester,
    ) async {
      final lines = captureDiagnostics();
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom, kitchen]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);
      await castTo(tester, livingRoom);
      // The first receiver is fetching happily, and its twenty seconds are
      // running.
      lan.requestsServed = 4;
      // The second one takes a round trip to accept the media, as a real
      // receiver does. That round trip is the window: the listener has been
      // started again for this session, so its count is already zero, and
      // this session's own wait is not armed until the load comes back.
      cast.loadDelay = const Duration(seconds: 8);

      await tester.pump(
        PlayerScreen.castFetchTimeout - const Duration(seconds: 5),
      );
      await castTo(tester, kitchen);
      // The listener never stopped -- it was started on top of itself --
      // and that start is what put the count back to zero.
      expect(lan.toggles, [true, true]);
      expect(lan.requestsServed, 0);
      expect(find.text('Casting to ${kitchen.name}'), findsOneWidget);

      // Past where the first receiver's wait would have run out, with the
      // second one still loading. That wait is over: it was about a session
      // that has been replaced, and the zero it would read belongs to a
      // session five seconds old that has not been handed the media yet.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.byType(CastRefusedDialog), findsNothing);
      expect(find.text('Casting to ${kitchen.name}'), findsOneWidget);
      expect(cast.disconnects, 0);

      // The load lands and the second receiver's own twenty seconds start,
      // which it spends never asking for anything: that is the session that
      // gets ended, and the film comes back here.
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(PlayerScreen.castFetchTimeout);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('${kitchen.name} never asked for the stream'),
        findsOneWidget,
      );
      expect(lines, anyElement(contains('asked the LAN listener for nothing')));
      expect(cast.disconnects, 1);
      expect(lan.running, isFalse);
    });

    testWidgets('a stream off the internet is never accused', (tester) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      // An addon's own HTTPS URL: the receiver fetches it from its host and
      // owes this device's listener nothing, so a count of zero says
      // nothing at all about how the cast is going.
      final fixture = playerWithFilename('clip.mp4');
      final content =
          (fixture['stream'] as Map<String, dynamic>)['content'] as List;
      (content[0] as Map<String, dynamic>)['streaming_url'] =
          'https://cdn.example.com/clip.mp4';
      final harness = castHarness(cast: cast, lanMedia: lan, player: fixture);
      await harness.pump(tester);
      await castTo(tester, livingRoom);
      expect(cast.loads, hasLength(1));
      expect(lan.toggles, isEmpty);

      await tester.pump(PlayerScreen.castFetchTimeout);
      await tester.pumpAndSettle();

      expect(find.byType(CastRefusedDialog), findsNothing);
      expect(cast.disconnects, 0);
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

    testWidgets('a position the receiver has not reported is the one it was '
        'handed', (tester) async {
      // The client folds the SDK's status and position streams into one
      // report, carrying the last position it saw -- a zero, until the
      // receiver's first progress tick. Believed, that zero reached the
      // core as `TimeChanged{0}` on every cast start and drew a scrubber at
      // 0:00 for a film forty minutes in.
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final harness = castHarness(cast: cast);
      await harness.pump(tester);
      harness.engine.emitDuration(const Duration(minutes: 90));
      harness.engine.emitPosition(const Duration(minutes: 40));
      await pumpEvents(tester);
      await castTo(tester, livingRoom);
      final before = harness.playerActions().length;

      cast.emitStatus(const CastStatus(state: CastPlayerState.buffering));
      await tester.pumpAndSettle();
      final buffering = harness.playerActions().skip(before).toList();
      if (buffering.contains('TimeChanged')) {
        expect(
          harness.lastPlayerArgs('TimeChanged')?['time'],
          const Duration(minutes: 40).inMilliseconds,
        );
      }
      expect(find.text('40:00'), findsOneWidget);

      // The receiver's own tick is believed, and so is everything after it
      // -- a zero included, which is then a receiver really at the start.
      cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.playing,
          position: Duration(minutes: 40, seconds: 1),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        harness.lastPlayerArgs('TimeChanged')?['time'],
        const Duration(minutes: 40, seconds: 1).inMilliseconds,
      );
      cast.emitStatus(const CastStatus(state: CastPlayerState.playing));
      await tester.pumpAndSettle();
      expect(harness.lastPlayerArgs('TimeChanged')?['time'], 0);
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

    testWidgets('an episode that ends on the receiver does not move on', (
      tester,
    ) async {
      // Casts do not binge, by decision: the viewer is at the television,
      // not at the phone to cancel a countdown, and a TV that plays on by
      // itself is the thing to avoid. With a next episode, a stream for it
      // and `bingeWatching` on -- everything local playback moves on for.
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final harness = castHarness(cast: cast);
      harness.fixture['nextVideo'] = {
        'id': 'tt0063350:1:2',
        'title': 'The Cellar',
        'season': 1,
        'episode': 2,
      };
      harness.fixture['nextStream'] = {
        'url': 'https://x.example/e2.mp4',
        'name': 'Direct',
      };
      await harness.pump(tester);
      expect(harness.settings.bingeWatching, isTrue);
      harness.engine.emitDuration(const Duration(minutes: 90));
      await pumpEvents(tester);
      await castTo(tester, livingRoom);

      cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.idle,
          position: Duration(minutes: 90),
          duration: Duration(minutes: 90),
          ended: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(harness.playerActions(), contains('Ended'));
      expect(find.byType(UpNextCard), findsNothing);

      // Past the longest countdown there is.
      await tester.pump(const Duration(seconds: 100));
      await tester.pumpAndSettle();
      expect(harness.playerActions(), isNot(contains('NextVideo')));
      expect(harness.engines, hasLength(1));
      expect(cast.loads, hasLength(1));
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
