//! FRB surface for the Diagnostics screen: the crate's own recent log and
//! what it was built from, so a failure on a phone can be copied out of the
//! app instead of read over ADB.
//!
//! Nothing here is a secret. The embedded server's bearer token is never
//! logged and never leaves the Rust side (`AGENTS.md`, "Never log auth
//! material"), and the Dart side scrubs everything it copies anyway.

use flutter_rust_bridge::frb;

use crate::guard::guarded_ok;

/// Everything the Rust side can say about itself in one call.
pub struct DiagnosticsSnapshot {
    /// `xtremio_core`'s crate version.
    pub core_version: String,
    /// The git revision the embedded stream-server is pinned to, when it is
    /// still a git pin.
    pub stream_server_rev: Option<String>,
    /// The git revision stremio-core is pinned to.
    pub stremio_core_rev: Option<String>,
    /// Base URL of the embedded server, or null when it is not running --
    /// which is also how the app tells whether it is.
    pub server_base_url: Option<String>,
    /// The captured `tracing` lines, oldest first: this crate's and the
    /// embedded server's, both through the one subscriber, bounded by
    /// `crate::logging::RING_CAPACITY`.
    pub log_lines: Vec<String>,
}

/// The snapshot. Cheap enough for the UI thread: a lock, a clone of a few
/// hundred short strings, and no I/O.
#[frb(sync)]
pub fn diagnostics_snapshot() -> anyhow::Result<DiagnosticsSnapshot> {
    guarded_ok(|| {
        let build = crate::diagnostics::build_info();
        DiagnosticsSnapshot {
            core_version: build.core_version,
            stream_server_rev: build.stream_server_rev,
            stremio_core_rev: build.stremio_core_rev,
            server_base_url: crate::server::base_url().map(|url| url.to_string()),
            log_lines: crate::logging::recent_lines(),
        }
    })
}
