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
    CacheUsage, DownloadInfo, EngineStats, EvictionReport, ProxyDownloadRequest, ProxyPinKey,
    ServerHandle, ServerSettings, UnpinOutcome,
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
    /// The Google Drive pairing's refresh token, while this device is
    /// linked -- see [`set_drive_grant`] for where it comes from and what
    /// it is for. In memory only: the secure store on the Dart side is
    /// its home, and this process never writes it anywhere.
    drive_grant: Mutex<Option<String>>,
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

    fn grant(&self) -> MutexGuard<'_, Option<String>> {
        self.drive_grant
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// Hands this process the Drive pairing's refresh token, or takes it back.
///
/// **Why Rust holds a copy at all.** A Drive download is a pin on the
/// server that fetches the file with the account's grant
/// (`ServerHandle::pin_proxy_download`), and two of the pins are not asked
/// for by a screen: the launch re-pins every unfinished download
/// (`downloads::reconcile_pins`), and a pin is retried after a refusal.
/// Neither has a Dart frame above it to fetch the token from, so
/// `DriveAccount` hands the grant down once -- on load, on a new pairing
/// -- and takes it back on unlink or `pairAgain`. It is held in memory
/// beside the server handle, exactly as long as the account is linked,
/// and it is spent only inside the server's own process
/// (`routes::drive`); it is in no log line and no registry file. Playing
/// a Drive file still passes the token per call (`open_drive_file`) and
/// does not read this.
///
/// Answers whether a grant *arrived* -- `None` to `Some`, or a different
/// token -- which is when the unfinished Drive downloads are worth pinning
/// again ([`crate::downloads::repin_drive_downloads`]).
pub fn set_drive_grant(refresh_token: Option<String>) -> bool {
    match crate::state::current() {
        Some(app) => set_drive_grant_in(&app, refresh_token),
        None => false,
    }
}

pub(crate) fn set_drive_grant_in(app: &AppState, refresh_token: Option<String>) -> bool {
    let refresh_token = refresh_token.filter(|token| !token.is_empty());
    let mut grant = app.server.grant();
    let arrived = refresh_token.is_some() && *grant != refresh_token;
    let changed = *grant != refresh_token;
    *grant = refresh_token;
    drop(grant);
    if changed {
        tracing::info!(linked = arrived, "the Drive grant changed hands");
    }
    arrived
}

/// The sentence a Drive pin is refused with while no account is linked.
/// Client-safe, and the whole of what the download's row then says.
pub const DRIVE_NOT_LINKED: &str =
    "No Google account is linked to this device, so its Drive files cannot be downloaded.";

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
    stream_server::start(server_config(config))
}

/// Everything this app asks of the embedded server, as one value.
///
/// Separate from [`spawn`] so that a test can read what is asked for
/// without binding a port: the fields here are decisions, and two of them
/// -- the pin set and the Drive pairing endpoint -- are the kind that fail
/// silently. A missing endpoint is every Drive file refusing to open with
/// `noPairingService`, which no test that stubs the opener would ever see.
fn server_config(config: &StartConfig) -> stream_server::ServerConfig {
    stream_server::ServerConfig {
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
        // And the link downloads, under the same rule (`downloads::proxy_pins`).
        proxy_pins: crate::downloads::proxy_pins(),
        // Where a Drive refresh token is turned into an access token. The
        // server holds no client secret and must not guess an endpoint --
        // a wrong one is a refresh token posted to somebody else's host --
        // so it is configured here, once, from the one place this app
        // writes that origin down.
        drive_refresh_endpoint: Url::parse(DRIVE_REFRESH_ENDPOINT).ok(),
        ..stream_server::ServerConfig::default()
    }
}

/// Where the pairing service renews an access token:
/// `POST {"refreshToken":...}` -> `{"accessToken","expiresIn"}`, or a
/// `401` with `pairAgain` for a grant that is gone.
///
/// **The same origin the pairing screen talks to**
/// (`XtremioDrivePairingService.defaultOrigin` in
/// `lib/core/drive_pairing.dart`, which is the service's own
/// `PUBLIC_ORIGIN`). It is written here rather than handed in from Dart
/// because a caller who could name it could point the server's renewals --
/// and this device's refresh token with them -- at a host of their
/// choosing, and the whole reason the token never crosses a URL is that
/// nobody but this device and that service should ever see it.
const DRIVE_REFRESH_ENDPOINT: &str = "https://xtremio-drive.web.app/refresh";

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
    // The setting as the server loaded it from its own file: a viewer who
    // turned the trace on last week gets it on again at this start, which
    // is what the server does for its half of the switch too.
    match handle.settings() {
        Ok(settings) => {
            crate::logging::set_verbose(settings.diagnostics_trace);
        }
        Err(error) => tracing::warn!(%error, "could not read the diagnostics setting"),
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
/// per-file stats (`ServerHandle::file_stats`, what the core's
/// `/{infoHash}/{fileIdx}/stats.json` answers) for `Some(file_idx)`, the
/// torrent-level ones (`ServerHandle::engine_stats`) otherwise. `trackers`
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

/// **Tells the server how long the film is**, without saying where the
/// player is in it.
///
/// What a cast can say and nothing else: the receiver does the reading and
/// reports its position in seconds, which do not convert to a byte offset
/// without a constant bitrate. The length *is* the bitrate, so the window
/// is sized correctly throughout a cast even though where it sits is left
/// to the receiver's own (plainly sequential) reads.
///
/// Silent about everything: a hint that does not arrive costs the
/// freshness of a hint.
///
/// `file_idx` is the player URL's `{fileIdx}` segment: an index, or `-1`
/// for a file the server picks, narrowed by the URL's `f=` `filters`. Any
/// negative number is that spelling; the server resolves it.
pub fn note_duration(info_hash: &str, file_idx: i64, filters: &[String], duration: Duration) {
    let Some(app) = crate::state::current() else {
        return;
    };
    let Some(handle) = app.server.running() else {
        return;
    };
    let spelling = if file_idx < 0 {
        "-1".to_owned()
    } else {
        file_idx.to_string()
    };
    crate::env::CONCURRENT.block_on(handle.note_duration(info_hash, &spelling, filters, duration));
}

/// A player opened on `info_hash`; see
/// [`stream_server::ServerHandle::note_player_opened`]. Nothing when the
/// server is not running.
pub fn note_player_opened(info_hash: &str) {
    let Some(app) = crate::state::current() else {
        return;
    };
    let Some(handle) = app.server.running() else {
        return;
    };
    crate::env::CONCURRENT.block_on(handle.note_player_opened(info_hash));
}

/// The player of `info_hash` is buffering after having played; see
/// [`stream_server::ServerHandle::note_player_stalled`]. Nothing when the
/// server is not running.
pub fn note_player_stalled(info_hash: &str) {
    let Some(app) = crate::state::current() else {
        return;
    };
    let Some(handle) = app.server.running() else {
        return;
    };
    crate::env::CONCURRENT.block_on(handle.note_player_stalled(info_hash));
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
    // A row's coordinates say which pin it holds: a proxy download's key
    // is 64 hex characters, an info hash 40 (`downloads::is_proxy_key`).
    // Dispatched here so every unpin site in the registry -- a removal, a
    // replacement's release, a boot's reconcile, a row marked gone -- asks
    // one function and cannot get the two mixed up.
    if crate::downloads::is_proxy_key(info_hash) {
        return unpin_proxy_download(info_hash, delete_files);
    }
    with_handle(|handle| handle.unpin_download(info_hash, file_idx, delete_files))
}

/// The key a link download has or would have, derived by the server with
/// no network (`ServerHandle::proxy_download_key`); `Ok(None)` for what it
/// cannot key.
pub fn proxy_download_key(pin: &ProxyPinKey) -> anyhow::Result<Option<String>> {
    with_handle(|handle| Ok(handle.proxy_download_key(pin)))
}

/// Pins a link as an offline download (`ServerHandle::pin_proxy_download`):
/// the row it answers has the key for `info_hash` and `0` for `file_idx`.
pub fn pin_proxy_download(pin: ProxyPinKey, name: Option<String>) -> anyhow::Result<DownloadInfo> {
    let app = crate::state::current().ok_or_else(not_running)?;
    pin_proxy_download_in(&app, pin, name)
}

/// [`pin_proxy_download`] against a given state. A Drive pin takes the
/// grant [`set_drive_grant`] left here and is refused -- before the server
/// is asked anything -- while there is none ([`DRIVE_NOT_LINKED`]).
pub(crate) fn pin_proxy_download_in(
    app: &AppState,
    pin: ProxyPinKey,
    name: Option<String>,
) -> anyhow::Result<DownloadInfo> {
    let request = match pin {
        ProxyPinKey::Url { target, headers } => ProxyDownloadRequest {
            url: Some(target),
            headers,
            drive_file_id: None,
            refresh_token: None,
            name,
        },
        ProxyPinKey::Drive { file_id } => {
            let refresh_token = app
                .server
                .grant()
                .clone()
                .ok_or_else(|| anyhow::anyhow!(DRIVE_NOT_LINKED))?;
            ProxyDownloadRequest {
                url: None,
                headers: Default::default(),
                drive_file_id: Some(file_id),
                refresh_token: Some(refresh_token),
                name,
            }
        }
    };
    with_handle_in(app, |handle| handle.pin_proxy_download(request))
}

/// Drops a link download's pin by its key
/// (`ServerHandle::unpin_proxy_download`).
pub fn unpin_proxy_download(key: &str, delete_files: bool) -> anyhow::Result<UnpinOutcome> {
    with_handle(|handle| handle.unpin_proxy_download(key, delete_files))
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

/// Why a linked Drive file could not be made playable. **Three answers the
/// app acts on differently**, which is why it is an enum and not a
/// sentence.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DriveOpenFailure {
    /// The grant is gone: revoked, or expired, and no retry brings it
    /// back. The viewer pairs again from their phone, and
    /// `DriveAccount.notePairAgain` is what the app does with this.
    /// **Terminal**, which is the whole reason it is told apart.
    PairAgain,
    /// This build has no pairing service configured, so there is nothing
    /// to renew against. A fact about the build; a viewer can do nothing
    /// about it.
    NoPairingService,
    /// Google or the pairing service could not be reached, or would not
    /// serve the file. Worth trying again; the grant may be perfectly
    /// good.
    Unreachable,
    /// The embedded server is not running, so nothing could be opened.
    /// Not about the account either.
    Unavailable,
}

/// What [`open_drive_file`] answers: a URL, or the reason there is none.
///
/// The `ok`/`reason` shape `downloads::OpenOutcome` already uses, and for
/// the same reason -- the refusals are outcomes the app draws differently,
/// not errors, and an error would cross the FFI as a sentence the caller
/// would have to match English against.
///
/// **Nothing here can carry the refresh token.** The fields are a URL the
/// server minted, the name the caller passed in and two facts about the
/// file; every failure is one of the four words above.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DriveOpenOutcome {
    pub ok: bool,
    /// Where the player fetches the film: this server's own
    /// `/drive/stream/{key}`, carrying a random key and no credential.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub length: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<DriveOpenFailure>,
}

impl DriveOpenOutcome {
    fn refused(reason: DriveOpenFailure) -> Self {
        Self {
            ok: false,
            url: None,
            name: None,
            content_type: None,
            length: None,
            reason: Some(reason),
        }
    }
}

/// Open a file in the paired Google Drive and answer a URL the player can
/// fetch (`ServerHandle::open_drive_file`; there is no HTTP route for it,
/// because the argument is the account's grant).
///
/// **The token is an argument and never a request.** It crosses from Dart
/// into this process, is handed to the server's library API, and is spent
/// inside the server for an hourly access token; it is in no URL, no log
/// line and no error. What comes back names a random key, so the string
/// that reaches mpv -- and the diagnostics log, and a bug report -- says
/// nothing about the account or even which file it is.
///
/// A server that is not running is [`DriveOpenFailure::Unavailable`]
/// rather than an error, so that every way this can fail is one of four
/// words the app switches on.
pub fn open_drive_file(
    file_id: &str,
    refresh_token: &str,
    name: Option<String>,
) -> DriveOpenOutcome {
    outcome_of(with_handle(|handle| {
        handle.open_drive_file(file_id, refresh_token, name)
    }))
}

/// [`open_drive_file`] against a given state, which is how a test says
/// "no server is running" without taking the process's embedded one away
/// from another test (the same reason [`update_settings_in`] exists).
#[cfg(test)]
fn open_drive_file_in(
    app: &AppState,
    file_id: &str,
    refresh_token: &str,
    name: Option<String>,
) -> DriveOpenOutcome {
    outcome_of(with_handle_in(app, |handle| {
        handle.open_drive_file(file_id, refresh_token, name)
    }))
}

/// What the server answered, as one of the four words and a URL.
///
/// The whole of the mapping, shared by the two entry points above so that
/// neither can answer differently: an `Err` at this level is a server that
/// is not running or a runtime that is gone, which is `unavailable` and
/// **not** the error's own sentence -- a caller that had to read one would
/// be matching English.
fn outcome_of(
    opened: anyhow::Result<Result<stream_server::DriveFileOpened, stream_server::DriveOpenError>>,
) -> DriveOpenOutcome {
    let opened = match opened {
        Ok(opened) => opened,
        Err(_) => return DriveOpenOutcome::refused(DriveOpenFailure::Unavailable),
    };
    match opened {
        Ok(file) => DriveOpenOutcome {
            ok: true,
            url: Some(file.url),
            name: file.name,
            content_type: Some(file.content_type),
            length: Some(file.length),
            reason: None,
        },
        Err(error) if error.is_pair_again() => {
            DriveOpenOutcome::refused(DriveOpenFailure::PairAgain)
        }
        Err(error) if error.refused() == Some("noPairingService") => {
            DriveOpenOutcome::refused(DriveOpenFailure::NoPairingService)
        }
        Err(error) => {
            // The *kind*, never the sentence: a refusal's text is written
            // in the server and says nothing secret, but a habit of
            // logging what an error said is how the one that does gets
            // filed. See `AGENTS.md`, "Never log auth material".
            tracing::warn!(
                pair_again = false,
                "a linked Drive file could not be opened"
            );
            let _ = error;
            DriveOpenOutcome::refused(DriveOpenFailure::Unreachable)
        }
    }
}

/// Applies `patch` as `POST /settings` would (same keys, validation and
/// persistence) and returns the settings afterwards.
pub fn update_settings(patch: serde_json::Value) -> anyhow::Result<ServerSettings> {
    update_settings_in(&crate::state::state(), patch)
}

/// [`update_settings`] against a given state, which is how a test writes a
/// setting without taking the process's embedded server from another one.
pub(crate) fn update_settings_in(
    app: &AppState,
    patch: serde_json::Value,
) -> anyhow::Result<ServerSettings> {
    let settings = with_handle_in(app, |handle| handle.update_settings(patch))?;
    // Where the Verbose logging switch actually reaches the log. The
    // server's own `set_diagnostics_trace` reloads a filter it installed,
    // and it installed none: this crate owns the process's subscriber
    // (`init_logging: false`), so the setting reached the server's file and
    // stopped there. Read off the settings the server answered with rather
    // than off the patch, so any other way of changing it lands here too.
    crate::logging::set_verbose(settings.diagnostics_trace);
    Ok(settings)
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

/// The mainline DHT's status on this host (`ServerHandle::dht_status`,
/// no HTTP route): whether a DHT is
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

    /// A Drive pin with no grant in hand is refused with the one sentence,
    /// before the server is asked -- there is no server here, and the
    /// refusal is not "not running". Once a grant arrives the pin gets as
    /// far as the server, which is the "not running" this state has.
    #[test]
    fn a_drive_pin_wants_the_grant_before_it_wants_the_server() {
        let app = Arc::new(AppState::default());
        let pin = ProxyPinKey::Drive {
            file_id: "1AbCdEfGh".into(),
        };
        let refused = pin_proxy_download_in(&app, pin.clone(), None).unwrap_err();
        assert_eq!(refused.to_string(), DRIVE_NOT_LINKED);

        assert!(
            !set_drive_grant_in(&app, Some(String::new())),
            "empty is none"
        );
        assert!(set_drive_grant_in(&app, Some("refresh-tok".into())));
        assert!(
            !set_drive_grant_in(&app, Some("refresh-tok".into())),
            "the same grant again is not an arrival"
        );
        let asked = pin_proxy_download_in(&app, pin.clone(), None).unwrap_err();
        assert_ne!(asked.to_string(), DRIVE_NOT_LINKED);
        assert!(asked.to_string().contains("not running"), "{asked}");

        assert!(
            !set_drive_grant_in(&app, None),
            "taking it back is not an arrival"
        );
        let refused = pin_proxy_download_in(&app, pin, None).unwrap_err();
        assert_eq!(refused.to_string(), DRIVE_NOT_LINKED);
    }

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
    /// The Verbose logging switch writes one of the embedded server's
    /// settings, and that write is the only thing that can turn the two
    /// traces on in this process: the server installed no filter of its
    /// own ([`crate::logging`] owns the subscriber), so its own
    /// `set_diagnostics_trace` has nothing to reload and the setting used
    /// to reach its file and stop there.
    #[test]
    fn the_diagnostics_setting_reaches_this_processes_filter() {
        let _serialised = crate::logging::VERBOSE_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        crate::logging::init();
        let app = Arc::new(AppState::default());
        let tmp = tempfile::tempdir().expect("tempdir");
        start_in(
            &app,
            StartConfig {
                config_dir: tmp.path().join("server"),
                cache_dir: tmp.path().join("cache"),
            },
        )
        .expect("server start");
        let traced = || tracing::enabled!(target: stream_server::RETENTION_TRACE_TARGET, tracing::Level::INFO);
        assert!(!traced(), "the trace was on before the setting said so");

        update_settings_in(&app, serde_json::json!({ "diagnosticsTrace": true }))
            .expect("the setting is written");
        assert!(traced(), "the setting did not reach this process's filter");

        update_settings_in(&app, serde_json::json!({ "diagnosticsTrace": false }))
            .expect("the setting is written");
        assert!(!traced(), "the setting did not shut it again");

        crate::logging::set_verbose(false);
        stop_in(&app).expect("server stop");
    }

    /// And a start finds it where the last session left it: the server
    /// loads its own settings file, so a viewer who turned the trace on
    /// last week gets it on again without touching the switch.
    #[test]
    fn a_start_applies_the_setting_the_last_session_left() {
        let _serialised = crate::logging::VERBOSE_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        crate::logging::init();
        let tmp = tempfile::tempdir().expect("tempdir");
        let config = StartConfig {
            config_dir: tmp.path().join("server"),
            cache_dir: tmp.path().join("cache"),
        };
        let traced = || tracing::enabled!(target: stream_server::RETENTION_TRACE_TARGET, tracing::Level::INFO);

        let first = Arc::new(AppState::default());
        start_in(&first, config.clone()).expect("server start");
        update_settings_in(&first, serde_json::json!({ "diagnosticsTrace": true }))
            .expect("the setting is written");
        stop_in(&first).expect("server stop");
        // What a fresh process would have: nothing has told this one yet.
        crate::logging::set_verbose(false);
        assert!(!traced());

        let second = Arc::new(AppState::default());
        start_in(&second, config).expect("server start");

        assert!(traced(), "the start did not apply the persisted setting");

        crate::logging::set_verbose(false);
        stop_in(&second).expect("server stop");
    }

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

    /// The pairing endpoint is a URL, it is the one the app's own pairing
    /// screen talks to, and **the server is actually told about it**. A typo
    /// or an omission here is every Drive file refusing to open, and nothing
    /// above the FFI would see it: a test with a fake opener never reaches
    /// the server's configuration at all.
    #[test]
    fn the_server_is_told_where_the_pairing_service_is() {
        let url = Url::parse(DRIVE_REFRESH_ENDPOINT).expect("a literal URL");
        assert_eq!(url.scheme(), "https");
        assert_eq!(url.host_str(), Some("xtremio-drive.web.app"));
        assert_eq!(url.path(), "/refresh");

        let config = server_config(&StartConfig {
            config_dir: PathBuf::from("/tmp/xtremio-test-config"),
            cache_dir: PathBuf::from("/tmp/xtremio-test-cache"),
        });
        assert_eq!(config.drive_refresh_endpoint, Some(url));
        // And Drive itself stays the server's own constant: an origin this
        // side could name would be a credentialed relay with a cache behind
        // it (`routes::drive::DriveEndpoints`).
        assert_eq!(config.drive_api_base, None);
    }

    /// With no server running there is nothing to open, and that is an
    /// *outcome* rather than an error -- so every way this call can fail is
    /// one of the four words the app switches on, and none of them carries
    /// the grant.
    ///
    /// Against a state of its own, with no server in it: the process's
    /// embedded server belongs to whichever other test started it, and one
    /// running would send this test's marker to the real pairing service.
    #[test]
    fn no_server_is_unavailable_and_says_nothing_about_the_grant() {
        const TOKEN: &str = "not-a-token-only-a-marker-for-this-test";
        let app = AppState::default();
        let outcome = open_drive_file_in(&app, "a-file-id", TOKEN, Some("A Film.mkv".into()));
        assert!(!outcome.ok);
        assert_eq!(outcome.reason, Some(DriveOpenFailure::Unavailable));
        assert!(outcome.url.is_none());
        let answered = serde_json::to_string(&outcome).expect("the outcome serialises");
        assert!(!answered.contains(TOKEN), "{answered}");
        assert!(!answered.contains("a-file-id"), "{answered}");
    }

    /// **Every answer the server can give becomes the right word**, and
    /// above all `pairAgain`: that one is terminal, the app's response to
    /// it is a fresh QR, and it is the one thing nothing above the FFI may
    /// have to read English to recognise.
    ///
    /// The server's own tests prove `DriveOpenError::is_pair_again` for a
    /// grant that is gone (`server/tests/drive.rs`); this is the other
    /// half, which is that the word survives the crossing.
    #[test]
    fn every_refusal_crosses_as_its_own_word() {
        use stream_server::{DriveError, DriveOpenError};

        for (error, expected) in [
            (
                DriveOpenError::Drive(DriveError::PairAgain),
                DriveOpenFailure::PairAgain,
            ),
            (
                DriveOpenError::NoPairingService,
                DriveOpenFailure::NoPairingService,
            ),
            (
                DriveOpenError::Drive(DriveError::Refused(503)),
                DriveOpenFailure::Unreachable,
            ),
            (
                DriveOpenError::Drive(DriveError::Unreachable("no route".into())),
                DriveOpenFailure::Unreachable,
            ),
        ] {
            let outcome = outcome_of(Ok(Err(error)));
            assert!(!outcome.ok);
            assert_eq!(outcome.reason, Some(expected));
            assert!(outcome.url.is_none());
        }

        // And a file that opened is a URL with the three facts on it.
        let outcome = outcome_of(Ok(Ok(stream_server::DriveFileOpened {
            key: "a-key".into(),
            url: "http://127.0.0.1:1/drive/stream/a-key".into(),
            name: Some("A Film.mkv".into()),
            content_type: "video/x-matroska".into(),
            length: 4096,
        })));
        assert!(outcome.ok);
        assert_eq!(
            outcome.url.as_deref(),
            Some("http://127.0.0.1:1/drive/stream/a-key")
        );
        assert_eq!(outcome.name.as_deref(), Some("A Film.mkv"));
        assert_eq!(outcome.length, Some(4096));
        assert_eq!(outcome.reason, None);
    }
}
