//! FRB surface for the embedded stream-server.

use flutter_rust_bridge::frb;

use crate::guard::{guarded, guarded_ok};

/// Where and how the embedded server runs. Directories are decided by Dart
/// (path_provider) and created by Rust if missing.
pub struct ServerConfig {
    /// App-support directory for settings.json, logs/, localFiles/.
    pub config_dir: String,
    /// App-cache directory for the torrent piece cache.
    pub cache_dir: String,
    /// Port on 127.0.0.1; 11470 is stremio-core's default, 0 = ephemeral.
    pub port: u16,
    /// Retry with an ephemeral port if `port` is taken.
    pub fallback_to_ephemeral: bool,
}

impl From<ServerConfig> for crate::server::StartConfig {
    fn from(config: ServerConfig) -> Self {
        Self {
            config_dir: config.config_dir.into(),
            cache_dir: config.cache_dir.into(),
            port: config.port,
            fallback_to_ephemeral: config.fallback_to_ephemeral,
        }
    }
}

/// Starts the embedded server (idempotent) and returns its base URL, e.g.
/// `http://127.0.0.1:11470/`.
pub fn server_start(config: ServerConfig) -> anyhow::Result<String> {
    guarded(|| crate::server::start(config.into()).map(|url| url.to_string()))
}

/// Stops the embedded server and joins its thread. Ok if it is not running.
pub fn server_stop() -> anyhow::Result<()> {
    guarded(crate::server::stop)
}

/// Base URL of the running embedded server, or null when it is stopped.
#[frb(sync)]
pub fn server_base_url() -> anyhow::Result<Option<String>> {
    guarded_ok(|| crate::server::base_url().map(|url| url.to_string()))
}
