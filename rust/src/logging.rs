//! Process-wide `tracing` setup.
//!
//! stream-server is embedded with `init_logging: false`, so this crate owns
//! the one subscriber. Desktop builds print to stderr; on Android no
//! subscriber is installed and `tracing`'s `log` feature forwards events to
//! the `log` crate, which FRB's `setup_default_user_utils` routes to logcat.

use std::sync::Once;

/// Default filter when `RUST_LOG` is unset.
pub const DEFAULT_FILTER: &str = "xtremio_core=info,stream_server=info,enginefs=warn";

static INIT: Once = Once::new();

/// Installs the global subscriber once. Safe to call repeatedly; a subscriber
/// installed by someone else (e.g. a test harness) is left in place.
pub fn init() {
    INIT.call_once(|| {
        #[cfg(not(target_os = "android"))]
        {
            use tracing_subscriber::EnvFilter;
            let filter = EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new(DEFAULT_FILTER));
            let _ = tracing_subscriber::fmt()
                .with_env_filter(filter)
                .with_writer(std::io::stderr)
                .try_init();
        }
    });
}
