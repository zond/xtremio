//! The app's own preferences: one small JSON object in the storage
//! directory, next to stremio-core's buckets.
//!
//! This is for choices that are the *client's*, not the engine's -- how a
//! list is laid out, which view a screen came up in. It deliberately does
//! not go into stremio-core's `Settings`: that is a synced, engine-owned
//! struct, and adding a field to it would mean forking the core. It is not
//! a Dart preferences package either, because the storage directory is
//! already ours and already atomic (`crate::env::write_atomically`).
//!
//! The file is forgiving and additive, like the downloads registry: it is a
//! flat JSON object, every key is optional, and a key this build knows
//! nothing about survives a round trip untouched -- a write is a
//! read-modify-write of one key, never a rewrite of the whole shape. A file
//! that cannot be parsed at all reads as "no preferences set" so a bad byte
//! costs a layout choice and not the app; the next write replaces it.
//!
//! Nothing here is secret and nothing here is synced. Do not put auth
//! material in it (`AGENTS.md`, "Never log auth material") -- it is written
//! in the clear and copied into diagnostics-shaped reports by nobody, but
//! it is also not the place for a token.

use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};

use anyhow::Context;
use serde_json::{Map, Value};

/// `<storage_dir>/xtremio_prefs.json`. Prefixed because the directory is
/// shared with stremio-core's buckets, which are `<key>.json` for whatever
/// keys the engine decides to use.
const FILE_NAME: &str = "xtremio_prefs.json";

/// The preferences half of [`crate::state::AppState`]: the file's lock.
///
/// A write is a read-modify-write of a shared file, and the FFI calls that
/// do one run on FRB's worker pool, so two toggles landing together would
/// otherwise be able to lose each other's key.
#[derive(Default)]
pub struct PrefsState {
    file: Mutex<()>,
}

impl PrefsState {
    /// A poisoned lock only means a previous holder panicked; there is no
    /// value behind this one to be left inconsistent.
    fn file(&self) -> MutexGuard<'_, ()> {
        self.file
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// Where the file is, or `None` before `core_init` has pointed storage
/// anywhere.
fn path() -> Option<PathBuf> {
    crate::env::storage_dir().map(|dir| dir.join(FILE_NAME))
}

/// Every preference set, as a JSON object.
///
/// A missing file, an unreadable one and one holding anything but an object
/// all read as an empty set: a preference is a default the user changed, so
/// "cannot tell" and "not changed" are the same answer to the caller.
pub fn get_all() -> anyhow::Result<Map<String, Value>> {
    let path = path().context("preferences: storage directory is not set")?;
    Ok(read_object(&path))
}

fn read_object(path: &std::path::Path) -> Map<String, Value> {
    let Ok(bytes) = std::fs::read(path) else {
        return Map::new();
    };
    match serde_json::from_slice::<Value>(&bytes) {
        Ok(Value::Object(map)) => map,
        _ => {
            tracing::warn!("preferences file is not a JSON object; ignoring it");
            Map::new()
        }
    }
}

/// Stores `value` under `key`, or removes the key when it is `None`,
/// leaving every other key exactly as it was.
pub fn set(key: &str, value: Option<Value>) -> anyhow::Result<()> {
    let path = path().context("preferences: storage directory is not set")?;
    let state = crate::state::state();
    let _guard = state.prefs.file();
    let mut object = read_object(&path);
    match value {
        Some(value) => {
            object.insert(key.to_owned(), value);
        }
        None => {
            object.remove(key);
        }
    }
    let bytes = serde_json::to_vec(&Value::Object(object))?;
    crate::env::write_atomically(&path, &bytes)
        .with_context(|| format!("write preferences to {path:?}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::with_storage_dir;

    #[test]
    fn a_preference_round_trips_through_storage() {
        with_storage_dir(|dir| {
            assert!(get_all().expect("empty").is_empty());

            set("streamsFlat", Some(Value::Bool(true))).expect("set");
            assert!(dir.join(FILE_NAME).is_file());
            assert_eq!(
                get_all().expect("get").get("streamsFlat"),
                Some(&Value::Bool(true))
            );

            // A second write of the same key replaces it, and reads back as
            // the new value rather than as both.
            set("streamsFlat", Some(Value::Bool(false))).expect("set again");
            assert_eq!(
                get_all().expect("get"),
                Map::from_iter([("streamsFlat".to_owned(), Value::Bool(false))])
            );
        });
    }

    #[test]
    fn other_keys_survive_a_write_and_none_removes() {
        with_storage_dir(|dir| {
            std::fs::write(
                dir.join(FILE_NAME),
                br#"{"fromANewerBuild":{"nested":1},"streamsFlat":false}"#,
            )
            .expect("write");

            set("streamsFlat", Some(Value::Bool(true))).expect("set");
            let stored = get_all().expect("get");
            assert_eq!(stored.get("streamsFlat"), Some(&Value::Bool(true)));
            assert_eq!(
                stored.get("fromANewerBuild"),
                Some(&serde_json::json!({"nested": 1})),
                "a key this build knows nothing about was dropped"
            );

            set("streamsFlat", None).expect("remove");
            let stored = get_all().expect("get");
            assert!(!stored.contains_key("streamsFlat"));
            assert!(stored.contains_key("fromANewerBuild"));
        });
    }

    #[test]
    fn an_unreadable_file_reads_as_no_preferences_and_is_replaced() {
        with_storage_dir(|dir| {
            std::fs::write(dir.join(FILE_NAME), b"{not json").expect("write");
            assert!(get_all().expect("get").is_empty());

            set("streamsFlat", Some(Value::Bool(true))).expect("set");
            assert_eq!(
                get_all().expect("get"),
                Map::from_iter([("streamsFlat".to_owned(), Value::Bool(true))])
            );
        });
    }

    #[test]
    fn without_a_storage_directory_both_sides_fail_loudly() {
        crate::env::without_storage_dir(|| {
            assert!(get_all().is_err());
            assert!(set("streamsFlat", Some(Value::Bool(true))).is_err());
        });
    }
}
