//! Xtremio native core: the Rust side of the Flutter app.
//!
//! Everything under `api/` is exported to Dart through `flutter_rust_bridge`;
//! `frb_generated.rs` is produced by `flutter_rust_bridge_codegen generate`
//! and committed. The other modules are internal:
//!
//! - `addon_health`: how each installed addon has been answering, counted
//! - `env`: the `stremio_core::runtime::Env` (HTTP, storage, executors)
//! - `model`: the `#[derive(Model)]` app model and its JSON projection
//! - `state`: the one process-global value the modules below keep their
//!   state in, created by `core::init` and dropped by `core::shutdown`
//! - `core`: the stremio-core Runtime (init, dispatch, state, events)
//! - `downloads`: the offline-downloads registry over the server's pins
//! - `prefs`: the app's own UI preferences, one small JSON file
//! - `server`: the in-process stream-server (torrent/archive bytes over HTTP)
//! - `guard`: panic containment at the FFI boundary
//! - `logging`: the process-wide tracing subscriber and its in-memory ring
//! - `diagnostics`: what this binary was built from (the pinned revisions)
//! - `android`: JNI hooks the Kotlin side calls before Dart starts (Android only)

pub mod addon_health;
#[cfg(target_os = "android")]
pub mod android;
pub mod api;
pub mod core;
pub mod diagnostics;
pub mod downloads;
pub mod env;
mod frb_generated;
pub mod guard;
pub mod logging;
pub mod model;
pub mod prefs;
pub mod server;
pub mod state;
pub mod storage;
