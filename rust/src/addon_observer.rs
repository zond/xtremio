//! What the runtime pump saw every addon answer, turned into sweeps for
//! [`crate::addon_health`] to count.
//!
//! ## Why the pump, and not `Env::fetch`
//!
//! The obvious place to watch addons answer is the HTTP layer, and it is
//! the wrong one. [`crate::env::XtremioEnv::fetch`] is generic over its
//! output, so it cannot tell "the addon answered with nothing" from "the
//! addon answered" -- and that difference is the whole point of the record.
//! It also only has the *resource* URL, which maps back to an addon's
//! transport URL by guesswork (a legacy `/stremio/v1` transport rewrites
//! differently, and two addons can share a host), and that URL is the one
//! carrying a debrid API key.
//!
//! Doing it per screen in Dart is the other wrong layer: `build` runs many
//! times, so each screen would need its own edge detection, and only a
//! screen that is mounted sees anything at all.
//!
//! The runtime event pump has all three: `ResourceRequest::base` *is* the
//! addon's transport URL as the profile stores it, `Loadable` carries the
//! full three-way outcome, and one hook covers the board, search, discover,
//! meta details and the player without a screen opting in.
//!
//! ## One field's load is one sweep
//!
//! stremio-core settles addon answers one at a time -- every
//! `ResourceRequestResult` is its own message and its own `NewState` -- so
//! "everything that settled in this event" would be a sweep of one, and a
//! lone failure would then be indistinguishable from a broken connection
//! and recorded against nobody. Every failure would be thrown away.
//!
//! So a sweep is a *load*, not an event: settled answers accumulate in
//! [`FieldWatch::sweep`] while any of the field's loadables is still
//! `Loading`, and the sweep is handed to [`commit`] once the field has gone
//! quiet. That is the batch that went out together,
//! which is the only batch whose all-failing says something about the
//! network rather than about an addon.
//!
//! ## Only a transition into a settled state counts
//!
//! A `NewState` is re-emitted for a field whenever anything in it changes,
//! and the pump reads the model as it is *now*, so the same settled answer
//! is seen over and over. [`FieldWatch::settled`] is the edge detector:
//! every settled loadable of the field, by request identity, and how it
//! settled. An answer is counted only when that map did not already hold
//! the same outcome for it. `Loading` is never an outcome, and a loadable
//! with no content at all was never asked -- an unscrolled board row is not
//! evidence about anything.
//!
//! The map is rebuilt from the model on every walk rather than added to, so
//! it is bounded by what the model holds and a request that goes away
//! (unloading a screen) is forgotten with it. Asking the same addon again
//! after that is a new answer, because it is.
//!
//! Nothing here is written down: the map lives for the life of one
//! [`crate::state::AppState`], and it holds a [`crate::addon_health::key_for`]
//! digest and a digest of the resource path rather than the transport URL
//! or the id of what was being watched.

use std::collections::BTreeMap;
use std::sync::{Mutex, MutexGuard};

use sha2::{Digest, Sha256};
use stremio_core::models::common::{Loadable, ResourceError, ResourceLoadable};
use stremio_core::types::addon::ResourceRequest;

use crate::addon_health::{key_for, Outcome, ResourceKind, Sweep};
use crate::model::{XtremioModel, XtremioModelField};
use crate::state::AppState;

/// Hex characters of the resource path's digest kept per request. Only ever
/// compared with itself, and never stored, so eight bytes is generous.
const PATH_DIGEST_HEX: usize = 16;

/// The model fields whose loadables are addon answers.
///
/// `remote_addons` is left out because an `addon_catalog` is not a resource
/// this record is kept for, and `ctx`, `library`, `installed_addons`,
/// `continue_watching_preview` and `streaming_server` because nothing in
/// them is an addon being asked a question.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
enum Watched {
    Board,
    Search,
    Discover,
    MetaDetails,
    Player,
}

impl Watched {
    /// The watched field a `NewState` names, or `None` for one that holds
    /// no addon answers.
    fn of(field: &XtremioModelField) -> Option<Self> {
        match field {
            XtremioModelField::Board => Some(Self::Board),
            XtremioModelField::Search => Some(Self::Search),
            XtremioModelField::Discover => Some(Self::Discover),
            XtremioModelField::MetaDetails => Some(Self::MetaDetails),
            XtremioModelField::Player => Some(Self::Player),
            _ => None,
        }
    }
}

/// What makes two requests the same request.
///
/// The addon is its [`key_for`] key and the path is a digest, so the map
/// this is a key of holds neither a transport URL nor the id of whatever
/// was being watched -- the same rule the stored record follows, applied to
/// memory that never reaches the disk anyway.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct RequestId {
    addon: String,
    kind: ResourceKind,
    path: String,
}

impl RequestId {
    fn of(request: &ResourceRequest, kind: ResourceKind) -> Self {
        let mut hasher = Sha256::new();
        // Length-prefixed, so `id = "a/b"` and `id = "a", extra "b"` cannot
        // hash to the same request.
        for part in [
            request.path.resource.as_str(),
            request.path.r#type.as_str(),
            request.path.id.as_str(),
        ] {
            hasher.update((part.len() as u64).to_le_bytes());
            hasher.update(part.as_bytes());
        }
        for extra in &request.path.extra {
            for part in [extra.name.as_str(), extra.value.as_str()] {
                hasher.update((part.len() as u64).to_le_bytes());
                hasher.update(part.as_bytes());
            }
        }
        let digest = hasher.finalize();
        let mut path = String::with_capacity(PATH_DIGEST_HEX);
        for byte in digest.iter().take(PATH_DIGEST_HEX / 2) {
            path.push_str(&format!("{byte:02x}"));
        }
        Self {
            addon: key_for(&request.base),
            kind,
            path,
        }
    }
}

/// One watched field: what it currently holds, and what it has answered
/// since the last time it went quiet.
#[derive(Default)]
struct FieldWatch {
    /// Every settled loadable the field held when it was last walked. The
    /// edge detector: an outcome already in here has been counted.
    settled: BTreeMap<RequestId, Outcome>,
    /// The answers counted so far in the load that is still in flight.
    sweep: Sweep,
}

/// The observer half of [`crate::state::AppState`]: one [`FieldWatch`] per
/// watched field.
///
/// It belongs to the state rather than to the process because the pump
/// outlives a shutdown by design: an event still in flight has to be
/// edge-detected against the model it came from, and a later `init` starts
/// from a fresh model and so must start from a fresh memory of it.
#[derive(Default)]
pub struct ObserverState {
    watched: Mutex<BTreeMap<Watched, FieldWatch>>,
}

impl ObserverState {
    /// A poisoned lock only means a previous holder panicked; what is
    /// behind it is still a record of what was seen.
    fn watched(&self) -> MutexGuard<'_, BTreeMap<Watched, FieldWatch>> {
        self.watched
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// How one loadable stands.
enum Answer {
    /// Asked, still out.
    Pending,
    /// Planned but never asked -- a board row nobody scrolled to.
    NotAsked,
    /// Answered, one way or the other.
    Settled(Outcome),
}

/// [`Answer`] for one loadable's content.
///
/// stremio-core turns a valid-but-empty vector response into
/// `ResourceError::EmptyContent`, which is why "the addon has nothing"
/// arrives here as an error and has to be pulled back out of the failures.
fn answer<T>(content: &Option<Loadable<T, ResourceError>>) -> Answer {
    match content {
        Some(Loadable::Ready(_)) => Answer::Settled(Outcome::Answered),
        Some(Loadable::Err(ResourceError::EmptyContent)) => Answer::Settled(Outcome::Empty),
        // A response that is not the protocol is a broken addon, not a
        // fourth bucket.
        Some(Loadable::Err(ResourceError::UnexpectedResponse(_) | ResourceError::Env(_))) => {
            Answer::Settled(Outcome::Failed)
        }
        Some(Loadable::Loading) => Answer::Pending,
        None => Answer::NotAsked,
    }
}

/// One pass over one field's loadables.
struct Walk<'a> {
    /// What the field holds now, filling in as the walk goes.
    settled: BTreeMap<RequestId, Outcome>,
    /// Whether anything in the field is still out.
    pending: bool,
    /// What the field held when it was last walked.
    previous: &'a BTreeMap<RequestId, Outcome>,
    /// The load's sweep, added to for every answer that is new.
    sweep: &'a mut Sweep,
}

impl Walk<'_> {
    /// Notes one loadable: whether it keeps the field busy, and whether it
    /// has just settled into something not seen before.
    fn note<T>(&mut self, loadable: &ResourceLoadable<T>) {
        let outcome = match answer(&loadable.content) {
            Answer::Pending => {
                self.pending = true;
                return;
            }
            Answer::NotAsked => return,
            Answer::Settled(outcome) => outcome,
        };
        // A resource no record is kept for (`addon_catalog`, or whatever an
        // addon invents) is not an answer this counts, and does not make
        // the field busy either.
        let Some(kind) = ResourceKind::from_resource_name(&loadable.request.path.resource) else {
            return;
        };
        let id = RequestId::of(&loadable.request, kind);
        // The same request can appear twice in one field (a meta addon that
        // also serves streams is in both `meta_streams` and `streams`); one
        // identity is one answer per walk.
        if self.settled.insert(id.clone(), outcome).is_some() {
            return;
        }
        if self.previous.get(&id) != Some(&outcome) {
            self.sweep.observe(&loadable.request.base, kind, outcome);
        }
    }
}

/// Walks the loadables `field` holds. Every one of them, not only the ones
/// that just changed: what has settled is what says whether the load is
/// done, and the edge detector is what keeps it from being counted twice.
fn walk_field(walk: &mut Walk, model: &XtremioModel, field: Watched) {
    match field {
        Watched::Board => {
            for page in model.board.catalogs.iter().flatten() {
                walk.note(page);
            }
        }
        Watched::Search => {
            for page in model.search.catalogs.iter().flatten() {
                walk.note(page);
            }
        }
        Watched::Discover => {
            for page in &model.discover.catalog {
                walk.note(page);
            }
        }
        Watched::MetaDetails => {
            for item in &model.meta_details.meta_items {
                walk.note(item);
            }
            for streams in &model.meta_details.meta_streams {
                walk.note(streams);
            }
            for streams in &model.meta_details.streams {
                walk.note(streams);
            }
            // `last_used_stream` is left out: its request is one of the
            // above, and its content is an `Option`, so an addon that
            // answered with nothing would read as one that answered.
        }
        Watched::Player => {
            if let Some(item) = &model.player.meta_item {
                walk.note(item);
            }
            for subtitles in &model.player.subtitles {
                walk.note(subtitles);
            }
            if let Some(streams) = &model.player.next_streams {
                walk.note(streams);
            }
        }
    }
}

/// The sweeps that `fields` of `model` have just completed, remembering in
/// `app` what was seen so the same answer is not collected twice.
///
/// Reading and counting are two calls on purpose. The caller in the
/// runtime-event pump is holding the model's read lock while this one runs,
/// and [`commit`] is the half that can reach the disk: it writes the record
/// out, `fsync` and all, up to once a minute. Holding the model across that
/// would park any `Runtime::dispatch` waiting for the model's *write* lock
/// for the length of a flush -- and with `std`'s `RwLock` a waiting writer
/// also stalls the readers behind it, which includes the `core::get_state`
/// Dart calls on every field render. So the pump lets the model go, and
/// then counts.
///
/// Reading the model from the pump cannot deadlock against a dispatch:
/// `Runtime::dispatch` and `Runtime::handle_effect_output` both drop the
/// model's write guard before calling `handle_effects`, which is what emits
/// into this pump's channel, so no writer is ever waiting on the pump while
/// holding the lock the pump wants.
pub fn sweeps(app: &AppState, model: &XtremioModel, fields: &[XtremioModelField]) -> Vec<Sweep> {
    let mut watched = app.addon_observer.watched();
    let mut sweeps = Vec::new();
    for field in fields.iter().filter_map(Watched::of) {
        let watch = watched.entry(field).or_default();
        let previous = std::mem::take(&mut watch.settled);
        let mut sweep = std::mem::take(&mut watch.sweep);
        let mut walk = Walk {
            settled: BTreeMap::new(),
            pending: false,
            previous: &previous,
            sweep: &mut sweep,
        };
        walk_field(&mut walk, model, field);
        watch.settled = walk.settled;
        if walk.pending {
            // Still waiting on part of the load: the sweep is not whole
            // yet, and half a load cannot say whether the connection is up.
            watch.sweep = sweep;
        } else if !sweep.is_empty() {
            sweeps.push(sweep);
        }
    }
    sweeps
}

/// Counts collected sweeps into `app`, answering how many of them were
/// evidence about the addons at all (see
/// [`crate::addon_health::Sweep::commit_into`]).
///
/// Takes no model, and must be called with none held: this is where the
/// health table's lock and the preferences file behind it are taken. The
/// observer's own lock is released by then too -- [`sweeps`] gave it back
/// with the sweeps -- so the order is only ever observer, then table, then
/// file.
pub fn commit(app: &AppState, sweeps: Vec<Sweep>) -> usize {
    sweeps.into_iter().fold(0, |recorded, sweep| {
        recorded + usize::from(crate::addon_health::commit_in(app, sweep))
    })
}
