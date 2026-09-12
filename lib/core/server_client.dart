import 'dart:convert';
import 'dart:io';

import '../src/rust/api/server.dart' as rust;
import 'state/background_traffic.dart';
import 'state/dht_status.dart';
import 'state/server_storage.dart';
import 'state/stream_numbers.dart';

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

/// Asking what the server holds of one playing stream, which is the whole
/// of what the player's stats panel needs from it beyond the swarm.
///
/// Behind an interface for the same reason [ProxyStreamControl] is: the
/// player's widget tests must not reach FFI, and a test wants to see which
/// URL was asked about -- the panel's rows are only honest if the numbers
/// belong to the stream on screen.
abstract interface class StreamNumbersReader {
  /// What the server holds of the stream at [url] -- the URL handed to the
  /// player. Null when it holds nothing of it, which is an answer and not
  /// a failure. **Throws when the server is not running**, which a caller
  /// draws exactly like null: both mean there are no rows to show, but
  /// only one of them is worth writing down.
  Future<StreamNumbers?> streamNumbers(Uri url);
}

/// Changing something about the embedded server, which is one call: a
/// patch of settings keys, exactly as `POST /settings` takes it.
///
/// It exists so that the sharing policy can be handed a recorder in tests
/// and its writes read back, and so that the one method it needs is named
/// rather than the whole of [ServerClient]. There is deliberately no
/// second way in: a new need is another key in the patch, not another
/// call.
abstract interface class ServerSettingsWriter {
  /// Applies [patch] and answers the settings afterwards. Throws on a
  /// rejected value or when the server is not running.
  Future<Map<String, dynamic>> updateSettings(Map<String, dynamic> patch);
}

/// Reading the server's settings as well as writing them, which is what
/// the start-up root correction needs and nothing else does: it has to see
/// the `cacheRoot` a *previous* build persisted before it can decide
/// whether this device is on a root the system may reclaim.
///
/// Deliberately not folded into [ServerSettingsWriter]: a writer is handed
/// to policies that must not be able to read the settings back, and a read
/// is the whole of what this adds.
abstract interface class ServerSettingsAccess implements ServerSettingsWriter {
  /// The settings as they stand (`GET /settings` -> `values`). Throws when
  /// the server is not running.
  Future<Map<String, dynamic>> settings();
}

/// What the storage screen needs from the server: where torrent data
/// lives, what it occupies against its limit, and the one way there is to
/// ask the server to reclaim some.
///
/// It writes through [ServerSettingsWriter] rather than owning a call of
/// its own, because moving the root is one settings key (`cacheRoot`) like
/// every other -- see there.
///
/// Behind an interface so the screen can be driven by a fake in tests.
abstract interface class ServerCacheControl implements ServerSettingsWriter {
  /// Where the server writes and what room that volume has left. Throws
  /// when the server is not running.
  Future<ServerStorage> storage();

  /// What the cache currently occupies against its limit, without evicting
  /// anything. Throws when the server is not running.
  Future<CacheUsage> cacheUsage();

  /// Asks the server for its slack now and reports what that freed.
  /// Nothing here stops playback: the server's owners give back only what
  /// nobody is playing and nobody kept, so a pinned download and the
  /// window of the title played last are never touched. Throws when the
  /// server is not running.
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
    implements
        LanMediaControl,
        ServerCacheControl,
        ProxyStreamControl,
        StreamNumbersReader,
        ServerSettingsAccess,
        ServerSettingsWriter {
  const ServerClient();

  /// Starts the server (idempotent) and returns its base URL.
  ///
  /// The port is the OS's choice and the returned URL is the only place it
  /// is known; nothing downstream assumes a number. It used to ask for
  /// 11470 -- stremio-core's default -- and fall back when that was taken,
  /// which only ever bought a collision with a desktop Stremio or a second
  /// instance of this app.
  Future<Uri> start({
    required Directory configDir,
    required Directory cacheDir,
  }) async {
    final url = await rust.serverStart(
      config: rust.ServerConfig(
        configDir: configDir.path,
        cacheDir: cacheDir.path,
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

  /// The server's settings (`GET /settings` → `values`: `cacheRoot`,
  /// `cacheSize`, `btMaxConnections`, ...). Throws when the server is not
  /// running.
  @override
  Future<Map<String, dynamic>> settings() async =>
      _object(await rust.serverSettings());

  /// Applies [patch] (settings keys and their new values) as
  /// `POST /settings` would -- validated, merged, persisted -- and returns
  /// the settings afterwards. Throws on a rejected value or when the server
  /// is not running.
  @override
  Future<Map<String, dynamic>> updateSettings(
    Map<String, dynamic> patch,
  ) async =>
      _object(await rust.serverUpdateSettings(patchJson: jsonEncode(patch)));

  /// What the server's storage costs right now: the one torrent-data root,
  /// everything under it against the `cacheSize` limit, and the room left
  /// on the volume it is on.
  ///
  /// Walks that root on the Rust side, so it is a worker call rather than
  /// a property; throws when the server is not running (there is no root
  /// to name then). This is the disk-and-directory half of the picture --
  /// the free/total space of the volume the server writes to, which
  /// stream-server does not report itself; for the cache's own occupancy
  /// against its limit, [cacheUsage] is the authoritative number (see
  /// `server_storage_report`).
  @override
  Future<ServerStorage> storage() async =>
      ServerStorage.fromJson(_object(await rust.serverStorageReport()));

  /// What the cache currently occupies against its `cacheSize` limit,
  /// without evicting anything (`ServerHandle::cache_usage`). Throws when
  /// the server is not running.
  @override
  Future<CacheUsage> cacheUsage() async =>
      CacheUsage.fromJson(_object(await rust.serverCacheUsage()));

  /// Asks the server for its slack now and reports what that freed
  /// (`ServerHandle::clean_cache_now`). There is no scheduled sweep for
  /// this to run early: the torrent engine and the proxy cache each own
  /// their bytes and give back what nobody is playing and nobody kept, and
  /// this asks both for that at once. A pin and the window of the title
  /// played last are never touched, and nothing here stops playback.
  /// Throws when the server is not running.
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

  /// Whether the server is moving bytes over this device's connection while
  /// nothing is playing, in each direction
  /// (`ServerHandle::background_traffic`): what the activity light reads.
  /// The "nothing playing" conjunction is taken on the Rust side over one
  /// sample, so the two halves and [BackgroundTraffic.playing] agree with
  /// each other; read them from one call rather than combining calls.
  ///
  /// Safe to poll every few seconds: the server peeks at the per-torrent
  /// peer counters librqbit already keeps, creates no engine and touches no
  /// idle clock -- unlike [torrentStats], which creates the engine it is
  /// asked about and must never stand in for this. Throws when the server
  /// is not running, which the caller draws as dark.
  Future<BackgroundTraffic> backgroundTraffic() async =>
      BackgroundTraffic.fromJson(_object(await rust.serverBackgroundTraffic()));

  /// What the server holds of the stream at [url] -- the URL handed to the
  /// player (`ServerHandle::stream_numbers`): the cache around the
  /// playhead, and for a torrent the set committed for sharing and what
  /// it has moved since it last went live.
  ///
  /// Null is a complete answer and not a failure: the URL's shape is what
  /// decides which store answers, and a URL neither store holds is a
  /// stream this server never touched -- an addon's direct link, a debrid
  /// URL, a file on the device. Every absence *inside* the answer means
  /// "there is no such number" too; see [StreamNumbers].
  ///
  /// A peek that creates no engine and touches no idle clock, so polling
  /// it cannot keep a torrent seeding to report on -- but it lists the
  /// stream's own directories, so it is a worker call and belongs on a
  /// panel's cadence rather than the process's. Throws when the server is
  /// not running.
  @override
  Future<StreamNumbers?> streamNumbers(Uri url) async {
    final json = await rust.serverStreamNumbers(url: url.toString());
    return json == null ? null : StreamNumbers.fromJson(jsonDecode(json));
  }

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
