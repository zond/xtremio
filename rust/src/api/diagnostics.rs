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

/// Records one line from the Dart side into the same ring the Rust log
/// fills, so a report can explain a failure that happened above the FFI --
/// a player open that was refused and retried, an engine error out of
/// media_kit, an unhandled Flutter error. Without this the ring holds only
/// the Rust half of a session and a playback failure leaves no trace in it
/// at all.
///
/// Sync on purpose: the line is written where it happened, so the ring's
/// order stays the order things occurred in rather than the order a worker
/// pool got to them. `level` is `error`/`warn`/`info`/`debug` (anything
/// else is info) and `target` names the Dart source (`player`, `flutter`).
/// A message longer than [`crate::logging::MAX_APP_MESSAGE`] is cut.
///
/// **Nothing secret may be passed here.** The caller sanitizes (no event
/// args, no auth material, no manifest URL with a key), and the Dart side
/// redacts again on the way to the clipboard; this is the middle of that
/// sandwich, not a place to be careless.
#[frb(sync)]
pub fn diagnostics_log(level: String, target: String, message: String) -> anyhow::Result<()> {
    guarded_ok(|| crate::logging::record_app_event(&level, &target, &message))
}
