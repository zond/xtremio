//! Xtremio native core: the Rust side of the Flutter app.
//!
//! Everything under `api/` is exported to Dart through `flutter_rust_bridge`;
//! `frb_generated.rs` is produced by `flutter_rust_bridge_codegen generate`
//! and committed.

pub mod api;
mod frb_generated;
