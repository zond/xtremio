import 'dart:convert';
import 'dart:io';

import '../src/rust/api/server.dart' as rust;

/// stremio-core's default streaming-server port, preferred so a persisted
/// profile that points at `http://127.0.0.1:11470` still reaches us.
const int kDefaultServerPort = 11470;

/// Control over the server's LAN media listener, which is what a cast
/// session needs and the only thing that ever turns it on.
///
/// A second HTTP listener serving media bytes to the local network -- a
/// Chromecast cannot fetch from the loopback one -- with no control routes
/// on it at all, and deliberately not `/proxy` or `/ftp`. It exists for the
/// length of a cast session and no longer.
///
/// Behind an interface so the cast tests can assert that it is turned off
/// when a session ends without a server to turn off.
abstract interface class LanMediaControl {
  /// Starts or stops the listener; answers the address it is bound to
  /// afterwards (`0.0.0.0:39271`), or null after a stop. Throws when the
  /// server is not running or the bind fails, in which case nothing is
  /// listening.
  Future<String?> setLanMedia({required bool enabled});

  /// Whether the listener is running. False with no server running either:
  /// both mean nothing of ours is on the LAN.
  bool get lanMediaRunning;

  /// The base URL to give a receiver at [peerIp], so a media URL built on it
  /// names an interface that receiver can connect back to. [peerIp] null
  /// when the receiver's address is not known -- the Cast SDK does not
  /// report one -- which answers the host's first non-loopback interface.
  ///
  /// Null when the listener is not running or the host has nothing but
  /// loopback: the receiver is out of reach, and a loopback URL would not
  /// change that.
  Future<Uri?> lanMediaBaseUrl({String? peerIp});
}

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
class ServerClient implements LanMediaControl {
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

  @override
  Future<String?> setLanMedia({required bool enabled}) =>
      rust.serverSetLanMedia(enabled: enabled);

  @override
  bool get lanMediaRunning => rust.serverLanMediaRunning();

  @override
  Future<Uri?> lanMediaBaseUrl({String? peerIp}) async {
    final url = await rust.serverLanMediaBaseUrl(peerIp: peerIp);
    return url == null ? null : Uri.parse(url);
  }

  static Map<String, dynamic> _object(String json) =>
      jsonDecode(json) as Map<String, dynamic>;
}
