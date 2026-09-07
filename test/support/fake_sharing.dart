import 'dart:async';

import 'package:xtremio/core/core.dart';
import 'package:xtremio/shell/network_cost.dart';

/// A [NetworkCostSource] a test drives by hand, so the readings arrive
/// when the test says they do -- which is the only way to walk what the
/// policy does *between* sessions rather than at one moment.
class FakeNetworkCost implements NetworkCostSource {
  FakeNetworkCost([this.opening]);

  /// Emitted as soon as it is listened to, the way the real ones do; null
  /// for a source that has not heard anything yet.
  final NetworkCost? opening;

  final StreamController<NetworkCost> _readings =
      StreamController<NetworkCost>();

  /// Whether anything is subscribed: the policy watching, or not.
  bool get watched => _readings.hasListener;

  @override
  Stream<NetworkCost> get costs async* {
    final opening = this.opening;
    if (opening != null) yield opening;
    yield* _readings.stream;
  }

  /// The connection changed under the app, which is the case that decides
  /// between watching and asking.
  void report(NetworkCost cost) => _readings.add(cost);

  void fail(Object error) => _readings.addError(error);

  Future<void> close() => _readings.close();
}

/// A [ServerSettingsWriter] that records what the app asked the embedded
/// server to change, instead of reaching FFI.
class RecordingServerSettings implements ServerSettingsWriter {
  RecordingServerSettings({this.failWhile = 0});

  /// Every patch, in order and exactly as it was written -- the keys are
  /// the server's own spellings and a test reads them literally.
  final List<Map<String, dynamic>> patches = [];

  /// How many of the first calls throw, for the "the server is not up yet"
  /// path.
  int failWhile;

  @override
  Future<Map<String, dynamic>> updateSettings(
    Map<String, dynamic> patch,
  ) async {
    if (failWhile > 0) {
      failWhile -= 1;
      throw StateError('server is not running');
    }
    patches.add(patch);
    return patch;
  }
}
