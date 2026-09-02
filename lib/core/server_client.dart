import 'dart:io';

import '../src/rust/api/server.dart' as rust;

/// stremio-core's default streaming-server port, preferred so a persisted
/// profile that points at `http://127.0.0.1:11470` still reaches us.
const int kDefaultServerPort = 11470;

/// Thin Dart facade over the embedded, in-process `stream-server`.
///
/// The server is a process-wide singleton on the Rust side; this class only
/// shapes the calls and parses URLs. Directories come from `path_provider`
/// in the app (Rust creates them if missing).
class ServerClient {
  const ServerClient();

  /// Starts the server (idempotent) and returns its base URL.
  ///
  /// [port] 0 asks for an ephemeral port; with [fallbackToEphemeral] a busy
  /// preferred port falls back to an ephemeral one instead of failing.
  Future<Uri> start({
    required Directory configDir,
    required Directory cacheDir,
    int port = kDefaultServerPort,
    bool fallbackToEphemeral = true,
  }) async {
    final url = await rust.serverStart(
      config: rust.ServerConfig(
        configDir: configDir.path,
        cacheDir: cacheDir.path,
        port: port,
        fallbackToEphemeral: fallbackToEphemeral,
      ),
    );
    return Uri.parse(url);
  }

  /// Stops the server and waits for its thread. No-op when not running.
  Future<void> stop() => rust.serverStop();

  /// Base URL of the running server, or null when stopped.
  Uri? get baseUrl {
    final url = rust.serverBaseUrl();
    return url == null ? null : Uri.parse(url);
  }
}
