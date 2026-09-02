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
use std::sync::{Mutex, MutexGuard};

use anyhow::Context;
use stream_server::{EngineStats, ServerHandle, ServerSettings};
use url::Url;

/// stremio-core's default `streaming_server_url` port; preferred so a
/// previously persisted profile keeps pointing at the embedded server.
pub const DEFAULT_PORT: u16 = stream_server::DEFAULT_HTTP_PORT;

static SERVER: Mutex<Option<ServerHandle>> = Mutex::new(None);

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

fn lock() -> MutexGuard<'static, Option<ServerHandle>> {
    // A poisoned lock only means a previous holder panicked; the Option is
    // still a valid value.
    SERVER
        .lock()
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
    let mut guard = lock();
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
    let handle = lock().take();
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
    lock().as_ref().and_then(|handle| url_of(handle).ok())
}

/// Runs `f` against the running server's handle. The handle's library calls
/// block the calling thread until the server's runtime answers, so callers
/// stay off the UI thread (FRB's worker pool is fine).
fn with_handle<T>(f: impl FnOnce(&ServerHandle) -> anyhow::Result<T>) -> anyhow::Result<T> {
    let guard = lock();
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
    base_url().is_some_and(|base| same_authority(&base, url))
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
    let guard = lock();
    let handle = guard.as_ref()?;
    let base = url_of(handle).ok()?;
    if same_authority(&base, url) {
        handle.auth_token().map(str::to_owned)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
