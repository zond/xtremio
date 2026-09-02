import 'dart:convert';
import 'dart:io';

import '../src/rust/api/server.dart' as rust;

/// stremio-core's default streaming-server port, preferred so a persisted
/// profile that points at `http://127.0.0.1:11470` still reaches us.
const int kDefaultServerPort = 11470;

/// Thin Dart facade over the embedded, in-process `stream-server`.
///
/// The server is a process-wide singleton on the Rust side; this class only
/// shapes the calls and parses URLs and JSON. Directories come from
/// `path_provider` in the app (Rust creates them if missing). Everything the
/// app wants from the server's control API -- settings, a torrent's
/// start-up stats -- comes through here over FFI, the same functions its
/// HTTP routes run: the Dart side never speaks HTTP to the server (those
/// routes want a bearer token only the Rust side knows); the player fetches
/// media from the open stream routes.
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

  /// The server's settings (`GET /settings` → `values`: `cacheSize`,
  /// `btMaxConnections`, ...). Throws when the server is not running.
  Future<Map<String, dynamic>> settings() async =>
      _object(await rust.serverSettings());

  /// Applies [patch] (settings keys and their new values) as
  /// `POST /settings` would -- validated, merged, persisted -- and returns
  /// the settings afterwards. Throws on a rejected value or when the server
  /// is not running.
  Future<Map<String, dynamic>> updateSettings(
    Map<String, dynamic> patch,
  ) async =>
      _object(await rust.serverUpdateSettings(patchJson: jsonEncode(patch)));

  /// A torrent's `stats.json`: the per-file stats when [fileIdx] is set,
  /// the torrent-level ones otherwise. [trackers] is the stream's
  /// `announce` list, used only when this call is what creates the engine.
  /// Throws when the server is not running or [fileIdx] is not a file of
  /// the torrent (once its metadata is known).
  Future<Map<String, dynamic>> torrentStats({
    required String infoHash,
    int? fileIdx,
    List<String> trackers = const [],
  }) async => _object(
    await rust.serverTorrentStats(
      infoHash: infoHash,
      fileIdx: fileIdx,
      trackers: trackers,
    ),
  );

  static Map<String, dynamic> _object(String json) =>
      jsonDecode(json) as Map<String, dynamic>;
}
