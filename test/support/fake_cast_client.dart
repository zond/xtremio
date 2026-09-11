import 'dart:async';

import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/cast/cast_client.dart';

/// [CastClient] for widget tests: records every call and lets the test say
/// what receivers exist and what they report. No Cast SDK, no network.
class FakeCastClient implements CastClient {
  FakeCastClient({
    this.isSupported = true,
    List<CastDevice> devices = const [],
    this.addresses = const {},
  }) : _devices = [...devices];

  /// Where each receiver is, keyed by device id, as the platform would
  /// answer it. The real client only asks when a session starts, so a
  /// device in the list carries no address until [connect] hands one back.
  final Map<String, String> addresses;

  @override
  bool isSupported;

  List<CastDevice> _devices;
  final _devicesController = StreamController<List<CastDevice>>.broadcast(
    sync: true,
  );
  final _sessionController = StreamController<CastDevice?>.broadcast(
    sync: true,
  );
  final _statusController = StreamController<CastStatus>.broadcast(sync: true);

  CastDevice? _connected;

  int discoveryStarts = 0;
  int discoveryStops = 0;
  int disconnects = 0;
  int plays = 0;
  int pauses = 0;
  int stops = 0;
  final List<Duration> seeks = [];

  /// Every `load`: the media and the position it was asked to start at.
  final List<(CastMedia, Duration)> loads = [];

  /// How long a `load` takes to answer. Zero unless a test is about what
  /// happens during it: a real receiver takes a round trip to accept the
  /// media, and a session started mid-cast spends that round trip with the
  /// listener's count already reset for it and its own wait not yet armed.
  Duration loadDelay = Duration.zero;

  /// When set, `load` records the media and then throws it: the platform
  /// refusing, not the receiver (a receiver's refusal is a status).
  Object? loadError;

  /// When set, `connect` records the device and then answers null.
  bool connectFails = false;
  final List<CastDevice> connectAttempts = [];

  /// Holds `connect` open until it completes. Starting a session is a
  /// round trip to the platform and then to the receiver -- seconds on a
  /// real Chromecast -- and everything the player does with a session
  /// happens after it, so a test about leaving mid-start says here when
  /// the session comes back.
  Future<void>? connectPending;

  /// The same for ending one, which is the round trip the film coming
  /// back to this device waits on.
  Future<void>? disconnectPending;

  bool disposed = false;

  /// Puts [devices] on the network and tells whoever is listening.
  void emitDevices(List<CastDevice> devices) {
    _devices = [...devices];
    _devicesController.add(_devices);
  }

  /// One report from the receiver.
  void emitStatus(CastStatus status) => _statusController.add(status);

  /// The platform reporting the session as [device] (null: ending, or
  /// gone), without anything here having asked for it: the session moved by
  /// the system's own output switcher, or ended from the receiver.
  void emitSession(CastDevice? device) {
    _connected = device;
    _sessionController.add(device);
  }

  @override
  Stream<List<CastDevice>> get devices async* {
    yield _devices;
    yield* _devicesController.stream;
  }

  @override
  List<CastDevice> get currentDevices => _devices;

  @override
  Future<void> startDiscovery() async => discoveryStarts++;

  @override
  Future<void> stopDiscovery() async => discoveryStops++;

  @override
  Stream<CastDevice?> get session async* {
    yield _connected;
    yield* _sessionController.stream;
  }

  @override
  CastDevice? get connectedDevice => _connected;

  @override
  Future<CastDevice?> connect(CastDevice device) async {
    connectAttempts.add(device);
    if (connectPending != null) await connectPending;
    if (connectFails) return null;
    final receiver = CastDevice(
      id: device.id,
      name: device.name,
      model: device.model,
      address: addresses[device.id] ?? device.address,
    );
    // As the SDK does: a session on another receiver is ended before the
    // new one comes up, and the platform reports that end -- twice, ending
    // and then gone -- exactly as it reports one nobody here asked for.
    if (_connected != null && _connected != receiver) {
      _sessionController
        ..add(null)
        ..add(null);
    }
    _connected = receiver;
    _sessionController.add(receiver);
    return receiver;
  }

  @override
  Future<void> disconnect() async {
    if (disconnectPending != null) await disconnectPending;
    disconnects++;
    _connected = null;
    _sessionController.add(null);
  }

  @override
  Future<void> load(CastMedia media, {Duration start = Duration.zero}) async {
    loads.add((media, start));
    if (loadDelay > Duration.zero) await Future<void>.delayed(loadDelay);
    if (loadError != null) throw loadError!;
  }

  @override
  Future<void> play() async => plays++;

  @override
  Future<void> pause() async => pauses++;

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> stop() async => stops++;

  @override
  Stream<CastStatus> get status => _statusController.stream;

  @override
  void dispose() {
    disposed = true;
    _devicesController.close();
    _sessionController.close();
    _statusController.close();
  }
}

/// [LanMediaControl] for widget tests: remembers whether the listener is on
/// and hands out a LAN base URL, without a server anywhere.
class FakeLanMediaControl implements LanMediaControl {
  FakeLanMediaControl({this.baseUrl, this.address = '0.0.0.0:39271'});

  /// What [lanMediaBaseUrl] answers while the listener runs; null means the
  /// receiver cannot be reached, which is a refusal and not a loopback URL.
  Uri? baseUrl;

  /// The address a start reports.
  String address;

  /// When set, a start throws it (the server is not running, the bind
  /// failed), and nothing is left listening.
  Object? startError;

  bool running = false;

  /// Every `setLanMedia`, in order: the listener's life as the screen ran
  /// it, so a test can say "on once, off once" rather than only "off now".
  final List<bool> toggles = [];

  /// The peers a base URL was asked for.
  final List<String?> baseUrlRequests = [];

  /// What the listener has been asked for: zero is a receiver that never
  /// came back for the stream.
  ///
  /// Every `setLanMedia` puts it back to zero, exactly as the server's own
  /// counter does -- the count belongs to a cast session and not to the
  /// listener, so a second receiver picked while the first still has the
  /// stream starts from nothing even though the listener never stopped.
  /// The whole never-fetched check rests on that, so a test says what a
  /// receiver fetched *after* starting the session it fetched during, and
  /// taking the reset away is something a test can now see.
  int requestsServed = 0;

  @override
  Future<String?> setLanMedia({required bool enabled}) async {
    toggles.add(enabled);
    // Above the failure below because the server resets above its own: a
    // start that cannot bind has still ended the last session's count.
    requestsServed = 0;
    if (enabled && startError != null) {
      running = false;
      throw startError!;
    }
    running = enabled;
    return enabled ? address : null;
  }

  @override
  bool get lanMediaRunning => running;

  @override
  int get lanMediaRequestsServed => running ? requestsServed : 0;

  @override
  Future<Uri?> lanMediaBaseUrl({String? peerIp}) async {
    baseUrlRequests.add(peerIp);
    return running ? baseUrl : null;
  }
}
