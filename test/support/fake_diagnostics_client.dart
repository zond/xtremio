import 'package:xtremio/core/core.dart';

/// [DiagnosticsClient] for widget tests: answers with whatever the test
/// put in it, or throws. No FFI.
class FakeDiagnosticsClient implements DiagnosticsClient {
  FakeDiagnosticsClient({
    DiagnosticsSnapshot? snapshot,
    this.platform = 'android',
    this.os = 'Android 14 (API 34)',
    this.storageReport,
    this.dht = const DhtStatus(
      enabled: false,
      nodes: 0,
      nodesV6: 0,
      everBootstrapped: false,
    ),
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

  /// What [storage] answers, or null for a server that is not running --
  /// which the report must survive with an `unknown` line.
  ServerStorage? storageReport;

  @override
  Future<ServerStorage> storage() async {
    final report = storageReport;
    if (report == null) throw StateError('embedded server is not running');
    return report;
  }

  /// What [dhtStatus] answers. Disabled by default, matching "the server is
  /// not running" -- a test opts in to the interesting states explicitly.
  DhtStatus dht;

  @override
  DhtStatus dhtStatus() => dht;

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
