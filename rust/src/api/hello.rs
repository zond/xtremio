//! Bridge smoke surface: proves the Dart <-> Rust round trip works before any
//! real functionality is layered on top.

use flutter_rust_bridge::frb;

/// The `flutter_rust_bridge` runtime version this crate was built against.
/// Dart asserts it matches the pinned Dart package version.
pub const BRIDGE_VERSION: &str = "2.13.0";

/// Runs automatically from `RustLib.init()` on the Dart side.
#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Trivial synchronous getter (runs on the calling Dart thread).
#[frb(sync)]
pub fn bridge_version() -> String {
    BRIDGE_VERSION.to_owned()
}

/// stremio-core's persisted storage schema version (`SCHEMA_VERSION`); the
/// Env runs migrations up to this on every init.
#[frb(sync)]
pub fn core_schema_version() -> u32 {
    stremio_core::constants::SCHEMA_VERSION
}
