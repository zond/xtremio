//! The embedded stream-server: one instance per process, owned by this crate.
//!
//! `stream_server::start` runs the server on its own OS thread with its own
//! tokio runtime, so torrent hashing and disk I/O never compete with the
//! stremio-core runtime or FRB's thread pool. We keep a single
//! [`ServerHandle`] -- in [`ServerState`], the server's field of the
//! process's [`AppState`] -- and expose start/stop/base_url around it, plus
//! the bearer token its control API requires: `Env::fetch` attaches it to
//! the engine's requests to the server, and nothing else ever sees it. The
//! app's own control calls (torrent stats, server settings) go through the
//! handle's library API here, never over HTTP.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard, RwLock, RwLockReadGuard, RwLockWriteGuard};
use std::time::Duration;

use anyhow::Context;
use enginefs::backend::DhtStatus;
use stream_server::{
    CacheUsage, DownloadInfo, EngineStats, EvictionReport, ServerHandle, ServerSettings,
    UnpinOutcome,
};
use url::Url;

use crate::state::AppState;

/// The embedded server's half of [`AppState`]: the running handle, or
/// nothing.
///
/// **The handle's lock is held for a look and never across a call.** The
/// sync exports read it on the UI isolate (`server_base_url`), and
/// [`token_for`] reads it from `Env::fetch` on stremio-core's tokio workers,
/// including the single-worker sequential runtime. [`with_handle`]'s library
/// calls block for as long as the server takes -- a pin waits out a magnet's
/// metadata, up to ninety seconds -- so they clone the `Arc` out and call
/// through that. Held across such a call, the read lock queued the next
/// `start`/`stop` behind it, and a queued writer holds up every new reader:
/// the UI isolate and the engine's fetches waited on a pin they had nothing
/// to do with. The boot is the same story on the write side, which is why
/// `start`/`stop` serialize on `lifecycle` instead and take the handle's lock
/// only to install or take the handle.
///
/// The same reasoning is why this is a lock of its own inside `AppState`
/// rather than one lock around the whole of it.
#[derive(Default)]
pub struct ServerState {
    handle: RwLock<Option<Arc<ServerHandle>>>,
    /// Held by [`start_in`] and [`stop_in`] for their whole length: two
    /// starts must not both spawn a server, and a stop that lands during a
    /// boot must stop what that boot installs rather than find nothing and
    /// leave it running.
    lifecycle: Mutex<()>,
}

impl ServerState {
    /// A poisoned lock only means a previous holder panicked; the Option is
    /// still a valid value.
    fn read(&self) -> RwLockReadGuard<'_, Option<Arc<ServerHandle>>> {
        self.handle
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn write(&self) -> RwLockWriteGuard<'_, Option<Arc<ServerHandle>>> {
        self.handle
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn lifecycle(&self) -> MutexGuard<'_, ()> {
        self.lifecycle
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// The running handle, to call through without holding the lock.
    fn running(&self) -> Option<Arc<ServerHandle>> {
        self.read().clone()
    }
}

/// How to start the embedded server. Two directories, and nothing else to
/// decide: the port is always ephemeral (see [`spawn`]).
#[derive(Clone, Debug)]
pub struct StartConfig {
    /// settings.json, logs/, localFiles/ live here (app support dir).
    pub config_dir: PathBuf,
    /// Torrent piece cache (app cache dir; may be purged by the OS).
    pub cache_dir: PathBuf,
}

fn url_of(handle: &ServerHandle) -> anyhow::Result<Url> {
    Url::parse(&format!("http://{}", handle.http_addr())).context("embedded server base URL")
}

/// Both directories are passed explicitly: every effective path stream-server
/// uses (settings, logs, torrent session and DHT state, archive caches) comes
/// from them, and nothing on its startup path fails without `HOME`/`XDG_*`,
/// which Android app processes do not have. (It may still glance at the
/// environment for defaults these directories override.)
///
/// **Port 0: the OS picks.** This used to ask for 11470 and fall back to an
/// ephemeral port when that was taken, because stremio-core's default
/// profile points `streaming_server_url` at `http://127.0.0.1:11470`. It
/// does not have to: `start_with` reads the bound address back and
/// `core::retarget_loopback_server` rewrites *any* loopback URL in the
/// profile to it, whatever the port. So the preferred port only ever bought
/// a collision -- with a desktop Stremio, with another instance of this app,
/// with whatever else holds 11470 -- and the fallback that handled it was a
/// second bind attempt for a number nothing reads.
fn spawn(config: &StartConfig) -> anyhow::Result<ServerHandle> {
    stream_server::start(stream_server::ServerConfig {
        http_addr: SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
        config_dir: Some(config.config_dir.clone()),
        cache_dir: Some(config.cache_dir.clone()),
        lan_media_addr: Some(LAN_MEDIA_ADDR),
        // **What the user asked to keep, and the only record of it.** The
        // server keeps none: it sweeps everything this set does not claim
        // before its session opens, which is the one moment early enough to
        // spare it hash-checking data that is about to go. `None` -- a
        // registry that would not read -- names nothing and is not an empty
        // set: the server then keeps every torrent's data for that boot.
        // See `crate::downloads::pins`.
        pins: crate::downloads::pins(),
        ..stream_server::ServerConfig::default()
    })
}

/// Where the LAN media listener binds when a cast session turns it on: every
/// interface (a receiver is on the LAN, not on loopback) on a port the OS
/// picks, so nothing collides with another Stremio server or a second
/// instance of this app.
///
/// Configuring it is what makes [`set_lan_media`] able to start it at all
/// ([`stream_server::ServerConfig::lan_media_addr`] is `None` by default and
/// then there is nothing to start). It is a place, not a listener: nothing
/// binds it at boot, and only `set_lan_media(true)` ever does.
///
/// **What the listener serves is the server's decision, and it is narrow**:
/// the bytes of torrents and archive sessions the loopback side has already
/// created, and nothing a stranger on the network could make this device
/// *do*. A `GET /{infoHash}/{fileIdx}` for a hash the server does not hold
/// is a `404` at once, no `/create` is mounted, and no control route sits
/// behind a token to guess. It was not always so -- before stream-server
/// `388f68b` the stream route was the loopback one and *created* the torrent
/// with the request's `tr=` trackers, so for the length of a cast any host
/// on the LAN could make this device join a swarm of its choosing, and
/// nothing on this side could filter it. `rust/tests/lan_media.rs` pins the
/// closed contract, with a timing assertion that would catch the old
/// behaviour coming back: a lookup answers now, a creation waits on
/// metadata.
const LAN_MEDIA_ADDR: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0);

/// Starts the server if it is not running and returns its base URL
/// (`http://127.0.0.1:<port>/`). Idempotent: a running server's URL is
/// returned as-is, regardless of the config passed.
pub fn start(config: StartConfig) -> anyhow::Result<Url> {
    start_in(&crate::state::state(), config)
}

/// [`start`] against a given state. `core::init` starts the server as part
/// of booting and passes the state it is building, so both halves are the
/// same instance even if a shutdown lands in between.
pub(crate) fn start_in(app: &AppState, config: StartConfig) -> anyhow::Result<Url> {
    start_with(app, config, spawn)
}

/// [`start_in`] with the spawn handed in, which is how a test holds a boot
/// open for as long as it takes to look at what else waits on it.
fn start_with(
    app: &AppState,
    config: StartConfig,
    spawn: impl Fn(&StartConfig) -> anyhow::Result<ServerHandle>,
) -> anyhow::Result<Url> {
    crate::logging::init();
    let _lifecycle = app.server.lifecycle();
    if let Some(handle) = app.server.running() {
        return url_of(&handle);
    }
    std::fs::create_dir_all(&config.config_dir)
        .with_context(|| format!("create server config dir {:?}", config.config_dir))?;
    std::fs::create_dir_all(&config.cache_dir)
        .with_context(|| format!("create server cache dir {:?}", config.cache_dir))?;

    let handle = spawn(&config).context("start embedded server")?;
    let url = url_of(&handle)?;
    // A cast grants the server's `lanMediaEnabled` permission and the server
    // persists it; a process killed mid-cast never takes it back, and the
    // server loads the setting as it finds it and resets it for nobody. No
    // listener stands on it -- nothing binds the LAN address at boot, only
    // `set_lan_media(true)` does -- but what is on disk while nothing is
    // casting has to read "no", so the first thing a freshly started server
    // is told is that there is no permission. Start-up has nobody to report
    // a failure to, so this warns and goes on.
    if let Err(error) = allow_lan_media(&handle, false) {
        tracing::warn!(%error, "could not clear the lanMediaEnabled setting");
    }
    tracing::info!(%url, "embedded stream-server started");
    *app.server.write() = Some(Arc::new(handle));
    Ok(url)
}

/// Closes the LAN media listener on `handle`, best effort, and drops the
/// `lanMediaEnabled` permission with it. Used where the answer has to be
/// "off" and there is nobody left to report a failure to: shutdown, on the
/// way out of a cast session the process is ending inside.
fn lan_media_off(handle: &ServerHandle) {
    if let Err(error) = handle.set_lan_media(false) {
        tracing::warn!(%error, "could not stop the LAN media listener");
    }
    if let Err(error) = allow_lan_media(handle, false) {
        tracing::warn!(%error, "could not clear the lanMediaEnabled setting");
    }
}

/// Stops the server and waits for its thread to exit. Ok if not running --
/// and with no state at all there is nothing that could be.
pub fn stop() -> anyhow::Result<()> {
    match crate::state::current() {
        Some(app) => stop_in(&app),
        None => Ok(()),
    }
}

/// [`stop`] against a given state, which is how `core::shutdown` stops the
/// server it already took out of the process.
pub(crate) fn stop_in(app: &AppState) -> anyhow::Result<()> {
    let _lifecycle = app.server.lifecycle();
    let handle = app.server.write().take();
    if let Some(handle) = handle {
        // Before the shutdown, not instead of it: the server closes the LAN
        // listener as part of going down anyway, but this is also what puts
        // the `lanMediaEnabled` veto back on disk, so a process that is
        // killed after this point leaves nothing permitted behind. Nothing
        // but a grant already in flight: a `set_lan_media(true)` that took
        // its handle before this stop did is not waited for, and can write
        // the permission back after this. The next boot's `start_in` takes
        // it away again before anything could use it.
        lan_media_off(&handle);
        handle
            .shutdown()
            .context("signal embedded server shutdown")?;
        sole(handle).join().context("join embedded server thread")?;
        tracing::info!("embedded stream-server stopped");
    }
    Ok(())
}

/// The handle once no call holds a clone of it, so its thread can be
/// joined. A call holds one for its own length only, and after the
/// shutdown each ends as soon as the server's runtime does, so this waits
/// for about as long as the old write lock waited for its readers -- but
/// without holding anything that a reader would queue behind.
fn sole(mut handle: Arc<ServerHandle>) -> ServerHandle {
    loop {
        match Arc::try_unwrap(handle) {
            Ok(handle) => return handle,
            Err(shared) => {
                handle = shared;
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    }
}

/// Base URL of the running server, if any.
pub fn base_url() -> Option<Url> {
    crate::state::current().and_then(|app| base_url_in(&app))
}

/// [`base_url`] against a given state.
pub(crate) fn base_url_in(app: &AppState) -> Option<Url> {
    app.server
        .read()
        .as_ref()
        .and_then(|handle| url_of(handle).ok())
}

/// Runs `f` against the running server's handle. The handle's library calls
/// block the calling thread until the server's runtime answers, so callers
/// stay off the UI thread (FRB's worker pool is fine). No lock is held
/// while `f` runs (see [`ServerState`]).
fn with_handle<T>(f: impl FnOnce(&ServerHandle) -> anyhow::Result<T>) -> anyhow::Result<T> {
    let app = crate::state::current().ok_or_else(not_running)?;
    with_handle_in(&app, f)
}

/// [`with_handle`] against a given state.
fn with_handle_in<T>(
    app: &AppState,
    f: impl FnOnce(&ServerHandle) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    let handle = app.server.running().ok_or_else(not_running)?;
    f(&handle)
}

fn not_running() -> anyhow::Error {
    anyhow::anyhow!("embedded server is not running")
}

/// A torrent's `stats.json` as the server's library API answers it: the
/// per-file stats (`/{infoHash}/{fileIdx}/stats.json`) for `Some(file_idx)`,
/// the torrent-level ones (`/{infoHash}/stats.json`) otherwise. `trackers`
/// are the stream's `announce` list, exactly what the stream URL's `tr=`
/// carries; the server uses them only when this call is what creates the
/// engine. A magnet still resolving reports `phase: resolvingMetadata`
/// (per-file too, so the caller need not fall back), a failed add
/// `phase: error` with an `error` message; an index the torrent does not
/// have, once its metadata is known, is an error.
pub fn torrent_stats(
    info_hash: &str,
    file_idx: Option<usize>,
    trackers: &[String],
) -> anyhow::Result<EngineStats> {
    with_handle(|handle| match file_idx {
        Some(idx) => handle.file_stats(info_hash, idx, trackers),
        None => handle.engine_stats(info_hash, trackers),
    })
}

/// **Tells the server where the player is**, so the retention window
/// follows the film rather than a guess made from byte ranges.
///
/// `offset` is the player's own byte offset into the file (mpv's
/// `stream-pos`), which is where the retention window belongs -- the server
/// otherwise has to tell a container-index read from a seek by the shape of
/// a `Range` header, and cannot. `duration` is how long the film is, which
/// with the file's own size is its bitrate, and that is what sizes a window
/// measured in seconds. Neither is inferred and neither is measured.
///
/// **A hint, and silent when there is nothing to hint to.** No error when
/// the server is not running, the torrent is not this process's, or nothing
/// is bounding the file -- this runs about once a second for as long as a
/// film is open, and a caller that had to handle "not yet" every second
/// would handle it by ignoring it. A hint that stops arriving goes stale at
/// the server in fifteen seconds and the inference answers again.
pub fn note_playhead(info_hash: &str, file_idx: usize, offset: u64, duration: Option<Duration>) {
    let Some(app) = crate::state::current() else {
        return;
    };
    let Some(handle) = app.server.running() else {
        return;
    };
    crate::env::CONCURRENT.block_on(handle.note_playhead(info_hash, file_idx, offset, duration));
}

/// **Tells the server how long the film is**, without saying where the
/// player is in it.
///
/// What a cast can say and nothing else: the receiver does the reading and
/// reports its position in seconds, which do not convert to a byte offset
/// without a constant bitrate. The length *is* the bitrate, so the window
/// is sized correctly throughout a cast even though where it sits is left
/// to the receiver's own (plainly sequential) reads.
///
/// Silent about everything, exactly as [`note_playhead`] is.
pub fn note_duration(info_hash: &str, file_idx: usize, duration: Duration) {
    let Some(app) = crate::state::current() else {
        return;
    };
    let Some(handle) = app.server.running() else {
        return;
    };
    crate::env::CONCURRENT.block_on(handle.note_duration(info_hash, file_idx, duration));
}

/// Pins `file_idx` of `info_hash` as an offline download: the engine is
/// created with `trackers` when the hash is new, the file is kept wanted
/// whatever else the torrent streams, and the torrent stops being evictable.
/// Idempotent. The error is a `stream_server::PinDownloadError` behind
/// `anyhow`, which `crate::downloads::PinFailure` classifies for the UI.
pub fn pin_download(
    info_hash: &str,
    file_idx: usize,
    trackers: &[String],
) -> anyhow::Result<DownloadInfo> {
    with_handle(|handle| handle.pin_download(info_hash, file_idx, trackers))
}

/// Drops the pin on `file_idx` of `info_hash`. With `delete_files` the data
/// goes too (the whole torrent when this was its last pin, only that file
/// while other pins hold). The outcome reports what actually happened, which
/// is not `delete_files` echoed back.
pub fn unpin_download(
    info_hash: &str,
    file_idx: usize,
    delete_files: bool,
) -> anyhow::Result<UnpinOutcome> {
    with_handle(|handle| handle.unpin_download(info_hash, file_idx, delete_files))
}

/// Every pinned download the server knows about, with live progress.
pub fn downloads() -> anyhow::Result<Vec<DownloadInfo>> {
    with_handle(|handle| handle.downloads())
}

/// Where `file_idx` of `info_hash` is on disk, when the engine knows.
/// Creates nothing.
pub fn download_path(info_hash: &str, file_idx: usize) -> anyhow::Result<Option<String>> {
    with_handle(|handle| handle.download_path(info_hash, file_idx))
}

/// The server's current settings (`GET /settings` → `values`).
pub fn settings() -> anyhow::Result<ServerSettings> {
    with_handle(|handle| handle.settings())
}

/// Applies `patch` as `POST /settings` would (same keys, validation and
/// persistence) and returns the settings afterwards.
pub fn update_settings(patch: serde_json::Value) -> anyhow::Result<ServerSettings> {
    with_handle(|handle| handle.update_settings(patch))
}

/// What the cache currently occupies against the limit in force, taking
/// nothing: `totalBytes`/`limitBytes` in the server's occupancy accounting
/// (allocated blocks), and `protectedBytes`/`protectedFiles` for what a
/// pinned download or the window of the stream being played holds right
/// now, which a clean can never take. Counted from what the piece store and
/// the proxy cache say they hold, not from a walk, so it is cheap for a
/// screen open; nothing caches it, so not for a sub-second timer.
pub fn cache_usage() -> anyhow::Result<CacheUsage> {
    with_handle(|handle| handle.cache_usage())
}

/// Asks the server's owners for their slack right now and reports what is
/// left -- the same passes the server's own reconciler runs, so it is never
/// less careful: a pinned download and the window of the stream being
/// played are not touched, however far over the limit the cache is, and
/// nothing here stops playback.
pub fn clean_cache_now() -> anyhow::Result<EvictionReport> {
    with_handle(|handle| handle.clean_cache_now())
}

/// [`enginefs::traffic::BackgroundTraffic`] as it crosses the FFI: the same
/// seven fields, camelCase like every other JSON this crate hands Dart. The
/// server's own struct serialises snake_case (`bytes_downloaded`), and the
/// app reads one shape for everything the server answers, so the rename
/// happens here rather than in a Dart decoder that would be the odd one
/// out. A field added upstream crosses only once it is added here, which is
/// the point: what crosses is what the app was written for.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BackgroundTraffic {
    /// `downloading || uploading`: the connection is in use while nobody is
    /// watching, whichever way the bytes went.
    pub active: bool,
    /// Bytes came in from peers over the last closed window and nothing was
    /// playing over it or since.
    pub downloading: bool,
    /// Bytes went out to peers over the last closed window and nothing was
    /// playing over it or since.
    pub uploading: bool,
    /// Whether a player is reading from the server as this is answered.
    pub playing: bool,
    /// The sums the verdict was judged from, over the torrents that exist
    /// right now: bytes received from and sent to peers.
    pub bytes_downloaded: u64,
    pub bytes_uploaded: u64,
    /// The window the halves were judged over, in seconds.
    pub window_secs: u64,
}

impl From<enginefs::traffic::BackgroundTraffic> for BackgroundTraffic {
    fn from(traffic: enginefs::traffic::BackgroundTraffic) -> Self {
        Self {
            active: traffic.active,
            downloading: traffic.downloading,
            uploading: traffic.uploading,
            playing: traffic.playing,
            bytes_downloaded: traffic.bytes_downloaded,
            bytes_uploaded: traffic.bytes_uploaded,
            window_secs: traffic.window_secs,
        }
    }
}

/// Whether the server is moving bytes over this device's connection while
/// nothing is playing, in each direction
/// (`ServerHandle::background_traffic`): the activity light's reading.
///
/// Each half is "that direction's peer counter grew over the last closed
/// window (`enginefs::traffic::TRAFFIC_WINDOW`, 5 s) and no player was seen
/// reading over it or since"; `active` is either. The conjunction with
/// playback is taken on the server side over one sample, on purpose: a
/// client reading traffic and playback as two calls would sample them a
/// moment apart and get a light that flickers whenever they disagree.
///
/// **It creates and touches nothing, so it is safe to poll every few
/// seconds.** The traffic is `EngineFS::transfer_totals`, a peek: it walks
/// the engines that exist and reads each one's `TransferTotals` off
/// librqbit's live stats snapshot -- no hash is looked up, so nothing goes
/// near `get_or_begin_add_magnet`, and `last_accessed` is left alone, so a
/// poll never holds a torrent out of the idle sweep and lights itself with
/// the seeding it caused. "Playing" is `playback_is_live`, three live
/// fields. That is the opposite of [`torrent_stats`], which creates the
/// engine it is asked about and must never stand in for this.
///
/// Errors when the server is not running, like the other blocking calls
/// here: the caller can draw "no server" and "idle" the same way, but it
/// gets to know which it is.
pub fn background_traffic() -> anyhow::Result<BackgroundTraffic> {
    with_handle(|handle| handle.background_traffic().map(Into::into))
}

/// What this server holds of the stream a player is playing right now
/// (`ServerHandle::stream_numbers`), asked with the URL that player was
/// handed: what is on the disk around the playhead, and -- for a torrent --
/// what has been committed for sharing and what it has moved since it went
/// live.
///
/// `url` is the whole of the question: its shape decides which store
/// answers, the piece store for `/{infoHash}/{fileIdx}` (`-1` included, the
/// auto-select resolved with the same `f=` filters the stream route uses)
/// and the proxy cache for `/proxy/...`. `Ok(None)` is a URL neither holds
/// -- an addon's direct link the player fetched itself, a file:// path, a
/// debrid stream -- and is a complete answer rather than a failure.
///
/// **Every number is measured when it is asked for and none of it is
/// kept.** In particular the transfer totals are librqbit's own per-torrent
/// counters, which live in the torrent's live state and start at zero every
/// time it enters one (`enginefs::backend::TransferTotals`): the ratio
/// taken from them covers that live period and not the process's lifetime,
/// since a pause and resume or an idle drop and re-add begins it again, and
/// a caller must label it as the period it is. Nothing here is read off
/// disk, so nothing here is a claim about a past this process never saw.
///
/// A peek, like [`background_traffic`]: it creates no engine, starts no
/// magnet add and touches no idle clock, so a panel asking every few
/// seconds cannot hold a torrent out of the idle sweep by looking at it.
/// It is not free, though -- the window is counted from a listing of the
/// stream's own directories -- so ask it while a panel is open and not for
/// the life of the process. Errors when the server is not running.
pub fn stream_numbers(
    url: &str,
) -> anyhow::Result<Option<stream_server::stream_numbers::StreamNumbers>> {
    with_handle(|handle| handle.stream_numbers(url))
}

/// The mainline DHT's status on this host, exactly the `dht` key of
/// `GET /stats.json` (`ServerHandle::dht_status`): whether a DHT is
/// running, how many nodes are in each routing table right now, and
/// whether either has ever been non-empty this session (sticky: a table
/// that empties out again -- peers aged out, the network changed -- still
/// counts as having bootstrapped once).
///
/// The server not running answers the same as "no DHT to ask either way"
/// (`DhtStatus::default()`, `enabled: false`), not an error -- this is
/// information for a curious person, never a failure to surface. A
/// network that drops the DHT's UDP (carrier-grade NAT, a firewalled
/// mobile APN, a captive portal) simply never finishes bootstrapping, and
/// torrents with working trackers keep streaming regardless.
///
/// Cheap: two routing-table length reads, no I/O.
pub fn dht_status() -> DhtStatus {
    with_handle(|handle| Ok(handle.dht_status())).unwrap_or_default()
}

/// Ends every proxied stream carrying `token` and answers how many that
/// was (`ServerHandle::close_proxy_streams`).
///
/// The token is a name the app minted for one player and put in the
/// `/proxy` URL that player fetches, so this closes that player's reads
/// and nobody else's. What it buys is that tearing a player down is an
/// action rather than a wait: the read fails at once instead of after
/// `network-timeout`, which is deliberately generous because a slow swarm
/// must not be mistaken for a dead connection.
///
/// It also retires the token on the server, which is the half that makes
/// it stick: ffmpeg reconnects through the URL it already has, so a broken
/// read alone is a stutter rather than an end, and a later request bearing
/// the same token is answered `410 Gone`.
///
/// Zero is an ordinary answer -- the player may have finished already, or
/// never have been proxied -- and so is zero from a server that is not
/// running: nothing of ours is streaming either way, which is what the
/// caller wanted to be true. No error, because a teardown has nothing to
/// do with one.
///
/// Cheap: a scan of the live-stream map and a `oneshot` send per hit, no
/// runtime hop and no I/O.
pub fn close_proxy_streams(token: &str) -> usize {
    with_handle(|handle| Ok(handle.close_proxy_streams(token))).unwrap_or(0)
}

/// Starts or stops the LAN media listener -- the server's second HTTP
/// listener, which serves media bytes to the local network and mounts no
/// control route at all (deliberately not `/proxy` and not `/ftp`) -- and
/// answers the address it is bound to afterwards: `Some` after a start,
/// `None` after a stop. What it serves is the server's affair, and it is
/// only what this device already holds; see [`LAN_MEDIA_ADDR`].
///
/// This is what a cast session turns on and off, and the only thing that
/// ever should: a Chromecast cannot fetch from a loopback-only server, and
/// nothing else about this app wants a socket open to the LAN.
///
/// The server keeps a `lanMediaEnabled` setting that vetoes the listener
/// outright and defaults to `false`, so enabling carries that permission
/// with it and disabling takes it back. That way the persisted answer to
/// "may this app serve the LAN" is `false` whenever no session is running
/// -- and [`start_in`] makes it so after a kill that skipped the disabling.
pub fn set_lan_media(enabled: bool) -> anyhow::Result<Option<SocketAddr>> {
    with_handle(|handle| {
        if !enabled {
            let addr = handle.set_lan_media(false)?;
            allow_lan_media(handle, false)?;
            return Ok(addr);
        }
        allow_lan_media(handle, true)?;
        match handle.set_lan_media(true) {
            Ok(addr) => Ok(addr),
            Err(error) => {
                // Nothing is listening, so the permission must not be left
                // standing either.
                allow_lan_media(handle, false).ok();
                Err(error)
            }
        }
    })
}

/// Writes the `lanMediaEnabled` setting when it is not already `allowed`,
/// through the same path `POST /settings` takes (validation, the engine
/// update and persistence). Turning it off there also stops a listener that
/// is still running, which is why the off direction is safe to rely on.
fn allow_lan_media(handle: &ServerHandle, allowed: bool) -> anyhow::Result<()> {
    if handle.settings()?.lan_media_enabled == allowed {
        return Ok(());
    }
    handle.update_settings(serde_json::json!({ "lanMediaEnabled": allowed }))?;
    Ok(())
}

/// Whether the LAN media listener is running right now. False when no server
/// is running either -- "nothing of ours is on the LAN" is the same answer.
pub fn lan_media_running() -> bool {
    with_handle(|handle| Ok(handle.lan_media_running())).unwrap_or(false)
}

/// How many requests the LAN media listener has been asked for since it last
/// started, per cast session rather than per process. Zero when no listener
/// and no server are running -- both mean nothing has been asked of us.
///
/// It answers the one question nothing else can: whether the receiver ever
/// came back for the stream. A receiver handed an address it cannot route to
/// never reports an error (the connect hangs), so from the outside it looks
/// exactly like one that is buffering.
pub fn lan_media_requests_served() -> u64 {
    with_handle(|handle| Ok(handle.lan_media_requests_served())).unwrap_or(0)
}

/// The base URL to hand a receiver at `peer`, e.g.
/// `http://192.168.1.20:39271/`: the host is the local interface that shares
/// `peer`'s subnet, so a media URL built on it is one that receiver can
/// actually connect back to (the first interface on a host with a VPN or a
/// container bridge regularly is not).
///
/// `None` when the listener is not running, or when no local interface can
/// reach `peer` -- which is the answer that says this receiver cannot be
/// cast to, rather than one to paper over with a loopback URL it could
/// never fetch.
pub fn lan_media_base_url(peer: IpAddr) -> Option<Url> {
    with_handle(|handle| Ok(handle.lan_media_base_url(peer))).unwrap_or(None)
}

/// Whether `url` addresses the running embedded server: same scheme, host
/// and (effective) port as [`base_url`]. False when no server runs.
pub fn is_embedded_url(url: &Url) -> bool {
    crate::state::current().is_some_and(|app| {
        app.server
            .read()
            .as_ref()
            .is_some_and(|handle| is_embedded_url_locked(handle, url))
    })
}

/// [`is_embedded_url`]'s check against an already-locked `handle`; the sole
/// authority check, shared by `is_embedded_url` and `token_for` so there is
/// only one implementation to keep in sync.
fn is_embedded_url_locked(handle: &ServerHandle, url: &Url) -> bool {
    url_of(handle).is_ok_and(|base| same_authority(&base, url))
}

fn same_authority(a: &Url, b: &Url) -> bool {
    a.scheme() == b.scheme()
        && a.host() == b.host()
        && a.port_or_known_default() == b.port_or_known_default()
}

/// The bearer token to send with a request to `url`: the running server's
/// per-launch token when `url` is the embedded server's (see
/// [`is_embedded_url`]), else nothing. Any other host, loopback or not, gets
/// no credentials. Never log or serialize the token: it is what keeps other
/// local processes out of the server's settings.
pub fn token_for(url: &Url) -> Option<String> {
    let app = crate::state::current()?;
    token_for_in(&app, url)
}

/// [`token_for`] against a given state.
fn token_for_in(app: &AppState, url: &Url) -> Option<String> {
    let guard = app.server.read();
    let handle = guard.as_ref()?;
    if is_embedded_url_locked(handle, url) {
        handle.auth_token().map(str::to_owned)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Barrier};
    use std::time::{Duration, Instant};

    use super::*;

    /// `with_handle` (stats, settings) and `token_for` (`Env::fetch`) both
    /// only need to observe the running handle, so they must run
    /// concurrently rather than serialise on `ServerState`'s lock: a slow
    /// stats poll must never stall an addon/catalog fetch waiting on its
    /// bearer token. Runs a call in one thread via `with_handle`'s closure
    /// (blocked on a barrier then a sleep) and asserts `token_for` returns
    /// from another thread almost immediately, well inside the sleep -- with
    /// a `Mutex` held across the call it would take as long as the sleep.
    ///
    /// Against a state of its own, so it neither takes the process's
    /// embedded server away from another test nor has to be serialized
    /// against one: what is under test is a property of `ServerState`, and
    /// starting a second server on its own ephemeral port and temp dirs is
    /// how that gets said.
    #[test]
    fn with_handle_readers_run_concurrently_with_token_for() {
        let app = Arc::new(AppState::default());
        let tmp = tempfile::tempdir().expect("tempdir");
        let url = start_in(
            &app,
            StartConfig {
                config_dir: tmp.path().join("server"),
                cache_dir: tmp.path().join("cache"),
            },
        )
        .expect("server start");

        let barrier = Arc::new(Barrier::new(2));
        let handle_thread = std::thread::spawn({
            let barrier = Arc::clone(&barrier);
            let app = Arc::clone(&app);
            move || {
                with_handle_in(&app, |_handle| {
                    // Reached once the call has its handle.
                    barrier.wait();
                    std::thread::sleep(Duration::from_millis(500));
                    Ok(())
                })
            }
        });

        barrier.wait();
        let started = Instant::now();
        let token = token_for_in(&app, &url);
        let elapsed = started.elapsed();

        handle_thread
            .join()
            .expect("with_handle thread")
            .expect("with_handle closure");
        stop_in(&app).expect("server stop");

        assert!(token.is_some(), "server was still running");
        assert!(
            elapsed < Duration::from_millis(250),
            "token_for waited on with_handle's in-flight call: {elapsed:?}"
        );
    }

    fn config(tmp: &std::path::Path) -> StartConfig {
        StartConfig {
            config_dir: tmp.join("server"),
            cache_dir: tmp.join("cache"),
        }
    }

    /// How long `f` takes on this thread.
    fn timed<T>(f: impl FnOnce() -> T) -> (T, Duration) {
        let started = Instant::now();
        let value = f();
        (value, started.elapsed())
    }

    /// A stop has to wait for a call in flight before it can join the
    /// server's thread, and nobody else may wait with it: `server_base_url`
    /// is answered on the UI isolate and `token_for` on the engine's fetch
    /// workers. With the lock held across the call, the stop queued behind
    /// it as a writer and every new reader queued behind the stop.
    #[test]
    fn a_stop_waiting_on_a_call_in_flight_holds_up_no_reader() {
        let app = Arc::new(AppState::default());
        let tmp = tempfile::tempdir().expect("tempdir");
        let url = start_in(&app, config(tmp.path())).expect("server start");

        let barrier = Arc::new(Barrier::new(2));
        let in_flight = std::thread::spawn({
            let (app, barrier) = (Arc::clone(&app), Arc::clone(&barrier));
            move || {
                with_handle_in(&app, |_handle| {
                    barrier.wait();
                    std::thread::sleep(Duration::from_millis(800));
                    Ok(())
                })
            }
        });
        barrier.wait();
        let stopping = std::thread::spawn({
            let app = Arc::clone(&app);
            move || stop_in(&app)
        });
        // Long enough for the stop to be waiting on the call.
        std::thread::sleep(Duration::from_millis(200));
        let (_, base_url_took) = timed(|| base_url_in(&app));
        let (_, token_took) = timed(|| token_for_in(&app, &url));

        in_flight.join().expect("call thread").expect("the call");
        stopping.join().expect("stop thread").expect("server stop");
        assert!(
            base_url_took < Duration::from_millis(250),
            "base_url waited on the stop: {base_url_took:?}"
        );
        assert!(
            token_took < Duration::from_millis(250),
            "token_for waited on the stop: {token_took:?}"
        );
        assert_eq!(base_url_in(&app), None, "and the stop did stop it");
    }

    /// A spawn that says when it has been entered and then waits to be let
    /// through: a boot held open for as long as a test needs it.
    fn held_spawn() -> (
        impl Fn(&StartConfig) -> anyhow::Result<ServerHandle> + Send + 'static,
        std::sync::mpsc::Receiver<()>,
        std::sync::mpsc::Sender<()>,
    ) {
        let (entered_tx, entered) = std::sync::mpsc::channel();
        let (release, release_rx) = std::sync::mpsc::channel::<()>();
        let release_rx = std::sync::Mutex::new(release_rx);
        let held = move |config: &StartConfig| {
            entered_tx.send(()).ok();
            release_rx.lock().unwrap().recv().ok();
            spawn(config)
        };
        (held, entered, release)
    }

    /// A boot is not a reason to wait either: until it installs a handle,
    /// the server is not running, and that is the answer. On a device the
    /// boot is seconds of launch sweep and session restore, and the UI
    /// isolate asks for the base URL throughout.
    #[test]
    fn a_boot_holds_up_no_reader() {
        let app = Arc::new(AppState::default());
        let tmp = tempfile::tempdir().expect("tempdir");
        let (held, entered, release) = held_spawn();
        let booting = std::thread::spawn({
            let (app, config) = (Arc::clone(&app), config(tmp.path()));
            move || start_with(&app, config, held)
        });
        entered.recv().expect("the boot reached its spawn");

        let (answer_tx, answer) = std::sync::mpsc::channel();
        std::thread::spawn({
            let app = Arc::clone(&app);
            move || answer_tx.send(base_url_in(&app)).ok()
        });
        let answered = answer.recv_timeout(Duration::from_secs(2));
        release.send(()).expect("let the boot through");
        booting.join().expect("boot thread").expect("server start");
        stop_in(&app).expect("server stop");
        assert_eq!(answered, Ok(None), "answered while the boot ran");
    }

    /// A start during a boot waits for it and answers the server it
    /// started, rather than finding none yet and spawning a second one.
    #[test]
    fn a_start_during_a_boot_is_the_same_server() {
        let app = Arc::new(AppState::default());
        let tmp = tempfile::tempdir().expect("tempdir");
        let spawned = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counted = |spawned: &Arc<std::sync::atomic::AtomicUsize>| {
            let spawned = Arc::clone(spawned);
            move || {
                spawned.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            }
        };
        let (held, entered, release) = held_spawn();
        let first = std::thread::spawn({
            let (app, config, count) = (Arc::clone(&app), config(tmp.path()), counted(&spawned));
            move || {
                start_with(&app, config, move |config: &StartConfig| {
                    count();
                    held(config)
                })
            }
        });
        entered.recv().expect("the boot reached its spawn");
        let second = std::thread::spawn({
            let (app, config, count) = (Arc::clone(&app), config(tmp.path()), counted(&spawned));
            move || {
                start_with(&app, config, move |config: &StartConfig| {
                    count();
                    spawn(config)
                })
            }
        });
        // Long enough for the second start to have spawned, had it not
        // waited.
        std::thread::sleep(Duration::from_millis(200));
        release.send(()).expect("let the boot through");
        let first = first.join().expect("start thread").expect("server start");
        let second = second.join().expect("start thread").expect("server start");
        stop_in(&app).expect("server stop");
        assert_eq!(spawned.load(std::sync::atomic::Ordering::SeqCst), 1);
        assert_eq!(first, second, "one server, not two");
    }

    /// A stop during a boot waits for it and stops what it started, rather
    /// than finding nothing yet and leaving the boot's server running.
    #[test]
    fn a_stop_during_a_boot_stops_what_it_starts() {
        let app = Arc::new(AppState::default());
        let tmp = tempfile::tempdir().expect("tempdir");
        let (held, entered, release) = held_spawn();
        let booting = std::thread::spawn({
            let (app, config) = (Arc::clone(&app), config(tmp.path()));
            move || start_with(&app, config, held)
        });
        entered.recv().expect("the boot reached its spawn");
        let stopping = std::thread::spawn({
            let app = Arc::clone(&app);
            move || stop_in(&app)
        });
        std::thread::sleep(Duration::from_millis(200));
        let stopped_early = stopping.is_finished();
        release.send(()).expect("let the boot through");
        booting.join().expect("boot thread").expect("server start");
        stopping.join().expect("stop thread").expect("server stop");
        let left = base_url_in(&app);
        stop_in(&app).expect("server stop");
        assert!(!stopped_early, "the stop did not wait for the boot");
        assert_eq!(left, None, "and left its server running");
    }

    #[test]
    fn same_authority_compares_scheme_host_and_effective_port() {
        let a = Url::parse("http://127.0.0.1:43123/").unwrap();
        assert!(same_authority(
            &a,
            &Url::parse("http://127.0.0.1:43123/settings").unwrap()
        ));
        assert!(same_authority(
            &a,
            &Url::parse("HTTP://127.0.0.1:43123").unwrap()
        ));
        // Another port, host or scheme is another server.
        assert!(!same_authority(
            &a,
            &Url::parse("http://127.0.0.1:11470/settings").unwrap()
        ));
        assert!(!same_authority(
            &a,
            &Url::parse("http://localhost:43123/").unwrap()
        ));
        assert!(!same_authority(
            &a,
            &Url::parse("https://127.0.0.1:43123/").unwrap()
        ));
        assert!(!same_authority(
            &a,
            &Url::parse("http://192.168.1.20:43123/").unwrap()
        ));
        // Default ports compare by their effective value.
        assert!(same_authority(
            &Url::parse("http://example.com/").unwrap(),
            &Url::parse("http://example.com:80/x").unwrap()
        ));
    }
}
