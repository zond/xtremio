import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../src/rust/api/diagnostics.dart' as rust;
import 'server_client.dart';
import 'state/server_storage.dart';

export '../src/rust/api/diagnostics.dart' show DiagnosticsSnapshot;

/// What the Diagnostics screen reads: the Rust side's own recent log and
/// build facts, plus the little the Dart side knows about the device.
///
/// An interface so widget tests can hand the screen a snapshot instead of
/// reaching FFI, the way `TorrentStatsClient` works for the player.
abstract interface class DiagnosticsClient {
  /// The core's log ring, the pinned revisions and the embedded server's
  /// base URL (null when it is not running). Cheap: no I/O.
  rust.DiagnosticsSnapshot snapshot();

  /// `Platform.operatingSystem`, e.g. `android`.
  String get platform;

  /// What the OS and the hardware are, in words: `Android 14 (API 34) ·
  /// Google Pixel 7`. Asynchronous because on Android it is a platform
  /// channel call -- `dart:io` only has the build fingerprint there.
  Future<String> osVersion();

  /// What the embedded server's storage costs: the cache against its
  /// limit, and the room left where it writes. Throws when the server is
  /// not running, which costs the report those lines and nothing else.
  Future<ServerStorage> storage();
}

/// [DiagnosticsClient] over FFI, `dart:io` and the `xtremio/device`
/// channel.
class RustDiagnosticsClient implements DiagnosticsClient {
  const RustDiagnosticsClient({
    this.channel = deviceChannel,
    this.server = const ServerClient(),
  });

  /// The same channel `DeviceProfile.detect` asks; `MainActivity` answers
  /// `os` with the release, the API level and the hardware.
  static const MethodChannel deviceChannel = MethodChannel('xtremio/device');

  final MethodChannel channel;

  /// Where the storage numbers come from, over FFI like every other
  /// control call.
  final ServerClient server;

  @override
  rust.DiagnosticsSnapshot snapshot() => rust.diagnosticsSnapshot();

  @override
  String get platform => Platform.operatingSystem;

  @override
  Future<ServerStorage> storage() => server.storage();

  /// The platform's answer, or what `dart:io` says when there is nobody to
  /// ask.
  ///
  /// On Android `Platform.operatingSystemVersion` is the *build
  /// fingerprint* (`W1VVS36H.7-108-8-6`), which names neither the Android
  /// version, nor the API level, nor the hardware -- and the hardware is
  /// what decides whether a codec is decoded on a chip or on the CPU.
  /// Everywhere else it is already a sentence a person can read.
  @override
  Future<String> osVersion() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Platform.operatingSystemVersion;
    }
    try {
      final reply = await channel.invokeMapMethod<String, Object?>('os');
      final described = reply == null ? null : describeAndroidOs(reply);
      return described == null || described.isEmpty
          ? Platform.operatingSystemVersion
          : described;
    } on PlatformException catch (_) {
      return Platform.operatingSystemVersion;
    } on MissingPluginException catch (_) {
      return Platform.operatingSystemVersion;
    }
  }
}

/// `MainActivity`'s `os` reply as one line: `Android 14 (API 34) · Google
/// Pixel 7`.
///
/// Every part is optional -- an emulator image with no manufacturer, a
/// build with no release string -- and what is missing is left out rather
/// than written as a blank or an `unknown`. A model that already names its
/// maker (`Nokia X20`) is not made to say it twice.
String describeAndroidOs(Map<String, Object?> reply) {
  final release = (reply['release'] as String? ?? '').trim();
  final sdk = reply['sdkInt'];
  final model = (reply['model'] as String? ?? '').trim();
  final manufacturer = (reply['manufacturer'] as String? ?? '').trim();

  final version = StringBuffer('Android');
  if (release.isNotEmpty) version.write(' $release');
  if (sdk != null) version.write(' (API $sdk)');

  final device = model.toLowerCase().startsWith(manufacturer.toLowerCase())
      ? model
      : [manufacturer, model].where((part) => part.isNotEmpty).join(' ');
  return device.isEmpty ? version.toString() : '$version · $device';
}
