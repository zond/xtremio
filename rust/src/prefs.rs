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
//! costs a layout choice and not the app -- but it is moved aside first
//! (`xtremio_prefs.json.corrupt-<seconds>`, `crate::env::move_aside`), so
//! the next write starts a fresh file beside the bytes rather than over
//! them. A file the disk will not *read* is a different thing: nothing says
//! its contents are bad, so a read answers with the error and a write
//! refuses, instead of "nothing set" letting one key be written over every
//! other -- which is what an `EIO` on an ageing flash chip, or a
//! file-descriptor shortage under a busy swarm, used to cost: the whole
//! file, silently.
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
/// A missing file and one holding anything but an object both read as an
/// empty set: a preference is a default the user changed, so "not there"
/// and "not changed" are the same answer to the caller. A file the disk
/// will not read is not the same answer -- that is "cannot tell" -- and
/// comes back as the error, so nobody writes a default over what could not
/// be seen.
pub fn get_all() -> anyhow::Result<Map<String, Value>> {
    let path = path().context("preferences: storage directory is not set")?;
    read_object(&path)
}

/// The file as an object: empty when it is not there or will not parse
/// (moved aside first, see the module docs), an error when it cannot be
/// read at all.
fn read_object(path: &std::path::Path) -> anyhow::Result<Map<String, Value>> {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Map::new()),
        Err(error) => anyhow::bail!("read preferences from {path:?}: {error}"),
    };
    match serde_json::from_slice::<Value>(&bytes) {
        Ok(Value::Object(map)) => Ok(map),
        parsed => {
            let reason = parsed
                .err()
                .map(|error| error.to_string())
                .unwrap_or_else(|| "the file is not a JSON object".to_owned());
            match crate::env::move_aside(path) {
                Ok(_) => tracing::warn!(
                    reason,
                    "preferences file is unreadable; moved aside and starting empty"
                ),
                Err(error) => tracing::warn!(
                    reason,
                    %error,
                    "preferences file is unreadable and could not be moved aside; starting empty"
                ),
            }
            Ok(Map::new())
        }
    }
}

/// Stores `value` under `key`, or removes the key when it is `None`,
/// leaving every other key exactly as it was.
///
/// Serialized on the process state's file lock, which is what an FFI
/// caller wants; a caller that is already holding a state writes into that
/// one with [`set_in`].
pub fn set(key: &str, value: Option<Value>) -> anyhow::Result<()> {
    set_in(&crate::state::state(), key, value)
}

/// [`set`] into the file lock of a state the caller already has.
///
/// `crate::core::shutdown` takes the state out of the process on its first
/// line and *then* flushes the addon-health table through here. Looking the
/// state up at that point would build a fresh one and leave it in the
/// process static -- undoing the `take` -- and would lock a mutex nobody
/// else holds, so a concurrent FFI [`set`] that started before the `take`
/// would be doing its own read-modify-write of the same file at the same
/// time and one of the two keys would be lost. The state comes in as an
/// argument for the same reason `crate::server::stop_in` takes one.
///
/// A file that cannot be read refuses the write: the read-modify-write has
/// nothing to modify, and writing the one key anyway is how a transient
/// read failure became a file holding nothing else.
pub(crate) fn set_in(
    app: &crate::state::AppState,
    key: &str,
    value: Option<Value>,
) -> anyhow::Result<()> {
    let path = path().context("preferences: storage directory is not set")?;
    let _guard = app.prefs.file();
    let mut object = read_object(&path)?;
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

    fn moved_aside(dir: &std::path::Path) -> Vec<PathBuf> {
        std::fs::read_dir(dir)
            .expect("read dir")
            .filter_map(|entry| entry.ok().map(|entry| entry.path()))
            .filter(|path| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with("xtremio_prefs.json.corrupt-"))
            })
            .collect()
    }

    /// A file that will not parse reads as nothing set and the next write
    /// starts over -- beside the bytes, which are moved aside first rather
    /// than written over.
    #[test]
    fn a_file_that_will_not_parse_is_moved_aside_and_reads_as_empty() {
        with_storage_dir(|dir| {
            std::fs::write(dir.join(FILE_NAME), b"{not json").expect("write");
            assert!(get_all().expect("get").is_empty());
            let aside = moved_aside(dir);
            assert_eq!(aside.len(), 1, "{aside:?}");
            assert_eq!(std::fs::read(&aside[0]).expect("read aside"), b"{not json");
            assert!(
                !dir.join(FILE_NAME).exists(),
                "out of the way of the next write"
            );

            set("streamsFlat", Some(Value::Bool(true))).expect("set");
            assert_eq!(
                get_all().expect("get"),
                Map::from_iter([("streamsFlat".to_owned(), Value::Bool(true))])
            );
            assert_eq!(
                std::fs::read(&aside[0]).expect("read aside"),
                b"{not json",
                "and the write did not touch what was moved"
            );
        });
    }

    /// A file the disk will not read is neither empty nor replaceable: the
    /// read is an error, the write is refused, and the file is as it was.
    /// A directory under the file's name is what makes the read fail on
    /// every platform.
    #[test]
    fn a_file_the_disk_will_not_read_refuses_both_a_read_and_a_write() {
        with_storage_dir(|dir| {
            std::fs::create_dir(dir.join(FILE_NAME)).expect("mkdir");
            let error = get_all().expect_err("a read failure is not an empty set");
            assert!(error.to_string().contains("read preferences"), "{error}");
            assert!(
                set("streamsFlat", Some(Value::Bool(true))).is_err(),
                "and nothing writes a default over what could not be read"
            );
            assert!(
                moved_aside(dir).is_empty(),
                "nothing was moved aside either"
            );
            assert!(dir.join(FILE_NAME).is_dir());
        });
    }

    /// The case the owner met: the file is there and full, and the read is
    /// refused by permissions (an `EIO` reads the same way). A `set` used to
    /// answer `Ok` and leave the file holding its one key.
    #[cfg(unix)]
    #[test]
    fn a_full_file_the_read_is_refused_on_keeps_every_key() {
        use std::os::unix::fs::PermissionsExt;

        with_storage_dir(|dir| {
            let file = dir.join(FILE_NAME);
            let full = br#"{"subtitleSync":{"a":1},"addonHealth":{"b":2},"focusEmphasis":"bold"}"#;
            std::fs::write(&file, full).expect("write");
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o000)).expect("chmod");
            let restore = || {
                std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600))
                    .expect("chmod back");
            };
            if std::fs::read(&file).is_ok() {
                // Running as root, where no mode refuses a read: there is
                // nothing this test can provoke here.
                restore();
                return;
            }

            assert!(get_all().is_err(), "the read is refused, not empty");
            let result = set("streamsFlat", Some(Value::Bool(true)));
            restore();
            assert!(result.is_err(), "so the write is refused too");
            assert_eq!(
                std::fs::read(&file).expect("read"),
                full,
                "and every key is still there"
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
