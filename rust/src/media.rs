//! **Playable things by id**: the app's half of the embedded server's media
//! API (stream-server `docs/design/media-pipeline.md` §2.3-2.5).
//!
//! The app registers what it wants played -- today the torrent URL
//! stremio-core built -- and gets an opaque id; mpv is handed
//! `xtremio://<id>` and reads it through [`crate::mpv_stream`]. The play
//! that reader is (the `p=` token and the read-ahead choice the HTTP route
//! took off the URL) is registered here per id by [`set_play_in`], before the
//! open, because the open happens on mpv's thread with nobody to ask.
//!
//! Every call here goes through the running [`stream_server::ServerHandle`]
//! and holds it for its own length only ([`crate::server::with_handle_in`]):
//! a reader never holds it.

use std::collections::{HashMap, VecDeque};
use std::sync::{Mutex, MutexGuard, PoisonError};

use enginefs::backend::priorities::BufferProfile;
use stream_server::{MediaId, MediaReader, MediaSpec, PlayToken, Refusal};
use url::Url;

use crate::state::AppState;

/// The plays the app registered, by id: what [`open_for_player`] opens a
/// reader with. At most [`stream_server::media::MEDIA_ID_CAP`] of them, the
/// oldest let go first, as the server lets its ids go -- a play outliving
/// its id would be one nobody can open.
#[derive(Default)]
pub struct MediaState {
    plays: Mutex<Plays>,
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
    crate::server::with_handle_in(app, |handle| {
        Ok(handle.register(MediaSpec::StreamingUrl(url))?.to_string())
    })
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
        assert!(open_for_player_in(&app, "abc").is_err());
        assert!(resolve_in(&app, "abc").is_err());
    }
}
