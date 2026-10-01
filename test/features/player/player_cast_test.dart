import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart'
    show CoreField, MediaResolution, mediaIdUrl;
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

/// The LAN address the server would answer with for a receiver: what a
/// published token's URL is built on.
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
  _durationDuringACast();
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

    testWidgets('a receiver that answers while the list is open joins it', (
      tester,
    ) async {
      // The sheet is a route of its own, so the screen's rebuild does not
      // reach it: a television that woke up a second after the viewer
      // pressed Cast never appeared, however long they waited.
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final harness = castHarness(cast: cast);
      await harness.pump(tester);
      await tester.tap(castButton);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('cast-device-${kitchen.id}')), findsNothing);

      cast.emitDevices(const [livingRoom, kitchen]);
      await tester.pumpAndSettle();

      expect(find.byKey(ValueKey('cast-device-${kitchen.id}')), findsOneWidget);
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
    testWidgets('connects and loads the published stream on the LAN URL', (
      tester,
    ) async {
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
      // The id mpv reads is what is published -- with the play it was
      // opened with here, so the server keeps the same play session and
      // shares from it as it did before -- and the receiver is handed the
      // token's URL on the listener, and nothing that names the stream.
      expect(harness.engine.opened.last.$1, mediaIdUrl('m1'));
      expect(harness.mediaIds.published, ['m1']);
      expect(harness.mediaIds.plays.last.id, 'm1');
      expect(cast.loads, hasLength(1));
      final (media, start) = cast.loads.single;
      expect(media.url, lanBase.resolve('cast/t1'));
      expect(media.contentType, 'video/mp4');
      expect(start, const Duration(minutes: 12));
      // Local playback stopped, so the film is not running twice.
      expect(harness.engine.pauseCalls, greaterThan(0));
      expect(find.byType(CastRemotePanel), findsOneWidget);
      expect(find.text('Casting to Living Room TV'), findsOneWidget);
    });

    group('an H.264 + AAC Matroska film', () {
      const mkv = 'Night.of.the.Living.Dead.1080p.x264.AAC.mkv';
      const h264Aac = PlaybackStats(
        videoCodec: 'h264 (High)',
        audioCodec: 'aac',
      );

      /// [castTo], with mpv reporting [stats] while the list is up -- the
      /// only time the screen samples it.
      Future<void> castWithStats(
        WidgetTester tester,
        PlayerHarness harness,
      ) async {
        await tester.tap(castButton);
        await tester.pumpAndSettle();
        harness.engine.emitStats(h264Aac);
        await tester.pump();
        await tester.tap(find.byKey(ValueKey('cast-device-${livingRoom.id}')));
        await tester.pumpAndSettle();
      }

      testWidgets('is cast as a rendition, from where it is playing', (
        tester,
      ) async {
        useWideViewport(tester);
        final cast = FakeCastClient(devices: const [livingRoom]);
        final lan = FakeLanMediaControl()..baseUrl = lanBase;
        final harness = castHarness(cast: cast, lanMedia: lan, filename: mkv);
        harness.mediaIds.renditionsAvailable = true;
        await harness.pump(tester);
        harness.engine.emitDuration(const Duration(minutes: 90));
        harness.engine.emitPosition(const Duration(minutes: 12));
        // The second of two audio tracks is the one playing.
        harness.engine.emitTracks(
          const PlaybackTracks(
            audio: [
              TrackInfo(id: '1', language: 'eng'),
              TrackInfo(id: '2', language: 'fre'),
            ],
            activeAudioId: '2',
          ),
        );
        await pumpEvents(tester);

        await castWithStats(tester, harness);

        expect(find.byType(CastRefusedDialog), findsNothing);
        // A rendition of the id mpv reads, published with this player's
        // length, position and audio track, and nothing published as is.
        expect(harness.mediaIds.renditions, hasLength(1));
        final published = harness.mediaIds.renditions.single;
        expect(published.id, 'm1');
        expect(published.spec.toJson(), {
          'durationMs': const Duration(minutes: 90).inMilliseconds,
          'segmentMs': 6000,
          'startMs': const Duration(minutes: 12).inMilliseconds,
          'video': 'copy',
          'audio': 'copy',
          'audioTrack': 1,
        });
        expect(harness.mediaIds.published, ['m1']);
        // The receiver is handed the token's stream -- one MP4, starting
        // where this player is -- and how long the film is.
        final (media, start) = cast.loads.single;
        expect(media.url, lanBase.resolve('cast/t1/stream.mp4'));
        expect(media.contentType, 'video/mp4');
        expect(media.duration, const Duration(minutes: 90));
        expect(start, const Duration(minutes: 12));
        expect(find.byType(CastRemotePanel), findsOneWidget);
      });

      /// A rendition cast from 12:00 of a 90-minute film, the receiver
      /// reporting [positions] (minutes:seconds) as it plays, with the
      /// length it knows -- only what has arrived of the stream.
      Future<(PlayerHarness, FakeCastClient)> castRendition(
        WidgetTester tester,
      ) async {
        useWideViewport(tester);
        final cast = FakeCastClient(devices: const [livingRoom]);
        final lan = FakeLanMediaControl()..baseUrl = lanBase;
        final harness = castHarness(cast: cast, lanMedia: lan, filename: mkv);
        harness.mediaIds.renditionsAvailable = true;
        await harness.pump(tester);
        harness.engine.emitDuration(const Duration(minutes: 90));
        harness.engine.emitPosition(const Duration(minutes: 12));
        await pumpEvents(tester);
        await castWithStats(tester, harness);
        expect(cast.loads, hasLength(1));
        return (harness, cast);
      }

      Future<void> receiverAt(
        WidgetTester tester,
        FakeCastClient cast,
        Duration position, {
        CastPlayerState state = CastPlayerState.playing,
      }) async {
        cast.emitStatus(
          CastStatus(
            state: state,
            position: position,
            duration: const Duration(seconds: 48),
          ),
        );
        await tester.pumpAndSettle();
      }

      testWidgets('is sought here by loading its stream again from there', (
        tester,
      ) async {
        final (harness, cast) = await castRendition(tester);
        await receiverAt(tester, cast, const Duration(minutes: 12, seconds: 1));

        await tester.tap(find.byKey(const ValueKey('cast-forward')));
        await tester.pumpAndSettle();

        // Not a seek on the receiver, which cannot make one: the stream from
        // the target -- past the 48 s the receiver knows of, since the film's
        // length is mpv's -- with the receiver told to start there.
        expect(cast.seeks, isEmpty);
        expect(cast.loads, hasLength(2));
        final (media, start) = cast.loads.last;
        const target = Duration(minutes: 12, seconds: 11);
        expect(
          media.url,
          lanBase.resolve('cast/t1/stream.mp4?from=${target.inMilliseconds}'),
        );
        expect(media.contentType, 'video/mp4');
        expect(media.duration, const Duration(minutes: 90));
        expect(start, target);
        expect(
          harness.mediaIds.renditions,
          hasLength(1),
          reason: 'not republished',
        );
      });

      testWidgets('a restart by the receiver is put back where it was', (
        tester,
      ) async {
        final (harness, cast) = await castRendition(tester);
        for (final second in [1, 2, 3]) {
          await receiverAt(
            tester,
            cast,
            Duration(minutes: 12, seconds: second),
          );
        }
        // The remote's seek: the receiver plays the stream from its start,
        // 12:00, again -- reporting it before the server has seen it fetch
        // the stream again, and then the count moves.
        await receiverAt(
          tester,
          cast,
          const Duration(minutes: 12),
          state: CastPlayerState.buffering,
        );
        expect(cast.loads, hasLength(1));
        harness.mediaIds.restarts['t1'] = 1;
        await receiverAt(
          tester,
          cast,
          const Duration(minutes: 12),
          state: CastPlayerState.buffering,
        );

        expect(cast.loads, hasLength(2));
        final (media, start) = cast.loads.last;
        const was = Duration(minutes: 12, seconds: 3);
        expect(
          media.url,
          lanBase.resolve('cast/t1/stream.mp4?from=${was.inMilliseconds}'),
        );
        expect(start, was);
        // The remote shows where the film is, not the restart.
        expect(find.text('12:03'), findsWidgets);

        // Until the load lands the receiver reports the stream it was playing
        // (here, a stale 12:40), and a restart counted meanwhile is the
        // load's own fetches: none of it moves anything.
        harness.mediaIds.restarts['t1'] = 2;
        await receiverAt(
          tester,
          cast,
          const Duration(minutes: 12, seconds: 40),
        );
        await receiverAt(tester, cast, const Duration(minutes: 12, seconds: 4));
        await receiverAt(tester, cast, const Duration(minutes: 12, seconds: 5));
        expect(cast.loads, hasLength(2));

        // Landed, the next restart is undone where the load played to.
        harness.mediaIds.restarts['t1'] = 3;
        await receiverAt(
          tester,
          cast,
          const Duration(minutes: 12, seconds: 3),
          state: CastPlayerState.buffering,
        );
        expect(cast.loads, hasLength(3));
        expect(cast.loads.last.$2, const Duration(minutes: 12, seconds: 5));
      });

      testWidgets('a move back the receiver makes itself is followed', (
        tester,
      ) async {
        final (harness, cast) = await castRendition(tester);
        for (final second in [1, 2, 20]) {
          await receiverAt(
            tester,
            cast,
            Duration(minutes: 12, seconds: second),
          );
        }
        // Back inside what it has buffered: three reports agree.
        for (final second in [5, 6, 7]) {
          await receiverAt(
            tester,
            cast,
            Duration(minutes: 12, seconds: second),
          );
        }
        harness.mediaIds.restarts['t1'] = 1;
        await receiverAt(tester, cast, const Duration(minutes: 12));
        expect(cast.loads.last.$2, const Duration(minutes: 12, seconds: 7));
      });

      testWidgets('is refused while mpv has not said how long it is', (
        tester,
      ) async {
        // The playlist is written from the length: without one there is
        // nothing to publish, and the container's refusal stands.
        useWideViewport(tester);
        final cast = FakeCastClient(devices: const [livingRoom]);
        final lan = FakeLanMediaControl()..baseUrl = lanBase;
        final harness = castHarness(cast: cast, lanMedia: lan, filename: mkv);
        harness.mediaIds.renditionsAvailable = true;
        await harness.pump(tester);

        await castWithStats(tester, harness);

        expect(find.byType(CastRefusedDialog), findsOneWidget);
        expect(harness.mediaIds.renditions, isEmpty);
        expect(cast.loads, isEmpty);
      });

      testWidgets('is refused where this device cannot repackage', (
        tester,
      ) async {
        useWideViewport(tester);
        final cast = FakeCastClient(devices: const [livingRoom]);
        final lan = FakeLanMediaControl()..baseUrl = lanBase;
        final harness = castHarness(cast: cast, lanMedia: lan, filename: mkv);
        await harness.pump(tester);
        harness.engine.emitDuration(const Duration(minutes: 90));
        await pumpEvents(tester);

        await castWithStats(tester, harness);

        expect(find.byType(CastRefusedDialog), findsOneWidget);
        expect(find.textContaining('Matroska'), findsOneWidget);
        expect(harness.mediaIds.renditions, isEmpty);
        expect(cast.loads, isEmpty);
      });
    });

    testWidgets('a stream the server will not publish is said so', (
      tester,
    ) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      harness.mediaIds.publishFailure = StateError('unknown id');
      await harness.pump(tester);

      await castTo(tester, livingRoom);

      expect(
        find.textContaining('could not hand the stream to Living Room TV'),
        findsOneWidget,
      );
      expect(cast.loads, isEmpty);
      expect(lan.toggles, [true, false]);
      expect(lan.running, isFalse);
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

    testWidgets('a /proxy stream is published like any other', (tester) async {
      // What stremio-core resolves for a source with request headers: the
      // server's own `/proxy`. Played by id, it casts by id -- through the
      // proxy cache, and with its headers on the loopback side.
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final fixture = playerWithFilename('clip.mp4');
      const proxied =
          'http://127.0.0.1:39661/proxy/d=http%3A%2F%2Fhost/clip.mp4';
      final content =
          (fixture['stream'] as Map<String, dynamic>)['content'] as List;
      (content[0] as Map<String, dynamic>)['streaming_url'] = proxied;
      final harness = castHarness(cast: cast, lanMedia: lan, player: fixture);
      await harness.pump(tester);

      await castTo(tester, livingRoom);

      expect(harness.mediaIds.registered, [Uri.parse(proxied)]);
      expect(harness.mediaIds.published, ['m1']);
      expect(cast.loads.single.$1.url, lanBase.resolve('cast/t1'));
    });

    testWidgets('a stream nothing else names is judged by the server\'s name', (
      tester,
    ) async {
      // A Drive file the addon never named: the server resolved it, and
      // the name it resolved is the file's own.
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final fixture = loadPlayerFixture();
      const stream = {'url': 'xtremio-drive:1AbC', 'name': 'Drive'};
      (fixture['selected'] as Map<String, dynamic>)['stream'] = stream;
      fixture['stream'] = {
        'type': 'Ready',
        'content': [
          {'stream': stream, 'streaming_url': 'xtremio-drive:1AbC'},
          stream,
        ],
      };
      final harness = castHarness(cast: cast, lanMedia: lan, player: fixture);
      harness.mediaIds.resolution = const MediaResolution(name: 'Clip.mp4');
      await harness.pump(tester);

      await castTo(tester, livingRoom);

      expect(find.byType(CastRefusedDialog), findsNothing);
      expect(cast.loads.single.$1.contentType, 'video/mp4');
    });

    testWidgets('a stream this device reads only forward is refused', (
      tester,
    ) async {
      // An origin that will not serve ranges, behind the server's `/proxy`:
      // nothing here can seek it for a receiver, and the listener serves
      // published ids only.
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final fixture = playerWithFilename('clip.mp4');
      const proxied =
          'http://127.0.0.1:39661/proxy/d=http%3A%2F%2Fhost/clip.mp4';
      final content =
          (fixture['stream'] as Map<String, dynamic>)['content'] as List;
      (content[0] as Map<String, dynamic>)['streaming_url'] = proxied;
      final harness = castHarness(cast: cast, lanMedia: lan, player: fixture);
      harness.mediaIds.readsForward = true;
      await harness.pump(tester);
      expect(harness.engine.opened.single.$1, Uri.parse(proxied));

      await castTo(tester, livingRoom);

      expect(find.textContaining('proxy'), findsOneWidget);
      expect(cast.loads, isEmpty);
      expect(lan.toggles, isEmpty);
      expect(harness.mediaIds.published, isEmpty);
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
      // the listener's address and the peer it was chosen for are the
      // whole of the evidence -- and the receiver's name is deliberately
      // not in it, nor the token, which is a way into this device.
      expect(
        lines,
        anyElement(
          allOf(
            contains('casting a published stream from 192.168.1.20:39271'),
            contains('192.168.1.44'),
            isNot(contains('Living Room')),
          ),
        ),
      );
      expect(lines, isNot(anyElement(contains('cast/t1'))));
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
      expect(lines, isNot(anyElement(contains('casting '))));
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

    testWidgets('a build with no server of its own rebuilds nothing', (
      tester,
    ) async {
      // No embedded server (`CoreInitInfo.serverBaseUrl` null). The
      // recorded torrent's URL is still a loopback one, but nothing here
      // serves it, so there is nothing for the LAN listener to put on the
      // network: the listener is never started and nothing is cast.
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = PlayerHarness(
        player: playerWithFilename(
          'Night.of.the.Living.Dead.1080p.x264.AAC.mp4',
        ),
        cast: cast,
        lanMedia: lan,
        embeddedServer: false,
      );
      await harness.pump(tester);

      await castTo(tester, livingRoom);

      expect(cast.loads, isEmpty);
      expect(lan.toggles, isEmpty);
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

  group('the transport keys while a receiver has the stream', () {
    testWidgets('play and pause reach the receiver, not the engine here', (
      tester,
    ) async {
      // A phone that answered them itself would play the film locally
      // under the cast too: two playbacks of one film, one of them
      // audible in the room.
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final harness = castHarness(cast: cast);
      await harness.pump(tester);
      await castTo(tester, livingRoom);
      final playedLocally = harness.engine.playCalls;
      final pausedLocally = harness.engine.pauseCalls;

      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPause);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlay);
      await tester.pumpAndSettle();

      expect(cast.pauses, 1);
      expect(cast.plays, 1);
      expect(harness.engine.playCalls, playedLocally);
      expect(harness.engine.pauseCalls, pausedLocally);
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
      // Nothing awaits `_startCast`, so `load`'s error is caught explicitly:
      // left uncaught, it would leave the screen a remote with the engine
      // paused and the listener open, no wait armed, and only Stop left to
      // press.
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
    // that disarmed on anything but buffering would disarm on the one case
    // it exists for. Silence is on the list too, as the shape a fake that
    // emits nothing reports, distinct from what a real receiver ever does.
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

    testWidgets('one that was sent the film is left alone, and told nothing', (
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
      // requests arrive and because starting one zeroes the counts.
      lan
        ..requestsServed = 3
        ..bodiesServed = 1;

      // Still buffering, and reporting nothing else. It has reached this
      // device and been sent bytes, so neither the network nor the server
      // is what to talk about, and nothing that can be known at this point
      // is worth a dialog blaming the file.
      await tester.pump(PlayerScreen.castFetchTimeout);
      await tester.pumpAndSettle();

      expect(find.byType(CastRefusedDialog), findsNothing);
      expect(find.byKey(const ValueKey('cast-note')), findsNothing);
      expect(lines, anyElement(contains('asked the LAN listener for 3')));
      expect(cast.disconnects, 0);
      expect(lan.running, isTrue);
      expect(find.byType(CastRemotePanel), findsOneWidget);
    });

    testWidgets('one that reached us and was sent nothing is waited for, '
        'never ended', (tester) async {
      // The second reading: requests, no body. A stream whose bytes are not
      // here yet -- a dead swarm -- is waited for for as long as the viewer
      // likes; the remote says what is happening, and only Stop ends it.
      final lines = captureDiagnostics();
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);
      await castTo(tester, livingRoom);
      lan.requestsServed = 2;

      await tester.pump(PlayerScreen.castFetchTimeout);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Living Room TV has reached this device and has not been sent any '
          'of the film yet.',
        ),
        findsOneWidget,
      );
      expect(lines, anyElement(contains('has been sent nothing yet')));

      // However long it takes.
      for (var i = 0; i < 10; i++) {
        await tester.pump(PlayerScreen.castFetchTimeout);
      }
      await tester.pumpAndSettle();
      expect(find.byType(CastRefusedDialog), findsNothing);
      expect(cast.disconnects, 0);
      expect(lan.running, isTrue);
      expect(harness.mediaIds.unpublished, isEmpty);

      // The film arrives, and the note goes.
      lan.bodiesServed = 1;
      await tester.pump(PlayerScreen.castFetchTimeout);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cast-note')), findsNothing);
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
      // An addon's own HTTPS URL that will not serve ranges (a live
      // playlist): the server reads it only forward, so the receiver is
      // handed it as it is and fetches it from its host, owing this
      // device's listener nothing -- a count of zero says nothing at all
      // about how the cast is going.
      final fixture = playerWithFilename('clip.mp4');
      final content =
          (fixture['stream'] as Map<String, dynamic>)['content'] as List;
      (content[0] as Map<String, dynamic>)['streaming_url'] =
          'https://cdn.example.com/clip.mp4';
      final harness = castHarness(cast: cast, lanMedia: lan, player: fixture);
      harness.mediaIds.readsForward = true;
      await harness.pump(tester);
      await castTo(tester, livingRoom);
      expect(
        cast.loads.single.$1.url,
        Uri.parse('https://cdn.example.com/clip.mp4'),
      );
      expect(lan.toggles, isEmpty);

      await tester.pump(PlayerScreen.castFetchTimeout);
      await tester.pumpAndSettle();

      expect(find.byType(CastRefusedDialog), findsNothing);
      expect(cast.disconnects, 0);
    });
  });

  // A container is played as the film inside it, and so is cast: the server
  // resolved the id to its member (`Resolved.member`), and that member's
  // name is what the compatibility check judges. Without this, `_startCast`
  // would judge the container by its own name, refusing every one of these
  // on the strength of an extension the viewer never chose ("a Chromecast
  // plays MP4 and WebM files; this stream is a .rar file").
  group('a container casts as the film inside it', () {
    /// The recorded torrent, whose file is [container] and which the server
    /// resolved to [member].
    PlayerHarness torrentContainer({
      required String container,
      required String member,
      required FakeCastClient cast,
      required FakeLanMediaControl lan,
    }) {
      final harness = PlayerHarness(
        player: playerWithFilename(container),
        cast: cast,
        lanMedia: lan,
      );
      harness.mediaIds.resolution = MediaResolution(
        name: member.split('/').last,
        memberName: member,
      );
      harness.torrentStats.response = TorrentStats(
        phase: TorrentPhase.ready,
        streamName: container,
      );
      return harness;
    }

    testWidgets('a .rar is cast as its .mp4 member, by its id', (tester) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = torrentContainer(
        container: 'Night.of.the.Living.Dead.1080p.x264.AAC.rar',
        member: 'Feature/Night.of.the.Living.Dead.1080p.x264.AAC.mp4',
        cast: cast,
        lan: lan,
      );
      await harness.pump(tester);
      expect(harness.engine.opened.single.$1, mediaIdUrl('m1'));

      await castTo(tester, livingRoom);

      // No refusal: what was judged is the member's `.mp4`, not the
      // container's `.rar`.
      expect(find.byType(CastRefusedDialog), findsNothing);
      final media = cast.loads.single.$1;
      expect(media.contentType, 'video/mp4');
      expect(media.url, lanBase.resolve('cast/t1'));
      expect(harness.mediaIds.published, ['m1']);
    });

    testWidgets(
      "a member the receiver cannot decode is refused in the member's own "
      'words',
      (tester) async {
        useWideViewport(tester);
        final cast = FakeCastClient(devices: const [livingRoom]);
        final lan = FakeLanMediaControl()..baseUrl = lanBase;
        // The container is a `.rar`; the film inside it is a Matroska. The
        // refusal has to name the Matroska -- that is what the receiver
        // would have to decode, and it is the reason another source would
        // help.
        final harness = torrentContainer(
          container: 'Night.of.the.Living.Dead.1080p.x264.AAC.rar',
          member: 'Night.of.the.Living.Dead.1080p.x264.AAC.mkv',
          cast: cast,
          lan: lan,
        );
        await harness.pump(tester);

        await castTo(tester, livingRoom);

        expect(find.byType(CastRefusedDialog), findsOneWidget);
        // The member's problem, named. Not the archive's.
        expect(find.textContaining('Matroska'), findsOneWidget);
        expect(find.textContaining('.rar'), findsNothing);
        // And nothing was opened to the network for a cast that never was.
        expect(cast.loads, isEmpty);
        expect(cast.connectAttempts, isEmpty);
        expect(lan.toggles, isEmpty);
        expect(harness.mediaIds.published, isEmpty);
      },
    );

    testWidgets('a member with no name to read is an answer, not a "not yet"', (
      tester,
    ) async {
      // The server has opened the container and said what is inside it,
      // and this member is what it said: a member whose name says nothing
      // is an unknown file, not a wait that would never end.
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = torrentContainer(
        container: 'Night.of.the.Living.Dead.1080p.x264.AAC.rar',
        member: 'FEATURE',
        cast: cast,
        lan: lan,
      );
      await harness.pump(tester);

      await castTo(tester, livingRoom);

      expect(find.byType(CastRefusedDialog), findsOneWidget);
      expect(find.textContaining('Nothing here says'), findsOneWidget);
      expect(find.textContaining('try again'), findsNothing);
      expect(cast.loads, isEmpty);
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
      // Behind what the core holds, so said as a `Seek`, which is the only
      // way the core moves back (`player_core_progress_test.dart`).
      expect(harness.lastPlayerArgs('Seek')?['time'], 0);
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

    testWidgets('the next-episode keys do nothing while casting, like the '
        'button', (tester) async {
      // The top bar's Next is disabled while a cast runs; without a
      // matching guard on the keys, N and the remote's next-track key
      // would go round it and move on anyway.
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
      await castTo(tester, livingRoom);

      for (final key in [
        LogicalKeyboardKey.keyN,
        LogicalKeyboardKey.mediaTrackNext,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }
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
      // The listener goes with the session, and the publication before it;
      // nothing is left on the LAN.
      expect(harness.mediaIds.unpublished, ['t1']);
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
      expect(harness.mediaIds.unpublished, ['t1']);
      expect(lan.toggles, [true, false]);
      expect(lan.running, isFalse);
    });

    testWidgets('another stream on this screen withdraws the one published', (
      tester,
    ) async {
      // The token names one stream; the receiver must not go on being
      // served the last one under it once the screen has moved on.
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);
      await castTo(tester, livingRoom);
      expect(harness.mediaIds.unpublished, isEmpty);

      final next = Map<String, dynamic>.from(harness.fixture);
      final stream = Map<String, dynamic>.from(next['stream'] as Map);
      final content = List<Object?>.from(stream['content'] as List);
      content[0] = {
        ...content[0]! as Map<String, dynamic>,
        'streaming_url': 'http://127.0.0.1:39661/next/0?',
      };
      next['stream'] = {...stream, 'content': content};
      harness.core.setState(CoreField.player, next);
      await tester.pumpAndSettle();

      expect(harness.mediaIds.unpublished, ['t1']);
    });

    testWidgets('another receiver is handed its own token, and the first one '
        'goes', (tester) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom, kitchen]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan);
      await harness.pump(tester);
      await castTo(tester, livingRoom);
      await castTo(tester, kitchen);

      expect(harness.mediaIds.published, ['m1', 'm1']);
      expect(harness.mediaIds.unpublished, ['t1']);
      expect(cast.loads.last.$1.url, lanBase.resolve('cast/t2'));
    });
  });
}

void _durationDuringACast() {
  group("the film's length during a cast", () {
    testWidgets('is reported, although its position is not', (tester) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final harness = castHarness(cast: cast);
      await harness.pump(tester);
      await castTo(tester, livingRoom);

      cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.playing,
          position: Duration(minutes: 7),
          duration: Duration(seconds: 6669),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        harness.hints.durations,
        contains(6669),
        reason: "the length is the bitrate, and it is what sizes the window",
      );
    });

    testWidgets('and once, not on every status the receiver repeats', (
      tester,
    ) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final harness = castHarness(cast: cast);
      await harness.pump(tester);
      await castTo(tester, livingRoom);

      for (final minutes in [7, 8, 9]) {
        cast.emitStatus(
          CastStatus(
            state: CastPlayerState.playing,
            position: Duration(minutes: minutes),
            duration: const Duration(seconds: 6669),
          ),
        );
        await tester.pumpAndSettle();
      }

      expect(harness.hints.durations, [
        6669,
      ], reason: 'a length does not go stale, so repeating it buys nothing');
    });
  });
}
