import 'dart:convert';
import 'dart:io';

import '../src/rust/api/server.dart' as rust;
import 'state/dht_status.dart';
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

  /// How many requests the listener has been asked for since it started;
  /// zero when nothing is listening. Per cast session, since a start and a
  /// stop both reset it -- a second receiver picked while the first still
  /// has the stream starts from zero rather than inheriting its count.
  ///
  /// What it separates is a receiver that never fetched the stream from one
  /// that did -- which look identical from the sofa, and identical to the
  /// sender too: a receiver handed an address it cannot route to hangs on
  /// the connect and reports nothing at all. Above zero says the receiver
  /// reached this device and nothing further: a cold torrent twenty seconds
  /// in has fetched and is still warming up, so the count cannot tell a
  /// receiver that is filling a buffer from one that cannot decode what it
  /// fetched.
  int get lanMediaRequestsServed;

  /// The base URL to give a receiver at [peerIp], so a media URL built on it
  /// names an interface that receiver can connect back to. [peerIp] null
  /// when the receiver's address is not known, which answers the server's
  /// best-ranked interface -- a private address on an ordinary interface
  /// ahead of anything on one a receiver cannot be behind at all: a tunnel,
  /// a cellular link, a tether, a container or VM bridge -- rather than the
  /// address it happened to enumerate first.
  ///
  /// Null when the listener is not running or the host has nothing but
  /// loopback: the receiver is out of reach, and a loopback URL would not
  /// change that.
  Future<Uri?> lanMediaBaseUrl({String? peerIp});
}

/// Ending the proxied streams one player is reading, which is what leaving
/// a player asks for.
///
/// Behind an interface so the player's widget tests can leave a screen
/// without reaching FFI, and so they can say which token was closed.
abstract interface class ProxyStreamControl {
  /// Ends every proxied stream carrying [token] -- the name this app
  /// minted for one player and wrote into the `/proxy` URL that player
  /// fetches -- and answers how many streams that was. An HLS player has
  /// several, because the server carries the token into every line of
  /// every playlist it rewrites, and they all end together.
  ///
  /// Zero is an ordinary answer: the player may have finished, or never
  /// have been proxied, or there may be no server running. None of those
  /// is a failure, and none of them is a reason for a teardown to stop --
  /// which is why this does not wait.
  ///
  /// It can still **throw**, and a caller on a teardown path has to say
  /// what happens when it does. The implementation is a synchronous FFI
  /// call, so a panic in the core or a bridge that is not up arrives here
  /// as an exception; there is no answer to give in that case and nothing
  /// useful to do about it beyond writing it down. It used to say it never
  /// throws, and the one caller believed it: the call sat at the top of a
  /// `dispose` and a throw would have skipped the release of the player
  /// itself.
  ///
  /// **It ends the read *and the token*.** The body fails and the
  /// connection is dropped, so the demuxer sees its source break now
  /// instead of after `network-timeout` -- which stays generous on
  /// purpose, because a slow swarm must not be mistaken for a dead
  /// connection. On its own that is not the end of the stream: ffmpeg
  /// reconnects through the URL it already has, token and all, and simply
  /// carries on. So the server retires the token at the same time and
  /// answers `410 Gone` to anything that comes back with it. Its
  /// documented order is quit-then-close -- a cancelled demuxer never
  /// reaches its reconnect -- and the refusal is what covers a close that
  /// gets there first. A demuxer wedged anywhere else -- on the Flutter
  /// texture, on the audio device -- is not waiting on this read and is
  /// untouched.
  int closeProxyStreams(String token);
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
class ServerClient
    implements LanMediaControl, ServerCacheControl, ProxyStreamControl {
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

  /// The mainline DHT's status right now (`ServerHandle::dht_status`):
  /// whether it is running, how many nodes are in each routing table, and
  /// whether either has ever been non-empty this session. Never throws --
  /// a server that is not running answers the same as "no DHT to ask",
  /// `DhtStatus(enabled: false, ...)`.
  ///
  /// Cheap and synchronous (two routing-table length reads); still, do not
  /// poll it on a timer of its own -- read it on screen-open, or alongside
  /// a poll that is already running.
  DhtStatus get dhtStatus =>
      DhtStatus.fromJson(_object(rust.serverDhtStatus()));

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
  int get lanMediaRequestsServed => rust.serverLanMediaRequestsServed();

  /// Ends every proxied stream carrying [token]
  /// (`ServerHandle::close_proxy_streams`) and answers how many that was.
  ///
  /// Synchronous, like the reads above and for a sharper reason: it is a
  /// map scan with no I/O, and it is called from a teardown, where queuing
  /// behind a blocking call already on the FRB worker pool would hand back
  /// exactly the delay it exists to remove. Synchronous also means a
  /// failure arrives as a throw rather than a rejected future, which is
  /// why the caller catches.
  @override
  int closeProxyStreams(String token) =>
      rust.serverCloseProxyStreams(token: token);

  @override
  Future<Uri?> lanMediaBaseUrl({String? peerIp}) async {
    final url = await rust.serverLanMediaBaseUrl(peerIp: peerIp);
    return url == null ? null : Uri.parse(url);
  }

  static Map<String, dynamic> _object(String json) =>
      jsonDecode(json) as Map<String, dynamic>;
}
