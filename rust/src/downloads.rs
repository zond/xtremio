//! The offline-downloads registry: what the app asked to keep on disk.
//!
//! The server owns the *pins* (which file of which torrent stays wanted and
//! evictable-never, `stream_server::ServerHandle::pin_download`); this module
//! owns everything the server has no idea about — which meta and video a
//! download belongs to, the raw stream JSON `Load Player` takes back, the
//! meta snapshot the Details and Downloads screens render offline, and when
//! the file was added, finished and last played.
//!
//! It lives in `<storage_dir>/downloads.json` next to stremio-core's buckets
//! and is written with the same atomic writer (`crate::env::write_atomically`),
//! so a crash mid-write cannot leave half a registry. Reading is
//! forward-compatible on purpose: a file from a newer build keeps its
//! `version` and its unknown keys (they round-trip through
//! [`Entry::extra`]), an entry this build cannot parse is dropped with a
//! warning, and a corrupt file starts an empty registry rather than failing
//! init.
//!
//! Live progress is not stored by the server per download either: it comes
//! from `ServerHandle::downloads()` and is merged in by [`refresh`], which
//! the FFI list call and the ~1 Hz [`ticker`] both use.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard, RwLock, RwLockReadGuard, RwLockWriteGuard};
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize};
use stream_server::{DownloadInfo, PinDownloadError};

use crate::state::AppState;

/// Schema version of `downloads.json`. A file that names a higher one is
/// read anyway (unknown keys survive in [`Entry::extra`]) and keeps its
/// version when written back, so a downgrade does not silently claim the
/// newer file is this build's shape.
pub const VERSION: u32 = 1;

/// The registry file, under `crate::env::storage_dir()`.
const FILE_NAME: &str = "downloads.json";

/// How often [`ticker`] merges live progress while anything is unfinished.
const TICK: Duration = Duration::from_secs(1);

/// How long a change to nothing but `downloaded` may wait for the disk.
///
/// The registry's byte count is a cache of the server's own -- [`refresh`]
/// merges it in, and the app never computes progress itself -- so what a
/// skipped write costs is a stale number in a listing taken with no server
/// to ask, until the next write that matters. What writing every tick costs
/// is a whole-file rewrite and an fsync per second for the length of a
/// download, on a phone. Anything that is not a byte count -- a state, a
/// path, an error, a finished file -- goes to disk at once.
const PROGRESS_WRITE_INTERVAL: Duration = Duration::from_secs(30);

/// How long [`resolve_media_file`] waits for the file list of a stream that
/// names no `fileIdx`. The same wait the server gives a magnet's metadata
/// (`enginefs::METADATA_RESOLVE_TIMEOUT`, which it does not re-export), so
/// such a stream is no slower to refuse than the pin itself would be.
const METADATA_WAIT: Duration = Duration::from_secs(90);

/// How often [`resolve_media_file`] re-asks while that wait runs.
const METADATA_POLL: Duration = Duration::from_millis(250);

/// Receives one serialized progress payload; returns `false` once closed.
pub type EventSink = Box<dyn Fn(String) -> bool + Send + Sync>;

/// What is known about the registry file, behind the lock that serializes
/// read-modify-write cycles on it. `last_write` is only ever read or set
/// while that lock is held, so it is a field of what the lock guards rather
/// than a second lock to remember to take.
#[derive(Default)]
struct RegistryFile {
    /// When the registry was last written, so a progress-only change can
    /// wait for [`PROGRESS_WRITE_INTERVAL`].
    last_write: Option<Instant>,
}

/// The downloads half of [`AppState`]: the registry file's lock, what was
/// last pushed to the sink, the sink, and whether the ticker runs.
///
/// Separate locks inside one value, deliberately. A pin or a listing blocks
/// on the server for as long as a magnet takes to resolve; holding one lock
/// across all of that would stall the progress sink and every other
/// download call with it. The order, where two are needed, is `ticking`
/// then `file` -- [`ensure_ticker`] is the only place that takes both.
#[derive(Default)]
pub struct DownloadsState {
    /// Serializes read-modify-write cycles on the registry file: the FFI
    /// calls, the progress ticker and the init-time re-pin all run on
    /// different threads and must not lose each other's edits.
    file: Mutex<RegistryFile>,
    /// The last progress delivered per key, so the ticker does not repeat
    /// itself: with a write skipped the registry on disk stays behind the
    /// server's numbers, and every tick would otherwise "change" the same
    /// row back to the same values. Cleared whenever a new sink arrives --
    /// it has the whole picture from `downloads_list` and needs no
    /// reminder.
    last_sent: Mutex<BTreeMap<String, Progress>>,
    event_sink: RwLock<Option<EventSink>>,
    /// Whether a [`ticker`] task is running for this state.
    ticking: Mutex<bool>,
}

/// A poisoned lock only means a previous holder panicked; the value behind
/// it is still valid, so every accessor here reads through the poison.
impl DownloadsState {
    fn file(&self) -> MutexGuard<'_, RegistryFile> {
        self.file
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn last_sent(&self) -> MutexGuard<'_, BTreeMap<String, Progress>> {
        self.last_sent
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn sink(&self) -> RwLockReadGuard<'_, Option<EventSink>> {
        self.event_sink
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn sink_mut(&self) -> RwLockWriteGuard<'_, Option<EventSink>> {
        self.event_sink
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn ticking(&self) -> MutexGuard<'_, bool> {
        self.ticking
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// What a download is doing. Unknown values (a file from a newer build) read
/// back as [`State::Queued`] rather than failing the whole entry.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum State {
    /// Pinned, but nothing is on disk yet (metadata resolving, or checking).
    #[default]
    Queued,
    /// Bytes are arriving.
    Downloading,
    /// `downloaded == size`: playable from the file, offline.
    Complete,
    /// The server reported an error for the torrent or the pin.
    Error,
    /// Reserved: the server has no pause for a pinned file yet.
    Paused,
}

impl<'de> Deserialize<'de> for State {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(deserializer)?;
        Ok(match raw.as_str() {
            "queued" => Self::Queued,
            "downloading" => Self::Downloading,
            "complete" => Self::Complete,
            "error" => Self::Error,
            "paused" => Self::Paused,
            other => {
                tracing::warn!(
                    state = other,
                    "unknown download state; reading it as queued"
                );
                Self::Queued
            }
        })
    }
}

/// One offline download, keyed by [`Entry::key`] (`"{metaId}:{videoId}"`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    /// The meta this belongs to (`tt0111161`).
    pub meta_id: String,
    /// The video inside it; the meta id itself for a movie.
    pub video_id: String,
    /// `movie`, `series`, ... — stremio-core's meta type.
    #[serde(rename = "type", default)]
    pub kind: String,
    /// What to show in a list row.
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub poster: Option<String>,
    /// The addon's stream, verbatim: `Load Player` takes this back, so it is
    /// never reshaped here.
    #[serde(default)]
    pub stream: serde_json::Value,
    pub info_hash: String,
    #[serde(default)]
    pub file_idx: usize,
    /// The stream's trackers; only used when a pin is what creates the engine.
    #[serde(default)]
    pub announce: Vec<String>,
    /// Where the file is on disk, once the server knows.
    #[serde(default)]
    pub path: Option<String>,
    /// The file's full length in bytes; 0 until metadata resolves.
    #[serde(default)]
    pub size: u64,
    #[serde(default)]
    pub downloaded: u64,
    #[serde(default)]
    pub state: State,
    /// The server's client-safe reason the download is not progressing.
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub created_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub completed_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub last_played_at: Option<DateTime<Utc>>,
    /// `MetaItem` snapshot, so Details renders with no network.
    #[serde(default)]
    pub meta: Option<serde_json::Value>,
    /// The addon request the stream came from, for `Load Player`.
    #[serde(default)]
    pub stream_request: Option<serde_json::Value>,
    /// The addon request the meta came from, for `Load Player`.
    #[serde(default)]
    pub meta_request: Option<serde_json::Value>,
    /// Keys a newer build wrote that this one does not know: kept so a
    /// downgrade round-trip does not throw them away.
    #[serde(flatten, default)]
    pub extra: BTreeMap<String, serde_json::Value>,
}

impl Entry {
    /// The registry key for a meta/video pair.
    pub fn key_of(meta_id: &str, video_id: &str) -> String {
        format!("{meta_id}:{video_id}")
    }

    /// This entry's registry key.
    pub fn key(&self) -> String {
        Self::key_of(&self.meta_id, &self.video_id)
    }

    /// Whether the ticker still has a reason to poll for this entry.
    fn unfinished(&self) -> bool {
        !matches!(self.state, State::Complete | State::Paused)
    }

    /// Folds one live `DownloadInfo` into this entry: progress, path, size,
    /// the server's error, and the state they imply. `completed_at` is set
    /// the first time the file is whole and cleared only when the server
    /// says it stopped being whole.
    ///
    /// Some of the server's readings say nothing about the bytes on disk,
    /// and they read as zeros: while the torrent hash-checks, per-file
    /// progress is empty until the check ends, and a torrent with no file
    /// list at all -- a magnet still resolving, or a dormant pin whose
    /// torrent the backend does not have right now (an unmounted downloads
    /// volume) -- reports a placeholder with no path, no length and no
    /// progress. Those are treated as *unknown*, the way `path` and `size`
    /// already were: taking them at face value demoted a complete, playable
    /// download to `queued, 0 B` on the first refresh after a restart and
    /// erased a `completedAt` nothing can recover. The server's own reason
    /// still comes through, so a complete entry can explain why it is not
    /// reachable.
    fn apply_live(&mut self, info: &DownloadInfo, now: DateTime<Utc>) {
        if info.path.is_some() {
            self.path = info.path.clone();
        }
        if info.length > 0 {
            self.size = info.length;
        }
        let phase = phase(info);
        let unknown = phase == "checking"
            || (info.length == 0 && info.downloaded == 0 && info.path.is_none());
        if !unknown {
            self.downloaded = info.downloaded;
        }
        self.error = info.error.clone();
        let failing = info.error.is_some() || phase == "error";
        self.state = if info.complete {
            State::Complete
        } else if unknown {
            // Nothing here contradicts what was already known about the
            // bytes; only the reason it is not progressing is news.
            match self.state {
                State::Complete => State::Complete,
                _ if failing => State::Error,
                _ => State::Queued,
            }
        } else if failing {
            State::Error
        } else if phase == "resolvingMetadata" {
            State::Queued
        } else {
            State::Downloading
        };
        match self.state {
            State::Complete if self.completed_at.is_none() => self.completed_at = Some(now),
            State::Complete => {}
            // Only a reading that actually counted the bytes can say the
            // file is no longer whole (a deleted file the server
            // re-downloads); a transient zero must not erase the date.
            _ if !unknown && self.downloaded < self.size => self.completed_at = None,
            _ => {}
        }
    }
}

/// The download's `StartupPhase` as its wire name (`resolvingMetadata`,
/// `checking`, `buffering`, `ready`, `error`). The enum itself is
/// `enginefs`', which stream-server does not re-export, and the camelCase
/// serialization is the contract anyway.
fn phase(info: &DownloadInfo) -> String {
    serde_json::to_value(info.phase)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_default()
}

/// What moves while a download runs, for one row: the six fields a progress
/// event carries, and nothing else.
///
/// The whole entry -- the `MetaItem` snapshot, the raw stream JSON, the two
/// addon requests -- is what [`list`] is for. Pushing all of that once a
/// second per row means serializing a large blob here and decoding it on the
/// UI isolate there, for six numbers; a screen folds these into the listing
/// it already has ([`Entry`] keyed by [`Progress::key`]).
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Progress {
    /// The registry key, `"{metaId}:{videoId}"`.
    pub key: String,
    pub downloaded: u64,
    pub size: u64,
    pub state: State,
    pub path: Option<String>,
    pub error: Option<String>,
    pub completed_at: Option<DateTime<Utc>>,
}

impl Progress {
    fn of(key: &str, entry: &Entry) -> Self {
        Self {
            key: key.to_owned(),
            downloaded: entry.downloaded,
            size: entry.size,
            state: entry.state,
            path: entry.path.clone(),
            error: entry.error.clone(),
            completed_at: entry.completed_at,
        }
    }
}

/// What a progress event is on the wire: `{"version":1,"progress":[…]}`.
/// A different shape from the `downloads_list` envelope on purpose, so a
/// reader can tell a narrow update from a full listing without guessing.
#[derive(Debug, Serialize)]
struct ProgressEvent<'a> {
    version: u32,
    progress: &'a [Progress],
}

/// Where the downloads were last answered to go, and by whom.
///
/// It is the registry's business rather than the server's because the
/// server's `downloadsDir` cannot say any of this: a null there is both
/// "with the torrent cache, on purpose" and "nobody has been asked", and
/// the server clears a `downloadsDir` it cannot prepare at boot -- which
/// would take the answer with it.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub enum Destination {
    /// Nobody has been asked yet, so a start-up may point the server at
    /// whatever this platform's default is.
    #[default]
    Unset,
    /// The app applied this platform's own default because nothing had been
    /// chosen. Not an answer: a build whose default lies elsewhere may
    /// replace it, and nothing presents it as something the user picked.
    PlatformDefault(String),
    /// "Default (with the cache)", chosen on purpose: a null `downloadsDir`
    /// and not an open question.
    Cache,
    /// A directory the user chose, spelled the way the server stored it
    /// (`prepare_downloads_dir` resolves symlinks, so what [`set_dir`] was
    /// handed is not always what comes back). Kept so a start-up can
    /// compare it with the live `downloadsDir`: a recorded path the
    /// settings no longer have is one the server dropped at boot, and the
    /// app asks for it again rather than leaving the files in a cache the
    /// OS may reclaim.
    Explicit(String),
}

impl Destination {
    /// Whether where the downloads go has been answered at all -- by the
    /// user, or by the platform default a first run applies.
    pub fn is_settled(&self) -> bool {
        !matches!(self, Self::Unset)
    }

    /// Whether the answer is the user's own, which is what a default must
    /// never overwrite.
    pub fn is_chosen(&self) -> bool {
        matches!(self, Self::Cache | Self::Explicit(_))
    }

    /// The directory it names, where it names one.
    pub fn path(&self) -> Option<&str> {
        match self {
            Self::PlatformDefault(path) | Self::Explicit(path) => Some(path),
            Self::Unset | Self::Cache => None,
        }
    }

    /// What goes under `destinationChoice`. A user's answer keeps the shape
    /// every build so far has written -- the path as a string, and null for
    /// the cache, which `destinationSettled` tells apart from an open
    /// question -- so an older build still reads it the way it always did.
    /// Only the platform default, which no older build could record, needs
    /// a shape of its own.
    fn to_json(&self) -> serde_json::Value {
        match self {
            Self::Unset | Self::Cache => serde_json::Value::Null,
            Self::Explicit(path) => serde_json::Value::String(path.clone()),
            Self::PlatformDefault(path) => {
                serde_json::json!({ "kind": "platformDefault", "path": path })
            }
        }
    }

    /// Reads the two keys back, forgivingly: a bare string is the path a
    /// user chose (the shape written before this build), an object names
    /// its own kind, and anything else -- a kind from a newer build among
    /// it -- falls back on the two things always readable, whether the
    /// question was settled and whether a path was named.
    fn from_json(settled: bool, choice: Option<&serde_json::Value>) -> Self {
        let named = |path: Option<&str>| match path {
            Some(path) => Self::Explicit(path.to_owned()),
            None if settled => Self::Cache,
            None => Self::Unset,
        };
        match choice {
            None | Some(serde_json::Value::Null) => named(None),
            Some(serde_json::Value::String(path)) => named(Some(path)),
            Some(value) => {
                let path = value.get("path").and_then(serde_json::Value::as_str);
                match value.get("kind").and_then(serde_json::Value::as_str) {
                    // A platform default with no path names nothing, so it
                    // answers nothing either.
                    Some("platformDefault") => path
                        .map(|path| Self::PlatformDefault(path.to_owned()))
                        .unwrap_or(Self::Unset),
                    Some("cache") => Self::Cache,
                    Some("unset") => Self::Unset,
                    _ => named(path),
                }
            }
        }
    }
}

/// `downloads.json` as a whole: the file shape, and what the list call and
/// the progress events emit.
#[derive(Clone, Debug, PartialEq)]
pub struct Registry {
    pub version: u32,
    pub items: BTreeMap<String, Entry>,
    /// Where the downloads were answered to go, and by whom: [`set_dir`]
    /// records the user's own answer, [`apply_default_dir`] the platform
    /// default the app stands in with. On the wire it is the pair of keys
    /// it has always been, `destinationSettled` and `destinationChoice`.
    pub destination: Destination,
    /// Entries this build could not parse, exactly as they were on disk.
    /// They are invisible to everything but [`Registry::serialize`], which
    /// writes them back among the items: a forgiving read plus a whole-file
    /// rewrite would otherwise *erase* an entry the next version wrote (or
    /// a truncated one), while the server's pin for it lived on -- an
    /// orphan the list cannot show and `remove` cannot reach.
    unreadable: BTreeMap<String, serde_json::Value>,
}

impl Default for Registry {
    fn default() -> Self {
        Self {
            version: VERSION,
            items: BTreeMap::new(),
            destination: Destination::Unset,
            unreadable: BTreeMap::new(),
        }
    }
}

impl Serialize for Registry {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::{Error, SerializeStruct};

        let mut items = serde_json::Map::with_capacity(self.items.len() + self.unreadable.len());
        for (key, entry) in &self.items {
            items.insert(
                key.clone(),
                serde_json::to_value(entry).map_err(Error::custom)?,
            );
        }
        for (key, raw) in &self.unreadable {
            items.entry(key.clone()).or_insert_with(|| raw.clone());
        }
        let mut registry = serializer.serialize_struct("Registry", 4)?;
        registry.serialize_field("version", &self.version)?;
        registry.serialize_field("items", &items)?;
        registry.serialize_field("destinationSettled", &self.destination.is_settled())?;
        registry.serialize_field("destinationChoice", &self.destination.to_json())?;
        registry.end()
    }
}

impl Registry {
    /// Parses a registry file, never failing: a corrupt file, a missing
    /// `items` object or an entry this build cannot read all degrade to a
    /// warning and less data, because the alternative is an app that will
    /// not start. A `version` at or above [`VERSION`] is preserved.
    pub fn parse(bytes: &[u8]) -> Self {
        let value: serde_json::Value = match serde_json::from_slice(bytes) {
            Ok(value) => value,
            Err(error) => {
                tracing::warn!(%error, "downloads registry is unreadable; starting empty");
                return Self::default();
            }
        };
        Self::from_value(&value)
    }

    /// The parsed form of an already-decoded registry file.
    fn from_value(value: &serde_json::Value) -> Self {
        let version = value
            .get("version")
            .and_then(serde_json::Value::as_u64)
            .unwrap_or(VERSION as u64)
            .max(VERSION as u64) as u32;
        if version > VERSION {
            tracing::warn!(
                version,
                supported = VERSION,
                "downloads registry was written by a newer build; unknown keys are kept as-is"
            );
        }
        let destination = Destination::from_json(
            value
                .get("destinationSettled")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false),
            value.get("destinationChoice"),
        );
        let Some(items) = value.get("items").and_then(serde_json::Value::as_object) else {
            tracing::warn!("downloads registry has no items object; starting empty");
            return Self {
                version,
                destination,
                ..Self::default()
            };
        };
        let mut parsed = BTreeMap::new();
        let mut unreadable = BTreeMap::new();
        for (key, raw) in items {
            match serde_json::from_value::<Entry>(raw.clone()) {
                Ok(entry) => {
                    parsed.insert(key.clone(), entry);
                }
                Err(error) => {
                    // Kept verbatim, not dropped: the next write would
                    // otherwise erase it from disk for good.
                    tracing::warn!(key, %error, "unreadable download entry; keeping it as it is");
                    unreadable.insert(key.clone(), raw.clone());
                }
            }
        }
        Self {
            version,
            items: parsed,
            destination,
            unreadable,
        }
    }
}

/// Where the registry lives. Errors before `core_init` has pointed storage
/// at the app directory.
fn registry_path() -> anyhow::Result<PathBuf> {
    registry_path_in(crate::env::storage_dir())
}

/// The same, against a storage directory handed in rather than read from
/// the process-global one: `storage_dir` is set once by `core_init` and
/// shared by every test in the lib binary, so what "there is no storage
/// directory" does is answered here, where no other test can set one
/// halfway through.
fn registry_path_in(dir: Option<PathBuf>) -> anyhow::Result<PathBuf> {
    dir.map(|dir| dir.join(FILE_NAME))
        .ok_or_else(|| anyhow::anyhow!("storage directory is not set; is the core initialized?"))
}

fn load_locked() -> anyhow::Result<Registry> {
    let path = registry_path()?;
    let bytes = match std::fs::read(&path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Registry::default())
        }
        Err(error) => return Err(anyhow::anyhow!("read downloads registry: {error}")),
    };
    match serde_json::from_slice::<serde_json::Value>(&bytes) {
        Ok(value) if value.is_object() => Ok(Registry::from_value(&value)),
        parsed => {
            let reason = parsed
                .err()
                .map(|error| error.to_string())
                .unwrap_or_else(|| "the file is not a JSON object".to_owned());
            move_aside(&path, &reason);
            Ok(Registry::default())
        }
    }
}

/// Renames a registry the app cannot read at all to
/// `downloads.json.corrupt-<seconds>`, so the next write starts a fresh file
/// instead of overwriting the one a human (or a later build) might still get
/// something out of.
fn move_aside(path: &std::path::Path, reason: &str) {
    let aside = path.with_file_name(format!("{FILE_NAME}.corrupt-{}", Utc::now().timestamp()));
    match std::fs::rename(path, &aside) {
        Ok(()) => tracing::warn!(
            reason,
            "downloads registry is unreadable; moved aside and starting empty"
        ),
        Err(error) => tracing::warn!(
            reason,
            %error,
            "downloads registry is unreadable and could not be moved aside; starting empty"
        ),
    }
}

/// The registry as it is on disk.
pub fn load() -> anyhow::Result<Registry> {
    load_in(&crate::state::state())
}

/// [`load`] against a state the caller already holds, which is the only
/// thing background work may do: `state::state` *creates* a state when there
/// is none, so work that outlived a shutdown would put one back into the
/// process rather than quietly finish against its own.
fn load_in(app: &AppState) -> anyhow::Result<Registry> {
    let _guard = app.downloads.file();
    load_locked()
}

/// Runs `f` against the registry and writes it back if `f` changed anything.
/// The file lock is held throughout, so two concurrent updates cannot lose
/// each other's edits.
pub fn update<T>(f: impl FnOnce(&mut Registry) -> anyhow::Result<T>) -> anyhow::Result<T> {
    update_in(&crate::state::state(), f)
}

/// [`update`] against a state the caller already holds. See [`load_in`].
fn update_in<T>(
    app: &AppState,
    f: impl FnOnce(&mut Registry) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    update_when_in(app, f, |_, _, _| true)
}

/// The same, with a say in whether the change is worth a write. `needed` is
/// asked what `f` did -- the registry before and after -- and a `false`
/// leaves the file as it was, edits and all: the caller must be one whose
/// change the next write picks up again anyway. [`refresh`] is that caller,
/// and the only one.
fn update_when_in<T>(
    app: &AppState,
    f: impl FnOnce(&mut Registry) -> anyhow::Result<T>,
    needed: impl FnOnce(&RegistryFile, &Registry, &Registry) -> bool,
) -> anyhow::Result<T> {
    let mut file = app.downloads.file();
    let mut registry = load_locked()?;
    let before = registry.clone();
    let result = f(&mut registry)?;
    if registry != before && needed(&file, &before, &registry) {
        let bytes = serde_json::to_vec(&registry)?;
        crate::env::write_atomically(&registry_path()?, &bytes)
            .map_err(|error| anyhow::anyhow!("write downloads registry: {error}"))?;
        file.last_write = Some(Instant::now());
    }
    Ok(result)
}

/// Whether a refresh's changes have to reach the disk now: everything but a
/// byte count does, and a byte count does too once the last write is
/// [`PROGRESS_WRITE_INTERVAL`] old. Asked with the registry file's lock
/// already held, which is what makes reading `last_write` here honest.
fn refresh_needs_a_write(file: &RegistryFile, before: &Registry, after: &Registry) -> bool {
    !only_downloaded_moved(before, after)
        || file
            .last_write
            .is_none_or(|last| last.elapsed() >= PROGRESS_WRITE_INTERVAL)
}

/// Whether the only difference between the two is how many bytes are on
/// disk. Compared by laying `after`'s byte count over `before`'s entry, so a
/// field added later is a difference until someone says otherwise.
fn only_downloaded_moved(before: &Registry, after: &Registry) -> bool {
    if before.items.len() != after.items.len() || before.destination != after.destination {
        return false;
    }
    after.items.iter().all(|(key, entry)| {
        before.items.get(key).is_some_and(|was| {
            *entry
                == Entry {
                    downloaded: entry.downloaded,
                    ..was.clone()
                }
        })
    })
}

/// Why a pin could not be taken, in the shape the UI shows. Every message is
/// the server's `client_message` (or one of ours): none of them names a
/// local path, which the backend's own error chains do.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum PinFailure {
    /// The download volume has less than the missing bytes plus the server's
    /// 500 MiB margin. The numbers are bytes.
    InsufficientSpace {
        required: u64,
        available: u64,
        margin: u64,
        message: String,
    },
    /// The torrent has no such file.
    #[serde(rename_all = "camelCase")]
    FileNotFound {
        file_idx: usize,
        file_count: usize,
        message: String,
    },
    /// The torrent could not be added: no peer supplied the info dictionary
    /// in time, or the backend refused it. The message is the server's own
    /// client-safe sentence, which names the timeout but never a path.
    MagnetAdd { message: String },
    /// The torrent engine refused the pin itself.
    Backend { message: String },
    /// Nothing to ask: the embedded server is not running, or its runtime
    /// went away mid-call.
    Unavailable { message: String },
}

impl PinFailure {
    /// Classifies what `crate::server::pin_download` returned. The concrete
    /// [`PinDownloadError`] travels inside `anyhow`, so this downcasts;
    /// anything else is one of our own (path-free) messages.
    pub fn classify(error: &anyhow::Error) -> Self {
        let Some(pin_error) = error.downcast_ref::<PinDownloadError>() else {
            return Self::Unavailable {
                message: error.to_string(),
            };
        };
        let message = pin_error.client_message();
        match pin_error {
            PinDownloadError::InsufficientSpace {
                required,
                available,
                margin,
            } => Self::InsufficientSpace {
                required: *required,
                available: *available,
                margin: *margin,
                message,
            },
            PinDownloadError::FileNotFound {
                file_idx,
                file_count,
            } => Self::FileNotFound {
                file_idx: *file_idx,
                file_count: *file_count,
                message,
            },
            PinDownloadError::MagnetAdd(_) => Self::MagnetAdd { message },
            PinDownloadError::Backend(_) => Self::Backend { message },
        }
    }

    /// The sentence to show, and to keep on the entry.
    pub fn message(&self) -> &str {
        match self {
            Self::InsufficientSpace { message, .. }
            | Self::FileNotFound { message, .. }
            | Self::MagnetAdd { message }
            | Self::Backend { message }
            | Self::Unavailable { message } => message,
        }
    }
}

/// What `downloads_add` answers. A refused pin is `ok: false` with a
/// [`PinFailure`], not an exception: a full disk is not a programming error,
/// and an exception would lose the numbers the message is built from.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AddOutcome {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entry: Option<Entry>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<PinFailure>,
}

/// The JSON `downloads_add` takes: what the stream picker already has.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AddRequest {
    pub meta_id: String,
    pub video_id: String,
    #[serde(rename = "type", default)]
    pub kind: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub poster: Option<String>,
    /// The addon's raw stream JSON; must be a torrent (`infoHash`).
    pub stream: serde_json::Value,
    /// Overrides the stream's own `fileIdx`, for a caller that resolved the
    /// episode's index itself. Negative (the `-1` the player's URL carries)
    /// means "you pick", exactly like a stream with no `fileIdx`.
    #[serde(default)]
    pub file_idx: Option<i64>,
    #[serde(default)]
    pub meta: Option<serde_json::Value>,
    #[serde(default)]
    pub stream_request: Option<serde_json::Value>,
    #[serde(default)]
    pub meta_request: Option<serde_json::Value>,
}

/// The torrent coordinates of a stream, as the player's own URL carries
/// them: `infoHash`, the file the stream names, the trackers and the
/// `fileMustInclude` filters. Errors when the stream is not a torrent,
/// which is the one thing the caller must not get wrong.
#[derive(Clone, Debug, PartialEq)]
struct TorrentSource {
    info_hash: String,
    /// The index the stream names, or `None` when it names none — a missing
    /// `fileIdx` and the explicit `-1` sentinel alike. `None` is not file 0:
    /// the app plays `/{infoHash}/-1`, which the server resolves to the
    /// filtered or largest media file (`routes::compat::resolve_file_idx`),
    /// so the index has to be asked for rather than assumed.
    file_idx: Option<usize>,
    announce: Vec<String>,
    /// The stream's `fileMustInclude`, which the play URL passes as `f=` and
    /// which wins over the largest-file rule.
    filters: Vec<String>,
}

fn string_list(stream: &serde_json::Value, keys: &[&str]) -> Vec<String> {
    keys.iter()
        .find_map(|key| stream.get(key).and_then(serde_json::Value::as_array))
        .map(|list| {
            list.iter()
                .filter_map(|item| item.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}

fn torrent_source(
    stream: &serde_json::Value,
    file_idx_override: Option<i64>,
) -> anyhow::Result<TorrentSource> {
    let info_hash = stream
        .get("infoHash")
        .and_then(serde_json::Value::as_str)
        .filter(|hash| !hash.is_empty())
        .ok_or_else(|| anyhow::anyhow!("only torrent streams can be downloaded (no infoHash)"))?
        .to_lowercase();
    // A negative index is the caller saying "you pick", the same thing the
    // media route's `-1` says, so it never becomes a real index here.
    let file_idx = file_idx_override
        .or_else(|| stream.get("fileIdx").and_then(serde_json::Value::as_i64))
        .filter(|idx| *idx >= 0)
        .map(|idx| idx as usize);
    // `announce` is stremio-core's field; `sources` is what addons that
    // speak the server's shape send. Either is only consulted when this pin
    // is what creates the engine.
    let announce = string_list(stream, &["announce", "sources"]);
    let filters = string_list(stream, &["fileMustInclude"]);
    Ok(TorrentSource {
        info_hash,
        file_idx,
        announce,
        filters,
    })
}

/// Whether a file name is one the server counts as media
/// (`routes::compat::is_video_name`).
fn is_video_name(name: &str) -> bool {
    matches!(
        name.to_ascii_lowercase().rsplit('.').next(),
        Some("mkv" | "mp4" | "avi" | "webm" | "mov" | "wmv" | "m4v" | "ts")
    )
}

/// One `fileMustInclude` filter against one file name, as the server matches
/// it (`routes::compat::file_matches_filter`): `/pattern/flags` is a regular
/// expression, anything else a case-insensitive substring.
fn file_matches_filter(name: &str, filter: &str) -> bool {
    if let Some((pattern, flags)) = filter
        .strip_prefix('/')
        .and_then(|rest| rest.rsplit_once('/'))
        .filter(|(pattern, _)| !pattern.is_empty())
    {
        return regex::RegexBuilder::new(pattern)
            .case_insensitive(flags.contains('i'))
            .build()
            .map(|regex| regex.is_match(name))
            .unwrap_or(false);
    }
    name.to_ascii_lowercase()
        .contains(&filter.to_ascii_lowercase())
}

/// The file `/{infoHash}/-1` plays, from the torrent's `(name, length)` list:
/// the first one a `fileMustInclude` filter matches, else the largest file
/// with a media extension, else the largest file of any kind. A mirror of
/// the server's `routes::compat::resolve_file_idx("-1", ..)` — what the app
/// keeps offline has to be what it played online, and the index is the
/// file's position in the torrent either way.
fn media_file_index(files: &[(String, u64)], filters: &[String]) -> Option<usize> {
    if !filters.is_empty() {
        let matched = files.iter().position(|(name, _)| {
            filters
                .iter()
                .any(|filter| file_matches_filter(name, filter))
        });
        if let Some(idx) = matched {
            return Some(idx);
        }
    }
    files
        .iter()
        .enumerate()
        .filter(|(_, (name, _))| is_video_name(name))
        .max_by_key(|(_, (_, length))| *length)
        .or_else(|| {
            files
                .iter()
                .enumerate()
                .max_by_key(|(_, (_, length))| *length)
        })
        .map(|(idx, _)| idx)
}

/// Which file of `source` to pin when the stream names none: the server is
/// asked for the torrent's file list and the media route's rule applied to
/// it. The stats call creates the engine when the hash is new, so this waits
/// for a magnet's metadata the way the pin itself would, and refuses with a
/// message the UI can show rather than guessing file 0.
fn resolve_media_file(source: &TorrentSource) -> Result<usize, PinFailure> {
    let deadline = std::time::Instant::now() + METADATA_WAIT;
    loop {
        let stats = crate::server::torrent_stats(&source.info_hash, None, &source.announce)
            .map_err(|error| PinFailure::classify(&error))?;
        let files: Vec<(String, u64)> = stats
            .files
            .iter()
            .map(|file| (file.name.clone(), file.length))
            .collect();
        if let Some(idx) = media_file_index(&files, &source.filters) {
            return Ok(idx);
        }
        if let Some(error) = stats.error.clone() {
            return Err(PinFailure::MagnetAdd { message: error });
        }
        if std::time::Instant::now() >= deadline {
            return Err(PinFailure::MagnetAdd {
                message: format!(
                    "the torrent's file list did not resolve within {}s, so there is no way to \
                     tell which file this stream plays",
                    METADATA_WAIT.as_secs()
                ),
            });
        }
        std::thread::sleep(METADATA_POLL);
    }
}

/// Pins the request's stream and records it. An existing entry for the same
/// meta/video keeps its `createdAt` and `lastPlayedAt` and takes everything
/// else from this call, so re-downloading after a failure is one call.
pub fn add(request: AddRequest) -> anyhow::Result<AddOutcome> {
    let source = torrent_source(&request.stream, request.file_idx)?;
    let TorrentSource {
        info_hash,
        announce,
        ..
    } = source.clone();
    let key = Entry::key_of(&request.meta_id, &request.video_id);

    // A stream that names no file is not a stream about file 0: it plays
    // whatever `/{infoHash}/-1` resolves to, and that is what gets pinned.
    let file_idx = match source.file_idx {
        Some(file_idx) => file_idx,
        None => match resolve_media_file(&source) {
            Ok(file_idx) => file_idx,
            Err(failure) => {
                tracing::warn!(
                    key,
                    message = failure.message(),
                    "could not tell which file this stream downloads"
                );
                return Ok(AddOutcome {
                    ok: false,
                    key: Some(key),
                    entry: None,
                    error: Some(failure),
                });
            }
        },
    };

    let info = match crate::server::pin_download(&info_hash, file_idx, &announce) {
        Ok(info) => info,
        Err(error) => {
            let failure = PinFailure::classify(&error);
            tracing::warn!(
                key,
                message = failure.message(),
                "could not pin the download"
            );
            return Ok(AddOutcome {
                ok: false,
                key: Some(key),
                entry: None,
                error: Some(failure),
            });
        }
    };
    release_replaced_pin(&key, &info_hash, file_idx);

    // `pin_download` already reports the path when the engine knows it; ask
    // again only for the case where it did not (metadata just landed).
    let path = match info.path.clone() {
        Some(path) => Some(path),
        None => crate::server::download_path(&info_hash, file_idx).unwrap_or_default(),
    };

    let now = Utc::now();
    let entry = update(|registry| {
        let previous = registry.items.get(&key);
        // Re-adding the *same* file is a retry, not a new download, and only
        // a reading that counted bytes may move its numbers. `pin_download`
        // can answer `checking` while it relocates the torrent, which
        // `apply_live` treats as saying nothing at all -- so a row rebuilt
        // from zero here would sit at `queued, 0 B` until the hash check
        // ends, and its `completedAt` would be gone for good, that date
        // being set once and never recomputed.
        let same = previous.filter(|entry| {
            entry.info_hash.eq_ignore_ascii_case(&info_hash) && entry.file_idx == file_idx
        });
        let mut entry = Entry {
            meta_id: request.meta_id.clone(),
            video_id: request.video_id.clone(),
            kind: request.kind.clone(),
            name: request.name.clone(),
            poster: request.poster.clone(),
            stream: request.stream.clone(),
            info_hash: info_hash.clone(),
            file_idx,
            announce: announce.clone(),
            path: path
                .clone()
                .or_else(|| same.and_then(|entry| entry.path.clone())),
            size: same.map(|entry| entry.size).unwrap_or_default(),
            downloaded: same.map(|entry| entry.downloaded).unwrap_or_default(),
            state: same.map(|entry| entry.state).unwrap_or_default(),
            error: None,
            created_at: previous.and_then(|entry| entry.created_at).or(Some(now)),
            completed_at: same.and_then(|entry| entry.completed_at),
            last_played_at: previous.and_then(|entry| entry.last_played_at),
            meta: request.meta.clone(),
            stream_request: request.stream_request.clone(),
            meta_request: request.meta_request.clone(),
            extra: previous
                .map(|entry| entry.extra.clone())
                .unwrap_or_default(),
        };
        entry.apply_live(&info, now);
        registry.items.insert(key.clone(), entry.clone());
        Ok(entry)
    })?;

    ensure_ticker();
    Ok(AddOutcome {
        ok: true,
        key: Some(key),
        entry: Some(entry),
        error: None,
    })
}

/// Whether an entry other than `key` names the same `(infoHash, fileIdx)` --
/// one torrent that is a stream of two metas (a Cinemeta id and an anime id
/// for the same film), downloaded from both.
///
/// The server's pin registry is a set with no reference count, so a single
/// unpin serves every entry naming that file: dropping one of them has to
/// leave the pin, and the bytes, to the others.
fn pin_is_shared(registry: &Registry, key: &str, info_hash: &str, file_idx: usize) -> bool {
    registry.items.iter().any(|(other, entry)| {
        other != key
            && entry.info_hash.eq_ignore_ascii_case(info_hash)
            && entry.file_idx == file_idx
    })
}

/// Drops the pin the entry at `key` used to hold, when the download being
/// recorded is a different file (the user pressed Download on a second
/// stream for the same title, or retried at another index). The registry is
/// keyed by meta and video, the server's pin registry by `(infoHash,
/// fileIdx)`, so without this the replaced torrent stays wanted, exempt
/// from the idle sweeper and the cache cleaner, and downloading -- with
/// nothing in `downloads.json` naming it any more, which means the list
/// cannot show it and [`remove`] cannot reach it, ever.
///
/// Another entry naming the same file (the same movie under two metas) owns
/// that pin too, so it is left alone; otherwise the pin goes and the bytes
/// with it, since nothing references them any more.
fn release_replaced_pin(key: &str, info_hash: &str, file_idx: usize) {
    let registry = match load() {
        Ok(registry) => registry,
        Err(error) => {
            tracing::warn!(%error, "could not check for a download to replace");
            return;
        }
    };
    let Some(previous) = registry.items.get(key) else {
        return;
    };
    if previous.info_hash.eq_ignore_ascii_case(info_hash) && previous.file_idx == file_idx {
        return;
    }
    if pin_is_shared(&registry, key, &previous.info_hash, previous.file_idx) {
        tracing::info!(
            key,
            file_idx = previous.file_idx,
            "the replaced download is another entry's too; its pin stays"
        );
        return;
    }
    match crate::server::unpin_download(&previous.info_hash, previous.file_idx, true) {
        Ok(outcome) => tracing::info!(
            key,
            file_idx = previous.file_idx,
            deleted_files = outcome.deleted_files,
            "released the download this one replaces"
        ),
        Err(error) => tracing::warn!(
            key,
            file_idx = previous.file_idx,
            %error,
            "could not release the download this one replaces; it stays pinned"
        ),
    }
}

/// What `downloads_remove` answers: whether a pin was actually cleared,
/// whether bytes actually left the disk (not the flag echoed back), and
/// whether the registry had an entry to forget.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoveOutcome {
    pub removed: bool,
    pub unpinned: bool,
    pub deleted_files: bool,
}

/// Unpins `key` and forgets it. With `delete_files` the data goes too. An
/// entry the registry does not have is not an error — the pin is dropped
/// anyway when its coordinates are known, and there is nothing to forget.
///
/// Another entry naming the same file keeps it: the pin is that entry's as
/// much as this one's, so only the registry row goes and the answer says so
/// (`unpinned: false`). Unpinning anyway would delete the survivor's bytes
/// under it, or at best leave it unpinned and evictable while its row keeps
/// claiming a complete download.
pub fn remove(key: &str, delete_files: bool) -> anyhow::Result<RemoveOutcome> {
    let registry = load()?;
    let Some(entry) = registry.items.get(key).cloned() else {
        return Ok(RemoveOutcome {
            removed: false,
            unpinned: false,
            deleted_files: false,
        });
    };
    if pin_is_shared(&registry, key, &entry.info_hash, entry.file_idx) {
        tracing::info!(
            key,
            file_idx = entry.file_idx,
            "another download names this file; forgetting the entry, keeping the pin"
        );
        update(|registry| {
            registry.items.remove(key);
            Ok(())
        })?;
        return Ok(RemoveOutcome {
            removed: true,
            unpinned: false,
            deleted_files: false,
        });
    }
    // The unpin comes first: dropping the registry entry for a pin the
    // server still holds would leave a download nothing can find again.
    let outcome = crate::server::unpin_download(&entry.info_hash, entry.file_idx, delete_files)?;
    update(|registry| {
        registry.items.remove(key);
        Ok(())
    })?;
    Ok(RemoveOutcome {
        removed: true,
        unpinned: outcome.unpinned,
        deleted_files: outcome.deleted_files,
    })
}

/// Why a download cannot be played off the device. None of these is an
/// error: each one is something a screen says before streaming the title
/// instead, which is the whole point of answering rather than raising.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum OpenFailure {
    /// The registry has no such entry — it was removed while a screen still
    /// held the row.
    Unknown,
    /// The bytes are not all here yet.
    Incomplete,
    /// Whole as far as the registry knows, but the file is not where it was
    /// left: an unmounted downloads volume, or something outside the app
    /// deleted it.
    Missing,
}

/// What [`open`] answers.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenOutcome {
    pub ok: bool,
    pub key: String,
    /// The `file://` URL to hand the player, when there is one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// The entry as it now stands, `lastPlayedAt` included.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entry: Option<Entry>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<OpenFailure>,
}

impl OpenOutcome {
    fn refused(key: &str, reason: OpenFailure) -> Self {
        Self {
            ok: false,
            key: key.to_owned(),
            url: None,
            entry: None,
            reason: Some(reason),
        }
    }
}

/// The `file://` URL of a finished download's file, or why there is none.
///
/// Only the entry and the filesystem are consulted — never the length on
/// disk, which says nothing about how much of the file is real (librqbit
/// allocates it whole; `downloaded == size` is the only proof, and that is
/// what [`State::Complete`] already stands for).
fn local_url(entry: &Entry) -> Result<String, OpenFailure> {
    if entry.state != State::Complete {
        return Err(OpenFailure::Incomplete);
    }
    let path = entry.path.as_deref().ok_or(OpenFailure::Missing)?;
    let path = std::path::Path::new(path);
    if !path.is_file() {
        return Err(OpenFailure::Missing);
    }
    // Only fails on a relative path; the server always answers an absolute
    // one, so this is the same "not playable from here" as a missing file.
    url::Url::from_file_path(path)
        .map(String::from)
        .map_err(|()| OpenFailure::Missing)
}

/// What to play `key` off the device with, and a note that it was played.
///
/// A finished download whose file is really there answers `ok: true` with
/// the `file://` URL for it, and its `lastPlayedAt` is stamped in the same
/// locked read-modify-write — so the timestamp cannot be lost to a progress
/// tick landing between the check and the write, and cannot be stamped on a
/// play that never happened.
///
/// Anything else answers `ok: false` with a [`OpenFailure`]: the caller
/// streams the title instead of opening a dead player.
pub fn open(key: &str) -> anyhow::Result<OpenOutcome> {
    update(|registry| {
        let Some(entry) = registry.items.get_mut(key) else {
            return Ok(OpenOutcome::refused(key, OpenFailure::Unknown));
        };
        let url = match local_url(entry) {
            Ok(url) => url,
            Err(reason) => {
                tracing::info!(key, ?reason, "no file to play this download from");
                return Ok(OpenOutcome::refused(key, reason));
            }
        };
        entry.last_played_at = Some(Utc::now());
        Ok(OpenOutcome {
            ok: true,
            key: key.to_owned(),
            url: Some(url),
            entry: Some(entry.clone()),
            reason: None,
        })
    })
}

/// What a [`refresh`] found.
pub struct Refresh {
    /// The registry as it now stands, live progress merged in -- which is
    /// not always what is on disk: a tick that only moved byte counts leaves
    /// the file alone (see [`PROGRESS_WRITE_INTERVAL`]), so this, and not a
    /// re-read, is what a listing answers with.
    pub registry: Registry,
    /// The rows that moved, narrow enough to push once a second.
    pub moved: Vec<Progress>,
}

/// Merges the server's live download stats into the registry and reports
/// what moved. The file is rewritten for anything but a byte count, and for
/// a byte count no more often than [`PROGRESS_WRITE_INTERVAL`].
pub fn refresh() -> anyhow::Result<Refresh> {
    refresh_in(&not_initialized_unless_running()?)
}

/// The process state for a caller that only wants to *read* it. Reaching
/// for the resurrecting accessor here is what let an FFI call in flight
/// across a shutdown put a fresh state back into the process: the Android
/// notification service re-lists every five seconds and nothing cancels
/// that timer before the app awaits `core_shutdown`, so a tick landing in
/// the window undid the shutdown's whole point. See [`crate::state::state`]
/// for which callers may build one -- the ones that *install* something.
fn not_initialized_unless_running() -> anyhow::Result<Arc<AppState>> {
    crate::state::current()
        .ok_or_else(|| anyhow::anyhow!("the core is not initialized; is `core_init` done?"))
}

/// [`refresh`] against a state the caller already holds -- the ticker's, so
/// that a tick finishing after a shutdown merges into the registry of the
/// state it was started for and re-arms nothing but that state's ticker.
/// See [`load_in`].
///
/// The live stats are the one thing still asked of the process rather than
/// of `app`, and they may be: `crate::server::downloads` reads
/// [`crate::state::current`], which answers "not running" instead of
/// building a state, and a tick whose own server a shutdown has stopped has
/// nothing left to merge anyway.
fn refresh_in(app: &Arc<AppState>) -> anyhow::Result<Refresh> {
    let live = crate::server::downloads()?;
    let now = Utc::now();
    let mut merged = Registry::default();
    let moved = update_when_in(
        app,
        |registry| {
            let mut moved = Vec::new();
            for (key, entry) in registry.items.iter_mut() {
                let before = entry.clone();
                if let Some(info) = live.iter().find(|info| {
                    info.info_hash.eq_ignore_ascii_case(&entry.info_hash)
                        && info.file_idx == entry.file_idx
                }) {
                    entry.apply_live(info, now);
                }
                if *entry != before {
                    moved.push(Progress::of(key, entry));
                }
            }
            merged = registry.clone();
            Ok(moved)
        },
        refresh_needs_a_write,
    )?;
    // A refresh is also where an entry can go *back* to unfinished -- a
    // torrent that is checking again, a file that went away, a pin the
    // server lost -- and nothing else would restart the poll: `add` and
    // `set_event_sink` are its only other callers and neither runs
    // afterwards, so progress would stay silent for the rest of the
    // session.
    ensure_ticker_in(app);
    Ok(Refresh {
        registry: merged,
        moved,
    })
}

/// The whole registry with live progress merged in. Falls back to what is on
/// disk when the server cannot be asked, so the list still renders offline.
/// It is an observer, so it raises before an `init` and after a
/// `shutdown` rather than building a state to read -- the caller before an
/// `init` had no storage directory to read from either, and the one after a
/// shutdown is a timer nobody stopped.
///
/// Entries this build cannot parse stay on disk (that is the whole point of
/// keeping them) but are left out here: the caller could not read them
/// either, and the list is a payload, not the file.
pub fn list() -> anyhow::Result<Registry> {
    // One state for both halves, and it is `current`: the fallback is a
    // second chance at the registry, not a second chance at the process.
    let app = not_initialized_unless_running()?;
    let registry = match refresh_in(&app) {
        // What the refresh merged, not a re-read: a tick that only moved
        // byte counts leaves the file behind on purpose, and a listing off
        // the disk would then be the one place showing the older numbers.
        Ok(refreshed) => refreshed.registry,
        Err(error) => {
            tracing::debug!(%error, "listing downloads without live progress");
            load_in(&app)?
        }
    };
    Ok(Registry {
        unreadable: BTreeMap::new(),
        ..registry
    })
}

/// Points the server's `downloadsDir` at `path` (or unsets it with `None`),
/// with the validation and persistence `POST /settings` does.
///
/// This is the *user's* answer: a path the server accepts is recorded as
/// [`Destination::Explicit`] and `None` as [`Destination::Cache`], and from
/// here on no default may overwrite either. A path the server refuses
/// records nothing -- it raises before this. What is recorded is what the
/// settings came back with, not what was asked for, so it can be compared
/// with the live `downloadsDir` later: the server resolves the path before
/// it stores it. That the answer could not be written down is worth a
/// warning and no more -- the setting itself is already in place, and
/// failing the call would be the worse lie.
pub fn set_dir(path: Option<String>) -> anyhow::Result<stream_server::ServerSettings> {
    let settings = crate::server::update_settings(serde_json::json!({ "downloadsDir": path }))?;
    record_destination(match settings.downloads_dir.clone() {
        Some(path) => Destination::Explicit(path),
        None => Destination::Cache,
    });
    Ok(settings)
}

/// Points the server's `downloadsDir` at a default the app resolved for
/// this platform, with the same validation [`set_dir`] gets -- and without
/// answering the question on the user's behalf.
///
/// The recorded destination becomes [`Destination::PlatformDefault`] only
/// while nothing has been chosen. A choice the server dropped at boot (an
/// SD card that is not in the device) stays on record while the default
/// stands in for it, so the next start-up asks for the chosen folder again
/// and the UI can say which folder is missing rather than quietly
/// presenting the fallback as what was wanted.
pub fn apply_default_dir(path: String) -> anyhow::Result<stream_server::ServerSettings> {
    let settings =
        crate::server::update_settings(serde_json::json!({ "downloadsDir": path.clone() }))?;
    let stored = settings.downloads_dir.clone().unwrap_or(path);
    if let Err(error) = update(|registry| {
        if !registry.destination.is_chosen() {
            registry.destination = Destination::PlatformDefault(stored.clone());
        }
        Ok(())
    }) {
        tracing::warn!(%error, "could not record the downloads destination applied");
    }
    Ok(settings)
}

/// Writes down where the downloads were answered to go. A failure here is
/// a warning: the server's setting is already in place either way.
fn record_destination(destination: Destination) {
    if let Err(error) = update(move |registry| {
        registry.destination = destination;
        Ok(())
    }) {
        tracing::warn!(%error, "could not record where the downloads were answered to go");
    }
}

/// Installs the progress sink, replacing any previous one, and starts the
/// ticker if there is anything to watch. Nothing is buffered for a missing
/// sink the way core events are: the full picture is one `downloads_list`
/// away, so a late subscriber loses nothing that matters.
pub fn set_event_sink(sink: EventSink) {
    let app = crate::state::state();
    *app.downloads.sink_mut() = Some(sink);
    app.downloads.last_sent().clear();
    ensure_ticker_in(&app);
}

/// Pushes the rows that moved, leaving out any whose numbers the sink was
/// already given: a row is in an event because it changed, and a tick whose
/// write was skipped keeps finding the same difference against the disk.
fn emit(app: &AppState, moved: &[Progress]) {
    let fresh: Vec<Progress> = {
        let mut sent = app.downloads.last_sent();
        let mut fresh = Vec::new();
        for row in moved {
            if sent.insert(row.key.clone(), row.clone()).as_ref() != Some(row) {
                fresh.push(row.clone());
            }
        }
        fresh
    };
    if fresh.is_empty() {
        return;
    }
    let payload = match serde_json::to_string(&ProgressEvent {
        version: VERSION,
        progress: &fresh,
    }) {
        Ok(payload) => payload,
        Err(error) => {
            tracing::warn!(%error, "could not serialize a downloads progress event");
            return;
        }
    };
    let delivered = {
        let guard = app.downloads.sink();
        guard.as_ref().map(|sink| sink(payload))
    };
    if delivered == Some(false) {
        tracing::info!("downloads event sink closed");
        *app.downloads.sink_mut() = None;
    }
}

/// Whether the progress poll is running. Nothing on the FFI surface needs
/// it; the integration test does, because an armed ticker and a silent one
/// look identical from outside until a download that nobody is polling for
/// stops moving.
pub fn is_ticking() -> bool {
    crate::state::current().is_some_and(|app| *app.downloads.ticking())
}

/// True while any entry of `app`'s registry is neither complete nor paused —
/// an errored one counts, because peers can still turn up and the poll is
/// one cheap call.
fn anything_unfinished_in(app: &AppState) -> bool {
    load_in(app)
        .map(|registry| registry.items.values().any(Entry::unfinished))
        .unwrap_or(false)
}

/// Starts the progress ticker unless one already runs or nothing is
/// unfinished. Called after every add and whenever a sink arrives.
pub fn ensure_ticker() {
    ensure_ticker_in(&crate::state::state());
}

/// [`ensure_ticker`] against a state the caller already holds. See
/// [`load_in`].
pub fn ensure_ticker_in(app: &Arc<AppState>) {
    let mut ticking = app.downloads.ticking();
    if *ticking || !anything_unfinished_in(app) {
        return;
    }
    *ticking = true;
    crate::env::CONCURRENT.spawn(ticker(Arc::clone(app)));
}

/// Merges live progress once a second and emits what changed, until nothing
/// is unfinished any more. The merge itself blocks on the server's runtime,
/// so it runs on a blocking thread rather than a `CONCURRENT` worker.
///
/// It holds the state it was started for, and stops as soon as that is no
/// longer the process's: a shutdown retired its sink and its server, and a
/// later `init` gets its own ticker rather than inheriting this one.
///
/// That check is where the tick stops, not where it becomes safe: a shutdown
/// can land anywhere inside the blocking refresh that follows it, and the
/// whole refresh is the window. So every call the tick makes is an `_in`
/// against the state in hand; one that looked a state up would create the
/// one the shutdown has just taken.
async fn ticker(app: Arc<AppState>) {
    loop {
        tokio::time::sleep(TICK).await;
        if !crate::state::is_current(&app) {
            *app.downloads.ticking() = false;
            return;
        }
        let tick = Arc::clone(&app);
        match tokio::task::spawn_blocking(move || refresh_in(&tick)).await {
            Ok(Ok(refreshed)) => emit(&app, &refreshed.moved),
            Ok(Err(error)) => tracing::debug!(%error, "downloads progress tick failed"),
            Err(error) => tracing::warn!(%error, "downloads progress tick panicked"),
        }
        let mut ticking = app.downloads.ticking();
        if !anything_unfinished_in(&app) {
            *ticking = false;
            return;
        }
    }
}

/// Re-issues the pin for every entry the server may have forgotten (it
/// persists its own pin set, but a registry entry can outlive a purged cache
/// dir or a `downloadsDir` that came back). Complete downloads are left
/// alone: their bytes are on disk and re-pinning them would only re-check.
/// Blocks per entry while a magnet resolves, so run it off the boot path.
pub fn repin_unfinished() {
    repin_unfinished_in(&crate::state::state())
}

/// [`repin_unfinished`] against a state the caller already holds -- `init`'s,
/// which is the state this work belongs to. It is the other half of the
/// boot that can still be running after a shutdown (a magnet blocks it for
/// as long as the tracker takes), so it may not look a state up either, and
/// it stops once its instance has been retired. See [`load_in`].
///
/// Stopping there is also why [`update_in`]'s no-resurrection has no test
/// left: this was the one path a shutdown could drive into it, and the
/// point of the check is that it no longer does.
pub fn repin_unfinished_in(app: &Arc<AppState>) {
    let items = match load_in(app) {
        Ok(registry) => registry.items,
        Err(error) => {
            tracing::warn!(%error, "could not read the downloads registry to re-pin");
            return;
        }
    };
    for (key, entry) in items {
        if !entry.unfinished() {
            continue;
        }
        // The ticker's check, in the loop that needs it most, and twice:
        // once so a retired instance starts no more work, and once around
        // the pin, which is where the window actually is -- it blocks for
        // as long as a magnet takes to resolve. Every pin issued after a
        // shutdown fails against a server that is not running any more, and
        // the arm below would write that down as the download's own state.
        // A registry of "embedded server is not running" is then what the
        // next boot lists, until its own re-pin and the first tick after it
        // put the server's reading back over the top -- a failure this
        // process caused, reported as the download's.
        if !crate::state::is_current(app) {
            return;
        }
        match crate::server::pin_download(&entry.info_hash, entry.file_idx, &entry.announce) {
            Ok(_) => tracing::info!(key, "re-pinned an unfinished download"),
            Err(error) => {
                let failure = PinFailure::classify(&error);
                tracing::warn!(key, message = failure.message(), "could not re-pin");
                if !crate::state::is_current(app) {
                    return;
                }
                let _ = update_in(app, |registry| {
                    if let Some(entry) = registry.items.get_mut(&key) {
                        entry.state = State::Error;
                        entry.error = Some(failure.message().to_owned());
                    }
                    Ok(())
                });
            }
        }
    }
    ensure_ticker_in(app);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(meta: &str, video: &str) -> Entry {
        Entry {
            meta_id: meta.into(),
            video_id: video.into(),
            kind: "movie".into(),
            name: "A Film".into(),
            poster: None,
            stream: serde_json::json!({"infoHash": "abc", "fileIdx": 2}),
            info_hash: "abc".into(),
            file_idx: 2,
            announce: vec!["udp://tracker".into()],
            path: None,
            size: 0,
            downloaded: 0,
            state: State::Queued,
            error: None,
            created_at: None,
            completed_at: None,
            last_played_at: None,
            meta: None,
            stream_request: None,
            meta_request: None,
            extra: BTreeMap::new(),
        }
    }

    #[test]
    fn key_is_meta_and_video() {
        assert_eq!(entry("tt1", "tt1:1:2").key(), "tt1:tt1:1:2");
    }

    /// Where the downloads go is part of the file, not something derived
    /// from the settings, and the four answers it can hold are told apart
    /// across a round trip.
    #[test]
    fn the_destination_survives_the_file() {
        for destination in [
            Destination::Unset,
            Destination::Cache,
            Destination::Explicit("/sdcard/downloads".into()),
            Destination::PlatformDefault("/sdcard/files/downloads".into()),
        ] {
            let registry = Registry {
                destination: destination.clone(),
                ..Registry::default()
            };
            let bytes = serde_json::to_vec(&registry).unwrap();
            assert_eq!(
                Registry::parse(&bytes),
                registry,
                "{destination:?} came back as something else"
            );
        }
    }

    /// The two keys keep the shape every build so far has written, so a
    /// downgrade reads an answer rather than an open question -- and so
    /// this build reads what those builds left behind.
    #[test]
    fn the_destination_is_written_the_way_it_always_was() {
        let written = |destination: Destination| {
            String::from_utf8(
                serde_json::to_vec(&Registry {
                    destination,
                    ..Registry::default()
                })
                .unwrap(),
            )
            .unwrap()
        };
        assert!(
            written(Destination::Explicit("/sdcard/downloads".into()))
                .contains(r#""destinationSettled":true,"destinationChoice":"/sdcard/downloads""#),
            "a chosen path is the path, under its camelCase name"
        );
        assert!(
            written(Destination::Cache)
                .contains(r#""destinationSettled":true,"destinationChoice":null"#),
            "the cache is the null it has always been, settled"
        );
        assert!(
            written(Destination::Unset)
                .contains(r#""destinationSettled":false,"destinationChoice":null"#),
            "and nothing answered is the null with nothing settled"
        );

        assert_eq!(
            Registry::parse(br#"{"version":1,"items":{}}"#).destination,
            Destination::Unset,
            "a file from before the keys has answered nothing"
        );
        assert_eq!(
            Registry::parse(br#"{"version":1,"destinationSettled":true}"#).destination,
            Destination::Cache,
            "settled with no path recorded is the cache, on purpose"
        );
        assert_eq!(
            Registry::parse(br#"{"version":1,"destinationSettled":true,"destinationChoice":"/x"}"#)
                .destination,
            Destination::Explicit("/x".into()),
            "and a recorded path is the user's own answer"
        );
    }

    /// A default the app applied is not an answer, and is the one shape an
    /// older build could not have written -- so it is the only one written
    /// as an object, and a shape this build cannot read falls back on the
    /// two things it can always see.
    #[test]
    fn a_default_is_told_apart_from_an_answer() {
        let applied = Destination::PlatformDefault("/sdcard/files/downloads".into());
        assert!(applied.is_settled(), "the question is not open any more");
        assert!(!applied.is_chosen(), "but nobody chose it");
        assert_eq!(applied.path(), Some("/sdcard/files/downloads"));
        assert!(Destination::Explicit("/x".into()).is_chosen());
        assert!(Destination::Cache.is_chosen());
        assert!(!Destination::Unset.is_settled());

        assert_eq!(
            Registry::parse(
                br#"{"version":1,"destinationSettled":true,
                     "destinationChoice":{"kind":"platformDefault","path":"/sdcard/files"}}"#
            )
            .destination,
            Destination::PlatformDefault("/sdcard/files".into())
        );
        assert_eq!(
            Registry::parse(
                br#"{"version":1,"destinationSettled":true,
                     "destinationChoice":{"kind":"somethingNewer","path":"/x"}}"#
            )
            .destination,
            Destination::Explicit("/x".into()),
            "a kind this build does not know still names a path"
        );
        assert_eq!(
            Registry::parse(
                br#"{"version":1,"destinationSettled":true,
                     "destinationChoice":{"kind":"somethingNewer"}}"#
            )
            .destination,
            Destination::Cache,
            "and one that names none is the answer the flag reports"
        );
        assert_eq!(
            Registry::parse(
                br#"{"version":1,"destinationSettled":true,
                     "destinationChoice":{"kind":"platformDefault"}}"#
            )
            .destination,
            Destination::Unset,
            "a default that names no directory has applied nothing"
        );
    }

    /// A registry survives a round-trip, and reading is forgiving in the
    /// three ways that decide whether the app starts: a corrupt file, a
    /// newer `version` with keys this build does not know, and one entry
    /// that cannot be parsed among good ones.
    #[test]
    fn parsing_is_forward_compatible_and_never_fails() {
        let mut registry = Registry::default();
        registry.items.insert("tt1:tt1".into(), entry("tt1", "tt1"));
        let bytes = serde_json::to_vec(&registry).unwrap();
        assert_eq!(Registry::parse(&bytes), registry);

        assert_eq!(Registry::parse(b"{not json"), Registry::default());
        assert_eq!(Registry::parse(b"[]"), Registry::default());
        assert_eq!(
            Registry::parse(br#"{"version":1}"#),
            Registry {
                version: 1,
                ..Registry::default()
            }
        );

        // A newer file: the version is kept, the unknown entry key survives
        // a round-trip, and an entry missing `metaId` is dropped, not fatal.
        let newer = br#"{"version":9,"items":{
            "tt1:tt1":{"metaId":"tt1","videoId":"tt1","infoHash":"abc",
                       "state":"seeding","futureField":{"a":1}},
            "broken":{"videoId":"x"}}}"#;
        let parsed = Registry::parse(newer);
        assert_eq!(parsed.version, 9);
        assert_eq!(parsed.items.len(), 1, "one entry this build can read");
        let kept = &parsed.items["tt1:tt1"];
        assert_eq!(
            kept.state,
            State::Queued,
            "an unknown state reads as queued"
        );
        assert_eq!(kept.extra["futureField"], serde_json::json!({"a": 1}));
        let round_tripped = serde_json::to_value(&parsed).unwrap();
        assert_eq!(round_tripped["version"], 9);
        assert_eq!(
            round_tripped["items"]["tt1:tt1"]["futureField"],
            serde_json::json!({"a": 1}),
            "unknown keys are written back"
        );
        // The entry this build cannot read is written back *as it was*: a
        // forgiving read plus a whole-file rewrite would otherwise erase a
        // download the server is still pinning, with nothing left to find
        // it by.
        assert_eq!(
            round_tripped["items"]["broken"],
            serde_json::json!({"videoId": "x"}),
            "{round_tripped}"
        );
        assert_eq!(
            Registry::parse(&serde_json::to_vec(&parsed).unwrap()),
            parsed,
            "and again, unchanged"
        );
        // A downgrade never claims a newer file is this build's shape.
        assert_eq!(
            Registry::parse(&serde_json::to_vec(&parsed).unwrap()).version,
            9
        );
    }

    #[test]
    fn a_stream_without_an_info_hash_is_not_downloadable() {
        let error =
            torrent_source(&serde_json::json!({"url": "http://example/x.mkv"}), None).unwrap_err();
        assert!(error.to_string().contains("infoHash"), "{error}");

        let source = torrent_source(
            &serde_json::json!({"infoHash": "ABC", "fileIdx": 3, "announce": ["udp://t", 7]}),
            None,
        )
        .unwrap();
        assert_eq!(
            (source.info_hash.as_str(), source.file_idx),
            ("abc", Some(3)),
            "the hash is normalized"
        );
        assert_eq!(
            source.announce,
            vec!["udp://t".to_owned()],
            "non-strings dropped"
        );

        // An explicit override wins over the stream's own index, and the
        // `fileMustInclude` filters the play URL carries come along.
        let source = torrent_source(
            &serde_json::json!({
                "infoHash": "abc", "fileIdx": 3, "sources": ["dht:abc"],
                "fileMustInclude": ["S01E02"],
            }),
            Some(9),
        )
        .unwrap();
        assert_eq!(source.file_idx, Some(9));
        assert_eq!(source.announce, vec!["dht:abc".to_owned()]);
        assert_eq!(source.filters, vec!["S01E02".to_owned()]);
    }

    /// A stream that names no file names *no* file — not file 0. The app
    /// plays `/{infoHash}/-1` for it, so the index has to be resolved the
    /// way the server resolves that URL, or the download keeps (and later
    /// deletes) a different file than the one that streamed.
    #[test]
    fn no_file_index_is_not_index_zero() {
        for stream in [
            serde_json::json!({"infoHash": "abc"}),
            serde_json::json!({"infoHash": "abc", "fileIdx": -1}),
            serde_json::json!({"infoHash": "abc", "fileIdx": null}),
        ] {
            let source = torrent_source(&stream, None).unwrap();
            assert_eq!(source.file_idx, None, "{stream}");
        }
        // A negative override says the same thing as a negative `fileIdx`.
        let source = torrent_source(&serde_json::json!({"infoHash": "abc"}), Some(-1)).unwrap();
        assert_eq!(source.file_idx, None);
    }

    /// The rule the media route applies to `-1`, mirrored: filters first,
    /// then the largest media file, then the largest file at all.
    #[test]
    fn the_resolved_file_is_the_one_the_player_would_open() {
        let files: Vec<(String, u64)> = [
            ("readme.nfo", 100_u64),
            ("sample.mkv", 1_000),
            ("Movie.2160p.mkv", 9_000),
            ("extras.zip", 20_000),
        ]
        .into_iter()
        .map(|(name, length)| (name.to_owned(), length))
        .collect();

        assert_eq!(
            media_file_index(&files, &[]),
            Some(2),
            "the largest media file, not the largest file"
        );
        assert_eq!(
            media_file_index(&files, &["sample".to_owned()]),
            Some(1),
            "a fileMustInclude filter wins"
        );
        assert_eq!(
            media_file_index(&files, &["/mo.ie\\.2160p/i".to_owned()]),
            Some(2),
            "a /regex/i filter is a regex, like the server's"
        );
        assert_eq!(
            media_file_index(&files, &["nothing matches".to_owned()]),
            Some(2),
            "an unmatched filter falls back to the largest media file"
        );

        // No media extension at all: the largest file of any kind.
        let blobs: Vec<(String, u64)> = [("a.bin", 10_u64), ("b.bin", 20)]
            .into_iter()
            .map(|(name, length)| (name.to_owned(), length))
            .collect();
        assert_eq!(media_file_index(&blobs, &[]), Some(1));

        // Nothing to choose from: the caller has to wait for metadata.
        assert_eq!(media_file_index(&[], &[]), None);
        assert_eq!(media_file_index(&[], &["x".to_owned()]), None);
    }

    /// The state a live `DownloadInfo` implies, and the `completedAt` stamp
    /// that goes with it.
    #[test]
    fn live_stats_decide_the_state() {
        let now = Utc::now();
        let info = |downloaded: u64, complete: bool, phase: &str, error: Option<&str>| {
            serde_json::from_value::<DownloadInfo>(serde_json::json!({
                "infoHash": "abc",
                "fileIdx": 2,
                "path": "/downloads/abc/film.mkv",
                "name": "film.mkv",
                "length": 100,
                "downloaded": downloaded,
                "complete": complete,
                "phase": phase,
                "error": error,
            }))
            .expect("DownloadInfo")
        };

        let mut e = entry("tt1", "tt1");
        e.apply_live(&info(0, false, "resolvingMetadata", None), now);
        assert_eq!(e.state, State::Queued);
        assert_eq!(e.size, 100);
        assert_eq!(e.path.as_deref(), Some("/downloads/abc/film.mkv"));

        e.apply_live(&info(40, false, "ready", None), now);
        assert_eq!((e.state, e.downloaded), (State::Downloading, 40));
        assert_eq!(e.completed_at, None);

        e.apply_live(&info(100, true, "ready", None), now);
        assert_eq!(e.state, State::Complete);
        assert_eq!(e.completed_at, Some(now));

        // Still complete later: the first stamp is kept.
        let later = now + chrono::Duration::seconds(60);
        e.apply_live(&info(100, true, "ready", None), later);
        assert_eq!(e.completed_at, Some(now));

        // The file really went away: a reading that counted the bytes and
        // found fewer than the file has drops both the state and the stamp.
        e.apply_live(&info(0, false, "buffering", None), later);
        assert_eq!((e.state, e.completed_at), (State::Downloading, None));

        e.apply_live(&info(10, false, "error", Some("no peers")), later);
        assert_eq!(e.state, State::Error);
        assert_eq!(e.error.as_deref(), Some("no peers"));
        // An error the phase does not show still counts.
        e.apply_live(&info(10, false, "buffering", Some("dormant")), later);
        assert_eq!(e.state, State::Error);
    }

    /// The server reports `downloaded: 0, complete: false` in states where
    /// the file may be whole on disk: while the torrent hash-checks, and for
    /// a pin whose torrent it does not have right now. A finished download
    /// must survive both -- offline Play is gated on `complete`, and the
    /// `completedAt` it would erase is not recoverable.
    #[test]
    fn transient_zeros_do_not_demote_a_finished_download() {
        let now = Utc::now();
        let later = now + chrono::Duration::seconds(60);
        let complete = serde_json::from_value::<DownloadInfo>(serde_json::json!({
            "infoHash": "abc", "fileIdx": 2, "path": "/downloads/abc/film.mkv",
            "name": "film.mkv", "length": 100, "downloaded": 100, "complete": true,
            "phase": "ready", "error": null,
        }))
        .expect("DownloadInfo");
        // What a re-opened torrent reads while librqbit re-checks it, and
        // what a pin whose torrent is not managed reads (no path, no length,
        // no progress -- `routes::downloads::DORMANT_DOWNLOAD_ERROR`).
        let checking = serde_json::from_value::<DownloadInfo>(serde_json::json!({
            "infoHash": "abc", "fileIdx": 2, "path": "/downloads/abc/film.mkv",
            "name": "film.mkv", "length": 100, "downloaded": 0, "complete": false,
            "phase": "checking", "error": null,
        }))
        .expect("DownloadInfo");
        let dormant = serde_json::from_value::<DownloadInfo>(serde_json::json!({
            "infoHash": "abc", "fileIdx": 2, "path": null, "name": "",
            "length": 0, "downloaded": 0, "complete": false,
            "phase": "error", "error": "the torrent is not managed right now",
        }))
        .expect("DownloadInfo");

        for transient in [&checking, &dormant] {
            let mut e = entry("tt1", "tt1");
            e.apply_live(&complete, now);
            assert_eq!((e.state, e.downloaded), (State::Complete, 100));
            e.apply_live(transient, later);
            assert_eq!(e.state, State::Complete, "{transient:?}");
            assert_eq!(e.downloaded, 100, "{transient:?}");
            assert_eq!(e.completed_at, Some(now), "{transient:?}");
            assert_eq!(e.path.as_deref(), Some("/downloads/abc/film.mkv"));
            assert_eq!(e.size, 100, "the placeholder length is not a size");
        }
        // The reason it is not reachable still comes through.
        let mut e = entry("tt1", "tt1");
        e.apply_live(&complete, now);
        e.apply_live(&dormant, later);
        assert_eq!(e.error, dormant.error);

        // An unfinished download keeps the progress it had, and says why it
        // is not moving.
        let mut e = entry("tt1", "tt1");
        e.apply_live(
            &serde_json::from_value::<DownloadInfo>(serde_json::json!({
                "infoHash": "abc", "fileIdx": 2, "path": "/downloads/abc/film.mkv",
                "name": "film.mkv", "length": 100, "downloaded": 40, "complete": false,
                "phase": "buffering", "error": null,
            }))
            .expect("DownloadInfo"),
            now,
        );
        assert_eq!((e.state, e.downloaded), (State::Downloading, 40));
        e.apply_live(&dormant, later);
        assert_eq!((e.state, e.downloaded), (State::Error, 40));
        e.apply_live(&checking, later);
        assert_eq!((e.state, e.downloaded), (State::Queued, 40));
        assert_eq!(e.error, None, "the check is not an error");
    }

    #[test]
    fn unfinished_is_what_the_ticker_polls_for() {
        let mut e = entry("tt1", "tt1");
        for state in [State::Queued, State::Downloading, State::Error] {
            e.state = state;
            assert!(e.unfinished(), "{state:?}");
        }
        for state in [State::Complete, State::Paused] {
            e.state = state;
            assert!(!e.unfinished(), "{state:?}");
        }
    }

    /// The pin errors the UI must be able to tell apart survive the trip
    /// through `anyhow`, with the numbers a "not enough space" message needs
    /// and never a local path.
    #[test]
    fn pin_failures_are_classified_with_their_numbers() {
        let error = anyhow::Error::new(PinDownloadError::InsufficientSpace {
            required: 700,
            available: 100,
            margin: 500,
        });
        let failure = PinFailure::classify(&error);
        assert_eq!(
            failure,
            PinFailure::InsufficientSpace {
                required: 700,
                available: 100,
                margin: 500,
                message: failure.message().to_owned(),
            }
        );
        let json = serde_json::to_value(&failure).unwrap();
        assert_eq!(json["kind"], "insufficientSpace");
        assert_eq!(json["required"], 700);
        assert!(json["message"].as_str().unwrap().contains("700"));

        let error = anyhow::Error::new(PinDownloadError::FileNotFound {
            file_idx: 9,
            file_count: 2,
        });
        let json = serde_json::to_value(PinFailure::classify(&error)).unwrap();
        assert_eq!(json["kind"], "fileNotFound");
        assert_eq!(json["fileIdx"], 9, "camelCase, like every other payload");
        assert_eq!(json["fileCount"], 2);

        // A magnet add that never resolved is its own kind.
        // (Constructed through the backend variant here: the magnet error
        // type is not re-exported, and the UI only needs the two apart.)
        // A backend error's own chain names server paths; the classified
        // one carries the server's client-safe sentence instead.
        let error = anyhow::Error::new(PinDownloadError::Backend(anyhow::anyhow!(
            "error opening /home/someone/downloads/abc/film.mkv"
        )));
        let failure = PinFailure::classify(&error);
        assert_eq!(
            serde_json::to_value(&failure).unwrap()["kind"],
            "backend",
            "{failure:?}"
        );
        assert!(!failure.message().contains("/home/someone"), "{failure:?}");

        // Anything that is not a pin error at all (no server running).
        let failure = PinFailure::classify(&anyhow::anyhow!("embedded server is not running"));
        assert_eq!(
            failure,
            PinFailure::Unavailable {
                message: "embedded server is not running".into()
            }
        );
    }

    /// The half of [`open`] that decides: only a finished entry whose file
    /// is really there is playable off the device, and the URL is a real
    /// `file://` one (a space in the name and all).
    #[test]
    fn only_a_finished_file_that_is_there_is_playable() {
        let dir = std::env::temp_dir().join(format!("xtremio-open-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("A Film 1080p.mkv");
        std::fs::write(&file, b"bytes").unwrap();

        let mut entry = entry("tt1", "tt1");
        entry.path = Some(file.to_string_lossy().into_owned());

        // Not finished: what is on disk is a fragment, whatever its name.
        entry.state = State::Downloading;
        assert_eq!(local_url(&entry), Err(OpenFailure::Incomplete));

        entry.state = State::Complete;
        let url = local_url(&entry).expect("a finished file is playable");
        assert!(url.starts_with("file://"), "{url}");
        assert!(url.ends_with("/A%20Film%201080p.mkv"), "{url}");
        assert_eq!(
            url::Url::parse(&url).unwrap().to_file_path().unwrap(),
            file,
            "the URL points back at the file it was built from"
        );

        // The file went away under a complete entry (an unplugged volume,
        // or a deletion from outside the app), and an entry the server
        // never gave a path.
        std::fs::remove_file(&file).unwrap();
        assert_eq!(local_url(&entry), Err(OpenFailure::Missing));
        entry.path = None;
        assert_eq!(local_url(&entry), Err(OpenFailure::Missing));
        // A directory is not a file to play either.
        entry.path = Some(dir.to_string_lossy().into_owned());
        assert_eq!(local_url(&entry), Err(OpenFailure::Missing));
        std::fs::remove_dir_all(&dir).ok();
    }

    /// The wire shape the Dart side reads: a refusal names its reason and
    /// carries no URL, and the reasons are camelCase like everything else.
    #[test]
    fn a_refused_open_is_a_value_with_a_reason() {
        let json =
            serde_json::to_value(OpenOutcome::refused("tt1:tt1", OpenFailure::Missing)).unwrap();
        assert_eq!(json["ok"], false);
        assert_eq!(json["key"], "tt1:tt1");
        assert_eq!(json["reason"], "missing");
        assert!(json.get("url").is_none(), "{json}");
        assert!(json.get("entry").is_none(), "{json}");
        assert_eq!(
            serde_json::to_value(OpenFailure::Incomplete).unwrap(),
            "incomplete"
        );
        assert_eq!(
            serde_json::to_value(OpenFailure::Unknown).unwrap(),
            "unknown"
        );
    }

    /// A progress event is the six fields that move and the key they move
    /// under -- not the entry, whose meta snapshot, raw stream JSON and two
    /// addon requests would be serialized here and decoded on the UI isolate
    /// once a second for the length of a download.
    #[test]
    fn a_progress_event_carries_what_moves_and_nothing_else() {
        let mut entry = entry("tt1", "tt1");
        entry.meta = Some(serde_json::json!({"id": "tt1", "name": "A Film"}));
        entry.stream_request = Some(serde_json::json!({"base": "https://addon"}));
        entry.downloaded = 512;
        entry.size = 1024;
        entry.state = State::Downloading;
        entry.path = Some("/downloads/a.mkv".into());

        let progress = Progress::of("tt1:tt1", &entry);
        let payload = serde_json::to_value(ProgressEvent {
            version: VERSION,
            progress: std::slice::from_ref(&progress),
        })
        .unwrap();
        assert_eq!(
            payload,
            serde_json::json!({
                "version": 1,
                "progress": [{
                    "key": "tt1:tt1",
                    "downloaded": 512,
                    "size": 1024,
                    "state": "downloading",
                    "path": "/downloads/a.mkv",
                    "error": null,
                    "completedAt": null,
                }],
            }),
            "the narrow event, under camelCase names like the rest of the file"
        );
        assert!(
            !payload.to_string().contains("A Film"),
            "and nothing of the entry the list already carries"
        );
    }

    /// The disk write is what a tick can skip, not the event: byte counts
    /// are a cache of the server's own numbers and the next write that
    /// matters carries them, while a state, a path, an error or a finished
    /// file goes down at once.
    #[test]
    fn only_a_moved_byte_count_may_wait_for_the_disk() {
        let one = |change: fn(&mut Entry)| {
            let mut before = Registry::default();
            before.items.insert("tt1:tt1".into(), entry("tt1", "tt1"));
            let mut after = before.clone();
            change(after.items.get_mut("tt1:tt1").unwrap());
            (before, after)
        };

        let (before, after) = one(|entry| entry.downloaded = 4096);
        assert!(only_downloaded_moved(&before, &after));
        for (what, change) in [
            (
                "a state",
                (|entry: &mut Entry| entry.state = State::Complete) as fn(&mut Entry),
            ),
            ("a path", |entry| {
                entry.path = Some("/downloads/a.mkv".into())
            }),
            ("an error", |entry| entry.error = Some("no peers".into())),
            ("a finished file", |entry| {
                entry.completed_at = Some(Utc::now())
            }),
            ("a size", |entry| entry.size = 1024),
        ] {
            let (before, after) = one(change);
            assert!(
                !only_downloaded_moved(&before, &after),
                "{what} has to reach the disk"
            );
        }

        let (before, mut after) = one(|entry| entry.downloaded = 4096);
        after.items.insert("tt2:tt2".into(), entry("tt2", "tt2"));
        assert!(!only_downloaded_moved(&before, &after), "an entry appeared");
        let (before, mut after) = one(|entry| entry.downloaded = 4096);
        after.destination = Destination::Cache;
        assert!(
            !only_downloaded_moved(&before, &after),
            "and where the downloads go is not progress at all"
        );
    }

    /// What that means for the file: a tick that only moved a byte count
    /// leaves it exactly as it was, and the next change that matters
    /// rewrites it with everything since.
    #[test]
    fn a_progress_only_tick_does_not_rewrite_the_file() {
        crate::env::with_storage_dir(|dir| {
            let file = dir.join(FILE_NAME);
            update(|registry| {
                registry.items.insert("tt1:tt1".into(), entry("tt1", "tt1"));
                Ok(())
            })
            .expect("first write");
            let written = std::fs::read(&file).expect("the registry is on disk");

            update_when_in(
                &crate::state::state(),
                |registry| {
                    registry.items.get_mut("tt1:tt1").unwrap().downloaded = 4096;
                    Ok(())
                },
                refresh_needs_a_write,
            )
            .expect("tick");
            assert_eq!(
                std::fs::read(&file).unwrap(),
                written,
                "a byte count alone is not worth an fsync a second"
            );

            update_when_in(
                &crate::state::state(),
                |registry| {
                    let entry = registry.items.get_mut("tt1:tt1").unwrap();
                    entry.downloaded = 8192;
                    entry.state = State::Complete;
                    Ok(())
                },
                refresh_needs_a_write,
            )
            .expect("tick");
            let after = String::from_utf8(std::fs::read(&file).unwrap()).unwrap();
            assert!(after.contains(r#""state":"complete""#), "{after}");
            assert!(
                after.contains(r#""downloaded":8192"#),
                "with the numbers since: {after}"
            );
        });
    }

    /// A row is pushed because it moved, so the same numbers are not pushed
    /// twice -- which is what a tick whose write was skipped keeps finding
    /// against the file. Against a state of this test's own: what has been
    /// sent is a property of an `AppState`, so this neither disturbs the
    /// process's sink nor cares what else ran first.
    #[test]
    fn a_row_that_has_not_moved_is_not_pushed_again() {
        let app = AppState::default();
        let (tx, rx) = std::sync::mpsc::channel();
        *app.downloads.sink_mut() = Some(Box::new(move |event| tx.send(event).is_ok()));

        let mut entry = entry("tt1", "tt1");
        entry.downloaded = 4096;
        let progress = Progress::of("tt1:tt1", &entry);
        emit(&app, std::slice::from_ref(&progress));
        let event = rx.try_recv().expect("the row moved");
        assert!(event.contains(r#""downloaded":4096"#), "{event}");

        emit(&app, std::slice::from_ref(&progress));
        assert!(rx.try_recv().is_err(), "the same numbers say nothing new");

        entry.downloaded = 8192;
        emit(&app, &[Progress::of("tt1:tt1", &entry)]);
        let event = rx.try_recv().expect("and a row that moved does");
        assert!(event.contains(r#""downloaded":8192"#), "{event}");
    }

    #[test]
    fn the_registry_needs_a_storage_dir() {
        assert!(
            registry_path_in(None).is_err(),
            "with no storage directory there is nowhere to keep the registry"
        );
        assert_eq!(
            registry_path_in(Some(PathBuf::from("/storage"))).unwrap(),
            PathBuf::from("/storage").join(FILE_NAME),
            "and with one it is a file next to the buckets"
        );
    }
}
