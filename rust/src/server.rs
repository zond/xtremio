//! The embedded stream-server: one instance per process, owned by this crate.
//!
//! `stream_server::start` runs the server on its own OS thread with its own
//! tokio runtime, so torrent hashing and disk I/O never compete with the
//! stremio-core runtime or FRB's thread pool. We keep a single global
//! [`ServerHandle`] and expose start/stop/base_url around it, plus the
//! bearer token its control API requires: `Env::fetch` attaches it to the
//! engine's requests to the server, and nothing else ever sees it. The
//! app's own control calls (torrent stats, server settings) go through the
//! handle's library API here, never over HTTP.

use std::net::{Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::{RwLock, RwLockReadGuard, RwLockWriteGuard};

use anyhow::Context;
use stream_server::{DownloadInfo, EngineStats, ServerHandle, ServerSettings, UnpinOutcome};
use url::Url;

/// stremio-core's default `streaming_server_url` port; preferred so a
/// previously persisted profile keeps pointing at the embedded server.
pub const DEFAULT_PORT: u16 = stream_server::DEFAULT_HTTP_PORT;

// A `RwLock`, not a `Mutex`: `with_handle`'s blocking library calls
// (`engine_stats`, `file_stats`, `settings`, `update_settings`) and
// `token_for` (called from `Env::fetch` on stremio-core's tokio workers,
// including the single-worker sequential runtime) all just need to observe
// the running handle, so they take a read lock and run concurrently with
// each other; only `start`/`stop`, which replace the handle, take the
// write lock. A slow stats poll must never stall an addon/catalog fetch
// waiting on `token_for`.
static SERVER: RwLock<Option<ServerHandle>> = RwLock::new(None);

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

fn read() -> RwLockReadGuard<'static, Option<ServerHandle>> {
    // A poisoned lock only means a previous holder panicked; the Option is
    // still a valid value.
    SERVER
        .read()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn write() -> RwLockWriteGuard<'static, Option<ServerHandle>> {
    SERVER
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
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
        ..stream_server::ServerConfig::embedded()
    })
}

/// Starts the server if it is not running and returns its base URL
/// (`http://127.0.0.1:<port>/`). Idempotent: a running server's URL is
/// returned as-is, regardless of the config passed.
pub fn start(config: StartConfig) -> anyhow::Result<Url> {
    crate::logging::init();
    let mut guard = write();
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
    tracing::info!(%url, "embedded stream-server started");
    *guard = Some(handle);
    Ok(url)
}

/// Stops the server and waits for its thread to exit. Ok if not running.
pub fn stop() -> anyhow::Result<()> {
    let handle = write().take();
    if let Some(handle) = handle {
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
    read().as_ref().and_then(|handle| url_of(handle).ok())
}

/// Runs `f` against the running server's handle. The handle's library calls
/// block the calling thread until the server's runtime answers, so callers
/// stay off the UI thread (FRB's worker pool is fine). Only a read lock is
/// held: concurrent `with_handle`/`token_for` calls (e.g. a stats poll
/// alongside `Env::fetch`) run in parallel instead of serialising on each
/// other; only `start`/`stop` exclude them.
fn with_handle<T>(f: impl FnOnce(&ServerHandle) -> anyhow::Result<T>) -> anyhow::Result<T> {
    let guard = read();
    let handle = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("embedded server is not running"))?;
    f(handle)
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

/// Whether `url` addresses the running embedded server: same scheme, host
/// and (effective) port as [`base_url`]. False when no server runs.
pub fn is_embedded_url(url: &Url) -> bool {
    read()
        .as_ref()
        .is_some_and(|handle| is_embedded_url_locked(handle, url))
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
    let guard = read();
    let handle = guard.as_ref()?;
    if is_embedded_url_locked(handle, url) {
        handle.auth_token().map(str::to_owned)
    } else {
        None
    }
}

/// Serializes tests that start/stop the process-global embedded server:
/// this module's lifecycle test and `env.rs`'s
/// `fetch_decodes_json_from_the_embedded_server` both drive it and would
/// otherwise race when `cargo test` runs unit tests in parallel.
#[cfg(test)]
pub(crate) static LIFECYCLE_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Barrier};
    use std::time::{Duration, Instant};

    use super::*;

    /// `with_handle` (stats, settings) and `token_for` (`Env::fetch`) both
    /// only need to observe the running handle, so they must run
    /// concurrently rather than serialise on `SERVER`: a slow stats poll
    /// must never stall an addon/catalog fetch waiting on its bearer token.
    /// Holds a read lock in one thread via `with_handle`'s closure (blocked
    /// on a barrier then a sleep) and asserts `token_for` returns from
    /// another thread almost immediately, well inside the sleep — with a
    /// `Mutex` instead of a `RwLock` this would take as long as the sleep.
    #[test]
    fn with_handle_readers_run_concurrently_with_token_for() {
        let _serialize = LIFECYCLE_TEST_LOCK
            .lock()
            .unwrap_or_else(|p| p.into_inner());

        let tmp = tempfile::tempdir().expect("tempdir");
        let url = start(StartConfig {
            config_dir: tmp.path().join("server"),
            cache_dir: tmp.path().join("cache"),
            port: 0,
            fallback_to_ephemeral: true,
        })
        .expect("server start");

        let barrier = Arc::new(Barrier::new(2));
        let handle_thread = std::thread::spawn({
            let barrier = Arc::clone(&barrier);
            move || {
                with_handle(|_handle| {
                    // Reached only once `with_handle`'s read guard is held.
                    barrier.wait();
                    std::thread::sleep(Duration::from_millis(500));
                    Ok(())
                })
            }
        });

        barrier.wait();
        let started = Instant::now();
        let token = token_for(&url);
        let elapsed = started.elapsed();

        handle_thread
            .join()
            .expect("with_handle thread")
            .expect("with_handle closure");
        stop().expect("server stop");

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
