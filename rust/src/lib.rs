//! Xtremio native core: the Rust side of the Flutter app.
//!
//! Everything under `api/` is exported to Dart through `flutter_rust_bridge`;
//! `frb_generated.rs` is produced by `flutter_rust_bridge_codegen generate`
//! and committed. The other modules are internal:
//!
//! - `addon_health`: how each installed addon has been answering, counted
//! - `addon_observer`: what the runtime pump saw each addon answer
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
//! - `subtitles`: when each subtitle file has text on screen, and the
//!   line that maps one file's clock onto another's
//! - `diagnostics`: what this binary was built from (the pinned revisions)
//!
//! The crate also owns the process's allocator, below.

/// mimalloc as the global allocator, the way the standalone stream-server
/// binary has it (`server/src/main.rs`); without it, this crate runs on the
/// platform's scudo on Android and on glibc's malloc on the desktop.
///
/// What it is for is retention rather than speed. A torrent engine allocates
/// in the shape an allocator handles worst: hundreds of thousands of short
/// lived buffers of a few sizes -- a peer's 16 KiB write and 32 KiB read
/// buffer, its channel, its task -- freed in an order unrelated to the one
/// they were taken in, so the heap is left holding pages that are mostly
/// free and cannot be given back. On the desktop, streaming one real swarm
/// to completion, about 170 MB of resident size was the allocator's, not
/// the program's. mimalloc's segments are per size class and purged back to
/// the OS a few milliseconds after they empty, which is the case this is.
///
/// Whether scudo on the owner's television shows the same gap is not known
/// and is what decides whether this stays: the win is measured on desktop
/// glibc and has to be confirmed on the device with `dumpsys meminfo`
/// (`Native Heap` and `TOTAL PSS`) after the same stream, on a build with
/// and without this attribute. Not on wasm, where there is no allocator to
/// replace.
#[cfg(not(target_family = "wasm"))]
#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

pub mod addon_health;
pub mod addon_observer;
pub mod api;
pub mod core;
pub mod diagnostics;
pub mod downloads;
pub mod env;
mod frb_generated;
pub mod guard;
pub mod logging;
pub mod media;
pub mod model;
pub mod mpv_stream;
pub mod prefs;
pub mod serde_fault;
pub mod server;
pub mod state;
pub mod storage;
pub mod subtitles;
