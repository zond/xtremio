import 'dart:async';

import 'package:xtremio/features/addons/addon_health.dart';
import 'package:xtremio/features/addons/addon_health_client.dart';

/// An [AddonHealthClient] over a table held in memory, standing in for the
/// Rust side's counts.
///
/// [forgotten] records every key handed to [forget], which is how a test
/// checks that what crosses is the record's key and never the transport
/// URL it was hashed from.
class FakeAddonHealthClient implements AddonHealthClient {
  FakeAddonHealthClient({
    Map<String, Map<AddonResourceKind, AddonHealthRecord>>? addons,
    this.everyAnswerFailed = false,
    this.failing = false,
    this.forgetFails = false,
  }) : addons = {...?addons};

  /// What is "recorded", keyed by [addonHealthKey].
  final Map<String, Map<AddonResourceKind, AddonHealthRecord>> addons;

  bool everyAnswerFailed;

  /// One that throws from both sides: the screen goes on listing the addons
  /// with nothing said about any of them.
  final bool failing;

  /// One that reads fine but cannot drop a record -- the core going away
  /// between the read and the tap, which is the shape the screen must not
  /// report as a successful forget.
  bool forgetFails;

  final List<String> forgotten = [];
  int reads = 0;

  /// Open while a read is being held: what the screen looks like between
  /// mounting and the record arriving, which on a device is an FFI call and
  /// not a microtask. A test that never calls [holdReads] never waits.
  Completer<void>? _gate;

  /// Makes every read from now on wait for [releaseReads].
  void holdReads() => _gate ??= Completer<void>();

  /// Lets the held reads answer.
  void releaseReads() {
    _gate?.complete();
    _gate = null;
  }

  @override
  Future<AddonHealthReport> read() async {
    final gate = _gate;
    if (gate != null) await gate.future;
    if (failing) throw StateError('no core');
    reads++;
    return AddonHealthReport(
      addons: {
        for (final entry in addons.entries) entry.key: {...entry.value},
      },
      everyAnswerFailed: everyAnswerFailed,
    );
  }

  @override
  Future<bool> forget(String key) async {
    if (failing || forgetFails) throw StateError('no core');
    forgotten.add(key);
    return addons.remove(key) != null;
  }
}
