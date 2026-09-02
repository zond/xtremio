//! Xtremio native core: the Rust side of the Flutter app.
//!
//! Everything under `api/` is exported to Dart through `flutter_rust_bridge`;
//! `frb_generated.rs` is produced by `flutter_rust_bridge_codegen generate`
//! and committed. The other modules are internal:
//!
//! - `env`: the `stremio_core::runtime::Env` (HTTP, storage, executors)
//! - `server`: the in-process stream-server (torrent/archive bytes over HTTP)
//! - `guard`: panic containment at the FFI boundary
//! - `logging`: the process-wide tracing subscriber

pub mod api;
pub mod env;
mod frb_generated;
pub mod guard;
pub mod logging;
pub mod server;
