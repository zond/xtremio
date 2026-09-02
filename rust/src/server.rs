//! The embedded stream-server: one instance per process, owned by this crate.
//!
//! `stream_server::start` runs the server on its own OS thread with its own
//! tokio runtime, so torrent hashing and disk I/O never compete with the
//! stremio-core runtime or FRB's thread pool. We keep a single global
//! [`ServerHandle`] and expose start/stop/base_url around it.

use std::net::{Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};

use anyhow::Context;
use stream_server::ServerHandle;
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

/// Both directories are passed explicitly: stream-server derives every path
/// it needs (settings, logs, torrent session and DHT state, archive caches)
/// from them and never consults `HOME`/`XDG_*`, which Android app processes
/// do not have.
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
