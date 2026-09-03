//! FRB surface for offline downloads: add, remove, list, the destination
//! directory, and a progress stream. JSON strings in and out, all real work
//! in `crate::downloads`; like every other server call these go over the
//! handle's library API, never over HTTP.

use crate::frb_generated::StreamSink;
use crate::guard::guarded;

/// Pins a torrent stream as an offline download and records it.
///
/// `request_json` is `{"metaId","videoId","type","name","poster","stream",
/// "fileIdx"?,"meta"?,"streamRequest"?,"metaRequest"?}`; `stream` is the
/// addon's raw stream JSON and must be a torrent (`infoHash`), `fileIdx`
/// overrides the stream's own index for a caller that resolved the episode
/// itself. A stream with no `fileIdx`, or a negative one (the `-1` the
/// player's URL carries), downloads the file that URL would play: the
/// `fileMustInclude` match, else the largest media file, asked of the
/// server. The entry is keyed `"{metaId}:{videoId}"`, and adding the same
/// pair again re-pins it while keeping its `createdAt`/`lastPlayedAt` —
/// releasing the pin (and the bytes) of the download it replaces, unless
/// another entry names that same file.
///
/// Answers `{"ok":true,"key":…,"entry":{…}}`, or, when the server refuses
/// the pin, `{"ok":false,"key":…,"error":{"kind":…,"message":…}}` —
/// `insufficientSpace` (with `required`/`available`/`margin` in bytes),
/// `fileNotFound`, `magnetAdd`, `backend` or `unavailable`. Only a
/// malformed request or a stream that is not a torrent raises. Blocks the
/// FRB worker while the pin is taken (a magnet resolves its metadata
/// first); never call from the UI thread.
pub fn downloads_add(request_json: String) -> anyhow::Result<String> {
    guarded(|| {
        let mut deserializer = serde_json::Deserializer::from_str(&request_json);
        let request: crate::downloads::AddRequest =
            serde_path_to_error::deserialize(&mut deserializer).map_err(|error| {
                anyhow::anyhow!(
                    "invalid download request at `{}`: {}",
                    error.path(),
                    error.inner()
                )
            })?;
        let outcome = crate::downloads::add(request)?;
        serde_json::to_string(&outcome).map_err(Into::into)
    })
}

/// Drops the download `key` (`"{metaId}:{videoId}"`): the pin goes, and with
/// `delete_files` the bytes too — the whole torrent when this was its last
/// pin, only that file while others stay pinned. Answers
/// `{"removed":…,"unpinned":…,"deletedFiles":…}`, where `deletedFiles`
/// reports what actually left the disk rather than echoing the flag, and
/// `removed: false` means the registry had no such entry. When another
/// download names that same file — one torrent streamed under two metas —
/// only the entry goes and `unpinned` is `false`; the pin, and the bytes,
/// are the other one's too. Errors when the server is not running, leaving
/// the entry in place.
pub fn downloads_remove(key: String, delete_files: bool) -> anyhow::Result<String> {
    guarded(|| {
        let outcome = crate::downloads::remove(&key, delete_files)?;
        serde_json::to_string(&outcome).map_err(Into::into)
    })
}

/// Every download as `{"version":1,"items":{"{metaId}:{videoId}":{…}}}`,
/// with live progress (`downloaded`, `size`, `path`, `state`, `error`)
/// merged in from the server. When the server cannot be asked, what is on
/// disk is answered instead, so the list still renders offline. An entry
/// this build cannot parse stays in the file but is left out here — the
/// caller could not read it either.
pub fn downloads_list() -> anyhow::Result<String> {
    guarded(|| serde_json::to_string(&crate::downloads::list()?).map_err(Into::into))
}

/// Points the server's `downloadsDir` at `path`, or unsets it (back to the
/// torrent cache root) with null. Validated and persisted exactly as
/// `POST /settings` does: the path must be absolute, creatable, writable and
/// not at or above a cache root. Returns the settings afterwards as JSON.
pub fn downloads_set_dir(path: Option<String>) -> anyhow::Result<String> {
    guarded(|| serde_json::to_string(&crate::downloads::set_dir(path)?).map_err(Into::into))
}

/// Progress, one JSON string per change: the same envelope as
/// [`downloads_list`], carrying only the entries that moved. The ticker
/// behind it runs about once a second and only while something is
/// unfinished, so a screen with nothing downloading costs nothing. Nothing
/// is buffered for a late subscriber — call `downloads_list` for the full
/// picture and treat these as updates to it.
pub fn downloads_events(sink: StreamSink<String>) -> anyhow::Result<()> {
    guarded(|| {
        crate::downloads::set_event_sink(Box::new(move |event| sink.add(event).is_ok()));
        Ok(())
    })
}
