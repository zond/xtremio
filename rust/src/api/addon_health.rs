//! FRB surface for the addon-health record: the counts out, and one
//! addon's history dropped.
//!
//! Two calls, both thin over [`crate::addon_health`]. The counts are stored
//! in the preferences file the app can already read, but neither of these
//! goes through it:
//!
//! - **Reading** comes out of memory, so the Addons screen shows the
//!   answers since the last flush too. The file is up to a minute behind on
//!   purpose (the throttle), and "not used yet" about an addon used a
//!   minute ago is a worse answer than none.
//! - **Forgetting** has to reach the live table, because a preferences
//!   write from the app would be overwritten by this process's next flush.
//!
//! Nothing secret crosses here. A record is addressed by
//! `crate::addon_health::key_for`'s `host[:port]#<digest>` key, never by a
//! transport URL -- a manifest URL can carry a debrid API key, and
//! `AGENTS.md` puts that in the class of things that are never written
//! down. The app derives the same key by hashing the transport URL it
//! already holds, so the URL never leaves the profile.

use flutter_rust_bridge::frb;

use crate::guard::guarded;

/// How every addon has been answering, as one JSON object.
///
/// `addons` maps a record key to that addon's resource kinds, and each of
/// those to `{"ok","empty","fail","lastOk","lastFail","updated"}`.
///
/// `ok`/`empty`/`fail` are decayed counts as of `updated`, and the app ages
/// them the rest of the way to now; the three are separate because "the
/// addon answered with nothing" is not "the addon failed". `resource` is
/// `catalog`, `meta`, `stream` or `subtitles`.
///
/// `everyAnswerFailed` is true when nothing has answered at all since this
/// run started, which is a statement about the connection rather than about
/// any addon -- such a sweep is recorded against nobody, so it leaves no
/// trace in the counts and has to be reported separately.
///
/// Sync: one lock, a clone of at most a couple of hundred small records and
/// no I/O. Empty before `core_init` and after `shutdown`.
#[frb(sync)]
pub fn addon_health_report() -> anyhow::Result<String> {
    guarded(|| serde_json::to_string(&crate::addon_health::report()).map_err(Into::into))
}

/// Drops everything recorded about one addon, answering whether there was
/// anything to drop.
///
/// `key` is the record's key, not a URL. Writes the table out at once
/// rather than waiting for the flush throttle, so the record cannot come
/// back after a restart either. Async: it fsyncs and renames the
/// preferences file.
pub fn addon_health_forget(key: String) -> anyhow::Result<bool> {
    guarded(|| Ok(crate::addon_health::forget(&key)))
}
