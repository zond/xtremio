import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

  /// The channel `MainActivity` answers `castDeviceAddress` on -- the same
  /// one `DeviceProfile.detect` asks about the device this app runs on.
  static const MethodChannel deviceChannel = MethodChannel('xtremio/device');

  final String applicationId;

  bool _initialised = false;

  /// Where each receiver is, as far as Android has said, keyed by Cast
  /// device id. [connect] is what fills a row, and what empties one it
  /// could not fill: a receiver the platform says nothing about this time
  /// has to have no address at all rather than the one it had last time.
  final Map<String, String> _addresses = {};
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

  /// [_onMediaStatus] for a test, which has no SDK stream to arrive on.
  @visibleForTesting
  void onMediaStatus(GoggleCastMediaStatus? status) => _onMediaStatus(status);

  /// [_onPosition] for a test.
  @visibleForTesting
  void onPosition(Duration position) => _onPosition(position);

  /// The last status built: what the next state change will copy its
  /// position from.
  @visibleForTesting
  CastStatus get lastStatus => _last;

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

  List<CastDevice> _devicesOf(List<GoogleCastDevice> devices) => [
    for (final device in devices) _castDevice(device),
  ];

  /// One of the SDK's devices as the app knows it, carrying whatever the
  /// platform has said about where it is ([_rememberAddress]).
  CastDevice _castDevice(GoogleCastDevice device) => CastDevice(
    id: device.deviceID,
    name: device.friendlyName,
    model: device.modelName,
    address: _addresses[device.deviceID],
  );

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
      ? sessionsOf(GoogleCastSessionManager.instance.currentSessionStream)
      : const Stream.empty();

  /// The SDK's session reports as [session] tells them.
  ///
  /// The plugin reports every step of a session's life -- starting,
  /// started, ending, ended -- and a session on its way up is not one on
  /// its way out. Reported as a null, a receiver still connecting read as
  /// a session that had ended, so the one starting in place of a live one
  /// told the player that the cast was over while it was being handed on.
  /// A session connecting is therefore not reported at all: it is either
  /// connected next, which is reported, or it fails, and the session that
  /// is then current (none) is reported as it is.
  @visibleForTesting
  Stream<CastDevice?> sessionsOf(Stream<GoogleCastSession?> sessions) =>
      sessions
          .where(
            (session) =>
                session?.connectionState != GoogleCastConnectState.connecting,
          )
          .map(_deviceOf);

  @override
  CastDevice? get connectedDevice => isSupported && _initialised
      ? _deviceOf(GoogleCastSessionManager.instance.currentSession)
      : null;

  CastDevice? _deviceOf(GoogleCastSession? session) {
    final device = session?.device;
    if (device == null) return null;
    if (session?.connectionState != GoogleCastConnectState.connected) {
      return null;
    }
    return _castDevice(device);
  }

  @override
  Future<CastDevice?> connect(CastDevice device) async {
    await _ensureInitialised();
    if (!_initialised) return null;
    final found = GoogleCastDiscoveryManager.instance.devices
        .where((candidate) => candidate.deviceID == device.id)
        .firstOrNull;
    if (found == null) return null;
    // Asked for here rather than during discovery: a channel round trip
    // per receiver on every route change buys nothing, and the one moment
    // the address is wanted is this one. It is also asked *before* the
    // session starts, because starting one is an answer that arrives long
    // after the call returns and the URL is wanted well before that.
    await _rememberAddress(device.id);
    final started = await GoogleCastSessionManager.instance
        .startSessionWithDevice(found);
    return started ? _castDevice(found) : null;
  }

  /// Asks Android where the receiver with [id] is and remembers the answer.
  ///
  /// The Cast SDK knows -- a MediaRouter route's extras carry the
  /// `CastDevice` and the address it announced over mDNS -- but the
  /// plugin's own `CastDeviceExtensions.toMap()` drops it, so
  /// `MainActivity.castDeviceAddress` reads it off the route instead.
  ///
  /// A silence is the answer this call never having existed gives: iOS has
  /// no such lookup, an old build has no such channel method, and a route
  /// can go stale between discovering it and casting to it. The server then
  /// ranks its own interfaces, which is what it did for every platform
  /// before this -- which is why the row is forgotten before it is asked
  /// for. Only ever writing would let a silence reuse the address of the
  /// last cast to this receiver, so the ranking a silence is documented to
  /// fall back to would never be reached at all, and a receiver moved to
  /// another part of the network would be handed an interface chosen for
  /// where it used to be. There is no test for this and there cannot be
  /// one here: everything below the first line is the platform's, and
  /// `isSupported` is false wherever the tests run.
  Future<void> _rememberAddress(String id) async {
    if (!Platform.isAndroid) return;
    _addresses.remove(id);
    try {
      final address = await deviceChannel.invokeMethod<String>(
        'castDeviceAddress',
        {'id': id},
      );
      if (address != null && address.isNotEmpty) _addresses[id] = address;
    } on PlatformException catch (error) {
      if (kDebugMode) debugPrint('cast device address unavailable: $error');
    } on MissingPluginException catch (error) {
      if (kDebugMode) debugPrint('cast device address unavailable: $error');
    }
  }

  @override
  Future<void> disconnect() async {
    if (!_initialised) return;
    await GoogleCastSessionManager.instance.endSessionAndStopCasting();
  }

  @override
  Future<void> load(CastMedia media, {Duration start = Duration.zero}) async {
    // The position the SDK reports arrives on its own stream, so a state
    // change is built on whatever position was last seen -- and until the
    // receiver's first tick that is the *previous* session's, minutes into
    // a film this receiver has not begun. So the record starts where the
    // media is being started: the first status of this session then
    // carries [start], which is the one position that is true of it. The
    // player's own rule cannot tell that case apart -- a stale forty
    // minutes looks exactly like a receiver reporting forty minutes --
    // which is why it is settled here, before anything is loaded and
    // whether or not the SDK is up (a client that never initialised has
    // nothing to report either way).
    _last = _last.at(start);
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
