//! FRB surface for playing by media id: registering what to play with the
//! embedded server, and the `xtremio://` protocol mpv reads it through
//! (`crate::media`, `crate::mpv_stream`; stream-server's
//! `docs/design/media-pipeline.md` §2.3-2.5).
//!
//! The registration calls answer at once and are `sync`: `register` does no
//! I/O and the play and buffer are a map write and a flag on the server.
//! [`media_resolve`] and the stream numbers wait on the server's runtime
//! and are not.

use flutter_rust_bridge::frb;

use crate::guard::{guarded, guarded_ok};

/// Registers `streaming_url` -- a URL stremio-core built on the embedded
/// server (a torrent's `/{infoHash}/{fileIdx}`, a `/proxy` link, an
/// archive member's `/{fmt}/create` or `/{fmt}/stream`) -- and answers the
/// id mpv
/// is handed as `xtremio://<id>`. No I/O. Errors when the server is not
/// running.
#[frb(sync)]
pub fn media_register(streaming_url: String) -> anyhow::Result<String> {
    guarded(|| crate::media::register_in(&crate::state::state(), &streaming_url))
}

/// Registers the linked Google Drive file `file_id` (what an
/// `xtremio-drive:<fileId>` stream names) and answers its id. The grant is
/// the one the app handed Rust (`server_drive_grant`), read when the
/// server resolves; a finished download of the file needs none. No I/O.
/// Errors when the server is not running.
#[frb(sync)]
pub fn media_register_drive(file_id: String, name: Option<String>) -> anyhow::Result<String> {
    guarded(|| crate::media::register_drive_in(&crate::state::state(), &file_id, name))
}

/// Registers a file on this device by its `path` and answers its id;
/// `name` is what to call it (the path's file name when null). No I/O.
/// Errors when the server is not running.
#[frb(sync)]
pub fn media_register_local_path(path: String, name: Option<String>) -> anyhow::Result<String> {
    guarded(|| crate::media::register_local_path_in(&crate::state::state(), &path, name))
}

/// Registers a file on this device by a descriptor the app has detached
/// (Android's `ParcelFileDescriptor.detachFd()`) and answers its id. **The
/// descriptor is Rust's from this call on**, answered or not: an error
/// closes it. `name` is what to call it -- a descriptor has no name, and
/// its extension is where the content type comes from. Errors when the
/// server is not running, and on a platform with no descriptors.
#[frb(sync)]
pub fn media_register_local_fd(fd: i64, name: Option<String>) -> anyhow::Result<String> {
    guarded(|| crate::media::register_local_fd_in(&crate::state::state(), fd, name))
}

/// Publishes `id` for a cast and answers the token the receiver's URL ends
/// in (`<lan base>/cast/<token>`); the play `media_set_play` recorded for
/// the id goes with it. **A URL into this device while published: never
/// log it.** Errors while the LAN listener is not running, or for an id
/// the server does not hold.
pub fn media_publish(id: String) -> anyhow::Result<String> {
    guarded(|| crate::media::publish_in(&crate::state::state(), &id))
}

/// Publishes a rendition of `id` for a cast -- an HLS stream the server
/// makes from the film as the receiver asks for it -- and answers the token
/// its playlist is under (`<lan base>/cast/<token>/hls/index.m3u8`); the
/// play `media_set_play` recorded for the id goes with it. `spec` is the
/// server's `RenditionSpec` as JSON (`durationMs`, `segmentMs`, `startMs`,
/// `video`, `audio`, `audioTrack`). **A URL into this device while
/// published: never log it.** Errors as `media_publish` does, and for a
/// spec that is not one.
pub fn media_publish_rendition(id: String, spec: String) -> anyhow::Result<String> {
    guarded(|| crate::media::publish_rendition_in(&crate::state::state(), &id, &spec))
}

/// Whether this device can make a rendition: a player has loaded libmpv,
/// and the FFmpeg in it is the one this build is bound to. False until the
/// first player has registered (`mpv_stream_register`), and on a desktop
/// whose system FFmpeg is another major. Cheap after the first ask.
#[frb(sync)]
pub fn media_renditions_available() -> anyhow::Result<bool> {
    guarded_ok(crate::rendition::available)
}

/// Ends the publication `token`: nothing more is served under it, and a
/// body in flight is cut. Whether it was published.
pub fn media_unpublish(token: String) -> anyhow::Result<bool> {
    guarded(|| Ok(crate::media::unpublish_in(&crate::state::state(), &token)))
}

/// What `id` is, as JSON: `{name, contentType, len, member, sniffed,
/// inProcess, proxyUrl}` once resolved, or `{refused, message}` when the server will
/// not play it -- a refusal is an answer. Waits while the server adds the
/// torrent and chooses its file (up to the metadata timeout for a
/// magnet), so it runs on a worker; the reader mpv opens afterwards finds
/// the answer kept. Errors when the server is not running.
pub fn media_resolve(id: String) -> anyhow::Result<String> {
    guarded(|| crate::media::resolve_in(&crate::state::state(), &id))
}

/// The play mpv's reader over `id` will be: this player's `token`
/// (`<viewer>.<screen>`, what `p=` carried) and its read-ahead `buffer`
/// (`normal`, `large`, `maximum`). Set before handing mpv the id; an open
/// without one is an aside, which shares nothing and moves no play.
#[frb(sync)]
pub fn media_set_play(id: String, token: String, buffer: String) -> anyhow::Result<()> {
    guarded(|| crate::media::set_play_in(&crate::state::state(), &id, token, &buffer))
}

/// The viewer changed the read-ahead for `id`. The open reader takes it at
/// its next reopen -- a seek -- and nothing reopens the player for it.
/// Errors when the server is not running or holds nothing under `id`.
#[frb(sync)]
pub fn media_set_buffer(id: String, buffer: String) -> anyhow::Result<()> {
    guarded(|| crate::media::set_buffer_in(&crate::state::state(), &id, &buffer))
}

/// `server_stream_numbers` for what `id` resolved to, as JSON, or null
/// for an id not resolved yet. Errors when the server is not running.
pub fn media_stream_numbers(id: String) -> anyhow::Result<Option<String>> {
    guarded(|| crate::media::stream_numbers_in(&crate::state::state(), &id))
}

/// How long the film behind `id` is (`server_note_duration`, by id). A
/// hint: never errors, and a length that is not one is dropped.
pub fn media_note_duration(id: String, duration_seconds: f64) -> anyhow::Result<()> {
    guarded_ok(move || {
        if !duration_seconds.is_finite() || duration_seconds <= 0.0 {
            return;
        }
        let Some(app) = crate::state::current() else {
            return;
        };
        let duration = std::time::Duration::from_secs_f64(duration_seconds);
        if let Err(error) = crate::media::note_duration_in(&app, &id, duration) {
            tracing::debug!(%error, "a duration hint did not arrive");
        }
    })
}

/// A player opened on `id` (`server_note_player_opened`, by id). A hint:
/// never errors.
pub fn media_note_player_opened(id: String) -> anyhow::Result<()> {
    guarded_ok(move || {
        let Some(app) = crate::state::current() else {
            return;
        };
        if let Err(error) = crate::media::note_player_opened_in(&app, &id) {
            tracing::debug!(%error, "a player-opened hint did not arrive");
        }
    })
}

/// The player of `id` is buffering after having played
/// (`server_note_player_stalled`, by id). A hint: never errors.
pub fn media_note_player_stalled(id: String) -> anyhow::Result<()> {
    guarded_ok(move || {
        let Some(app) = crate::state::current() else {
            return;
        };
        if let Err(error) = crate::media::note_player_stalled_in(&app, &id) {
            tracing::debug!(%error, "a stall hint did not arrive");
        }
    })
}

/// Registers the `xtremio` protocol on the mpv handle at `ctx` (media_kit's
/// `NativePlayer.ctx.address`), resolving libmpv's stream_cb API from the
/// library at `libmpv_path` (`NativeLibrary.path`). Once per player, after
/// `waitForPlayerInitialization` and before the first open; a second call
/// on the same handle is a no-op. Answers whether this call registered it
/// (`false`: it was there already). Errors for a null handle or a libmpv
/// without the API.
pub fn mpv_stream_register(ctx: i64, libmpv_path: String) -> anyhow::Result<bool> {
    guarded(|| {
        crate::mpv_stream::register(ctx, &libmpv_path)
            .map(|registered| registered == crate::mpv_stream::Registration::Registered)
    })
}
