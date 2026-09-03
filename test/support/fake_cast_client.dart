import 'dart:async';

import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/cast/cast_client.dart';

/// [CastClient] for widget tests: records every call and lets the test say
/// what receivers exist and what they report. No Cast SDK, no network.
class FakeCastClient implements CastClient {
  FakeCastClient({this.isSupported = true, List<CastDevice> devices = const []})
    : _devices = [...devices];

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

  /// When set, `connect` records the device and then answers false.
  bool connectFails = false;
  final List<CastDevice> connectAttempts = [];

  bool disposed = false;

  /// Puts [devices] on the network and tells whoever is listening.
  void emitDevices(List<CastDevice> devices) {
    _devices = [...devices];
    _devicesController.add(_devices);
  }

  /// One report from the receiver.
  void emitStatus(CastStatus status) => _statusController.add(status);

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
  Future<bool> connect(CastDevice device) async {
    connectAttempts.add(device);
    if (connectFails) return false;
    _connected = device;
    _sessionController.add(device);
    return true;
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    _connected = null;
    _sessionController.add(null);
  }

  @override
  Future<void> load(CastMedia media, {Duration start = Duration.zero}) async {
    loads.add((media, start));
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

  @override
  Future<String?> setLanMedia({required bool enabled}) async {
    toggles.add(enabled);
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
  Future<Uri?> lanMediaBaseUrl({String? peerIp}) async {
    baseUrlRequests.add(peerIp);
    return running ? baseUrl : null;
  }
}
