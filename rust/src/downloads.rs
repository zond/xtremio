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
use std::sync::{Mutex, RwLock};
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize};
use stream_server::{DownloadInfo, PinDownloadError};

/// Schema version of `downloads.json`. A file that names a higher one is
/// read anyway (unknown keys survive in [`Entry::extra`]) and keeps its
/// version when written back, so a downgrade does not silently claim the
/// newer file is this build's shape.
pub const VERSION: u32 = 1;

/// The registry file, under `crate::env::storage_dir()`.
const FILE_NAME: &str = "downloads.json";

/// How often [`ticker`] merges live progress while anything is unfinished.
const TICK: Duration = Duration::from_secs(1);

/// Serializes read-modify-write cycles on the registry file: the FFI calls,
/// the progress ticker and the init-time re-pin all run on different
/// threads and must not lose each other's edits.
static FILE_LOCK: Mutex<()> = Mutex::new(());

/// Receives one serialized progress payload; returns `false` once closed.
pub type EventSink = Box<dyn Fn(String) -> bool + Send + Sync>;

static EVENT_SINK: RwLock<Option<EventSink>> = RwLock::new(None);

/// Whether a [`ticker`] task is running. Taken before [`FILE_LOCK`] wherever
/// both are needed.
static TICKING: Mutex<bool> = Mutex::new(false);

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
    /// the first time the file is whole and cleared if it stops being whole
    /// (a deleted file the server re-downloads).
    fn apply_live(&mut self, info: &DownloadInfo, now: DateTime<Utc>) {
        if info.path.is_some() {
            self.path = info.path.clone();
        }
        if info.length > 0 {
            self.size = info.length;
        }
        self.downloaded = info.downloaded;
        self.error = info.error.clone();
        let phase = phase(info);
        self.state = if info.complete {
            State::Complete
        } else if info.error.is_some() || phase == "error" {
            State::Error
        } else if matches!(phase.as_str(), "resolvingMetadata" | "checking") {
            State::Queued
        } else {
            State::Downloading
        };
        match self.state {
            State::Complete if self.completed_at.is_none() => self.completed_at = Some(now),
            State::Complete => {}
            _ => self.completed_at = None,
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

/// `downloads.json` as a whole: the file shape, and what the list call and
/// the progress events emit.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Registry {
    pub version: u32,
    #[serde(default)]
    pub items: BTreeMap<String, Entry>,
}

impl Default for Registry {
    fn default() -> Self {
        Self {
            version: VERSION,
            items: BTreeMap::new(),
        }
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
        let Some(items) = value.get("items").and_then(serde_json::Value::as_object) else {
            tracing::warn!("downloads registry has no items object; starting empty");
            return Self {
                version,
                items: BTreeMap::new(),
            };
        };
        let mut parsed = BTreeMap::new();
        for (key, raw) in items {
            match serde_json::from_value::<Entry>(raw.clone()) {
                Ok(entry) => {
                    parsed.insert(key.clone(), entry);
                }
                Err(error) => {
                    tracing::warn!(key, %error, "unreadable download entry; dropping it")
                }
            }
        }
        Self {
            version,
            items: parsed,
        }
    }
}

/// Where the registry lives. Errors before `core_init` has pointed storage
/// at the app directory.
fn registry_path() -> anyhow::Result<PathBuf> {
    crate::env::storage_dir()
        .map(|dir| dir.join(FILE_NAME))
        .ok_or_else(|| anyhow::anyhow!("storage directory is not set; is the core initialized?"))
}

fn file_lock() -> std::sync::MutexGuard<'static, ()> {
    FILE_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn load_locked() -> anyhow::Result<Registry> {
    let path = registry_path()?;
    match std::fs::read(&path) {
        Ok(bytes) => Ok(Registry::parse(&bytes)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Registry::default()),
        Err(error) => Err(anyhow::anyhow!("read downloads registry: {error}")),
    }
}

/// The registry as it is on disk.
pub fn load() -> anyhow::Result<Registry> {
    let _guard = file_lock();
    load_locked()
}

/// Runs `f` against the registry and writes it back if `f` changed anything.
/// The file lock is held throughout, so two concurrent updates cannot lose
/// each other's edits.
pub fn update<T>(f: impl FnOnce(&mut Registry) -> anyhow::Result<T>) -> anyhow::Result<T> {
    let _guard = file_lock();
    let mut registry = load_locked()?;
    let before = registry.clone();
    let result = f(&mut registry)?;
    if registry != before {
        let bytes = serde_json::to_vec(&registry)?;
        crate::env::write_atomically(&registry_path()?, &bytes)
            .map_err(|error| anyhow::anyhow!("write downloads registry: {error}"))?;
    }
    Ok(result)
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
    /// episode's index itself.
    #[serde(default)]
    pub file_idx: Option<usize>,
    #[serde(default)]
    pub meta: Option<serde_json::Value>,
    #[serde(default)]
    pub stream_request: Option<serde_json::Value>,
    #[serde(default)]
    pub meta_request: Option<serde_json::Value>,
}

/// The torrent coordinates of a stream: `infoHash`, the file index and the
/// trackers. Errors when the stream is not a torrent, which is the one
/// thing the caller must not get wrong.
fn torrent_source(
    stream: &serde_json::Value,
    file_idx_override: Option<usize>,
) -> anyhow::Result<(String, usize, Vec<String>)> {
    let info_hash = stream
        .get("infoHash")
        .and_then(serde_json::Value::as_str)
        .filter(|hash| !hash.is_empty())
        .ok_or_else(|| anyhow::anyhow!("only torrent streams can be downloaded (no infoHash)"))?
        .to_lowercase();
    let file_idx = file_idx_override
        .or_else(|| {
            stream
                .get("fileIdx")
                .and_then(serde_json::Value::as_u64)
                .map(|idx| idx as usize)
        })
        .unwrap_or(0);
    // `announce` is stremio-core's field; `sources` is what addons that
    // speak the server's shape send. Either is only consulted when this pin
    // is what creates the engine.
    let announce = ["announce", "sources"]
        .iter()
        .find_map(|key| stream.get(key).and_then(serde_json::Value::as_array))
        .map(|list| {
            list.iter()
                .filter_map(|item| item.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default();
    Ok((info_hash, file_idx, announce))
}

/// Pins the request's stream and records it. An existing entry for the same
/// meta/video keeps its `createdAt` and `lastPlayedAt` and takes everything
/// else from this call, so re-downloading after a failure is one call.
pub fn add(request: AddRequest) -> anyhow::Result<AddOutcome> {
    let (info_hash, file_idx, announce) = torrent_source(&request.stream, request.file_idx)?;
    let key = Entry::key_of(&request.meta_id, &request.video_id);

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
    // `pin_download` already reports the path when the engine knows it; ask
    // again only for the case where it did not (metadata just landed).
    let path = match info.path.clone() {
        Some(path) => Some(path),
        None => crate::server::download_path(&info_hash, file_idx).unwrap_or_default(),
    };

    let now = Utc::now();
    let entry = update(|registry| {
        let previous = registry.items.get(&key);
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
            path: path.clone(),
            size: 0,
            downloaded: 0,
            state: State::Queued,
            error: None,
            created_at: previous.and_then(|entry| entry.created_at).or(Some(now)),
            completed_at: None,
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
pub fn remove(key: &str, delete_files: bool) -> anyhow::Result<RemoveOutcome> {
    let Some(entry) = load()?.items.get(key).cloned() else {
        return Ok(RemoveOutcome {
            removed: false,
            unpinned: false,
            deleted_files: false,
        });
    };
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

/// Merges the server's live download stats into the registry, writes it back
/// when anything moved, and returns just the entries that changed (in the
/// same envelope [`list`] answers, so one Dart parser reads both).
pub fn refresh() -> anyhow::Result<Registry> {
    let live = crate::server::downloads()?;
    let now = Utc::now();
    let mut version = VERSION;
    update(|registry| {
        version = registry.version;
        let mut changed = BTreeMap::new();
        for (key, entry) in registry.items.iter_mut() {
            let before = entry.clone();
            if let Some(info) = live.iter().find(|info| {
                info.info_hash.eq_ignore_ascii_case(&entry.info_hash)
                    && info.file_idx == entry.file_idx
            }) {
                entry.apply_live(info, now);
            }
            if *entry != before {
                changed.insert(key.clone(), entry.clone());
            }
        }
        Ok(changed)
    })
    .map(|changed| Registry {
        version,
        items: changed,
    })
}

/// The whole registry with live progress merged in. Falls back to what is on
/// disk when the server cannot be asked, so the list still renders offline.
pub fn list() -> anyhow::Result<Registry> {
    if let Err(error) = refresh() {
        tracing::debug!(%error, "listing downloads without live progress");
    }
    load()
}

/// Points the server's `downloadsDir` at `path` (or unsets it with `None`),
/// with the validation and persistence `POST /settings` does.
pub fn set_dir(path: Option<String>) -> anyhow::Result<stream_server::ServerSettings> {
    crate::server::update_settings(serde_json::json!({ "downloadsDir": path }))
}

/// Installs the progress sink, replacing any previous one, and starts the
/// ticker if there is anything to watch. Nothing is buffered for a missing
/// sink the way core events are: the full picture is one `downloads_list`
/// away, so a late subscriber loses nothing that matters.
pub fn set_event_sink(sink: EventSink) {
    *EVENT_SINK
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(sink);
    ensure_ticker();
}

fn emit(changed: &Registry) {
    if changed.items.is_empty() {
        return;
    }
    let payload = match serde_json::to_string(changed) {
        Ok(payload) => payload,
        Err(error) => {
            tracing::warn!(%error, "could not serialize a downloads progress event");
            return;
        }
    };
    let delivered = {
        let guard = EVENT_SINK
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        guard.as_ref().map(|sink| sink(payload))
    };
    if delivered == Some(false) {
        tracing::info!("downloads event sink closed");
        *EVENT_SINK
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
    }
}

fn ticking() -> std::sync::MutexGuard<'static, bool> {
    TICKING
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// True while any entry is neither complete nor paused — an errored one
/// counts, because peers can still turn up and the poll is one cheap call.
fn anything_unfinished() -> bool {
    load()
        .map(|registry| registry.items.values().any(Entry::unfinished))
        .unwrap_or(false)
}

/// Starts the progress ticker unless one already runs or nothing is
/// unfinished. Called after every add and whenever a sink arrives.
pub fn ensure_ticker() {
    let mut ticking = ticking();
    if *ticking || !anything_unfinished() {
        return;
    }
    *ticking = true;
    crate::env::CONCURRENT.spawn(ticker());
}

/// Merges live progress once a second and emits what changed, until nothing
/// is unfinished any more. The merge itself blocks on the server's runtime,
/// so it runs on a blocking thread rather than a `CONCURRENT` worker.
async fn ticker() {
    loop {
        tokio::time::sleep(TICK).await;
        match tokio::task::spawn_blocking(refresh).await {
            Ok(Ok(changed)) => emit(&changed),
            Ok(Err(error)) => tracing::debug!(%error, "downloads progress tick failed"),
            Err(error) => tracing::warn!(%error, "downloads progress tick panicked"),
        }
        let mut ticking = ticking();
        if !anything_unfinished() {
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
    let items = match load() {
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
        match crate::server::pin_download(&entry.info_hash, entry.file_idx, &entry.announce) {
            Ok(_) => tracing::info!(key, "re-pinned an unfinished download"),
            Err(error) => {
                let failure = PinFailure::classify(&error);
                tracing::warn!(key, message = failure.message(), "could not re-pin");
                let _ = update(|registry| {
                    if let Some(entry) = registry.items.get_mut(&key) {
                        entry.state = State::Error;
                        entry.error = Some(failure.message().to_owned());
                    }
                    Ok(())
                });
            }
        }
    }
    ensure_ticker();
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
                items: BTreeMap::new()
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
        assert_eq!(parsed.items.len(), 1, "the unreadable entry was dropped");
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

        let (hash, idx, announce) = torrent_source(
            &serde_json::json!({"infoHash": "ABC", "fileIdx": 3, "announce": ["udp://t", 7]}),
            None,
        )
        .unwrap();
        assert_eq!((hash.as_str(), idx), ("abc", 3), "the hash is normalized");
        assert_eq!(announce, vec!["udp://t".to_owned()], "non-strings dropped");

        // No `fileIdx` means the only file there can be; an explicit
        // override wins over the stream's own.
        let (_, idx, _) = torrent_source(&serde_json::json!({"infoHash": "abc"}), None).unwrap();
        assert_eq!(idx, 0);
        let (_, idx, announce) = torrent_source(
            &serde_json::json!({"infoHash": "abc", "fileIdx": 3, "sources": ["dht:abc"]}),
            Some(9),
        )
        .unwrap();
        assert_eq!(idx, 9);
        assert_eq!(announce, vec!["dht:abc".to_owned()]);
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

        // The file went away: not complete any more, and no stale stamp.
        e.apply_live(&info(0, false, "checking", None), later);
        assert_eq!((e.state, e.completed_at), (State::Queued, None));

        e.apply_live(&info(10, false, "error", Some("no peers")), later);
        assert_eq!(e.state, State::Error);
        assert_eq!(e.error.as_deref(), Some("no peers"));
        // An error the phase does not show still counts.
        e.apply_live(&info(10, false, "buffering", Some("dormant")), later);
        assert_eq!(e.state, State::Error);
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

    #[test]
    fn the_registry_needs_a_storage_dir() {
        // The lib test binary never calls `core_init`, so storage is unset.
        assert!(registry_path().is_err());
    }
}
