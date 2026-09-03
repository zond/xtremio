//! FRB surface for the app's own preferences: the whole small JSON object
//! out, one key at a time in. Thin, like every other `api` module; the file
//! itself is `crate::prefs`.
//!
//! Two calls rather than one per preference, so a new client-side choice
//! costs a key and no regenerated bindings. Values are JSON, which is what
//! the file holds -- the Dart side decides what a key means.

use crate::guard::guarded;

/// Every preference that has been set, as one JSON object
/// (`{"streamsFlat":true}`). An empty object means none has been: a file
/// that is missing, unreadable or not an object all read that way, since a
/// preference is a default the user changed. Errors only before storage has
/// a directory (`core_init`).
pub fn prefs_get_all() -> anyhow::Result<String> {
    guarded(|| serde_json::to_string(&crate::prefs::get_all()?).map_err(Into::into))
}

/// Stores `value_json` (any JSON value) under `key`, or removes the key
/// when it is null. Every other key in the file is left exactly as it was,
/// including one this build knows nothing about. Writes are atomic
/// (temp-fsync-rename), so a crash mid-write cannot leave half a file.
pub fn prefs_set(key: String, value_json: Option<String>) -> anyhow::Result<()> {
    guarded(|| {
        let value = match value_json {
            Some(json) => Some(
                serde_json::from_str(&json)
                    .map_err(|error| anyhow::anyhow!("invalid preference value: {error}"))?,
            ),
            None => None,
        };
        crate::prefs::set(&key, value)
    })
}
