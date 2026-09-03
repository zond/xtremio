import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_chrome_cast/cast_context.dart';
import 'package:flutter_chrome_cast/discovery.dart';
import 'package:flutter_chrome_cast/entities.dart';
import 'package:flutter_chrome_cast/enums.dart';
import 'package:flutter_chrome_cast/media.dart';
import 'package:flutter_chrome_cast/models.dart';
import 'package:flutter_chrome_cast/session.dart';

import 'cast_client.dart';

/// [CastClient] over `flutter_chrome_cast` (the Google Cast SDK).
///
/// Everything the plugin exposes is a process-wide singleton, so this is a
/// thin translation layer and not an owner of anything: it maps the SDK's
/// types onto ours, holds the subscriptions that shape its streams, and
/// initialises the Cast context once.
///
/// Only Android and iOS have a Cast SDK. Everywhere else [isSupported] is
/// false and nothing here is ever reached — importantly, the plugin's
/// singletons switch on `Platform.isAndroid` when they are first touched, so
/// they must not be touched at all on a desktop.
///
/// Discovery is not started here. It costs radio and battery, so the screen
/// that shows a device list starts it and stops it again
/// ([CastClient.startDiscovery]).
class GoogleCastClient implements CastClient {
  GoogleCastClient({this.applicationId = _defaultApplicationId});

  /// The default media receiver, which is what plays a plain URL. A custom
  /// receiver would be the place to teach a Chromecast about anything this
  /// app cannot already hand it — including, one day, the headers a
  /// converted stream might need.
  static const String _defaultApplicationId =
      GoogleCastDiscoveryCriteria.kDefaultApplicationId;

  final String applicationId;

  bool _initialised = false;
  final StreamController<CastStatus> _status =
      StreamController<CastStatus>.broadcast();
  final List<StreamSubscription<void>> _subscriptions = [];

  /// The last status built, so a position tick and a state change can each
  /// update their half without dropping the other.
  CastStatus _last = const CastStatus(state: CastPlayerState.idle);

  @override
  bool get isSupported => Platform.isAndroid || Platform.isIOS;

  /// Sets the shared Cast context up, once. Everything else on the plugin
  /// depends on it, so every entry point that reaches the SDK goes through
  /// here first.
  Future<void> _ensureInitialised() async {
    if (_initialised || !isSupported) return;
    _initialised = true;
    final options = Platform.isAndroid
        ? GoogleCastOptionsAndroid(appId: applicationId)
        : IOSGoogleCastOptions(
            GoogleCastDiscoveryCriteriaInitialize.initWithApplicationID(
              applicationId,
            ),
          );
    try {
      await GoogleCastContext.instance.setSharedInstanceWithOptions(options);
    } catch (error) {
      // A device with no Play services, or an SDK that refused to come up:
      // there is simply no casting, and the button will find no devices.
      _initialised = false;
      if (kDebugMode) debugPrint('cast context unavailable: $error');
      return;
    }
    _listen();
  }

  /// Folds the two streams the SDK reports playback on -- the media status
  /// and the player position, which arrive separately -- into one.
  void _listen() {
    final client = GoogleCastRemoteMediaClient.instance;
    _subscriptions.addAll([
      client.mediaStatusStream.listen(_onMediaStatus),
      client.playerPositionStream.listen(_onPosition),
    ]);
  }

  void _onMediaStatus(GoggleCastMediaStatus? status) {
    if (status == null) {
      _emit(const CastStatus(state: CastPlayerState.idle));
      return;
    }
    final state = switch (status.playerState) {
      CastMediaPlayerState.playing => CastPlayerState.playing,
      CastMediaPlayerState.paused => CastPlayerState.paused,
      CastMediaPlayerState.buffering ||
      CastMediaPlayerState.loading => CastPlayerState.buffering,
      CastMediaPlayerState.idle ||
      CastMediaPlayerState.unknown => CastPlayerState.idle,
    };
    _emit(
      CastStatus(
        state: state,
        position: _last.position,
        duration: status.mediaInformation?.duration ?? _last.duration,
        // Only `finished` is the media reaching its end; cancelled and
        // interrupted are someone stopping it or loading something else,
        // and the library must not record those as watched to the end.
        ended:
            state == CastPlayerState.idle &&
            status.idleReason == GoogleCastMediaIdleReason.finished,
      ),
    );
  }

  void _onPosition(Duration position) => _emit(
    CastStatus(
      state: _last.state,
      position: position,
      duration: _last.duration,
      ended: _last.ended,
    ),
  );

  void _emit(CastStatus status) {
    if (_status.isClosed || status == _last) return;
    _last = status;
    _status.add(status);
  }

  @override
  Stream<List<CastDevice>> get devices => isSupported
      ? GoogleCastDiscoveryManager.instance.devicesStream.map(_devicesOf)
      : const Stream.empty();

  @override
  List<CastDevice> get currentDevices => isSupported && _initialised
      ? _devicesOf(GoogleCastDiscoveryManager.instance.devices)
      : const [];

  static List<CastDevice> _devicesOf(List<GoogleCastDevice> devices) => [
    for (final device in devices)
      CastDevice(
        id: device.deviceID,
        name: device.friendlyName,
        model: device.modelName,
      ),
  ];

  @override
  Future<void> startDiscovery() async {
    await _ensureInitialised();
    if (!_initialised) return;
    await GoogleCastDiscoveryManager.instance.startDiscovery();
  }

  @override
  Future<void> stopDiscovery() async {
    if (!_initialised) return;
    await GoogleCastDiscoveryManager.instance.stopDiscovery();
  }

  @override
  Stream<CastDevice?> get session => isSupported
      ? GoogleCastSessionManager.instance.currentSessionStream.map(_deviceOf)
      : const Stream.empty();

  @override
  CastDevice? get connectedDevice => isSupported && _initialised
      ? _deviceOf(GoogleCastSessionManager.instance.currentSession)
      : null;

  static CastDevice? _deviceOf(GoogleCastSession? session) {
    final device = session?.device;
    if (device == null) return null;
    if (session?.connectionState != GoogleCastConnectState.connected) {
      return null;
    }
    return CastDevice(
      id: device.deviceID,
      name: device.friendlyName,
      model: device.modelName,
    );
  }

  @override
  Future<bool> connect(CastDevice device) async {
    await _ensureInitialised();
    if (!_initialised) return false;
    final found = GoogleCastDiscoveryManager.instance.devices
        .where((candidate) => candidate.deviceID == device.id)
        .firstOrNull;
    if (found == null) return false;
    return GoogleCastSessionManager.instance.startSessionWithDevice(found);
  }

  @override
  Future<void> disconnect() async {
    if (!_initialised) return;
    await GoogleCastSessionManager.instance.endSessionAndStopCasting();
  }

  @override
  Future<void> load(CastMedia media, {Duration start = Duration.zero}) async {
    if (!_initialised) return;
    final url = media.url.toString();
    final metadata = GoogleCastGenericMediaMetadata(
      title: media.title,
      subtitle: media.subtitle,
    );
    // The two differ only in how the platform channel decodes them; the
    // fields are the base class's either way.
    final information = Platform.isAndroid
        ? GoogleCastMediaInformationAndroid(
            contentId: url,
            contentUrl: media.url,
            contentType: media.contentType,
            streamType: CastMediaStreamType.buffered,
            metadata: metadata,
          )
        : GoogleCastMediaInformationIOS(
            contentId: url,
            contentUrl: media.url,
            contentType: media.contentType,
            streamType: CastMediaStreamType.buffered,
            metadata: metadata,
          );
    await GoogleCastRemoteMediaClient.instance.loadMedia(
      information,
      autoPlay: true,
      playPosition: start,
    );
  }

  @override
  Future<void> play() async {
    if (_initialised) await GoogleCastRemoteMediaClient.instance.play();
  }

  @override
  Future<void> pause() async {
    if (_initialised) await GoogleCastRemoteMediaClient.instance.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    if (!_initialised) return;
    await GoogleCastRemoteMediaClient.instance.seek(
      GoogleCastMediaSeekOption(position: position),
    );
  }

  @override
  Future<void> stop() async {
    if (_initialised) await GoogleCastRemoteMediaClient.instance.stop();
  }

  @override
  Stream<CastStatus> get status => _status.stream;

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _status.close();
  }
}
