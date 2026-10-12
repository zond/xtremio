import 'dart:convert';

import '../src/rust/api/media.dart' as media;
import '../src/rust/api/server.dart' as rust;
import 'diagnostics_log.dart';
import 'state/background_traffic.dart';
import 'state/dht_status.dart';
import 'state/server_storage.dart';
import 'state/read_wait.dart';
import 'state/stream_numbers.dart';

/// Control over the server's LAN media listener, which is what a cast
/// session needs and the only thing that ever turns it on.
///
/// A second HTTP listener that serves media bytes to the local network, since a
/// Chromecast cannot fetch from the loopback one. It serves the streams the
/// player published for a cast (`/cast/<token>`) and nothing else. It exists
/// for the length of a cast session and no longer.
///
/// Behind an interface so the cast tests can assert that it is turned off
/// when a session ends without a server to turn off.
abstract interface class LanMediaControl {
  /// Starts or stops the listener. Answers the address it is bound to
  /// afterwards (`0.0.0.0:39271`), or null after a stop. Throws when the server
  /// is not running or the bind fails, and then nothing is listening.
  Future<String?> setLanMedia({required bool enabled});

  /// Whether the listener is running. False with no server running either:
  /// both mean nothing of ours is on the LAN.
  bool get lanMediaRunning;

  /// How many requests the listener has been asked for since it started; zero
  /// when nothing is listening. It counts per cast session, since a start and a
  /// stop both reset it. A second receiver picked while the first still has the
  /// stream starts from zero rather than inheriting its count.
  ///
  /// It separates a receiver that never fetched the stream from one that did.
  /// The two look identical from the sofa, and to the sender too: a receiver
  /// handed an address it cannot route to hangs on the connect and reports
  /// nothing at all. Above zero says only that the receiver reached this
  /// device. A cold torrent twenty seconds in has fetched and is still warming
  /// up, so the count cannot tell a receiver filling a buffer from one that
  /// cannot decode what it fetched.
  int get lanMediaRequestsServed;

  /// How many `/cast` bodies the listener has begun since it started: a `GET`
  /// under a published token that started sending bytes, never a `HEAD`, an
  /// unknown token's `404` or a refusal. It is reset where
  /// [lanMediaRequestsServed] is, and is the cast watchdog's second reading
  /// beside it. Requests with no body mean a receiver reached this device and
  /// has been sent nothing yet.
  int get lanMediaBodiesServed;

  /// The base URL to give a receiver at [peerIp], so a media URL built on it
  /// names an interface that receiver can connect back to. When [peerIp] is
  /// null (the receiver's address is not known), this answers the server's
  /// best-ranked interface rather than the address it happened to enumerate
  /// first. A private address on an ordinary interface ranks ahead of anything
  /// on one a receiver cannot be behind at all: a tunnel, a cellular link, a
  /// tether, a container or VM bridge.
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
  /// Ends every proxied stream carrying [token] and answers how many streams
  /// that was. The token is the name this app minted for one player and wrote
  /// into the `/proxy` URL that player fetches. An HLS player has several
  /// streams, because the server carries the token into every line of every
  /// playlist it rewrites, and they all end together.
  ///
  /// Zero is an ordinary answer: the player may have finished, or never have
  /// been proxied, or there may be no server running. None of those is a
  /// failure or a reason for a teardown to stop, which is why this does not
  /// wait.
  ///
  /// It can still **throw**, and a caller on a teardown path has to say what
  /// happens when it does. The implementation is a synchronous FFI call, so a
  /// panic in the core or a bridge that is not up arrives here as an exception.
  /// There is nothing useful to do about it beyond writing it down. A caller
  /// that puts this at the top of a `dispose` without catching it would skip
  /// the player's own release.
  ///
  /// **It ends the read *and the token*.** The body fails and the connection is
  /// dropped, so the demuxer sees its source break now instead of after
  /// `network-timeout`. That timeout stays generous on purpose, because a slow
  /// swarm must not be mistaken for a dead connection. Ending the read alone
  /// does not end the stream: ffmpeg reconnects through the URL it already has,
  /// token and all, and carries on. So the server retires the token at the same
  /// time and answers `410 Gone` to anything that comes back with it. The
  /// documented order is quit-then-close, and a cancelled demuxer never reaches
  /// its reconnect. The refusal covers a close that gets there first. A demuxer
  /// wedged anywhere else (on the Flutter texture, on the audio device) is not
  /// waiting on this read and is untouched.
  int closeProxyStreams(String token);

  /// **The player screen [token] is gone**: the torrent its requests held is
  /// let go (stream-server's `ServerHandle::release_player`). The server keeps
  /// that torrent running from the screen's first read until this call, whether
  /// it is playing, paused, stalled or has nothing open. The app says when it
  /// stops using it, and the server does not guess. A cast published from the
  /// screen holds the torrent on its own until it is unpublished. Answers
  /// whether a hold was released, and throws as [closeProxyStreams] can.
  bool releasePlayer(String token);
}

/// Asking what the server holds of one playing stream, which is the whole
/// of what the player's stats panel needs from it beyond the swarm.
///
/// Behind an interface for the same reason [ProxyStreamControl] is: the
/// player's widget tests must not reach FFI, and a test wants to see which URL
/// was asked about. The panel's rows are only honest if the numbers belong to
/// the stream on screen.
abstract interface class StreamNumbersReader {
  /// What the server holds of the stream at [url], the URL handed to the
  /// player. Null when it holds nothing of it, which is an answer and not a
  /// failure. **Throws when the server is not running.** A caller draws that
  /// exactly like null, since both mean there are no rows to show, but only the
  /// throw is worth writing down.
  Future<StreamNumbers?> streamNumbers(Uri url);

  /// [streamNumbers] for a stream played by id ([MediaIds]): what the
  /// server holds of what [id] resolved to. Null for an id not resolved
  /// yet, and in the same cases as there.
  Future<StreamNumbers?> mediaStreamNumbers(String id);

  /// Whether mpv's reader of [id] is waiting on a read now ([ReadWait]):
  /// what the player shows its buffering card from while mpv, blocked in
  /// the read, reports no stall. Cheap; polled. **Throws** when the server
  /// is not running or holds nothing under [id].
  Future<ReadWait> mediaReadWait(String id);
}

/// What the player tells the server about a playback that the server
/// cannot see for itself: how long the film is, and when a player opened
/// on a torrent or stalled on it.
///
/// The server works out where the player *is* from what the reads do (the
/// read-pattern detector). The length is what it cannot work out. The film's
/// bitrate, and with it the seconds a buffer profile asks for, is the file's
/// size divided by the length.
///
/// Named on its own so the player screen can be handed a recorder in
/// tests, and because these calls are *hints*: they answer nothing, and
/// the server has its own answer without them.
abstract interface class PlaybackHints {
  /// How long the film is, with no position. That is all a cast can say: a
  /// receiver reports seconds, and seconds do not convert to a byte offset
  /// without a constant bitrate. The length *is* the bitrate, so the window is
  /// sized correctly throughout a cast, even though where it sits is left to
  /// the receiver's own reads.
  ///
  /// [fileIdx] and [filters] are the player URL's own: the `{fileIdx}` segment
  /// as the core wrote it, `-1` included, and its `f=` values. An addon that
  /// names no file leaves the choice to the server, which resolves the two the
  /// way the stream route does. For those streams, a length keyed to a resolved
  /// index the app guessed at never arrived.
  Future<void> noteDuration({
    required String infoHash,
    required int fileIdx,
    required List<String> filters,
    required double durationSeconds,
  });

  /// A player opened on the torrent, so what it goes on to report as stalls is
  /// this video's, not the last one's. Any file of the torrent will do, since
  /// the count the server keeps is the torrent's.
  Future<void> notePlayerOpened({required String infoHash});

  /// The buffering popup is up after the video had been playing. That is the
  /// one thing about a stall the server cannot see for itself. For the rest of
  /// this video, each report has it fetch one more piece ahead of the reader,
  /// as split, joinable claims; see stream-server's `retention::deadline`.
  Future<void> notePlayerStalled({required String infoHash});

  /// [noteDuration] for a stream played by id: the server knows which file
  /// of which torrent [id] is, so nothing is taken apart from a URL.
  Future<void> noteMediaDuration({
    required String id,
    required double durationSeconds,
  });

  /// [notePlayerOpened] for a stream played by id. Only after the id has
  /// resolved: before that the server does not know which torrent it is.
  Future<void> noteMediaPlayerOpened({required String id});

  /// [notePlayerStalled] for a stream played by id.
  Future<void> noteMediaPlayerStalled({required String id});

  /// The player of [id] is leaving at [positionSeconds] of the film: the
  /// server remembers it with where its reader was, so the next playback
  /// of the file resuming near there asks the swarm for that region first.
  Future<void> noteMediaPosition({
    required String id,
    required double positionSeconds,
  });
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

/// Reading the server's settings as well as writing them. Only the start-up
/// root correction needs this. It has to see the `cacheRoot` a *previous* build
/// persisted before it can decide whether this device is on a root the system
/// may reclaim.
///
/// It is deliberately not folded into [ServerSettingsWriter]. A writer is
/// handed to policies that must not be able to read the settings back, and a
/// read is all this adds.
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

  /// **Clears the cache**: stops every torrent that streams (all but a
  /// kept download's, which goes on) and deletes everything cached that no
  /// download keeps, the title played last included. Unlike
  /// [cleanCacheNow] this stops playback: a player reading a torrent gets
  /// a read error. Throws when the server is not running.
  Future<CacheClearReport> clearCache();
}

/// Thin Dart facade over the embedded, in-process `stream-server`.
///
/// The server is a process-wide singleton on the Rust side; this class only
/// shapes the calls and parses URLs and JSON. Directories come from
/// `path_provider` in the app (Rust creates them if missing). Everything the
/// app wants from the server's control API (settings, a torrent's start-up
/// stats) comes through here over FFI, through the same functions its HTTP
/// routes run. The Dart side never speaks HTTP to the server, since those
/// routes want a bearer token only the Rust side knows. The player fetches
/// media from the open stream routes.
class ServerClient
    implements
        LanMediaControl,
        ServerCacheControl,
        ProxyStreamControl,
        StreamNumbersReader,
        ServerSettingsAccess,
        ServerSettingsWriter,
        PlaybackHints {
  const ServerClient();

  @override
  Future<void> noteDuration({
    required String infoHash,
    required int fileIdx,
    required List<String> filters,
    required double durationSeconds,
  }) => rust.serverNoteDuration(
    infoHash: infoHash,
    fileIdx: fileIdx,
    filters: filters,
    durationSeconds: durationSeconds,
  );

  @override
  Future<void> notePlayerOpened({required String infoHash}) =>
      rust.serverNotePlayerOpened(infoHash: infoHash);

  @override
  Future<void> notePlayerStalled({required String infoHash}) =>
      rust.serverNotePlayerStalled(infoHash: infoHash);

  @override
  Future<void> noteMediaDuration({
    required String id,
    required double durationSeconds,
  }) => media.mediaNoteDuration(id: id, durationSeconds: durationSeconds);

  @override
  Future<void> noteMediaPlayerOpened({required String id}) =>
      media.mediaNotePlayerOpened(id: id);

  @override
  Future<void> noteMediaPlayerStalled({required String id}) =>
      media.mediaNotePlayerStalled(id: id);

  @override
  Future<void> noteMediaPosition({
    required String id,
    required double positionSeconds,
  }) => media.mediaNotePosition(id: id, positionSeconds: positionSeconds);

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
  /// It walks that root on the Rust side, so it is a worker call rather than a
  /// property. Throws when the server is not running, since there is no root to
  /// name then. This is the disk-and-directory half of the picture: the free
  /// and total space of the volume the server writes to, which stream-server
  /// does not report itself. For the cache's own occupancy against its limit,
  /// [cacheUsage] is the authoritative number (see `server_storage_report`).
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
  /// (`ServerHandle::clean_cache_now`). There is no scheduled sweep for this to
  /// run early. The torrent engine and the proxy cache each own their bytes and
  /// give back what nobody is playing and nobody kept, and this asks both for
  /// that at once. A pin and the window of the title played last are never
  /// touched, and nothing here stops playback. Throws when the server is not
  /// running.
  @override
  Future<EvictionReport> cleanCacheNow() async =>
      EvictionReport.fromJson(_object(await rust.serverCleanCacheNow()));

  /// Clears the cache and reports what that did (`ServerHandle::clear_cache`).
  /// Every torrent that streams is stopped except a kept download's, every read
  /// open on one fails, and every byte no download keeps is deleted. Kept
  /// downloads, the server's settings and where each file was last played stay.
  /// Throws when the server is not running.
  @override
  Future<CacheClearReport> clearCache() async =>
      CacheClearReport.fromJson(_object(await rust.serverClearCache()));

  /// The mainline DHT's status right now (`ServerHandle::dht_status`): whether
  /// it is running, how many nodes are in each routing table, and whether
  /// either has ever been non-empty this session. Never throws. A server that
  /// is not running answers the same as "no DHT to ask",
  /// `DhtStatus(enabled: false, ...)`.
  ///
  /// It is cheap and synchronous (two routing-table length reads). Still, do
  /// not poll it on a timer of its own. Read it on screen-open, or alongside a
  /// poll that is already running.
  DhtStatus get dhtStatus =>
      DhtStatus.fromJson(_object(rust.serverDhtStatus()));

  /// Whether the server is moving bytes over this device's connection while
  /// nothing is playing, in each direction
  /// (`ServerHandle::background_traffic`). This is what the activity light
  /// reads. The Rust side takes the "nothing playing" conjunction over one
  /// sample, so the two halves and [BackgroundTraffic.playing] agree with each
  /// other. Read them from one call rather than combining calls.
  ///
  /// Safe to poll every few seconds. The server peeks at the per-torrent peer
  /// counters librqbit already keeps, creates no engine and touches no idle
  /// clock. [torrentStats] is different: it creates the engine it is asked
  /// about and must never stand in for this. Throws when the server is not
  /// running, which the caller draws as dark.
  Future<BackgroundTraffic> backgroundTraffic() async =>
      BackgroundTraffic.fromJson(_object(await rust.serverBackgroundTraffic()));

  /// What the server holds of the stream at [url], the URL handed to the player
  /// (`ServerHandle::stream_numbers`): the cache around the playhead, and for a
  /// torrent the set committed for sharing and what it has moved since it last
  /// went live.
  ///
  /// Null is a complete answer and not a failure. The URL's shape decides which
  /// store answers. A URL neither store holds is a stream this server never
  /// touched: an addon's direct link, a debrid URL, a file on the device. Every
  /// absence *inside* the answer means "there is no such number" too; see
  /// [StreamNumbers].
  ///
  /// It is a peek that creates no engine and touches no idle clock, so polling
  /// it cannot keep a torrent seeding just to report on it. But it lists the
  /// stream's own directories, so it is a worker call and belongs on a panel's
  /// cadence rather than the process's. Throws when the server is not running.
  @override
  Future<StreamNumbers?> streamNumbers(Uri url) async {
    final json = await rust.serverStreamNumbers(url: url.toString());
    return json == null ? null : StreamNumbers.fromJson(jsonDecode(json));
  }

  @override
  Future<StreamNumbers?> mediaStreamNumbers(String id) async {
    final json = await media.mediaStreamNumbers(id: id);
    return json == null ? null : StreamNumbers.fromJson(jsonDecode(json));
  }

  @override
  Future<ReadWait> mediaReadWait(String id) async =>
      ReadWait.fromJson(jsonDecode(await media.mediaReadWait(id: id)));

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

  @override
  int get lanMediaBodiesServed => rust.serverLanMediaBodiesServed();

  /// Ends every proxied stream carrying [token]
  /// (`ServerHandle::close_proxy_streams`) and answers how many that was.
  ///
  /// Synchronous like the reads above, and for a sharper reason. It is a map
  /// scan with no I/O, called from a teardown, where queuing behind a blocking
  /// call already on the FRB worker pool would bring back exactly the delay it
  /// exists to remove. Being synchronous also means a failure arrives as a
  /// throw rather than a rejected future, which is why the caller catches.
  @override
  int closeProxyStreams(String token) =>
      rust.serverCloseProxyStreams(token: token);

  @override
  bool releasePlayer(String token) => rust.serverReleasePlayer(token: token);

  @override
  Future<Uri?> lanMediaBaseUrl({String? peerIp}) async {
    final url = await rust.serverLanMediaBaseUrl(peerIp: peerIp);
    if (url == null) return null;
    final base = Uri.parse(url);
    // A cast URL on this base is ours, and its `/{infoHash}/{fileIdx}` is
    // worth having in a report; nothing else on a LAN address is.
    DiagnosticsLog.noteOwnServer(base);
    return base;
  }

  static Map<String, dynamic> _object(String json) =>
      jsonDecode(json) as Map<String, dynamic>;
}
