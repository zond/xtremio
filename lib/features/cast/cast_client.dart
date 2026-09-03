import 'package:flutter/widgets.dart';

import '../../core/core.dart';

/// A receiver on the local network, as far as the app cares: something with
/// a name that can be picked from a list and connected to.
///
/// [id] is the Cast SDK's own device id, which is what a session is started
/// with and what tells two receivers apart; nothing else here is identity.
///
/// [address] is the receiver's IP when the platform reports one. The Cast
/// SDK does not, so it is null in practice; it exists because it is what the
/// server wants in order to name the *right* local interface in a media URL,
/// and a platform that starts reporting it should not need a new seam.
@immutable
final class CastDevice {
  const CastDevice({
    required this.id,
    required this.name,
    this.model,
    this.address,
  });

  final String id;

  /// What the receiver calls itself ("Living Room TV").
  final String name;

  /// The receiver's model ("Chromecast"), when it says.
  final String? model;

  /// The receiver's IP, when the platform reports one; see the class doc.
  final String? address;

  @override
  bool operator ==(Object other) => other is CastDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'CastDevice($id, $name)';
}

/// What a receiver is doing with the media it was given.
///
/// Deliberately the small set the player screen acts on: a receiver reports
/// a good deal more, and none of the rest changes what a remote shows.
enum CastPlayerState {
  /// Nothing loaded, or playback is over ([CastStatus.ended] says which).
  idle,
  playing,
  paused,

  /// Playing, but nothing is coming out yet: loading or rebuffering.
  buffering;

  /// Whether the receiver considers itself playing, which is what the core's
  /// `PausedChanged` is about. Buffering is playing that has not caught up.
  bool get isPlaying => this == playing || this == buffering;
}

/// One report from the receiver: what it is doing and where it has got to.
@immutable
final class CastStatus {
  const CastStatus({
    required this.state,
    this.position = Duration.zero,
    this.duration,
    this.ended = false,
  });

  final CastPlayerState state;

  /// How far into the media the receiver is.
  final Duration position;

  /// The media's length as the receiver knows it; null before it does.
  final Duration? duration;

  /// The receiver finished the media, rather than being stopped or having
  /// nothing loaded. Only ever true alongside [CastPlayerState.idle], and it
  /// is what tells the core `Ended` from a session someone closed.
  final bool ended;

  /// The same report at another position: what a seek shows while the
  /// receiver's own answer is still on its way.
  CastStatus at(Duration position) => CastStatus(
    state: state,
    position: position,
    duration: duration,
    ended: ended,
  );

  @override
  bool operator ==(Object other) =>
      other is CastStatus &&
      other.state == state &&
      other.position == position &&
      other.duration == duration &&
      other.ended == ended;

  @override
  int get hashCode => Object.hash(state, position, duration, ended);

  @override
  String toString() =>
      'CastStatus($state, $position/$duration${ended ? ', ended' : ''})';
}

/// The media to hand a receiver: a URL it can fetch, what is in it, and what
/// to call it on screen.
@immutable
final class CastMedia {
  const CastMedia({
    required this.url,
    required this.contentType,
    required this.title,
    this.subtitle,
  });

  /// The URL the *receiver* fetches, which is never a loopback one: it comes
  /// from the server's LAN media listener.
  final Uri url;

  /// `video/mp4`, `video/webm`.
  final String contentType;

  final String title;
  final String? subtitle;
}

/// What the app needs from a Cast sender. `flutter_chrome_cast` is the real
/// one; widget tests substitute a fake through [CastScope] so the player's
/// wiring can be exercised with no receiver anywhere.
///
/// Discovery is not free (it keeps the radio busy), so it is started and
/// stopped explicitly rather than running for the life of the app.
abstract interface class CastClient {
  /// Whether this platform can cast at all. False on desktop, and on a
  /// television — a TV is a receiver, not a sender — which is what keeps the
  /// cast button off screens that could never use it.
  bool get isSupported;

  /// The receivers found so far, re-emitted as the list changes. Emits the
  /// current list to a new listener.
  Stream<List<CastDevice>> get devices;

  /// The receivers found so far, without waiting for an event.
  List<CastDevice> get currentDevices;

  Future<void> startDiscovery();
  Future<void> stopDiscovery();

  /// The connected receiver, or null; re-emitted as the session changes.
  /// Emits the current value to a new listener.
  Stream<CastDevice?> get session;

  /// The connected receiver, without waiting for an event.
  CastDevice? get connectedDevice;

  /// Connects to [device]. False when the session could not be started.
  Future<bool> connect(CastDevice device);

  /// Ends the session. The receiver stops playing.
  Future<void> disconnect();

  /// Hands [media] to the connected receiver and starts it at [start].
  Future<void> load(CastMedia media, {Duration start = Duration.zero});

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// Stops playback without ending the session.
  Future<void> stop();

  /// What the receiver reports, as it reports it.
  Stream<CastStatus> get status;

  /// Lets go of whatever the sender is holding. The app has one client, so
  /// this is the app's to call, not a screen's.
  void dispose();
}

/// A [CastClient] for a platform that cannot cast: no devices, ever, and
/// every call a no-op. What [CastScope] falls back to, so a widget tree with
/// no scope above it simply has no cast button rather than reaching for a
/// plugin that is not there.
class UnsupportedCastClient implements CastClient {
  const UnsupportedCastClient();

  @override
  bool get isSupported => false;

  @override
  Stream<List<CastDevice>> get devices => const Stream.empty();

  @override
  List<CastDevice> get currentDevices => const [];

  @override
  Future<void> startDiscovery() async {}

  @override
  Future<void> stopDiscovery() async {}

  @override
  Stream<CastDevice?> get session => const Stream.empty();

  @override
  CastDevice? get connectedDevice => null;

  @override
  Future<bool> connect(CastDevice device) async => false;

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> load(CastMedia media, {Duration start = Duration.zero}) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> stop() async {}

  @override
  Stream<CastStatus> get status => const Stream.empty();

  @override
  void dispose() {}
}

/// Provides the [CastClient] and the [LanMediaControl] to the widget tree,
/// the way [PlaybackScope] and [DownloadsScope] do.
///
/// The two travel together because a cast session is both of them: the
/// receiver is told a URL, and that URL only answers while the server's LAN
/// media listener is up. With no scope above it a widget gets a client that
/// cannot cast and the real server, so the app needs no scope for the
/// listener half and a test that fakes one fakes both.
class CastScope extends InheritedWidget {
  const CastScope({
    super.key,
    required this.client,
    this.lanMedia,
    required super.child,
  });

  final CastClient client;

  /// The LAN media listener; absent, the real embedded server's.
  final LanMediaControl? lanMedia;

  static CastClient of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CastScope>()?.client ??
      const UnsupportedCastClient();

  static LanMediaControl lanMediaOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CastScope>()?.lanMedia ??
      const ServerClient();

  @override
  bool updateShouldNotify(CastScope oldWidget) =>
      client != oldWidget.client || lanMedia != oldWidget.lanMedia;
}
