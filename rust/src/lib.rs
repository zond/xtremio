//! Xtremio native core: the Rust side of the Flutter app.
//!
//! Everything under `api/` is exported to Dart through `flutter_rust_bridge`;
//! `frb_generated.rs` is produced by `flutter_rust_bridge_codegen generate`
//! and committed. The other modules are internal:
//!
//! - `env`: the `stremio_core::runtime::Env` (HTTP, storage, executors)
//! - `model`: the `#[derive(Model)]` app model and its JSON projection
//! - `core`: the stremio-core Runtime (init, dispatch, state, events)
//! - `server`: the in-process stream-server (torrent/archive bytes over HTTP)
//! - `guard`: panic containment at the FFI boundary
//! - `logging`: the process-wide tracing subscriber
//! - `android`: JNI hooks the Kotlin side calls before Dart starts (Android only)

#[cfg(target_os = "android")]
pub mod android;
pub mod api;
pub mod core;
pub mod env;
mod frb_generated;
pub mod guard;
pub mod logging;
pub mod model;
pub mod server;
