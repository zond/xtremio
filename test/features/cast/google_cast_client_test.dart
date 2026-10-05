import 'package:flutter_chrome_cast/_remote_media_client/android_remote_media_client_method_channel.dart';
import 'package:flutter_chrome_cast/entities.dart';
import 'package:flutter_chrome_cast/enums.dart';
import 'package:flutter_chrome_cast/logging.dart';
import 'package:flutter_chrome_cast/models.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/cast/cast_client.dart';
import 'package:xtremio/features/cast/google_cast_client.dart';

import '../../support/diagnostics_capture.dart';

/// What the SDK reports on its status stream when the receiver changes
/// state: no position anywhere in it, which is the whole of the trouble.
GoggleCastMediaStatus reported(
  CastMediaPlayerState state, {
  GoogleCastMediaIdleReason? idleReason,
}) => GoggleCastMediaStatus(
  mediaSessionID: 1,
  playerState: state,
  idleReason: idleReason,
  playbackRate: 1,
  volume: 1,
  isMuted: false,
  repeatMode: GoogleCastMediaRepeatMode.off,
);

final media = CastMedia(
  url: Uri.parse('http://192.168.1.20:39271/abc/0'),
  contentType: 'video/mp4',
  title: 'A Film',
);

/// The folding of the SDK's two streams into one status. Nothing here
/// touches the SDK itself: `isSupported` is false wherever these run, so
/// the client never initialises and `load` reaches nothing of the plugin --
/// which is exactly why the one thing `load` decides on its own has to be
/// decided before that check.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('waiting for the session before anything is loaded', () {
    // A LOAD sent before the session is up reaches nobody: the receiver
    // launches its application, comes up with no media on it, and reports
    // "No media status" until the sender gives up -- which from the
    // sending side is indistinguishable from a receiver that cannot reach
    // us.
    test('a session that connects while we wait is waited for', () async {
      final reports = StreamController<bool>();
      final ready = GoogleCastClient.connected(
        reports.stream,
        now: () => false,
      );

      reports.add(false);
      await Future<void>.delayed(Duration.zero);
      reports.add(true);

      expect(await ready, isTrue);
      await reports.close();
    });

    test('a session already connected is not waited for', () async {
      final reports = StreamController<bool>();
      expect(
        await GoogleCastClient.connected(reports.stream, now: () => true),
        isTrue,
      );
      await reports.close();
    });

    test('a receiver that never connects is given up on', () async {
      // Short enough to wait out here; the real one is twenty seconds.
      final reports = StreamController<bool>();
      expect(
        await GoogleCastClient.connected(
          reports.stream,
          now: () => false,
          timeout: const Duration(milliseconds: 20),
        ),
        isFalse,
      );
      await reports.close();
    });
  });

  test('what the receiver says is written down, once per thing it says', () {
    // The only account of a cast the sending side ever gets. A receiver
    // that refuses the film reports `idle` with a reason and fetches
    // nothing, which from here is indistinguishable from a receiver that
    // never heard of us -- unless this line is in the log.
    final lines = captureDiagnostics();
    final client = GoogleCastClient();

    client.onMediaStatus(reported(CastMediaPlayerState.buffering));
    client.onMediaStatus(reported(CastMediaPlayerState.buffering));
    client.onMediaStatus(
      reported(
        CastMediaPlayerState.idle,
        idleReason: GoogleCastMediaIdleReason.error,
      ),
    );

    expect(lines, [
      'info cast the receiver says buffering',
      'warn cast the receiver gave up on the media: idle (error)',
    ]);
    client.dispose();
  });

  test('a receiver giving up on the media is reported as failed, and only '
      'that', () {
    // What a cast handed straight to the source falls back on: a receiver
    // that could not fetch the link says so with an idle and ERROR, and
    // nothing else -- a film that finished, or one someone stopped -- may
    // read as a refusal, or a finished film would be cast again.
    final client = GoogleCastClient();
    final seen = <CastStatus>[];
    client.status.listen(seen.add);

    client.onMediaStatus(reported(CastMediaPlayerState.buffering));
    expect(client.lastStatus.failed, isFalse);
    client.onMediaStatus(
      reported(
        CastMediaPlayerState.idle,
        idleReason: GoogleCastMediaIdleReason.finished,
      ),
    );
    expect(client.lastStatus.failed, isFalse);
    client.onMediaStatus(
      reported(
        CastMediaPlayerState.idle,
        idleReason: GoogleCastMediaIdleReason.cancelled,
      ),
    );
    expect(client.lastStatus.failed, isFalse);
    client.onMediaStatus(
      reported(
        CastMediaPlayerState.idle,
        idleReason: GoogleCastMediaIdleReason.error,
      ),
    );
    expect(client.lastStatus.failed, isTrue);
    expect(client.lastStatus.ended, isFalse);
    // A position tick after it is still the same refusal, not a recovery.
    client.onPosition(const Duration(seconds: 3));
    expect(client.lastStatus.failed, isTrue);
    client.dispose();
  });

  test('a state change carries the position last seen', () {
    final client = GoogleCastClient();
    final seen = <CastStatus>[];
    client.status.listen(seen.add);

    client.onPosition(const Duration(minutes: 4));
    client.onMediaStatus(reported(CastMediaPlayerState.paused));

    expect(client.lastStatus.state, CastPlayerState.paused);
    expect(client.lastStatus.position, const Duration(minutes: 4));
    client.dispose();
  });

  test('a load starts the record at the handed position, so a previous '
      'session\'s position cannot leak into the new one', () async {
    final client = GoogleCastClient();
    final seen = <CastStatus>[];
    client.status.listen(seen.add);
    // The last session got forty minutes in before it ended.
    client.onPosition(const Duration(minutes: 40));
    client.onMediaStatus(reported(CastMediaPlayerState.idle));
    expect(client.lastStatus.position, const Duration(minutes: 40));

    await client.load(media, start: const Duration(minutes: 4));
    await pumpEventQueue();

    // Nothing is reported by the load itself...
    expect(seen.last.position, const Duration(minutes: 40));
    // ...but the first state change of the new session is built on what
    // it was handed, not on where the last receiver had got to.
    client.onMediaStatus(reported(CastMediaPlayerState.buffering));
    await pumpEventQueue();
    expect(seen.last.state, CastPlayerState.buffering);
    expect(seen.last.position, const Duration(minutes: 4));
    client.dispose();
  });

  test('a load from the start puts a stale position back to zero', () async {
    final client = GoogleCastClient();
    client.onPosition(const Duration(minutes: 40));

    await client.load(media);

    expect(client.lastStatus.position, Duration.zero);
    client.dispose();
  });

  test('no media status leaves the position where the receiver left it', () {
    // The SDK reports a null status when the receiver has nothing loaded
    // -- the session ending is one of those moments -- and it carries no
    // position at all. Read as a position, its zero is what the player
    // resumed from when the film came back to the phone.
    final client = GoogleCastClient();
    client.onPosition(const Duration(minutes: 40));
    client.onMediaStatus(reported(CastMediaPlayerState.playing));
    expect(client.lastStatus.position, const Duration(minutes: 40));

    client.onMediaStatus(null);

    expect(client.lastStatus.state, CastPlayerState.idle);
    expect(client.lastStatus.position, const Duration(minutes: 40));
    client.dispose();
  });

  test('a session connecting is not reported as one that ended', () async {
    // Picking a second receiver starts its session while the first one's
    // is live, and a null for the new one still connecting read, in the
    // player, as the cast having ended elsewhere.
    final client = GoogleCastClient();
    final device = GoogleCastAndroidDevice(
      deviceID: 'device-2',
      friendlyName: 'Kitchen Display',
      modelName: 'Nest Hub',
      statusText: null,
      deviceVersion: '1',
      isOnLocalNetwork: true,
      category: '',
      uniqueID: 'device-2',
    );
    GoogleCastSession session(GoogleCastConnectState state) =>
        GoogleCastSessionAndroid(
          device: device,
          sessionID: 'session',
          connectionState: state,
          currentDeviceMuted: false,
          currentDeviceVolume: 1,
          deviceStatusText: '',
        );

    final reported = await client
        .sessionsOf(
          Stream.fromIterable([
            session(GoogleCastConnectState.connecting),
            session(GoogleCastConnectState.connected),
            session(GoogleCastConnectState.disconnecting),
            session(GoogleCastConnectState.disconnected),
            null,
          ]),
        )
        .toList();

    expect(reported, hasLength(4));
    expect(reported.first?.id, 'device-2');
    expect(reported.skip(1), everyElement(isNull));
    client.dispose();
  });

  group('the picture the receiver reports', () {
    test('rides on every status until the receiver says otherwise', () {
      final client = GoogleCastClient();
      client.onMediaStatus(reported(CastMediaPlayerState.buffering));
      expect(client.lastStatus.picture, isNull);

      client.onPicture({'width': 1280, 'height': 720, 'hdr': 'sdr'});
      const picture = CastPicture(width: 1280, height: 720, hdr: 'sdr');
      expect(client.lastStatus.picture, picture);
      expect(client.lastStatus.state, CastPlayerState.buffering);

      // A state change and a position tick keep it.
      client.onMediaStatus(reported(CastMediaPlayerState.playing));
      client.onPosition(const Duration(seconds: 4));
      expect(client.lastStatus.picture, picture);
      expect(client.lastStatus.state, CastPlayerState.playing);
      expect(client.lastStatus.position, const Duration(seconds: 4));

      // A status with no picture in it is no picture.
      client.onPicture(null);
      expect(client.lastStatus.picture, isNull);
      client.dispose();
    });

    test('a report that is not a picture is none', () {
      for (final report in [
        null,
        'sdr',
        {'width': 0, 'height': 720},
        {'width': 1280},
        {'width': '1280', 'height': 720},
      ]) {
        expect(CastPicture.fromMap(report), isNull, reason: '$report');
      }
    });
  });
  group('the statuses a Default Media Receiver sends', () {
    // What the Cast SDK on Android hands the plugin (`MediaStatus.toJson()`,
    // which the plugin forwards as it is) for an MP4 cast to zond's
    // Chromecast with Google TV, 2026-10-05. BUFFERING carries no tracks;
    // once it plays, the receiver lists the video track it found in the
    // file -- with no `trackContentType`, since it is in-band. Up to
    // flutter_chrome_cast 1.4.8 that track failed to parse, the method
    // call handler swallowed the error, and no status from PLAYING on ever
    // reached the stream: the phone's log said "buffering" and never
    // "playing".
    Map<String, Object?> status(String state, {bool tracks = false}) => {
      'mediaSessionId': 1,
      'playbackRate': 1,
      'playerState': state,
      'currentTime': 12.5,
      'supportedMediaCommands': 274447,
      'volume': {'level': 1.0, 'muted': false},
      'repeatMode': 'REPEAT_OFF',
      'media': {
        'contentId': 'http://192.168.1.20:39271/cast/token',
        'streamType': 'BUFFERED',
        'contentType': 'video/mp4',
        'duration': 5400.0,
        if (tracks)
          'tracks': [
            {'trackId': 1, 'type': 'VIDEO'},
          ],
      },
      'activeTrackIds': '[]',
    };

    /// [json] sent over the plugin's own channel, the way its Kotlin does.
    Future<void> fromAndroid(Map<String, Object?> json) async {
      const channel = MethodChannel(
        'com.felnanuke.google_cast.remote_media_client',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          MethodCall('onMediaStatusChanged', jsonEncode(json)),
        ),
        (_) {},
      );
    }

    test(
      'PLAYING with an in-band video track arrives, and is playing',
      () async {
        final lines = captureDiagnostics();
        final plugin = GoogleCastRemoteMediaClientAndroidMethodChannel();
        final client = GoogleCastClient();
        final seen = <CastStatus>[];
        client.status.listen(seen.add);
        final relay = plugin.mediaStatusStream.listen(client.onMediaStatus);

        await fromAndroid(status('BUFFERING'));
        await pumpEventQueue();
        await fromAndroid(status('PLAYING', tracks: true));
        await pumpEventQueue();
        await fromAndroid(status('PAUSED', tracks: true));
        await pumpEventQueue();

        expect(seen.map((status) => status.state), [
          CastPlayerState.buffering,
          CastPlayerState.playing,
          CastPlayerState.paused,
        ]);
        expect(seen.last.duration, const Duration(minutes: 90));
        expect(lines, [
          'info cast the receiver says nothing loaded',
          'info cast the receiver says buffering',
          'info cast the receiver says playing',
          'info cast the receiver says paused',
        ]);
        await relay.cancel();
        client.dispose();
      },
    );
  });
  test('the plugin is told to keep media statuses out of the log', () async {
    // Its legacy level writes each status to logcat, URL and all: a
    // published token, or a debrid link with its key.
    final client = GoogleCastClient();
    await client.startDiscovery();
    expect(GoogleCastLogger.level, CastLogLevel.warning);
    expect(GoogleCastClient.pluginLogLevel, CastLogLevel.warning);
    client.dispose();
  });
}
