import 'package:flutter_chrome_cast/entities.dart';
import 'package:flutter_chrome_cast/enums.dart';
import 'package:flutter_chrome_cast/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/cast/cast_client.dart';
import 'package:xtremio/features/cast/google_cast_client.dart';

/// What the SDK reports on its status stream when the receiver changes
/// state: no position anywhere in it, which is the whole of the trouble.
GoggleCastMediaStatus reported(CastMediaPlayerState state) =>
    GoggleCastMediaStatus(
      mediaSessionID: 1,
      playerState: state,
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
}
