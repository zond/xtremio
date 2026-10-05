import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart'
    show CoreField, MediaResolution, RenditionReadiness, mediaIdUrl;
import 'package:xtremio/features/cast/cast_client.dart';
import 'package:xtremio/features/cast/cast_widgets.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/up_next_card.dart';

import '../../support/diagnostics_capture.dart';
import '../../support/fake_cast_client.dart';
import '../../support/fake_playback_engine.dart';
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

/// The recorded torrent player state with a filename on the stream. The
/// cast check never reads it -- mpv's report says what the file is -- so a
/// test that names a file either needs the name for something else (a URL
/// it rewrites) or is proving that the name does not count.
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

/// The recorded torrent -- no file name anywhere, which casting does not
/// need -- on an engine whose mpv reports [mpv] when the receiver list
/// opens: by default an MP4 of H.264 and AAC, which a receiver takes as it
/// is. Null is a file mpv has not reported on yet.
PlayerHarness castHarness({
  PlaybackStats? mpv = mpvMp4H264Aac,
  String? filename,
  FakeCastClient? cast,
  FakeLanMediaControl? lanMedia,
  Map<String, dynamic>? player,
  bool onTv = false,
}) => PlayerHarness(
  player: player ?? (filename == null ? null : playerWithFilename(filename)),
  cast: cast ?? FakeCastClient(devices: const [livingRoom]),
  lanMedia: lanMedia ?? (FakeLanMediaControl()..baseUrl = lanBase),
  device: onTv ? tv : null,
  mpvReport: mpv,
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
      /// [castTo], with mpv reporting [stats] while the list is up -- the
      /// only time the screen samples it.
      Future<void> castWithStats(
        WidgetTester tester,
        PlayerHarness harness, {
        PlaybackStats stats = mpvMkvH264Aac,
      }) async {
        harness.engine.report = stats;
        await castTo(tester, livingRoom);
      }

      testWidgets('is cast as a rendition, from where it is playing', (
        tester,
      ) async {
        useWideViewport(tester);
        final cast = FakeCastClient(devices: const [livingRoom]);
        final lan = FakeLanMediaControl()..baseUrl = lanBase;
        final harness = castHarness(
          cast: cast,
          lanMedia: lan,
          mpv: mpvMkvH264Aac,
        );
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

      testWidgets('with Dolby sound, has its sound converted to stereo AAC', (
        tester,
      ) async {
        useWideViewport(tester);
        final cast = FakeCastClient(devices: const [livingRoom]);
        final lan = FakeLanMediaControl()..baseUrl = lanBase;
        final harness = castHarness(
          cast: cast,
          lanMedia: lan,
          mpv: mpvMkvH264Aac,
        );
        harness.mediaIds.renditionsAvailable = true;
        await harness.pump(tester);
        harness.engine.emitDuration(const Duration(minutes: 90));
        harness.engine.emitPosition(const Duration(minutes: 3));
        await pumpEvents(tester);

        await castWithStats(
          tester,
          harness,
          stats: const PlaybackStats(
            fileFormat: 'mkv',
            videoCodec: 'h264 (High)',
            audioCodec: 'eac3',
          ),
        );

        expect(find.byType(CastRefusedDialog), findsNothing);
        expect(harness.mediaIds.renditions.single.spec.toJson(), {
          'durationMs': const Duration(minutes: 90).inMilliseconds,
          'segmentMs': 6000,
          'startMs': const Duration(minutes: 3).inMilliseconds,
          'video': 'copy',
          'audio': {
            'aacStereo': {'bitrate': 192000},
          },
          'audioTrack': 0,
        });
        expect(cast.loads.single.$1.url, lanBase.resolve('cast/t1/stream.mp4'));
      });

      testWidgets('an MP4 with 5.1 AAC is a rendition with its sound mixed '
          'down', (tester) async {
        useWideViewport(tester);
        final cast = FakeCastClient(devices: const [livingRoom]);
        final lan = FakeLanMediaControl()..baseUrl = lanBase;
        final harness = castHarness(cast: cast, lanMedia: lan);
        harness.mediaIds.renditionsAvailable = true;
        await harness.pump(tester);
        harness.engine.emitDuration(const Duration(minutes: 90));
        await pumpEvents(tester);

        await castWithStats(
          tester,
          harness,
          stats: const PlaybackStats(
            fileFormat: 'mov,mp4,m4a,3gp,3g2,mj2',
            videoCodec: 'h264 (High)',
            audioCodec: 'aac',
            audioChannels: 6,
          ),
        );

        expect(find.byType(CastRefusedDialog), findsNothing);
        expect(harness.mediaIds.renditions.single.spec.toJson()['audio'], {
          'aacStereo': {'bitrate': 192000},
        });
        expect(cast.loads.single.$1.url, lanBase.resolve('cast/t1/stream.mp4'));
      });

      /// [castWithStats] without settling: a rendition being prepared draws
      /// a spinner, which never settles, and a poll on a timer.
      Future<void> castWhilePreparing(
        WidgetTester tester,
        PlayerHarness harness,
      ) async {
        await tester.tap(castButton);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('cast-device-${livingRoom.id}')));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      /// One readiness poll: the wait, then what it set off.
      Future<void> nextPoll(WidgetTester tester) async {
        await tester.pump(PlayerScreen.castPreparePoll);
        for (var i = 0; i < 5; i++) {
          await tester.pump();
        }
      }

      PlayerHarness preparingHarness(FakeCastClient cast) {
        final lan = FakeLanMediaControl()..baseUrl = lanBase;
        final harness = castHarness(
          cast: cast,
          lanMedia: lan,
          mpv: mpvMkvH264Aac,
        );
        harness.mediaIds.renditionsAvailable = true;
        return harness;
      }

      testWidgets(
        'is loaded on the receiver only once its start is ready, at the '
        'start it was prepared for',
        (tester) async {
          useWideViewport(tester);
          final cast = FakeCastClient(devices: const [livingRoom]);
          final harness = preparingHarness(cast);
          harness.mediaIds.readiness = const RenditionReadiness('index');
          await harness.pump(tester);
          harness.engine.emitDuration(const Duration(minutes: 90));
          harness.engine.emitPosition(const Duration(minutes: 12));
          await pumpEvents(tester);
          final pausesBefore = harness.engine.pauseCalls;

          await castWhilePreparing(tester, harness);

          // Published and asked to prepare; the receiver has heard nothing.
          expect(harness.mediaIds.prepared, ['t1']);
          expect(cast.loads, isEmpty);
          expect(find.text('Preparing for Living Room TV…'), findsOneWidget);
          expect(find.text("Reading the film's index…"), findsOneWidget);
          expect(find.byType(CastRemotePanel), findsNothing);
          expect(
            harness.engine.pauseCalls,
            greaterThan(pausesBefore),
            reason: 'paused here at the start the rendition is made for',
          );

          harness.mediaIds.readiness = const RenditionReadiness('start');
          await nextPoll(tester);
          expect(find.text('Fetching the start…'), findsOneWidget);
          expect(cast.loads, isEmpty);

          // A late position report changes nothing: the television is told
          // the start the rendition was prepared for.
          harness.engine.emitPosition(const Duration(minutes: 13));
          harness.mediaIds.readiness = RenditionReadiness.ready;
          await nextPoll(tester);
          await tester.pumpAndSettle();
          expect(cast.loads, hasLength(1));
          final (media, start) = cast.loads.single;
          expect(media.url, lanBase.resolve('cast/t1/stream.mp4'));
          expect(start, const Duration(minutes: 12));
          expect(
            harness.mediaIds.renditions.single.spec.start,
            const Duration(minutes: 12),
          );
          expect(find.byType(CastPreparingPanel), findsNothing);
          expect(find.byType(CastRemotePanel), findsOneWidget);
        },
      );

      testWidgets('Cancel while preparing unpublishes and never loads', (
        tester,
      ) async {
        useWideViewport(tester);
        final cast = FakeCastClient(devices: const [livingRoom]);
        final harness = preparingHarness(cast);
        harness.mediaIds.readiness = const RenditionReadiness('index');
        await harness.pump(tester);
        harness.engine.emitDuration(const Duration(minutes: 90));
        harness.engine.emitPosition(const Duration(minutes: 12));
        harness.engine.emitPlaying(true);
        await pumpEvents(tester);
        await castWhilePreparing(tester, harness);
        expect(find.byType(CastPreparingPanel), findsOneWidget);
        final playsBefore = harness.engine.playCalls;

        await tester.tap(find.byKey(const ValueKey('cast-prepare-cancel')));
        await tester.pumpAndSettle();

        expect(harness.mediaIds.unpublished, ['t1']);
        expect(cast.disconnects, greaterThan(0));
        expect(cast.loads, isEmpty);
        expect(find.byType(CastPreparingPanel), findsNothing);
        expect(find.byType(CastRefusedDialog), findsNothing);
        expect(
          harness.engine.playCalls,
          greaterThan(playsBefore),
          reason: 'the film plays on here, as it was',
        );
        // Nothing polls after the cancel.
        final asks = harness.mediaIds.readinessAsks;
        await tester.pump(PlayerScreen.castPreparePoll * 4);
        expect(harness.mediaIds.readinessAsks, asks);
        expect(cast.loads, isEmpty);
      });

      testWidgets('a rendition that fails while prepared is refused with its '
          'sentence', (tester) async {
        // The producer's own refusal, quoted as `rust/tests/rendition.rs`
        // quotes it from the readiness: Dolby Vision profile 5, which mpv
        // does not report, so nothing refuses it before the producer reads
        // the container's record.
        const dolbyVision5 =
            "This film's picture is Dolby Vision profile 5, which has no "
            'ordinary HDR or SDR picture underneath: the television would '
            'show it in the wrong colours.';
        useWideViewport(tester);
        final cast = FakeCastClient(devices: const [livingRoom]);
        final harness = preparingHarness(cast);
        harness.mediaIds.nextReadiness.add(const RenditionReadiness('index'));
        harness.mediaIds.readiness = const RenditionReadiness(
          'failed',
          sentence: dolbyVision5,
        );
        await harness.pump(tester);
        harness.engine.emitDuration(const Duration(minutes: 90));
        harness.engine.emitPlaying(true);
        await pumpEvents(tester);
        final playsBefore = harness.engine.playCalls;
        await castWhilePreparing(tester, harness);
        await nextPoll(tester);
        await tester.pumpAndSettle();

        expect(find.byType(CastRefusedDialog), findsOneWidget);
        expect(find.text(dolbyVision5), findsOneWidget);
        expect(cast.loads, isEmpty);
        expect(harness.mediaIds.unpublished, ['t1']);
        expect(find.byType(CastPreparingPanel), findsNothing);
        expect(harness.engine.playCalls, greaterThan(playsBefore));
      });

      testWidgets('is sought on the receiver, which seeks in it by bytes', (
        tester,
      ) async {
        useWideViewport(tester);
        final cast = FakeCastClient(devices: const [livingRoom]);
        final lan = FakeLanMediaControl()..baseUrl = lanBase;
        final harness = castHarness(
          cast: cast,
          lanMedia: lan,
          mpv: mpvMkvH264Aac,
        );
        harness.mediaIds.renditionsAvailable = true;
        await harness.pump(tester);
        harness.engine.emitDuration(const Duration(minutes: 90));
        harness.engine.emitPosition(const Duration(minutes: 12));
        await pumpEvents(tester);
        await castWithStats(tester, harness);
        cast.emitStatus(
          const CastStatus(
            state: CastPlayerState.playing,
            position: Duration(minutes: 12, seconds: 1),
            duration: Duration(minutes: 90),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('cast-forward')));
        await tester.pumpAndSettle();

        // The file has a length, ranges and an index of its segments: a
        // SEEK, as for any file, and nothing loaded or published again.
        expect(cast.seeks, [const Duration(minutes: 12, seconds: 11)]);
        expect(cast.loads, hasLength(1));
        expect(harness.mediaIds.renditions, hasLength(1));
      });

      testWidgets('is refused while mpv has not said how long it is', (
        tester,
      ) async {
        // The playlist is written from the length: without one there is
        // nothing to publish, and the container's refusal stands.
        useWideViewport(tester);
        final cast = FakeCastClient(devices: const [livingRoom]);
        final lan = FakeLanMediaControl()..baseUrl = lanBase;
        final harness = castHarness(
          cast: cast,
          lanMedia: lan,
          mpv: mpvMkvH264Aac,
        );
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
        final harness = castHarness(
          cast: cast,
          lanMedia: lan,
          mpv: mpvMkvH264Aac,
        );
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

    group('the receiver decides what it decodes', () {
      const hevc4k = PlaybackStats(
        fileFormat: 'mkv',
        videoCodec: 'hevc (Main 10)',
        audioCodec: 'eac3',
        width: 3840,
        height: 2160,
        containerFps: 23.976,
      );

      PlayerHarness hevcHarness(FakeCastClient cast) {
        final harness = castHarness(cast: cast, mpv: hevc4k);
        harness.mediaIds.renditionsAvailable = true;
        return harness;
      }

      testWidgets(
        'a name only some models that decode it announce: HEVC is tried',
        (tester) async {
          final lines = captureDiagnostics();
          useWideViewport(tester);
          final cast = FakeCastClient(devices: const [livingRoom]);
          final harness = hevcHarness(cast);
          await harness.pump(tester);
          harness.engine.emitDuration(const Duration(minutes: 90));
          await pumpEvents(tester);

          await castTo(tester, livingRoom);

          expect(find.byType(CastRefusedDialog), findsNothing);
          expect(harness.mediaIds.renditions, hasLength(1));
          expect(cast.loads, hasLength(1));
          expect(lines, anyElement(contains('trying HEVC on a receiver')));
        },
      );

      testWidgets('a name whose one model cannot decode the film is refused '
          'up front', (tester) async {
        useWideViewport(tester);
        const hub = CastDevice(
          id: 'device-2',
          name: 'Kitchen display',
          model: 'Google Nest Hub',
        );
        final cast = FakeCastClient(devices: const [hub]);
        final harness = hevcHarness(cast);
        await harness.pump(tester);
        harness.engine.emitDuration(const Duration(minutes: 90));
        await pumpEvents(tester);

        await castTo(tester, hub);

        expect(
          find.textContaining(
            'Every receiver that calls itself "Google Nest Hub" plays H.264 '
            "or VP9 video; this film's video is HEVC.",
          ),
          findsOneWidget,
        );
        expect(harness.mediaIds.renditions, isEmpty);
        expect(cast.connectAttempts, isEmpty);
        expect(cast.loads, isEmpty);
      });

      testWidgets('a receiver whose name the table does not know is tried '
          'with what any receiver decodes, and refused what none does', (
        tester,
      ) async {
        useWideViewport(tester);
        const tv = CastDevice(
          id: 'device-9',
          name: 'Bedroom TV',
          model: 'BRAVIA 4K VH2',
        );
        final cast = FakeCastClient(devices: const [tv]);
        final harness = castHarness(
          cast: cast,
          mpv: const PlaybackStats(
            fileFormat: 'mov,mp4,m4a,3gp,3g2,mj2',
            videoCodec: 'mpeg2video',
            audioCodec: 'aac',
          ),
        );
        await harness.pump(tester);

        await castTo(tester, tv);

        expect(
          find.text(
            'The best Cast receiver xtremio knows of plays H.264, VP8, HEVC, '
            "VP9 or AV1 video; this film's video is MPEG-2. Casting it would "
            'need conversion, which this app cannot do yet.',
          ),
          findsOneWidget,
        );
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
        mpv: const PlaybackStats(
          fileFormat: 'mkv',
          videoCodec: 'h264 (High)',
          audioCodec: 'dts',
        ),
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

    testWidgets('a cast pressed before mpv has reported is a "not yet"', (
      tester,
    ) async {
      // mpv is the only word on what the file is, and it has not said:
      // a question still open, not a stream that cannot be cast.
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan, mpv: null);
      await harness.pump(tester);

      await castTo(tester, livingRoom);

      expect(find.byType(CastRefusedDialog), findsOneWidget);
      expect(find.text('Still working out what this file is'), findsOneWidget);
      expect(find.text(CastRefusedDialog.defaultTitle), findsNothing);
      expect(
        find.text(
          'The player has not said yet what kind of file this is, and that '
          'is what decides whether a Chromecast can play it. Try again once '
          'it has started playing.',
        ),
        findsOneWidget,
      );
      expect(cast.connectAttempts, isEmpty);
      expect(cast.loads, isEmpty);
      expect(lan.toggles, isEmpty);
      expect(harness.mediaIds.published, isEmpty);
      expect(harness.mediaIds.renditions, isEmpty);
    });

    testWidgets('the same stream casts once mpv has reported', (tester) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan, mpv: null);
      await harness.pump(tester);
      await castTo(tester, livingRoom);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // Nothing is reopened and no screen is left: the list is opened
      // again, mpv reports while it is up, and the same player casts.
      await tester.tap(castButton);
      await tester.pumpAndSettle();
      harness.engine.emitStats(mpvMp4H264Aac);
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('cast-device-${livingRoom.id}')));
      await tester.pumpAndSettle();

      expect(find.byType(CastRefusedDialog), findsNothing);
      expect(harness.mediaIds.published, ['m1']);
      expect(cast.loads.single.$1.contentType, 'video/mp4');
    });

    testWidgets('what mpv read of the last stream is not this one', (
      tester,
    ) async {
      // The player moves on to another stream (the next episode) and mpv
      // has said nothing of the new file yet: the MP4 it reported for the
      // last one would be a guess about this one.
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final harness = castHarness(cast: cast);
      await harness.pump(tester);
      await tester.tap(castButton);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('cast-device-${livingRoom.id}')),
        findsNothing,
      );

      final next = Map<String, dynamic>.from(harness.fixture);
      final stream = Map<String, dynamic>.from(next['stream'] as Map);
      final content = List<Object?>.from(stream['content'] as List);
      content[0] = {
        ...content[0]! as Map<String, dynamic>,
        'streaming_url': 'http://127.0.0.1:39661/next/0?',
      };
      next['stream'] = {...stream, 'content': content};
      harness.engine.report = null;
      harness.core.setState(CoreField.player, next);
      await tester.pumpAndSettle();

      await castTo(tester, livingRoom);

      expect(find.text('Still working out what this file is'), findsOneWidget);
      expect(cast.loads, isEmpty);
    });

    group('mpv outranks any name', () {
      testWidgets('a file named .mkv that mpv reads as an MP4 is an MP4', (
        tester,
      ) async {
        useWideViewport(tester);
        final cast = FakeCastClient(devices: const [livingRoom]);
        final lan = FakeLanMediaControl()..baseUrl = lanBase;
        final harness = castHarness(
          cast: cast,
          lanMedia: lan,
          filename: 'Night.of.the.Living.Dead.1080p.x265.DTS.mkv',
        );
        await harness.pump(tester);

        await castTo(tester, livingRoom);

        expect(find.byType(CastRefusedDialog), findsNothing);
        expect(cast.loads.single.$1.contentType, 'video/mp4');
      });

      testWidgets('a file named .mp4 that mpv reads as Matroska is Matroska', (
        tester,
      ) async {
        useWideViewport(tester);
        final cast = FakeCastClient(devices: const [livingRoom]);
        final lan = FakeLanMediaControl()..baseUrl = lanBase;
        final harness = castHarness(
          cast: cast,
          lanMedia: lan,
          filename: 'Night.of.the.Living.Dead.1080p.x264.AAC.mp4',
          mpv: mpvMkvH264Aac,
        );
        await harness.pump(tester);

        await castTo(tester, livingRoom);

        expect(find.byType(CastRefusedDialog), findsOneWidget);
        expect(find.textContaining('Matroska'), findsOneWidget);
        expect(cast.loads, isEmpty);
      });
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

    testWidgets('a Drive file nobody named casts by what mpv reads', (
      tester,
    ) async {
      // A Drive file the addon never named and the server resolved to no
      // name either: mpv reading it is all a cast needs.
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
        cast: cast,
        lanMedia: lan,
        embeddedServer: false,
        mpvReport: mpvMp4H264Aac,
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
  // resolved the id to its member (`Resolved.member`), and mpv reads that
  // member, so its report is about the film and not the archive. Judging
  // the archive would refuse every one of these on the strength of an
  // extension the viewer never chose ("this stream is a .rar file").
  group('a container casts as the film inside it', () {
    /// The recorded torrent, whose file is [container] and which the server
    /// resolved to [member], played by an engine whose mpv reports [mpv].
    PlayerHarness torrentContainer({
      required String container,
      required String member,
      required PlaybackStats mpv,
      required FakeCastClient cast,
      required FakeLanMediaControl lan,
    }) {
      final harness = PlayerHarness(
        player: playerWithFilename(container),
        cast: cast,
        lanMedia: lan,
        mpvReport: mpv,
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

    testWidgets('a .rar whose member mpv reads as an MP4 is cast as one, by '
        'its id', (tester) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      // A member whose name says nothing: what it is, mpv says.
      final harness = torrentContainer(
        container: 'Night.of.the.Living.Dead.1080p.x264.AAC.rar',
        member: 'Feature/FEATURE',
        mpv: mpvMp4H264Aac,
        cast: cast,
        lan: lan,
      );
      await harness.pump(tester);
      expect(harness.engine.opened.single.$1, mediaIdUrl('m1'));

      await castTo(tester, livingRoom);

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
        // The container is a `.rar`; the film inside it, as mpv reads it,
        // is a Matroska. The refusal has to name the Matroska -- that is
        // what the receiver would have to decode, and it is the reason
        // another source would help.
        final harness = torrentContainer(
          container: 'Night.of.the.Living.Dead.1080p.x264.AAC.rar',
          member: 'Night.of.the.Living.Dead.1080p.x264.AAC.mkv',
          mpv: const PlaybackStats(
            fileFormat: 'mkv',
            videoCodec: 'h264 (High)',
            audioCodec: 'dts',
          ),
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
  });

  group("the receiver's own report of its picture", () {
    const picture = CastPicture(width: 1280, height: 720, hdr: 'sdr');

    CastStatus playingAt(int seconds, {CastPicture? shows}) => CastStatus(
      state: CastPlayerState.playing,
      position: Duration(minutes: 10, seconds: seconds),
      duration: const Duration(minutes: 90),
      picture: shows,
    );

    /// A cast of [mpv]'s film, from 10:00, to a platform that reports the
    /// receiver's picture.
    Future<(PlayerHarness, FakeCastClient)> casting(
      WidgetTester tester, {
      PlaybackStats mpv = mpvMp4H264Aac,
      bool renditions = false,
    }) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom])
        ..reportsPicture = true;
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final harness = castHarness(cast: cast, lanMedia: lan, mpv: mpv);
      harness.mediaIds.renditionsAvailable = renditions;
      await harness.pump(tester);
      harness.engine.emitDuration(const Duration(minutes: 90));
      harness.engine.emitPosition(const Duration(minutes: 10));
      await pumpEvents(tester);
      await castTo(tester, livingRoom);
      expect(find.byType(CastRemotePanel), findsOneWidget);
      // The receiver fetches what it was sent: the fetch watchdog has
      // nothing to say, and this is about the picture.
      lan
        ..requestsServed = 3
        ..bodiesServed = 1;
      return (harness, cast);
    }

    const noPicture =
        "Living Room TV played the sound but showed no picture: it cannot show "
        "this film's picture (HEVC, 3840x2160). It was sent the film "
        'repackaged, its sound converted. The film is playing here again.';

    testWidgets('a picture reported: the cast plays on', (tester) async {
      final lines = captureDiagnostics();
      final (harness, cast) = await casting(tester);
      cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.buffering,
          position: Duration(minutes: 10),
          picture: picture,
        ),
      );
      for (var s = 0; s <= 30; s += 5) {
        cast.emitStatus(playingAt(s, shows: s == 0 ? picture : null));
        await tester.pumpAndSettle();
      }

      expect(find.byType(CastRefusedDialog), findsNothing);
      expect(find.byType(CastRemotePanel), findsOneWidget);
      expect(cast.disconnects, 0);
      expect(lines, anyElement(contains('the receiver shows a 1280x720 sdr')));
    });

    testWidgets('playing with no picture is ended, the film back here, and '
        'not sent there again', (tester) async {
      final (harness, cast) = await casting(
        tester,
        mpv: const PlaybackStats(
          fileFormat: 'mkv',
          videoCodec: 'hevc (Main 10)',
          audioCodec: 'eac3',
          width: 3840,
          height: 2160,
        ),
        renditions: true,
      );
      // Identified as nothing: an HEVC film on a "Chromecast" is a trial.
      cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.buffering,
          position: Duration(minutes: 10),
        ),
      );
      cast.emitStatus(playingAt(0));
      cast.emitStatus(playingAt(2));
      await tester.pumpAndSettle();
      expect(find.byType(CastRemotePanel), findsOneWidget);

      cast.emitStatus(playingAt(3));
      await tester.pumpAndSettle();

      expect(find.text('No picture on Living Room TV'), findsOneWidget);
      expect(find.text(noPicture), findsOneWidget);
      expect(cast.disconnects, 1);
      expect(
        harness.engine.seeks.last,
        const Duration(minutes: 10, seconds: 3),
      );
      expect(harness.engine.playCalls, greaterThan(0));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.byType(CastRemotePanel), findsNothing);

      // Not tried again this session.
      final connects = cast.connectAttempts.length;
      await castTo(tester, livingRoom);
      expect(
        find.text(
          'Living Room TV showed no picture for HEVC video when it was sent '
          'some earlier, so it is not sent it again.',
        ),
        findsOneWidget,
      );
      expect(cast.connectAttempts, hasLength(connects));
    });

    testWidgets('an uncertain receiver that shows the picture keeps it', (
      tester,
    ) async {
      final (harness, cast) = await casting(
        tester,
        mpv: const PlaybackStats(
          fileFormat: 'mkv',
          videoCodec: 'hevc (Main 10)',
          audioCodec: 'eac3',
        ),
        renditions: true,
      );
      expect(harness.mediaIds.renditions, hasLength(1));
      cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.buffering,
          position: Duration(minutes: 10),
          picture: CastPicture(width: 3840, height: 2160, hdr: 'hdr10'),
        ),
      );
      for (var s = 0; s <= 20; s += 5) {
        cast.emitStatus(playingAt(s));
        await tester.pumpAndSettle();
      }
      expect(find.byType(CastRefusedDialog), findsNothing);
      expect(cast.disconnects, 0);
    });

    testWidgets('buffering for as long as it takes is never ended', (
      tester,
    ) async {
      final (_, cast) = await casting(tester);
      for (var i = 0; i < 20; i++) {
        cast.emitStatus(
          CastStatus(
            state: CastPlayerState.buffering,
            position: Duration(minutes: 10, seconds: i),
          ),
        );
        await tester.pump(const Duration(seconds: 10));
      }
      await tester.pumpAndSettle();
      expect(find.byType(CastRefusedDialog), findsNothing);
      expect(cast.disconnects, 0);
    });

    testWidgets('sound alone has no picture to miss', (tester) async {
      final (_, cast) = await casting(
        tester,
        mpv: const PlaybackStats(
          fileFormat: 'mov,mp4,m4a,3gp,3g2,mj2',
          audioCodec: 'aac',
        ),
      );
      expect(cast.loads.single.$1.contentType, 'video/mp4');
      for (var s = 0; s <= 30; s += 5) {
        cast.emitStatus(playingAt(s));
        await tester.pumpAndSettle();
      }
      expect(find.byType(CastRefusedDialog), findsNothing);
      expect(cast.disconnects, 0);
    });

    testWidgets('a platform that reports no picture is never judged by it', (
      tester,
    ) async {
      final (_, cast) = await casting(tester);
      cast.reportsPicture = false;
      for (var s = 0; s <= 30; s += 5) {
        cast.emitStatus(playingAt(s));
        await tester.pumpAndSettle();
      }
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
