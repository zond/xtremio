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
use std::sync::{RwLock, RwLockReadGuard, RwLockWriteGuard};

use anyhow::Context;
use stream_server::{
    CacheUsage, DownloadInfo, EngineStats, EvictionReport, ServerHandle, ServerSettings,
    UnpinOutcome,
};
use url::Url;

use crate::state::AppState;

/// stremio-core's default `streaming_server_url` port; preferred so a
/// previously persisted profile keeps pointing at the embedded server.
pub const DEFAULT_PORT: u16 = stream_server::DEFAULT_HTTP_PORT;

/// The embedded server's half of [`AppState`]: the running handle, or
/// nothing.
///
/// A `RwLock`, not a `Mutex`: [`with_handle`]'s blocking library calls
/// (`engine_stats`, `file_stats`, `settings`, `update_settings`) and
/// [`token_for`] (called from `Env::fetch` on stremio-core's tokio workers,
/// including the single-worker sequential runtime) all just need to observe
/// the running handle, so they take a read lock and run concurrently with
/// each other; only `start`/`stop`, which replace the handle, take the
/// write lock. A slow stats poll must never stall an addon/catalog fetch
/// waiting on `token_for`, which is what
/// `with_handle_readers_run_concurrently_with_token_for` holds us to.
///
/// The same reasoning is why this is a lock of its own inside `AppState`
/// rather than one lock around the whole of it.
#[derive(Default)]
pub struct ServerState {
    handle: RwLock<Option<ServerHandle>>,
}

impl ServerState {
    /// A poisoned lock only means a previous holder panicked; the Option is
    /// still a valid value.
    fn read(&self) -> RwLockReadGuard<'_, Option<ServerHandle>> {
        self.handle
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn write(&self) -> RwLockWriteGuard<'_, Option<ServerHandle>> {
        self.handle
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// How to start the embedded server.
#[derive(Clone, Debug)]
pub struct StartConfig {
    /// settings.json, logs/, localFiles/ live here (app support dir).
    pub config_dir: PathBuf,
    /// Torrent piece cache (app cache dir; may be purged by the OS).
    pub cache_dir: PathBuf,
    /// Port to bind on 127.0.0.1; `0` picks an ephemeral one.
    pub port: u16,
    /// If binding `port` fails (another Stremio server is running), retry
    /// with an ephemeral port instead of failing.
    pub fallback_to_ephemeral: bool,
}

fn url_of(handle: &ServerHandle) -> anyhow::Result<Url> {
    Url::parse(&format!("http://{}", handle.http_addr())).context("embedded server base URL")
}

/// Both directories are passed explicitly: every effective path stream-server
/// uses (settings, logs, torrent session and DHT state, archive caches) comes
/// from them, and nothing on its startup path fails without `HOME`/`XDG_*`,
/// which Android app processes do not have. (It may still glance at the
/// environment for defaults these directories override.)
fn spawn(config: &StartConfig, port: u16) -> anyhow::Result<ServerHandle> {
    stream_server::start(stream_server::ServerConfig {
        http_addr: SocketAddr::from((Ipv4Addr::LOCALHOST, port)),
        https_addr: None,
        public_base_url: None,
        config_dir: Some(config.config_dir.clone()),
        cache_dir: Some(config.cache_dir.clone()),
        lan_media_addr: Some(LAN_MEDIA_ADDR),
        ..stream_server::ServerConfig::embedded()
    })
}

/// Where the LAN media listener binds when a cast session turns it on: every
/// interface (a receiver is on the LAN, not on loopback) on a port the OS
/// picks, so nothing collides with another Stremio server or a second
/// instance of this app.
///
/// Configuring it is what makes [`set_lan_media`] able to start it at all
/// ([`stream_server::ServerConfig::lan_media_addr`] is `None` by default and
/// then there is nothing to start). It also means `stream_server::run` binds
/// it once at boot, which is why [`start_in`] shuts it again immediately:
/// see [`lan_media_off`].
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
    crate::logging::init();
    let mut guard = app.server.write();
    if let Some(handle) = guard.as_ref() {
        return url_of(handle);
    }
    std::fs::create_dir_all(&config.config_dir)
        .with_context(|| format!("create server config dir {:?}", config.config_dir))?;
    std::fs::create_dir_all(&config.cache_dir)
        .with_context(|| format!("create server cache dir {:?}", config.cache_dir))?;

    let handle = match spawn(&config, config.port) {
        Ok(handle) => handle,
        Err(error) if config.fallback_to_ephemeral && config.port != 0 => {
            tracing::warn!(
                port = config.port,
                %error,
                "embedded server could not bind its preferred port; retrying with an ephemeral one"
            );
            spawn(&config, 0).context("start embedded server on an ephemeral port")?
        }
        Err(error) => return Err(error.context("start embedded server")),
    };
    let url = url_of(&handle)?;
    // The LAN media listener exists for the length of a cast session and no
    // longer, and `stream_server::run` binds a configured `lan_media_addr`
    // once at boot regardless of the `lanMediaEnabled` veto. So the first
    // thing a freshly started server is told is to close it again: whatever
    // a previous run persisted, and however the last session ended, the app
    // comes up with nothing of ours listening on the LAN.
    lan_media_off(&handle);
    tracing::info!(%url, "embedded stream-server started");
    *guard = Some(handle);
    Ok(url)
}

/// Closes the LAN media listener on `handle`, best effort, and drops the
/// `lanMediaEnabled` permission with it. Used where the answer has to be
/// "off" and there is nobody left to report a failure to: start-up, and the
/// end of a cast session.
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
    let handle = app.server.write().take();
    if let Some(handle) = handle {
        // Before the shutdown, not instead of it: the server closes the LAN
        // listener as part of going down anyway, but this is also what puts
        // the `lanMediaEnabled` veto back on disk, so a process that is
        // killed after this point leaves nothing permitted behind.
        lan_media_off(&handle);
        handle
            .shutdown()
            .context("signal embedded server shutdown")?;
        handle.join().context("join embedded server thread")?;
        tracing::info!("embedded stream-server stopped");
    }
    Ok(())
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
/// stay off the UI thread (FRB's worker pool is fine). Only a read lock is
/// held: concurrent `with_handle`/`token_for` calls (e.g. a stats poll
/// alongside `Env::fetch`) run in parallel instead of serialising on each
/// other; only `start`/`stop` exclude them.
fn with_handle<T>(f: impl FnOnce(&ServerHandle) -> anyhow::Result<T>) -> anyhow::Result<T> {
    let app = crate::state::current().ok_or_else(not_running)?;
    with_handle_in(&app, f)
}

/// [`with_handle`] against a given state.
fn with_handle_in<T>(
    app: &AppState,
    f: impl FnOnce(&ServerHandle) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    let guard = app.server.read();
    let handle = guard.as_ref().ok_or_else(not_running)?;
    f(handle)
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

/// What the cache currently occupies against its `cacheSize` limit, without
/// evicting anything: `totalBytes`/`limitBytes` in the cleaner's own
/// occupancy accounting, and `protectedBytes`/`protectedFiles` for what a
/// live engine or a pinned download is holding right now, which a clean
/// pass can never take. One `stat` per file currently in the cache -- the
/// same walk the cleaner itself runs on every debounced or hourly pass --
/// so it is cheap to call once, but stream-server's own docs say not to
/// poll it on a tight timer.
pub fn cache_usage() -> anyhow::Result<CacheUsage> {
    with_handle(|handle| handle.cache_usage())
}

/// Runs one eviction pass right now and reports what it freed -- the exact
/// function the server's own scheduled sweep calls, so it can never be less
/// careful: nothing a live engine is writing or a pin protects is touched,
/// however far over the limit the cache is. Replaces restarting the server
/// to make its start-up tick fire a sweep; nothing here stops playback.
pub fn clean_cache_now() -> anyhow::Result<EvictionReport> {
    with_handle(|handle| handle.clean_cache_now())
}

/// Starts or stops the LAN media listener -- the server's second HTTP
/// listener, which serves media bytes to the local network and mounts no
/// control route at all (deliberately not `/proxy` and not `/ftp`) -- and
/// answers the address it is bound to afterwards: `Some` after a start,
/// `None` after a stop.
///
/// This is what a cast session turns on and off, and the only thing that
/// ever should: a Chromecast cannot fetch from a loopback-only server, and
/// nothing else about this app wants a socket open to the LAN.
///
/// The server keeps a `lanMediaEnabled` setting that vetoes the listener
/// outright and defaults to `false`, so enabling carries that permission
/// with it and disabling takes it back. That way the persisted answer to
/// "may this app serve the LAN" is `false` whenever no session is running,
/// and a start the server performs by itself at boot cannot serve anything
/// this app did not ask for in the same breath.
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
    /// bearer token. Holds a read lock in one thread via `with_handle`'s
    /// closure (blocked on a barrier then a sleep) and asserts `token_for`
    /// returns from another thread almost immediately, well inside the
    /// sleep — with a `Mutex` instead of a `RwLock` this would take as long
    /// as the sleep.
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
                port: 0,
                fallback_to_ephemeral: true,
            },
        )
        .expect("server start");

        let barrier = Arc::new(Barrier::new(2));
        let handle_thread = std::thread::spawn({
            let barrier = Arc::clone(&barrier);
            let app = Arc::clone(&app);
            move || {
                with_handle_in(&app, |_handle| {
                    // Reached only once `with_handle`'s read guard is held.
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
