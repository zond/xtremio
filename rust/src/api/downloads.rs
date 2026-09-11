//! FRB surface for offline downloads: add, remove, list, open from the
//! device, and a progress stream. JSON strings in and out, all real work in
//! `crate::downloads`; like every other server call these go over the
//! handle's library API, never over HTTP.
//!
//! Where the bytes go is not here. There is one torrent-data root, the
//! server's `cacheRoot`, shared by the streaming cache and the kept
//! downloads alike; it is an ordinary settings key and is written through
//! `server_update_settings` like every other one.

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
                    "invalid download request {}",
                    crate::serde_fault::at_path(error.path(), error.inner())
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
///
/// A registry that will not read at all answers
/// `{"version":1,"items":{},"registryUnreadable":"<why>"}` rather than
/// raising. **An empty list is not the honest answer there and a thrown
/// error is not a useful one**: this file is the only record of what the
/// user asked to keep, so what the caller has to be able to say is "your
/// downloads are still on this device and I cannot list them", which needs
/// the reason and an otherwise well-formed payload. The bytes are kept --
/// the server is told no pin set at all this boot
/// (`crate::downloads::pins`) -- and the file is left where it is, so the
/// condition holds until it reads again rather than lasting one launch.
pub fn downloads_list() -> anyhow::Result<String> {
    guarded(|| match crate::downloads::list() {
        Ok(registry) => serde_json::to_string(&registry).map_err(Into::into),
        Err(error) => serde_json::to_string(&serde_json::json!({
            "version": crate::downloads::VERSION,
            "items": {},
            "registryUnreadable": format!("{error:#}"),
        }))
        .map_err(Into::into),
    })
}

/// Move an unreadable downloads registry aside and start an empty one.
///
/// The way out of the state `downloads_list` reports as
/// `registryUnreadable`: while the file stands, nothing can be pinned or
/// removed, because every write reads the list first. Answers `{}` on
/// success and raises when the registry reads -- this is a repair, not a
/// "delete everything" button.
///
/// **Say what it costs before calling it.** The list is discarded, so the
/// files it named stop being named: the server keeps them for the rest of
/// this launch and its sweep takes them at the next one. The old file is
/// renamed `downloads.json.corrupt-<seconds>`, not removed.
pub fn downloads_start_fresh() -> anyhow::Result<String> {
    guarded(|| {
        crate::downloads::start_fresh_registry()?;
        Ok("{}".to_owned())
    })
}

/// What to play the download `key` off the device with, and a note that it
/// was played.
///
/// Answers `{"ok":true,"key":…,"url":"http://127.0.0.1:…/{infoHash}/{fileIdx}",
/// "entry":{…}}` for a finished download, stamping the entry's
/// `lastPlayedAt` as it goes. **There is no file to open**: torrent data is
/// one file per piece in the server's store, so a kept download plays
/// through the embedded server's media route, off the pieces already on
/// this device — no peer, no tracker, no network. Two things have to be
/// true for that: the row says the file is whole, **and** the server says it
/// is holding it whole right now. When either is not, it answers
/// `{"ok":false,"key":…,"reason":…}` — `unknown` (no such entry),
/// `incomplete` (the bytes are not all here), `unavailable` (the server that
/// reads the pieces is not running) or `notHeld` (it is running and does not
/// have these pieces: the root moved or was reclaimed under them, the
/// torrent was not restored, or it is still being checked) — so the caller
/// can stream the title instead of opening a player on a URL that would
/// start a fresh torrent. Only a registry that cannot be read or written
/// raises.
pub fn downloads_open(key: String) -> anyhow::Result<String> {
    guarded(|| serde_json::to_string(&crate::downloads::open(&key)?).map_err(Into::into))
}

/// Progress, one JSON string per change:
/// `{"version":1,"progress":[{"key","downloaded","size","state","path",
/// "error","completedAt"}]}` — only the rows that moved, and of each row
/// only what moves. Deliberately not the `downloads_list` envelope: the
/// entry carries a `MetaItem` snapshot, the raw stream JSON and two addon
/// requests, and pushing those once a second per row is a large blob to
/// serialize here and to decode on the UI isolate, for six numbers. Fold
/// them into a listing by `key`.
///
/// The ticker behind it runs about once a second and only while something
/// is unfinished, so a screen with nothing downloading costs nothing, and a
/// row is in an event only when its numbers changed. Nothing is buffered
/// for a late subscriber — call `downloads_list` for the full picture and
/// treat these as updates to it.
pub fn downloads_events(sink: StreamSink<String>) -> anyhow::Result<()> {
    guarded(|| {
        crate::downloads::set_event_sink(Box::new(move |event| sink.add(event).is_ok()));
        Ok(())
    })
}
