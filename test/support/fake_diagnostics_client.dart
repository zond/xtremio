import 'package:xtremio/core/core.dart';

/// [DiagnosticsClient] for widget tests: answers with whatever the test
/// put in it, or throws. No FFI.
class FakeDiagnosticsClient implements DiagnosticsClient {
  FakeDiagnosticsClient({
    DiagnosticsSnapshot? snapshot,
    this.platform = 'android',
    this.os = 'Android 14 (API 34)',
    this.error,
  }) : _snapshot =
           snapshot ??
           const DiagnosticsSnapshot(
             coreVersion: '0.1.0',
             streamServerRev: '7c46427bc09075b98f5febe10f2a90143e44d826',
             stremioCoreRev: '00265b3bad7158535fccf1e119e10d6ad492183e',
             serverBaseUrl: 'http://127.0.0.1:11470/',
             logLines: ['first line', 'second line'],
           );

  final DiagnosticsSnapshot _snapshot;

  /// Thrown by [snapshot] instead of answering: the core not being up.
  Object? error;

  @override
  final String platform;

  /// What [osVersion] answers.
  final String os;

  @override
  Future<String> osVersion() async => os;

  /// How many times the screen has asked.
  int reads = 0;

  @override
  DiagnosticsSnapshot snapshot() {
    reads++;
    final error = this.error;
    if (error != null) throw error;
    return _snapshot;
  }
}
