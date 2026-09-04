//! How each installed addon has been answering, counted -- never judged.
//!
//! This side COUNTS and the app JUDGES. Nothing here decides that an addon
//! is broken or useless; it keeps the evidence a verdict could be read off
//! (`AddonHealth.verdict` in Dart) so that the rule and the arithmetic can
//! be changed without a migration, and so a verdict is testable against a
//! table rather than against a live network.
//!
//! ## Three outcomes, never two
//!
//! An answer settles as [`Outcome::Answered`], [`Outcome::Empty`] or
//! [`Outcome::Failed`], and empty is its own bucket on purpose. Folding
//! "the addon answered, with nothing" into "the addon failed" is the bug
//! this record exists to avoid: a public-domain catalog legitimately has
//! nothing for this year's blockbuster, and counting that against it turns
//! a specialist into a broken addon.
//!
//! ## What is kept, and what is deliberately not
//!
//! One [`Record`] per (addon, [`ResourceKind`]) pair, addressed by
//! [`key_for`]: `host[:port]#<12 hex of sha256(transport URL)>`. The URL
//! itself is never stored, and neither is any query string -- a manifest
//! URL can carry a debrid API key, which puts it in the class of things
//! `AGENTS.md` forbids writing down. The hash still separates two
//! configurations of the same addon, because they are two different
//! endpoints and answer differently.
//!
//! Not stored either: the resource id (that would be a viewing history),
//! per-request timestamps, or an error string (a transport error can carry
//! the URL back in its own message).
//!
//! ## Counts decay
//!
//! Every count is a float halving every [`HALF_LIFE_DAYS`] days rather than
//! a lifetime total or a rolling window: one multiply on read and write,
//! constant size, and self-healing, so an addon that was broken for a week
//! in March is not still condemned in June. Two timestamps ride along
//! because a decayed float cannot say *when* it last worked.
//!
//! ## A broken network is recorded against nobody
//!
//! Observations are buffered per [`Sweep`] -- one field's load, all the
//! addons asked at once -- and committed only if at least one of them did
//! not fail. When DNS is down every addon fails together, and that is
//! evidence about the connection, not about the addons. What is on
//! loopback is left out of the sweep entirely ([`is_own_stub`]): this app's
//! own stub answering says nothing about whether the network is up, and
//! nothing about an addon it was never asked to stand for.
//!
//! ## Where it lives
//!
//! In memory, in [`AddonHealthState`] (one field of
//! [`crate::state::AppState`]), behind one mutex whose guard also holds the
//! last-write instant, exactly as the downloads registry throttles its
//! progress writes: reading "when did we last write" under any other lock
//! than the one that writes is a race. Observations touch memory only; the
//! table reaches the disk through the app's generic preferences file
//! ([`PREFS_KEY`]) when it is dirty and the last write is
//! [`FLUSH_INTERVAL`] old, and whatever the throttle says when
//! [`flush_in`] is called. Nothing new crosses FFI: the app reads the same
//! preferences key it already reads.
//!
//! Every entry point takes the [`crate::state::AppState`] it counts into --
//! [`load_in`], [`commit_in`], [`flush_in`] -- the way
//! `crate::server::stop_in` does, and for the same two reasons. The
//! runtime-event pump outlives a shutdown by design, so an event still in
//! flight has to be counted into the state that pump was started for and
//! not into whatever a later `init` installed; and `crate::core::shutdown`
//! takes the state out of the process on its first line, so the flush that
//! makes the last minute of counts survive can only be a flush of the state
//! it is holding. Nothing here reaches for the process global, and a table
//! that [`load_in`] never filled is never written at all, so no late
//! observation can put its one record where the whole record was.
//!
//! Lock order, where both are taken: this table, then the preferences
//! file's lock (inside [`crate::prefs::set`]). Never the other way.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

use crate::state::AppState;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use stremio_core::constants::{
    CATALOG_RESOURCE_NAME, META_RESOURCE_NAME, STREAM_RESOURCE_NAME, SUBTITLES_RESOURCE_NAME,
};
use url::Url;

/// The preferences key the whole table is stored under. The app reads it
/// through the preferences FFI it already has.
pub const PREFS_KEY: &str = "addonHealth";

/// How long a count takes to halve. Two weeks: long enough that a handful
/// of answers still means something a fortnight later, short enough that an
/// addon which was fixed is not argued with for a month.
pub const HALF_LIFE_DAYS: f64 = 14.0;

/// At most this many addons are remembered. A profile holds a few dozen;
/// the cap is what stops a record that only ever grows, and the addon whose
/// newest record is oldest is the one dropped.
pub const MAX_ADDONS: usize = 200;

/// How long an addon that is no longer installed keeps its record, so that
/// uninstalling and reinstalling the same URL in one sitting -- or
/// reinstalling after a sync -- does not start from nothing.
pub const FORGET_UNINSTALLED_AFTER_DAYS: i64 = 30;

/// How long a change waits before it is written out. The same shape as the
/// downloads registry's progress throttle: the table is derived and
/// disposable, so it is not worth a write per answer.
const FLUSH_INTERVAL: Duration = Duration::from_secs(60);

/// Hex characters of the transport URL's digest that go into a key. Six
/// bytes: short enough to read in a preferences file, far more than enough
/// to keep one profile's addons apart.
const KEY_DIGEST_HEX: usize = 12;

/// The port stremio-core's default profile puts the streaming server, and
/// with it the local addon, on. Not read off the running server on purpose:
/// what matters is the port the *profile* believes in, which is where the
/// local addon's transport URL points however the server actually bound.
const DEFAULT_SERVER_PORT: u16 = 11470;

/// The path the streaming server serves the profile's built-in local addon
/// under (`stremio-official-addons`, `protected: true`).
const LOCAL_ADDON_PATH: &str = "/local-addon/";

/// How an addon's answer settled.
///
/// Three, never two: see the module docs. [`Outcome::Empty`] is a working
/// addon that has nothing for this request, which is not a fault.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Outcome {
    /// It answered, with content.
    Answered,
    /// It answered, with nothing.
    Empty,
    /// It did not answer: transport error, or a response that is not the
    /// protocol (which is a broken addon, not a fourth bucket).
    Failed,
}

/// The kinds of request a record is kept per, so that an addon with good
/// streams and a dead catalog reads as exactly that.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum ResourceKind {
    Catalog,
    Meta,
    Stream,
    Subtitles,
}

impl ResourceKind {
    /// The kind a stremio-core `ResourcePath::resource` names, or `None`
    /// for a resource this record does not keep (`addon_catalog`, and
    /// whatever an addon invents).
    pub fn from_resource_name(resource: &str) -> Option<Self> {
        match resource {
            CATALOG_RESOURCE_NAME => Some(Self::Catalog),
            META_RESOURCE_NAME => Some(Self::Meta),
            STREAM_RESOURCE_NAME => Some(Self::Stream),
            SUBTITLES_RESOURCE_NAME => Some(Self::Subtitles),
            _ => None,
        }
    }

    /// The name this kind is stored and read back under -- the same string
    /// stremio-core uses on the wire, so the app can match it against what
    /// a manifest declares without a translation table.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Catalog => CATALOG_RESOURCE_NAME,
            Self::Meta => META_RESOURCE_NAME,
            Self::Stream => STREAM_RESOURCE_NAME,
            Self::Subtitles => SUBTITLES_RESOURCE_NAME,
        }
    }
}

/// What one addon has answered for one resource kind.
///
/// The three counts are decayed floats (see [`decay_factor`]); `updated` is
/// what they were last decayed to, so decay is idempotent and can be
/// applied on every read. `last_ok` and `last_fail` are wall clock because
/// no float can say "it last worked three days ago".
///
/// `last_ok` pairs with `ok` and nothing else: an [`Outcome::Empty`] is not
/// a failure, but it is not proof the addon has anything either, so it
/// moves neither timestamp.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    /// Answers that carried content.
    #[serde(default)]
    pub ok: f64,
    /// Answers that were valid and empty.
    #[serde(default)]
    pub empty: f64,
    /// Requests that did not get an answer.
    #[serde(default)]
    pub fail: f64,
    #[serde(default)]
    pub last_ok: Option<DateTime<Utc>>,
    #[serde(default)]
    pub last_fail: Option<DateTime<Utc>>,
    /// When the counts were last decayed, and the age the cap and the
    /// uninstalled prune sort by.
    pub updated: DateTime<Utc>,
}

impl Record {
    /// An empty record as of `now`.
    pub fn new(now: DateTime<Utc>) -> Self {
        Self {
            ok: 0.0,
            empty: 0.0,
            fail: 0.0,
            last_ok: None,
            last_fail: None,
            updated: now,
        }
    }

    /// Ages the counts to `now`. Idempotent, and a clock that went
    /// backwards ages nothing rather than inflating the counts.
    pub fn decay(&mut self, now: DateTime<Utc>) {
        let factor = decay_factor(now - self.updated);
        self.ok *= factor;
        self.empty *= factor;
        self.fail *= factor;
        self.updated = self.updated.max(now);
    }

    /// Ages the record and adds one answer to it.
    pub fn observe(&mut self, outcome: Outcome, now: DateTime<Utc>) {
        self.decay(now);
        match outcome {
            Outcome::Answered => {
                self.ok += 1.0;
                self.last_ok = Some(now);
            }
            Outcome::Empty => self.empty += 1.0,
            Outcome::Failed => {
                self.fail += 1.0;
                self.last_fail = Some(now);
            }
        }
    }
}

/// What a count is multiplied by after `elapsed`: one half-life halves it.
///
/// Negative elapsed time (a clock correction, a record written by a device
/// whose clock ran ahead) decays nothing.
pub fn decay_factor(elapsed: chrono::Duration) -> f64 {
    let days = elapsed.num_milliseconds() as f64 / 86_400_000.0;
    if days <= 0.0 {
        1.0
    } else {
        0.5_f64.powf(days / HALF_LIFE_DAYS)
    }
}

/// The key an addon's records are held under: `host[:port]#<digest>`.
///
/// The host stays readable so a preferences file can be understood by the
/// person whose file it is; the rest of the URL only ever appears as a
/// digest. **The key never contains a query string** -- that is where a
/// debrid API key lives -- and never the path either. Two configurations of
/// the same addon still get two keys, because the digest is over the whole
/// URL.
///
/// The app derives the same key by hashing `AddonDescriptor.transportUrl`,
/// which is this same normalized URL as it was serialized into the profile.
pub fn key_for(transport_url: &Url) -> String {
    let host = transport_url.host_str().unwrap_or("unknown");
    let port = transport_url
        .port()
        .map(|port| format!(":{port}"))
        .unwrap_or_default();
    let digest = Sha256::digest(transport_url.as_str().as_bytes());
    let mut hash = String::with_capacity(KEY_DIGEST_HEX);
    for byte in digest.iter().take(KEY_DIGEST_HEX / 2) {
        hash.push_str(&format!("{byte:02x}"));
    }
    format!("{host}{port}#{hash}")
}

/// Every addon's records, keyed by [`key_for`].
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Table {
    addons: BTreeMap<String, BTreeMap<ResourceKind, Record>>,
}

impl Table {
    /// Adds one answer, ageing the record it lands in first, and drops the
    /// stalest addon if that put the table over [`MAX_ADDONS`].
    pub fn record(&mut self, key: &str, kind: ResourceKind, outcome: Outcome, now: DateTime<Utc>) {
        self.addons
            .entry(key.to_owned())
            .or_default()
            .entry(kind)
            .or_insert_with(|| Record::new(now))
            .observe(outcome, now);
        self.evict_to_cap();
    }

    /// What is known about one addon, by resource kind.
    pub fn get(&self, key: &str) -> Option<&BTreeMap<ResourceKind, Record>> {
        self.addons.get(key)
    }

    /// How many addons are remembered.
    pub fn len(&self) -> usize {
        self.addons.len()
    }

    pub fn is_empty(&self) -> bool {
        self.addons.is_empty()
    }

    /// The keys remembered, in order.
    pub fn keys(&self) -> impl Iterator<Item = &str> {
        self.addons.keys().map(String::as_str)
    }

    /// Forgets one addon entirely -- what "Forget this addon's history"
    /// deletes when a verdict is wrong.
    pub fn forget(&mut self, key: &str) -> bool {
        self.addons.remove(key).is_some()
    }

    /// Drops every addon that is not in `installed` and whose newest record
    /// is more than [`FORGET_UNINSTALLED_AFTER_DAYS`] old. Answers whether
    /// anything went.
    pub fn prune_uninstalled(&mut self, installed: &BTreeSet<String>, now: DateTime<Utc>) -> bool {
        let cutoff = now - chrono::Duration::days(FORGET_UNINSTALLED_AFTER_DAYS);
        let before = self.addons.len();
        self.addons.retain(|key, kinds| {
            installed.contains(key) || newest(kinds).is_some_and(|u| u > cutoff)
        });
        self.addons.len() != before
    }

    /// Drops the addon whose newest record is oldest until the table fits.
    fn evict_to_cap(&mut self) {
        while self.addons.len() > MAX_ADDONS {
            let Some(stalest) = self
                .addons
                .iter()
                .min_by_key(|(key, kinds)| (newest(kinds), (*key).clone()))
                .map(|(key, _)| key.clone())
            else {
                return;
            };
            self.addons.remove(&stalest);
        }
    }

    /// The table as it is stored: `{key: {resource: record}}`.
    pub fn to_value(&self) -> Value {
        Value::Object(
            self.addons
                .iter()
                .map(|(key, kinds)| {
                    let kinds = kinds
                        .iter()
                        .filter_map(|(kind, record)| {
                            serde_json::to_value(record)
                                .ok()
                                .map(|record| (kind.as_str().to_owned(), record))
                        })
                        .collect();
                    (key.clone(), Value::Object(kinds))
                })
                .collect(),
        )
    }

    /// The table read back, forgivingly: anything that is not a record this
    /// build understands -- a resource kind it does not keep, a record from
    /// a newer shape, a file someone edited -- is skipped rather than
    /// costing the whole table. The record is derived and disposable, so
    /// losing part of it is cheaper than refusing to start with it.
    pub fn from_value(value: &Value) -> Self {
        let mut addons: BTreeMap<String, BTreeMap<ResourceKind, Record>> = BTreeMap::new();
        let Some(object) = value.as_object() else {
            return Self::default();
        };
        for (key, kinds) in object {
            let Some(kinds) = kinds.as_object() else {
                continue;
            };
            let mut parsed = BTreeMap::new();
            for (name, record) in kinds {
                if let (Some(kind), Ok(record)) = (
                    ResourceKind::from_resource_name(name),
                    serde_json::from_value::<Record>(record.clone()),
                ) {
                    parsed.insert(kind, record);
                }
            }
            if !parsed.is_empty() {
                addons.insert(key.clone(), parsed);
            }
        }
        let mut table = Self { addons };
        table.evict_to_cap();
        table
    }
}

/// The newest `updated` among one addon's records.
fn newest(kinds: &BTreeMap<ResourceKind, Record>) -> Option<DateTime<Utc>> {
    kinds.values().map(|record| record.updated).max()
}

/// Whether `base` is this app's own stub rather than an addon on the
/// network: the embedded server, or the profile's built-in local addon.
///
/// Two rules, because the bound-authority check alone is not enough. The
/// local addon keeps the transport URL it was born with,
/// `http://127.0.0.1:11470/local-addon/manifest.json`, and nothing
/// retargets it -- `crate::core::retarget_loopback_server` rewrites the
/// streaming server URL in the settings and not the addon -- so as soon as
/// 11470 is taken by another Stremio and the embedded server falls back to
/// an ephemeral port, or no server is running at all, the local addon stops
/// looking embedded while still being ours.
///
/// Skipping it is not only about refusing to judge a protected addon. A
/// loopback answer is not evidence that the network is up, and
/// [`Sweep::is_evidence`] treats one non-failure as exactly that: with the
/// local addon in the sweep, an outage in which every real addon failed
/// would be charged to every one of them.
///
/// An addon genuinely self-hosted on loopback, on some port that is not the
/// streaming server's, is still recorded: what is skipped is this app's own
/// two endpoints, not everything on this machine.
fn is_own_stub(base: &Url, is_embedded: impl FnOnce(&Url) -> bool) -> bool {
    is_local_addon(base) || is_embedded(base)
}

/// Whether `base` is the streaming server's local addon: on this machine,
/// and either under [`LOCAL_ADDON_PATH`] or on the port the profile expects
/// the server at. Pure, and true whether or not a server is running.
fn is_local_addon(base: &Url) -> bool {
    crate::core::is_loopback(base)
        && (base.path().starts_with(LOCAL_ADDON_PATH)
            || base.port_or_known_default() == Some(DEFAULT_SERVER_PORT))
}

/// One field's worth of settled answers, held back until it is known
/// whether they say anything about the addons at all.
///
/// A board full of catalogs, a details screen's stream addons: they are
/// asked together, and when the network is gone they fail together. A sweep
/// in which *every* addon failed is recorded against nobody -- no
/// reachability probe, no DHT check, just the observation that a result
/// where nothing worked is a result about the connection.
#[derive(Debug, Default)]
pub struct Sweep {
    observed: Vec<(String, ResourceKind, Outcome)>,
}

impl Sweep {
    pub fn new() -> Self {
        Self::default()
    }

    /// Notes one settled answer, unless it came from this app's own stub
    /// rather than from an addon out on the network -- see [`is_own_stub`].
    pub fn observe(&mut self, base: &Url, kind: ResourceKind, outcome: Outcome) {
        self.observe_with(base, kind, outcome, crate::server::is_embedded_url);
    }

    /// [`Sweep::observe`] against a given "is this the embedded server"
    /// answer, so the rule is a pure function and the skip is testable
    /// without starting a server.
    pub fn observe_with(
        &mut self,
        base: &Url,
        kind: ResourceKind,
        outcome: Outcome,
        is_embedded: impl FnOnce(&Url) -> bool,
    ) {
        if is_own_stub(base, is_embedded) {
            return;
        }
        self.observed.push((key_for(base), kind, outcome));
    }

    /// Whether nothing has been observed yet.
    pub fn is_empty(&self) -> bool {
        self.observed.is_empty()
    }

    /// Whether this sweep says anything about the addons: at least one of
    /// them did not fail.
    pub fn is_evidence(&self) -> bool {
        self.observed
            .iter()
            .any(|(_, _, outcome)| *outcome != Outcome::Failed)
    }

    /// Commits the sweep into `table` if it is evidence at all, answering
    /// whether it was. An all-failed sweep -- and an empty one -- changes
    /// nothing.
    pub fn commit_into(self, table: &mut Table, now: DateTime<Utc>) -> bool {
        if !self.is_evidence() {
            return false;
        }
        for (key, kind, outcome) in self.observed {
            table.record(&key, kind, outcome, now);
        }
        true
    }
}

/// The addon-health half of [`crate::state::AppState`]: the table, whether
/// it has unwritten changes, and when it was last written.
///
/// One mutex over all three. `last_write` is a field of what the lock
/// guards rather than a lock of its own, so "is a write due" is answered by
/// the holder of the lock that would do the write -- the same arrangement
/// the downloads registry's progress throttle uses, for the same reason.
#[derive(Default)]
pub struct AddonHealthState {
    counted: Mutex<Counted>,
}

#[derive(Default)]
struct Counted {
    table: Table,
    /// Whether the table has changes the file does not have.
    dirty: bool,
    /// Whether the stored table has been read in yet. A table nobody has
    /// loaded is not "this addon has no history", it is "the history has
    /// not been read", and writing it out would replace the whole stored
    /// record with whatever this process happened to see since it started.
    /// So nothing reaches the disk before [`load_in`].
    loaded: bool,
    /// When the table was last written out -- or loaded, which counts as a
    /// write because the file already holds exactly that, and so keeps the
    /// first observation after a start from rewriting what was read a
    /// moment ago. `None` only while `loaded` is false, and such a table is
    /// never written.
    last_write: Option<Instant>,
}

impl AddonHealthState {
    /// A poisoned lock only means a previous holder panicked; counts are
    /// still counts, so every accessor reads through the poison.
    fn counted(&self) -> MutexGuard<'_, Counted> {
        self.counted
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// Reads the stored table into `app`. Called once at init, beside the
/// bucket hydration, with the state init has just built; a table that
/// cannot be read is simply an empty one.
///
/// Nothing is written out before this has run -- see [`Counted::loaded`].
pub fn load_in(app: &AppState) {
    let table = stored();
    let mut counted = app.addon_health.counted();
    counted.table = table;
    counted.dirty = false;
    counted.loaded = true;
    counted.last_write = Some(Instant::now());
}

/// Commits one sweep into `app` and writes the table out if a write is
/// due. Answers whether the sweep was recorded (see [`Sweep::commit_into`]).
pub fn commit_in(app: &AppState, sweep: Sweep) -> bool {
    let mut counted = app.addon_health.counted();
    let now = Utc::now();
    if !sweep.commit_into(&mut counted.table, now) {
        return false;
    }
    counted.dirty = true;
    flush_locked(&mut counted, false);
    true
}

/// What has been counted into `app` so far.
///
/// A copy: the table is small, and handing out the lock's contents would
/// make every reader a writer's problem. This is how the record is read
/// back without going through the preferences file -- which is what a test
/// wants, and what an FFI read would want if the app ever needs one that
/// does not wait for a flush.
pub fn table_in(app: &AppState) -> Table {
    app.addon_health.counted().table.clone()
}

/// Forgets the addons that are no longer installed and have not been for a
/// while. `installed` is [`key_for`] over every addon in the profile.
pub fn prune_uninstalled_in(app: &AppState, installed: &BTreeSet<String>) {
    let mut counted = app.addon_health.counted();
    if counted.table.prune_uninstalled(installed, Utc::now()) {
        counted.dirty = true;
        flush_locked(&mut counted, false);
    }
}

/// Writes the table out now, whatever the throttle says: shutdown, and the
/// app going to the background.
///
/// It takes the state rather than looking one up, because the caller that
/// most needs it is `crate::core::shutdown`, which has already taken the
/// state out of the process by the time it gets here.
pub fn flush_in(app: &AppState) {
    let mut counted = app.addon_health.counted();
    flush_locked(&mut counted, true);
}

/// Stores the table under [`PREFS_KEY`] when it has been loaded, is dirty,
/// and is either `force`d or [`FLUSH_INTERVAL`] old. Asked with the table's
/// lock held, which is what makes reading `last_write` here honest.
fn flush_locked(counted: &mut Counted, force: bool) {
    // Not even `force` writes a table that was never read: it would be
    // this process's few observations in place of the whole record.
    if !counted.loaded || !counted.dirty {
        return;
    }
    if !force
        && counted
            .last_write
            .is_some_and(|last| last.elapsed() < FLUSH_INTERVAL)
    {
        return;
    }
    let value = counted.table.to_value();
    counted.last_write = Some(Instant::now());
    match crate::prefs::set(PREFS_KEY, Some(value)) {
        // Still dirty on failure: the next flush tries again, and the
        // throttle above keeps a broken storage directory from being
        // written to on every answer.
        Err(error) => tracing::warn!(%error, "could not store how the addons have been answering"),
        Ok(()) => counted.dirty = false,
    }
}

/// The stored table, or an empty one when there is nothing to read.
fn stored() -> Table {
    match crate::prefs::get_all() {
        Ok(preferences) => preferences.get(PREFS_KEY).map(Table::from_value),
        Err(error) => {
            tracing::debug!(%error, "no stored addon health record");
            None
        }
    }
    .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;

    /// A manifest URL carrying what a debrid addon's configuration looks
    /// like: the half that must never be written down.
    const WITH_TOKEN: &str = "https://addons.example.com/manifest.json?apikey=SUPERSECRET";

    fn url(url: &str) -> Url {
        Url::parse(url).expect("parse")
    }

    fn now() -> DateTime<Utc> {
        DateTime::parse_from_rfc3339("2026-09-04T12:00:00Z")
            .expect("parse")
            .with_timezone(&Utc)
    }

    fn days(days: i64) -> chrono::Duration {
        chrono::Duration::days(days)
    }

    /// Five addons' worth of history, as it sits in the preferences file
    /// before this process starts: the record a late observation must not
    /// be allowed to replace.
    fn seeded_history() -> Value {
        let mut table = Table::default();
        for index in 0..5 {
            table.record(
                &format!("seeded{index}.example.com#{index:012x}"),
                ResourceKind::Catalog,
                Outcome::Answered,
                now() - days(1),
            );
        }
        table.to_value()
    }

    /// One addon answering, which is a sweep worth committing.
    fn one_answer(base: &Url) -> Sweep {
        let mut sweep = Sweep::new();
        sweep.observe_with(base, ResourceKind::Catalog, Outcome::Answered, |_| false);
        sweep
    }

    fn stored_keys() -> Vec<String> {
        stored().keys().map(str::to_owned).collect()
    }

    fn record_of(table: &Table, key: &str, kind: ResourceKind) -> Record {
        table
            .get(key)
            .and_then(|kinds| kinds.get(&kind))
            .cloned()
            .unwrap_or_else(|| panic!("no {kind:?} record for {key}"))
    }

    #[test]
    fn a_count_halves_after_one_half_life() {
        let mut record = Record::new(now());
        for _ in 0..8 {
            record.observe(Outcome::Answered, now());
        }
        assert_eq!(record.ok, 8.0);

        record.decay(now() + days(14));
        assert!(
            (record.ok - 4.0).abs() < 1e-9,
            "{} after 14 days",
            record.ok
        );

        record.decay(now() + days(28));
        assert!(
            (record.ok - 2.0).abs() < 1e-9,
            "{} after 28 days",
            record.ok
        );

        // Decaying is what `updated` is for: two seven-day steps age a
        // count exactly as far as one fourteen-day step, so applying it on
        // every read cannot compound.
        let mut stepwise = Record::new(now());
        stepwise.ok = 8.0;
        stepwise.decay(now() + days(7));
        stepwise.decay(now() + days(14));
        assert!((stepwise.ok - 4.0).abs() < 1e-9, "{}", stepwise.ok);
    }

    #[test]
    fn a_clock_that_went_backwards_ages_nothing() {
        let mut record = Record::new(now());
        record.observe(Outcome::Answered, now());
        record.decay(now() - days(30));
        assert_eq!(record.ok, 1.0);
        assert_eq!(record.updated, now(), "the newer timestamp was thrown away");
    }

    #[test]
    fn an_empty_answer_is_its_own_bucket_and_not_a_failure() {
        let mut record = Record::new(now());
        record.observe(Outcome::Empty, now());

        assert_eq!(record.empty, 1.0);
        assert_eq!(record.fail, 0.0, "an empty answer was counted as a failure");
        assert_eq!(record.ok, 0.0);
        // It answered, so nothing failed; it had nothing, so nothing worked.
        assert_eq!(record.last_fail, None);
        assert_eq!(record.last_ok, None);
    }

    #[test]
    fn the_key_never_carries_the_url_or_its_query() {
        let key = key_for(&url(WITH_TOKEN));

        assert!(!key.contains('?'), "{key} carries a query string");
        assert!(!key.contains("SUPERSECRET"), "{key} carries the api key");
        assert!(!key.contains("apikey"), "{key} names the api key");
        assert!(!key.contains("manifest"), "{key} carries the path");
        assert!(
            key.starts_with("addons.example.com#"),
            "{key} does not name the host"
        );
        assert_eq!(key.len(), "addons.example.com#".len() + KEY_DIGEST_HEX);
        assert!(
            key.rsplit('#').next().is_some_and(|hash| hash
                .chars()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())),
            "{key} does not end in lowercase hex"
        );
    }

    #[test]
    fn two_configurations_of_one_addon_are_two_records() {
        let plain = key_for(&url("https://addons.example.com/manifest.json"));
        let configured = key_for(&url(WITH_TOKEN));
        let other_token = key_for(&url(
            "https://addons.example.com/manifest.json?apikey=ANOTHERONE",
        ));

        assert_ne!(plain, configured, "the query is not part of the digest");
        assert_ne!(configured, other_token);
        // Same host, so the readable half still says which addon it is.
        assert!(plain.starts_with("addons.example.com#"));
        assert!(configured.starts_with("addons.example.com#"));
    }

    #[test]
    fn the_key_is_the_digest_the_app_computes() {
        // sha256("https://addons.example.com/manifest.json"), first 12 hex
        // characters: the Dart side hashes the same string, so this pins
        // what the two must agree on.
        assert_eq!(
            key_for(&url("https://addons.example.com/manifest.json")),
            "addons.example.com#810b3d5448bc"
        );
        // A port is part of the readable half, so two addons on one host
        // are told apart at a glance.
        assert!(
            key_for(&url("http://127.0.0.1:11470/manifest.json")).starts_with("127.0.0.1:11470#")
        );
    }

    #[test]
    fn a_sweep_in_which_everything_failed_is_recorded_against_nobody() {
        let mut sweep = Sweep::new();
        sweep.observe_with(
            &url("https://one.example.com/manifest.json"),
            ResourceKind::Catalog,
            Outcome::Failed,
            |_| false,
        );
        sweep.observe_with(
            &url("https://two.example.com/manifest.json"),
            ResourceKind::Catalog,
            Outcome::Failed,
            |_| false,
        );

        let mut table = Table::default();
        assert!(!sweep.commit_into(&mut table, now()));
        assert!(
            table.is_empty(),
            "a broken network was recorded against the addons"
        );
    }

    #[test]
    fn a_sweep_that_observed_nothing_records_nothing() {
        let mut table = Table::default();
        let sweep = Sweep::new();
        assert!(sweep.is_empty());
        assert!(!sweep.commit_into(&mut table, now()));
        assert!(table.is_empty());
    }

    #[test]
    fn a_mixed_sweep_records_every_answer_in_it() {
        let answered = url("https://good.example.com/manifest.json");
        let empty = url("https://specialist.example.com/manifest.json");
        let failed = url("https://dead.example.com/manifest.json");

        let mut sweep = Sweep::new();
        sweep.observe_with(&answered, ResourceKind::Catalog, Outcome::Answered, |_| {
            false
        });
        sweep.observe_with(&empty, ResourceKind::Catalog, Outcome::Empty, |_| false);
        sweep.observe_with(&failed, ResourceKind::Catalog, Outcome::Failed, |_| false);

        let mut table = Table::default();
        assert!(sweep.commit_into(&mut table, now()));
        assert_eq!(table.len(), 3);

        let answered = record_of(&table, &key_for(&answered), ResourceKind::Catalog);
        assert_eq!(answered.ok, 1.0);
        assert_eq!(answered.last_ok, Some(now()));

        let empty = record_of(&table, &key_for(&empty), ResourceKind::Catalog);
        assert_eq!((empty.ok, empty.empty, empty.fail), (0.0, 1.0, 0.0));

        // One addon did answer, so this sweep is evidence, and the addon
        // that failed inside it is counted as having failed.
        let failed = record_of(&table, &key_for(&failed), ResourceKind::Catalog);
        assert_eq!(failed.fail, 1.0);
        assert_eq!(failed.last_fail, Some(now()));
    }

    #[test]
    fn one_addon_is_counted_per_resource_kind() {
        let base = url("https://mixed.example.com/manifest.json");
        let mut sweep = Sweep::new();
        sweep.observe_with(&base, ResourceKind::Stream, Outcome::Answered, |_| false);
        sweep.observe_with(&base, ResourceKind::Catalog, Outcome::Failed, |_| false);

        let mut table = Table::default();
        assert!(sweep.commit_into(&mut table, now()));

        assert_eq!(table.len(), 1, "one addon is one key");
        let key = key_for(&base);
        assert_eq!(record_of(&table, &key, ResourceKind::Stream).ok, 1.0);
        assert_eq!(record_of(&table, &key, ResourceKind::Catalog).fail, 1.0);
        assert_eq!(
            record_of(&table, &key, ResourceKind::Stream).fail,
            0.0,
            "a dead catalog was counted against the streams"
        );
    }

    #[test]
    fn the_embedded_server_is_never_recorded_against() {
        let embedded = url("http://127.0.0.1:11470/manifest.json");
        let addon = url("https://good.example.com/manifest.json");

        let mut sweep = Sweep::new();
        sweep.observe_with(
            &embedded,
            ResourceKind::Catalog,
            Outcome::Failed,
            |candidate| *candidate == embedded,
        );
        sweep.observe_with(
            &addon,
            ResourceKind::Catalog,
            Outcome::Answered,
            |candidate| *candidate == embedded,
        );

        let mut table = Table::default();
        assert!(sweep.commit_into(&mut table, now()));
        assert_eq!(
            table.keys().collect::<Vec<_>>(),
            vec![key_for(&addon).as_str()],
            "the local addon was judged"
        );
    }

    #[test]
    fn an_embedded_only_sweep_is_not_evidence_about_anything() {
        let embedded = url("http://127.0.0.1:11470/manifest.json");
        let mut sweep = Sweep::new();
        sweep.observe_with(&embedded, ResourceKind::Catalog, Outcome::Answered, |_| {
            true
        });

        let mut table = Table::default();
        assert!(sweep.is_empty());
        assert!(!sweep.commit_into(&mut table, now()));
        assert!(table.is_empty());
    }

    #[test]
    fn the_local_addon_is_skipped_wherever_the_embedded_server_bound() {
        // 11470 was taken by another Stremio, so the embedded server fell
        // back to an ephemeral port -- but the profile's local addon still
        // carries the transport URL it was born with.
        let embedded = url("http://127.0.0.1:40503/");
        let local_addon = url("http://127.0.0.1:11470/local-addon/manifest.json");
        let remote = url("https://cinemeta.example.com/manifest.json");
        let bound_where_it_says = |candidate: &Url| candidate.port() == embedded.port();

        // Wi-Fi is gone: every addon out on the network fails, and the one
        // on loopback answers because loopback never left.
        let mut sweep = Sweep::new();
        sweep.observe_with(
            &local_addon,
            ResourceKind::Catalog,
            Outcome::Answered,
            bound_where_it_says,
        );
        sweep.observe_with(
            &remote,
            ResourceKind::Catalog,
            Outcome::Failed,
            bound_where_it_says,
        );

        let mut table = Table::default();
        assert!(
            !sweep.commit_into(&mut table, now()),
            "an answer from our own loopback stub was read as a working network"
        );
        assert!(
            table.is_empty(),
            "a connection outage was charged to the addons"
        );
    }

    #[test]
    fn the_local_addon_is_skipped_with_no_server_running_at_all() {
        // No handle, so nothing is the embedded server as far as
        // `server::is_embedded_url` is concerned.
        let no_server = |_: &Url| false;
        for base in [
            "http://127.0.0.1:11470/local-addon/manifest.json",
            "http://localhost:11470/local-addon/manifest.json",
            "http://[::1]:11470/local-addon/manifest.json",
            // The port alone is enough: whatever the server serves on the
            // port the profile expects it at is ours, not an addon.
            "http://127.0.0.1:11470/manifest.json",
            // And the path alone is, for a server moved to another port.
            "http://127.0.0.1:40503/local-addon/manifest.json",
        ] {
            let mut sweep = Sweep::new();
            sweep.observe_with(
                &url(base),
                ResourceKind::Catalog,
                Outcome::Failed,
                no_server,
            );
            assert!(sweep.is_empty(), "{base} was recorded against");
        }
    }

    #[test]
    fn an_addon_hosted_on_this_machine_is_still_an_addon() {
        // Not the streaming server's port and not its local addon: someone
        // running their own addon next to the app is measured like any
        // other, and only this app's own two endpoints are skipped.
        let mine = url("http://127.0.0.1:7000/manifest.json");
        let mut sweep = Sweep::new();
        sweep.observe_with(&mine, ResourceKind::Stream, Outcome::Answered, |_| false);

        let mut table = Table::default();
        assert!(sweep.commit_into(&mut table, now()));
        assert_eq!(table.keys().collect::<Vec<_>>(), vec![key_for(&mine)]);
    }

    #[test]
    fn the_table_drops_its_stalest_addon_at_the_cap() {
        let mut table = Table::default();
        for index in 0..MAX_ADDONS {
            table.record(
                &format!("addon{index}.example.com#{index:012x}"),
                ResourceKind::Catalog,
                Outcome::Answered,
                now() + chrono::Duration::seconds(index as i64),
            );
        }
        assert_eq!(table.len(), MAX_ADDONS);
        let stalest = format!("addon0.example.com#{:012x}", 0);
        assert!(table.get(&stalest).is_some());

        table.record(
            "newcomer.example.com#000000000000",
            ResourceKind::Stream,
            Outcome::Answered,
            now() + days(1),
        );

        assert_eq!(table.len(), MAX_ADDONS, "the cap did not hold");
        assert!(
            table.get(&stalest).is_none(),
            "the stalest addon survived the cap"
        );
        assert!(
            table.get("newcomer.example.com#000000000000").is_some(),
            "the newest answer was the one dropped"
        );
        let second = format!("addon1.example.com#{:012x}", 1);
        assert!(table.get(&second).is_some(), "more than one addon went");
    }

    #[test]
    fn an_uninstalled_addon_is_forgotten_only_once_it_is_stale() {
        let installed_key = "installed.example.com#000000000001";
        let recent_key = "recent.example.com#000000000002";
        let ancient_key = "ancient.example.com#000000000003";

        let mut table = Table::default();
        for (key, at) in [
            (installed_key, now() - days(90)),
            (recent_key, now() - days(5)),
            (ancient_key, now() - days(31)),
        ] {
            table.record(key, ResourceKind::Catalog, Outcome::Answered, at);
        }

        let installed = BTreeSet::from([installed_key.to_owned()]);
        assert!(table.prune_uninstalled(&installed, now()));

        assert!(
            table.get(installed_key).is_some(),
            "an installed addon was forgotten for being quiet"
        );
        assert!(
            table.get(recent_key).is_some(),
            "an addon uninstalled five days ago was forgotten too soon"
        );
        assert!(table.get(ancient_key).is_none());

        // Nothing left to prune is not a change.
        assert!(!table.prune_uninstalled(&installed, now()));
    }

    #[test]
    fn forgetting_one_addon_leaves_the_others() {
        let mut table = Table::default();
        table.record(
            "a.example.com#0",
            ResourceKind::Meta,
            Outcome::Answered,
            now(),
        );
        table.record(
            "b.example.com#1",
            ResourceKind::Meta,
            Outcome::Answered,
            now(),
        );

        assert!(table.forget("a.example.com#0"));
        assert!(!table.forget("a.example.com#0"));
        assert_eq!(table.keys().collect::<Vec<_>>(), vec!["b.example.com#1"]);
    }

    #[test]
    fn a_table_round_trips_through_what_is_stored() {
        let mut table = Table::default();
        table.record(
            "a.example.com#0",
            ResourceKind::Stream,
            Outcome::Answered,
            now(),
        );
        table.record(
            "a.example.com#0",
            ResourceKind::Stream,
            Outcome::Empty,
            now(),
        );
        table.record(
            "a.example.com#0",
            ResourceKind::Catalog,
            Outcome::Failed,
            now(),
        );
        table.record(
            "b.example.com#1",
            ResourceKind::Subtitles,
            Outcome::Empty,
            now(),
        );

        let stored = table.to_value();
        assert_eq!(
            stored["a.example.com#0"]["stream"]["ok"],
            serde_json::json!(1.0)
        );
        assert_eq!(stored["a.example.com#0"]["stream"]["lastFail"], Value::Null);
        assert_eq!(Table::from_value(&stored), table);
    }

    #[test]
    fn an_unreadable_record_costs_that_record_and_no_more() {
        let stored = serde_json::json!({
            "good.example.com#0": {
                "stream": {"ok": 3.0, "empty": 1.0, "fail": 0.0, "updated": "2026-09-04T12:00:00Z"},
                // A resource this build keeps no record for.
                "addon_catalog": {"ok": 9.0, "updated": "2026-09-04T12:00:00Z"},
                // A record with no `updated` cannot be decayed honestly.
                "meta": {"ok": 9.0}
            },
            "junk.example.com#1": "not an object",
            "empty.example.com#2": {}
        });

        let table = Table::from_value(&stored);

        assert_eq!(table.keys().collect::<Vec<_>>(), vec!["good.example.com#0"]);
        let kinds = table.get("good.example.com#0").expect("kinds");
        assert_eq!(
            kinds.keys().collect::<Vec<_>>(),
            vec![&ResourceKind::Stream]
        );
        assert_eq!(kinds[&ResourceKind::Stream].ok, 3.0);
    }

    #[test]
    fn anything_that_is_not_a_table_reads_as_no_history() {
        assert!(Table::from_value(&Value::Null).is_empty());
        assert!(Table::from_value(&serde_json::json!("nope")).is_empty());
    }

    #[test]
    fn a_table_that_was_never_loaded_is_never_written() {
        crate::env::with_storage_dir(|_| {
            crate::prefs::set(PREFS_KEY, Some(seeded_history())).expect("seed");
            let before = stored_keys();
            assert_eq!(before.len(), 5);

            // A state nothing has loaded into: what a commit that runs
            // before `load_in` holds, and what a state built after a
            // shutdown looks like. Its table is empty, and empty here means
            // "not read", not "no history".
            let app = AppState::default();
            assert!(commit_in(
                &app,
                one_answer(&url("https://late.example.com/manifest.json"))
            ));

            assert_eq!(
                stored_keys(),
                before,
                "one observation replaced the whole stored record"
            );
        });
    }

    #[test]
    fn a_sweep_that_arrives_after_a_shutdown_still_counts_into_its_own_state() {
        crate::env::with_storage_dir(|_| {
            crate::prefs::set(PREFS_KEY, Some(seeded_history())).expect("seed");

            // A state the process does not hold -- which is what the
            // runtime-event pump is left with the moment `core::shutdown`
            // takes the state out on its first line. It goes on delivering
            // into the state it was started for, and that state's counts
            // are the ones that have to reach the file.
            let app = Arc::new(AppState::default());
            assert!(!crate::state::is_current(&app), "not a retired state");
            load_in(&app);

            let late = url("https://late.example.com/manifest.json");
            assert!(commit_in(&app, one_answer(&late)));
            flush_in(&app);

            let keys = stored_keys();
            assert_eq!(
                keys.len(),
                6,
                "the seeded history did not survive: {keys:?}"
            );
            assert!(keys.contains(&key_for(&late)), "the late sweep was lost");
            assert!(keys.contains(&"seeded0.example.com#000000000000".to_owned()));
        });
    }

    #[test]
    fn an_answer_waits_for_the_flush_the_shutdown_asks_for() {
        crate::env::with_storage_dir(|_| {
            let app = Arc::new(AppState::default());
            assert!(!crate::state::is_current(&app), "not a retired state");
            load_in(&app);

            let addon = url("https://good.example.com/manifest.json");
            assert!(commit_in(&app, one_answer(&addon)));
            assert!(
                stored_keys().is_empty(),
                "a write per answer: the throttle did not hold"
            );

            flush_in(&app);
            assert_eq!(stored_keys(), vec![key_for(&addon)]);

            // Written is not dirty: a second flush has nothing to say.
            crate::prefs::set(PREFS_KEY, None).expect("clear");
            flush_in(&app);
            assert!(stored_keys().is_empty(), "a clean table was written again");
        });
    }

    #[test]
    fn only_the_resources_a_record_is_kept_for_are_named() {
        assert_eq!(
            ResourceKind::from_resource_name("catalog"),
            Some(ResourceKind::Catalog)
        );
        assert_eq!(
            ResourceKind::from_resource_name("meta"),
            Some(ResourceKind::Meta)
        );
        assert_eq!(
            ResourceKind::from_resource_name("stream"),
            Some(ResourceKind::Stream)
        );
        assert_eq!(
            ResourceKind::from_resource_name("subtitles"),
            Some(ResourceKind::Subtitles)
        );
        assert_eq!(ResourceKind::from_resource_name("addon_catalog"), None);
        assert_eq!(ResourceKind::from_resource_name(""), None);
        assert_eq!(ResourceKind::Stream.as_str(), "stream");
    }
}
