import 'dart:convert';
import 'dart:io';

import '../src/rust/api/server.dart' as rust;
import 'state/server_storage.dart';

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

/// What the storage screen needs from the server: the cache's usage
/// against its limit, and the one way there is to ask it to reclaim some.
///
/// Behind an interface so the screen can be driven by a fake in tests.
abstract interface class ServerCacheControl {
  /// What the cache currently occupies against its limit, without evicting
  /// anything. Throws when the server is not running.
  Future<CacheUsage> cacheUsage();

  /// Runs one eviction pass now and reports what it freed. Nothing here
  /// stops playback -- the same protections the server's own scheduled
  /// sweep uses apply, so a live stream or a pinned download is never
  /// touched. Throws when the server is not running.
  Future<EvictionReport> cleanCacheNow();
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
class ServerClient implements LanMediaControl, ServerCacheControl {
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

  /// What the server's storage costs right now: the cache against its
  /// `cacheSize` limit, and the room left on the volumes it writes to.
  ///
  /// Walks the cache directory on the Rust side, so it is a worker call
  /// rather than a property; throws when the server is not running (there
  /// is no cache root to name then). This is the disk-and-cache-directory
  /// half of the picture -- the free/total space of the volumes the server
  /// writes to, which stream-server does not report itself; for the
  /// cache's own occupancy against its limit, [cacheUsage] is the
  /// authoritative number (see `server_storage_report`).
  Future<ServerStorage> storage() async =>
      ServerStorage.fromJson(_object(await rust.serverStorageReport()));

  /// What the cache currently occupies against its `cacheSize` limit,
  /// without evicting anything (`ServerHandle::cache_usage`). Throws when
  /// the server is not running.
  @override
  Future<CacheUsage> cacheUsage() async =>
      CacheUsage.fromJson(_object(await rust.serverCacheUsage()));

  /// Runs one eviction pass now and reports what it freed
  /// (`ServerHandle::clean_cache_now`) -- the exact function the server's
  /// own scheduled sweep calls, so the same protections apply: nothing a
  /// live engine is writing or a pin keeps is ever touched. Nothing here
  /// stops playback. Throws when the server is not running.
  @override
  Future<EvictionReport> cleanCacheNow() async =>
      EvictionReport.fromJson(_object(await rust.serverCleanCacheNow()));

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
