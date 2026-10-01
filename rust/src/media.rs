//! **Playable things by id**: the app's half of the embedded server's media
//! API (stream-server `docs/design/media-pipeline.md` §2.3-2.5).
//!
//! The app registers what it wants played -- a URL stremio-core built on
//! the embedded server (a torrent, `/proxy`, an archive member), a linked
//! Drive file, a file on this device by path or descriptor -- and gets an
//! opaque id; mpv is handed `xtremio://<id>` and reads it through
//! [`crate::mpv_stream`], and a cast publishes it ([`publish_in`]). The play
//! that reader is (the `p=` token and the read-ahead choice the HTTP route
//! took off the URL) is registered here per id by [`set_play_in`], before the
//! open, because the open happens on mpv's thread with nobody to ask.
//!
//! Every call here goes through the running [`stream_server::ServerHandle`]
//! and holds it for its own length only ([`crate::server::with_handle_in`]):
//! a reader never holds it.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use enginefs::backend::priorities::BufferProfile;
use stream_server::{
    CastToken, LocalFile, MediaId, MediaReader, MediaSpec, PlayToken, Refusal, RenditionSpec,
};
use url::Url;

use crate::state::AppState;

/// The plays the app registered, by id: what [`open_for_player`] opens a
/// reader with. At most [`stream_server::media::MEDIA_ID_CAP`] of them, the
/// oldest let go first, as the server lets its ids go -- a play outliving
/// its id would be one nobody can open.
#[derive(Default)]
pub struct MediaState {
    plays: Mutex<Plays>,
    /// The Drive file [`open_drive_in`] last opened for a screen, and the
    /// id it resolved as: handed to the player's own registration of that
    /// file ([`register_drive_in`]) once, so the file is not opened twice
    /// for one press. Only the last: a screen opens one file and plays it.
    drive_opened: Mutex<Option<(String, String)>>,
}

#[derive(Default)]
struct Plays {
    by_id: HashMap<String, PlayToken>,
    order: VecDeque<String>,
}

impl MediaState {
    fn plays(&self) -> MutexGuard<'_, Plays> {
        self.plays.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn drive_opened(&self) -> MutexGuard<'_, Option<(String, String)>> {
        self.drive_opened
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }
}

impl Plays {
    fn insert(&mut self, id: &str, play: PlayToken) {
        if self.by_id.insert(id.to_owned(), play).is_none() {
            self.order.push_back(id.to_owned());
        }
        while self.order.len() > stream_server::media::MEDIA_ID_CAP {
            if let Some(oldest) = self.order.pop_front() {
                self.by_id.remove(&oldest);
            }
        }
    }
}

/// A buffer choice as the app spells it (`BufferAhead.wire`: `normal`,
/// `large`, `maximum`) -- the words the `buffer=` parameter carried.
pub fn buffer_profile(wire: &str) -> anyhow::Result<BufferProfile> {
    serde_json::from_value(serde_json::Value::String(wire.to_owned()))
        .map_err(|_| anyhow::anyhow!("{wire:?} is not a read-ahead choice"))
}

/// Registers `streaming_url` -- a URL stremio-core built on the embedded
/// server -- and answers its id. No I/O: what the URL names is found out by
/// [`resolve_in`]. Errors when the server is not running or the string is
/// not a URL.
pub fn register_in(app: &AppState, streaming_url: &str) -> anyhow::Result<String> {
    let url = Url::parse(streaming_url).map_err(|_| anyhow::anyhow!("not a URL"))?;
    register_spec_in(app, MediaSpec::StreamingUrl(url))
}

/// The stream URL a linked Google Drive file is played by:
/// `xtremio-drive:<fileId>` ([`crate::downloads::DRIVE_SOURCE_SCHEME`]),
/// the same string a Drive download's row keeps as its stream. It names
/// the file and nothing else -- no account, no grant -- and nothing fetches
/// it: the player registers it ([`register_drive_in`]).
pub fn drive_url(file_id: &str) -> String {
    format!("{}:{file_id}", crate::downloads::DRIVE_SOURCE_SCHEME)
}

/// Registers the linked Google Drive file `file_id` and answers its id. Its
/// grant is whatever the app holds when the server resolves it
/// ([`crate::server::ServerState::grant_supplier`]); a finished download of
/// the file resolves off the disk without one. The id [`open_drive_in`]
/// just resolved for this file is answered instead, once, so one press
/// opens the file once. No I/O.
pub fn register_drive_in(
    app: &AppState,
    file_id: &str,
    name: Option<String>,
) -> anyhow::Result<String> {
    {
        let mut opened = app.media.drive_opened();
        if opened.as_ref().is_some_and(|(file, _)| file == file_id) {
            if let Some((_, id)) = opened.take() {
                return Ok(id);
            }
        }
    }
    let grant = app.server.grant_supplier();
    register_spec_in(
        app,
        MediaSpec::Drive {
            file_id: file_id.to_owned(),
            name,
            grant,
        },
    )
}

/// **Opens a linked Drive file for the screen that pressed it**: registers
/// it and resolves it -- the grant renewed, the file probed, its head read --
/// the same work the player's resolve would do, done while the screen can
/// still say why not (a dead pairing above all). `refresh_token` is spent
/// for this resolve and dropped; later resolves of the id read the app's
/// grant. The id is kept for the player's registration of the same file
/// ([`register_drive_in`]).
pub fn open_drive_in(
    app: &AppState,
    file_id: &str,
    refresh_token: &str,
    name: Option<String>,
) -> crate::server::DriveOpenOutcome {
    let first = Mutex::new(Some(refresh_token.to_owned()).filter(|token| !token.is_empty()));
    let held = app.server.grant_supplier();
    let grant: stream_server::GrantSupplier = Arc::new(move || {
        first
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()
            .or_else(|| held())
    });
    let spec = MediaSpec::Drive {
        file_id: file_id.to_owned(),
        name,
        grant,
    };
    let resolved = crate::server::with_handle_in(app, |handle| {
        let id = handle.register(spec)?;
        let resolved = handle.resolve(&id);
        if resolved.is_ok() {
            *app.media.drive_opened() = Some((file_id.to_owned(), id.to_string()));
        }
        Ok(resolved)
    });
    crate::server::DriveOpenOutcome::of_resolved(file_id, resolved)
}

/// Registers a file on this device by its path and answers its id. No I/O:
/// the server opens it when it resolves. `name` is what to call it, the
/// path's file name when `None`.
pub fn register_local_path_in(
    app: &AppState,
    path: &str,
    name: Option<String>,
) -> anyhow::Result<String> {
    register_spec_in(
        app,
        MediaSpec::Local {
            file: LocalFile::Path(path.into()),
            name,
        },
    )
}

/// Registers a file on this device by a descriptor the app hands over --
/// on Android, `ParcelFileDescriptor.detachFd()` of a `content://`
/// document -- and answers its id. **The descriptor is this side's from
/// the call on**, whatever the answer: taken before anything else, so an
/// error closes it rather than leaking it, and the server closes it when
/// the id is let go. Errors for a negative descriptor, and on a platform
/// that has none to hand over.
pub fn register_local_fd_in(
    app: &AppState,
    fd: i64,
    name: Option<String>,
) -> anyhow::Result<String> {
    let file = local_fd(fd)?;
    register_spec_in(app, MediaSpec::Local { file, name })
}

#[cfg(unix)]
fn local_fd(fd: i64) -> anyhow::Result<LocalFile> {
    use std::os::fd::{FromRawFd, OwnedFd, RawFd};
    let raw = RawFd::try_from(fd)
        .ok()
        .filter(|raw| *raw >= 0)
        .ok_or_else(|| anyhow::anyhow!("not a file descriptor"))?;
    // SAFETY: the app hands over a descriptor it detached and no longer
    // owns (`ParcelFileDescriptor.detachFd`); from here this is its only
    // owner, which closes it once.
    Ok(LocalFile::Fd(unsafe { OwnedFd::from_raw_fd(raw) }))
}

#[cfg(not(unix))]
fn local_fd(_fd: i64) -> anyhow::Result<LocalFile> {
    anyhow::bail!("no file descriptors to hand over on this platform")
}

fn register_spec_in(app: &AppState, spec: MediaSpec) -> anyhow::Result<String> {
    crate::server::with_handle_in(app, |handle| Ok(handle.register(spec)?.to_string()))
}

/// **Publishes `id` for a cast** and answers the token the receiver's URL
/// ends in (`<lan base>/cast/<token>`), with the play [`set_play_in`]
/// recorded for the id -- the receiver's reads are the viewer's playback,
/// as mpv's were. Refused while the LAN listener is not running and for an
/// id the server does not hold. The token is a URL into this device for as
/// long as it is published: never logged.
pub fn publish_in(app: &AppState, id: &str) -> anyhow::Result<String> {
    let play = app.media.plays().by_id.get(id).cloned();
    let id = MediaId::from(id.to_owned());
    crate::server::with_handle_in(app, |handle| {
        Ok(handle.publish(&id, play)?.as_str().to_owned())
    })
}

/// **Publishes a rendition of `id` for a cast** and answers the token the
/// receiver's stream URL is built on (`<lan
/// base>/cast/<token>/stream.mp4`), with the play [`set_play_in`]
/// recorded for the id. `spec` is a `stream_server::RenditionSpec` as JSON
/// (camelCase). The producer making it is [`crate::rendition::Repackager`],
/// installed at every server start. Refused as [`publish_in`] is, and for a
/// spec that is not one. Never log the token.
pub fn publish_rendition_in(app: &AppState, id: &str, spec: &str) -> anyhow::Result<String> {
    let spec: RenditionSpec =
        serde_json::from_str(spec).map_err(|error| anyhow::anyhow!("not a rendition: {error}"))?;
    let play = app.media.plays().by_id.get(id).cloned();
    let id = MediaId::from(id.to_owned());
    crate::server::with_handle_in(app, |handle| {
        Ok(handle
            .publish_rendition(&id, spec, play)?
            .as_str()
            .to_owned())
    })
}

/// How many times the receiver restarted the rendition published as
/// `token`: fetched its stream again from a start it had played past,
/// which is what it does with a seek it cannot make. `0` for a token that
/// is not a rendition, and when the server is not running.
pub fn rendition_restarts_in(app: &AppState, token: &str) -> u64 {
    let token = CastToken::from(token.to_owned());
    crate::server::with_handle_in(app, |handle| Ok(handle.rendition_restarts(&token))).unwrap_or(0)
}

/// Ends a publication: nothing more is served under `token`, and a body
/// being served under it is cut. Whether it was published. `false` when
/// the server is not running, which stopped the listener and every token
/// with it.
pub fn unpublish_in(app: &AppState, token: &str) -> bool {
    let token = CastToken::from(token.to_owned());
    crate::server::with_handle_in(app, |handle| Ok(handle.unpublish(&token))).unwrap_or(false)
}

/// What `id` is, as JSON: the server's `Resolved` (`name`, `contentType`,
/// `len`, `inProcess`, ...) or its `Refusal` (`{refused, message}`) -- a
/// refusal is an answer, not a failure. Blocks while the server resolves,
/// which for a magnet whose metadata is not here yet is a wait of up to
/// `enginefs::METADATA_RESOLVE_TIMEOUT`. Errors only when the server is not
/// running.
pub fn resolve_in(app: &AppState, id: &str) -> anyhow::Result<String> {
    let id = MediaId::from(id.to_owned());
    crate::server::with_handle_in(app, |handle| {
        Ok(match handle.resolve(&id) {
            Ok(resolved) => serde_json::to_string(&resolved)?,
            Err(refusal) => serde_json::to_string(&refusal)?,
        })
    })
}

/// Records the play the reader over `id` is: the player's `token`
/// (`<viewer>.<screen>`, what `p=` carried) and its read-ahead choice. An
/// open of `id` without one is an aside, which moves no play session and
/// shares nothing, so the app sets this before handing mpv the id.
pub fn set_play_in(app: &AppState, id: &str, token: String, buffer: &str) -> anyhow::Result<()> {
    let buffer = buffer_profile(buffer)?;
    app.media.plays().insert(id, PlayToken { token, buffer });
    Ok(())
}

/// The viewer changed the read-ahead for `id`: recorded for the next open,
/// and handed to the server, which applies it to an open reader at its next
/// reopen (a seek) -- never by reopening the player. Errors when the
/// server is not running or refuses (`unknownId`).
pub fn set_buffer_in(app: &AppState, id: &str, buffer: &str) -> anyhow::Result<()> {
    let buffer = buffer_profile(buffer)?;
    if let Some(play) = app.media.plays().by_id.get_mut(id) {
        play.buffer = buffer;
    }
    let id = MediaId::from(id.to_owned());
    crate::server::with_handle_in(app, |handle| {
        handle.set_buffer(&id, buffer).map_err(refusal_error)
    })
}

/// What the server holds of what `id` resolved to, as JSON, or `None`
/// for an id not resolved yet. Errors when the server is not running.
pub fn stream_numbers_in(app: &AppState, id: &str) -> anyhow::Result<Option<String>> {
    let id = MediaId::from(id.to_owned());
    crate::server::with_handle_in(app, |handle| {
        handle
            .media_stream_numbers(&id)?
            .map(|numbers| serde_json::to_string(&numbers).map_err(Into::into))
            .transpose()
    })
}

/// How long the film behind `id` is; see
/// [`crate::server::note_duration`]. A no-op for anything not a torrent.
pub fn note_duration_in(
    app: &AppState,
    id: &str,
    duration: std::time::Duration,
) -> anyhow::Result<()> {
    let id = MediaId::from(id.to_owned());
    crate::server::with_handle_in(app, |handle| handle.note_media_duration(&id, duration))
}

/// A player opened on what `id` resolved to; see
/// [`crate::server::note_player_opened`].
pub fn note_player_opened_in(app: &AppState, id: &str) -> anyhow::Result<()> {
    let id = MediaId::from(id.to_owned());
    crate::server::with_handle_in(app, |handle| handle.note_media_player_opened(&id))
}

/// The player of `id` is buffering after having played; see
/// [`crate::server::note_player_stalled`].
pub fn note_player_stalled_in(app: &AppState, id: &str) -> anyhow::Result<()> {
    let id = MediaId::from(id.to_owned());
    crate::server::with_handle_in(app, |handle| handle.note_media_player_stalled(&id))
}

/// **A reader over `id` for mpv**, with the play [`set_play_in`] recorded
/// for it, or without one (an aside) when there is none. Called from mpv's
/// open callback on mpv's thread: the handle is held for the open and let
/// go before this returns, so the reader mpv keeps holds none. The error is
/// the refusal's kind and sentence, for the log.
pub fn open_for_player(id: &str) -> Result<MediaReader, String> {
    let app = crate::state::current().ok_or("the app is not running")?;
    open_for_player_in(&app, id)
}

/// [`open_for_player`] against a given state.
pub fn open_for_player_in(app: &AppState, id: &str) -> Result<MediaReader, String> {
    let play = app.media.plays().by_id.get(id).cloned();
    let id = MediaId::from(id.to_owned());
    crate::server::with_handle_in(app, |handle| {
        handle.open_reader(&id, play).map_err(refusal_error)
    })
    .map_err(|error| error.to_string())
}

/// A refusal as an error whose text is its kind -- which is safe in any
/// log line -- and never its sentence, which for a link can name its host.
fn refusal_error(refusal: Refusal) -> anyhow::Error {
    anyhow::anyhow!("refused: {}", refusal.kind())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_buffer_choice_is_the_words_the_url_carried() {
        assert_eq!(buffer_profile("normal").unwrap(), BufferProfile::Normal);
        assert_eq!(buffer_profile("large").unwrap(), BufferProfile::Large);
        assert_eq!(buffer_profile("maximum").unwrap(), BufferProfile::Maximum);
        assert!(buffer_profile("wholeFile").is_err());
    }

    /// **A play is kept per id until the server would have let the id go**,
    /// the oldest first, and a buffer change moves the kept one.
    #[test]
    fn plays_are_bounded_like_the_ids_they_belong_to() {
        let app = AppState::default();
        set_play_in(&app, "first", "v.s".into(), "large").unwrap();
        assert_eq!(
            app.media.plays().by_id["first"],
            PlayToken {
                token: "v.s".into(),
                buffer: BufferProfile::Large
            }
        );
        // No server: the change is refused, and still kept for the open.
        assert!(set_buffer_in(&app, "first", "maximum").is_err());
        assert_eq!(
            app.media.plays().by_id["first"].buffer,
            BufferProfile::Maximum
        );
        for n in 0..stream_server::media::MEDIA_ID_CAP {
            set_play_in(&app, &format!("id{n}"), "v.s".into(), "normal").unwrap();
        }
        let plays = app.media.plays();
        assert!(!plays.by_id.contains_key("first"));
        assert_eq!(plays.by_id.len(), stream_server::media::MEDIA_ID_CAP);
        assert_eq!(plays.order.len(), plays.by_id.len());
    }

    #[test]
    fn nothing_is_opened_or_registered_without_a_server() {
        let app = AppState::default();
        assert!(register_in(&app, "http://127.0.0.1:1/abc/0").is_err());
        assert!(register_drive_in(&app, "a-file-id", None).is_err());
        assert!(register_local_path_in(&app, "/tmp/a film.mkv", None).is_err());
        assert!(open_for_player_in(&app, "abc").is_err());
        assert!(resolve_in(&app, "abc").is_err());
        assert!(publish_in(&app, "abc").is_err());
        let spec = r#"{"durationMs":1,"segmentMs":1,"startMs":0,"video":"copy","audio":"copy","audioTrack":0}"#;
        assert!(publish_rendition_in(&app, "abc", spec).is_err());
        assert!(!unpublish_in(&app, "a-token"));
        assert_eq!(rendition_restarts_in(&app, "a-token"), 0);
    }

    /// **One press opens a Drive file once**: the id the screen's open
    /// resolved is the one the player's registration of the same file is
    /// handed, and only once -- a second registration, or one of another
    /// file, is a registration of its own.
    #[test]
    fn the_drive_file_a_screen_opened_is_handed_to_the_player_once() {
        let app = AppState::default();
        *app.media.drive_opened() = Some(("a-file-id".into(), "an-id".into()));
        assert!(register_drive_in(&app, "another-file", None).is_err());
        assert_eq!(register_drive_in(&app, "a-file-id", None).unwrap(), "an-id");
        // Taken: without a server the next one has nowhere to register.
        assert!(register_drive_in(&app, "a-file-id", None).is_err());
    }

    #[test]
    fn a_drive_file_plays_by_its_source_url() {
        assert_eq!(drive_url("a-file-id"), "xtremio-drive:a-file-id");
    }

    /// **A descriptor handed over is this side's at once**: an answer that
    /// is an error still closes it, rather than leaking one per failed
    /// play. Shown with a pipe, whose write end fails once the read end is
    /// closed -- a check that holds whatever number the descriptor had.
    #[cfg(unix)]
    #[test]
    fn a_descriptor_handed_over_is_closed_when_it_cannot_be_registered() {
        use std::io::Write;
        use std::os::fd::IntoRawFd;

        let app = AppState::default();
        assert!(register_local_fd_in(&app, -1, None).is_err());
        let (reader, mut writer) = std::io::pipe().expect("a pipe");
        let fd = i64::from(reader.into_raw_fd());
        assert!(register_local_fd_in(&app, fd, Some("a film.mkv".into())).is_err());
        let error = writer.write_all(b"x").expect_err("nobody reads the pipe");
        assert_eq!(error.kind(), std::io::ErrorKind::BrokenPipe);
    }
}
