//! FRB surface for the stremio-core runtime. Thin: JSON strings in and out,
//! all real work in `crate::core`.

use flutter_rust_bridge::frb;

use crate::api::server::ServerConfig;
use crate::frb_generated::StreamSink;
use crate::guard::{guarded, guarded_ok};

/// Boot configuration. Directories come from Dart (`path_provider`).
pub struct CoreConfig {
    /// Where stremio-core persists its buckets (`<key>.json`).
    pub storage_dir: String,
    /// Reserved for an HTTP cache; created but unused for now.
    pub cache_dir: String,
    /// When set, the embedded server is started first and the engine is
    /// pointed at it (unless the profile names a remote server).
    pub server: Option<ServerConfig>,
}

pub struct CoreInitResult {
    /// Base URL of the embedded server, when one was started.
    pub server_base_url: Option<String>,
    /// stremio-core's `SCHEMA_VERSION`.
    pub schema_version: u32,
}

/// Runtime events as JSON strings, one per item. Either
/// `{"name":"NewState","args":["board","ctx"]}` (the fields that changed) or
/// `{"name":"CoreEvent","args":{...}}`. Subscribe before `core_init`; events
/// emitted earlier are replayed from a bounded buffer.
pub fn core_events(sink: StreamSink<String>) -> anyhow::Result<()> {
    guarded(|| {
        crate::core::set_event_sink(Box::new(move |event| sink.add(event).is_ok()));
        Ok(())
    })
}

/// Boots the engine (idempotent). Blocks the FRB worker for the duration of
/// storage hydration and server start-up; never call from the UI thread.
pub fn core_init(config: CoreConfig) -> anyhow::Result<CoreInitResult> {
    guarded(|| {
        let outcome = crate::core::init(crate::core::InitConfig {
            storage_dir: config.storage_dir.into(),
            cache_dir: config.cache_dir.into(),
            server: config.server.map(Into::into),
        })?;
        Ok(CoreInitResult {
            server_base_url: outcome.server_base_url.map(|url| url.to_string()),
            schema_version: outcome.schema_version,
        })
    })
}

/// Dispatches `{"field": <"board"|...|null>, "action": <stremio_core Action>}`.
/// Malformed JSON is an error naming the offending path.
pub fn core_dispatch(action_json: String) -> anyhow::Result<()> {
    guarded(|| crate::core::dispatch(&action_json))
}

/// Serializes one model field (`snake_case`, e.g. `"streaming_server"`).
pub fn core_get_state(field: String) -> anyhow::Result<String> {
    guarded(|| crate::core::get_state(&field))
}

/// Whether `core_init` has completed and `core_shutdown` has not run since.
#[frb(sync)]
pub fn core_is_initialized() -> anyhow::Result<bool> {
    guarded_ok(crate::core::is_initialized)
}

/// Stops the engine and the embedded server.
pub fn core_shutdown() -> anyhow::Result<()> {
    guarded(crate::core::shutdown)
}
