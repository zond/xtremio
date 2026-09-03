import 'dart:io';

import '../src/rust/api/diagnostics.dart' as rust;

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

  /// `Platform.operatingSystemVersion`: what the OS calls itself.
  String get osVersion;
}

/// [DiagnosticsClient] over FFI and `dart:io`.
class RustDiagnosticsClient implements DiagnosticsClient {
  const RustDiagnosticsClient();

  @override
  rust.DiagnosticsSnapshot snapshot() => rust.diagnosticsSnapshot();

  @override
  String get platform => Platform.operatingSystem;

  @override
  String get osVersion => Platform.operatingSystemVersion;
}
