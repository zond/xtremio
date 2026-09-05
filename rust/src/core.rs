//! The stremio-core `Runtime` for this process: init, dispatch, state reads,
//! the runtime-event pump, and shutdown.
//!
//! Boot order (mirrors stremio-core-web's `initialize_runtime`): start the
//! embedded server -> point storage at the app dir -> run schema migrations
//! -> hydrate the persisted buckets -> retarget a loopback server URL at the
//! embedded server -> build the model -> `Runtime::new` -> pump events ->
//! re-pin the unfinished offline downloads in the background.
//!
//! Every `NewState` is also read for how the addons answered, into
//! [`crate::addon_health`] by way of [`crate::addon_observer`]. Reading the
//! model from the pump is safe: `Runtime::dispatch` and
//! `Runtime::handle_effect_output` both release the model's *write* guard
//! before `handle_effects` emits, so nothing is ever waiting on this
//! channel while holding the lock this pump wants.
//!
//! Login and logout replace the profile settings with stremio-core's
//! defaults, which point the streaming server back at loopback:11470, so the
//! pump re-applies the retarget when `UserAuthenticated` / `UserLoggedOut`
//! come through.
//!
//! Events leave through an [`EventSink`] callback (installed by the FRB layer
//! around a Dart `StreamSink`, or by tests around a channel). Events emitted
//! before a sink exists are buffered, bounded, so nothing is lost across the
//! subscribe/init ordering.
//!
//! None of that is a `static` of its own: it is [`CoreState`], one field of
//! the process's [`crate::state::AppState`], which `init` creates and
//! `shutdown` takes away whole.

use std::collections::VecDeque;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard, RwLock, RwLockReadGuard, RwLockWriteGuard};

use anyhow::Context;
use futures::StreamExt;
use serde::Deserialize;
use stremio_core::constants::{
    DISMISSED_EVENTS_STORAGE_KEY, LIBRARY_RECENT_STORAGE_KEY, LIBRARY_STORAGE_KEY,
    NOTIFICATIONS_STORAGE_KEY, PROFILE_STORAGE_KEY, SCHEMA_VERSION, SEARCH_HISTORY_STORAGE_KEY,
    STREAMING_SERVER_URLS_STORAGE_KEY, STREAMS_STORAGE_KEY,
};
use stremio_core::runtime::msg::{Action, ActionCtx, Event};
use stremio_core::runtime::{Env, EnvError, Runtime, RuntimeAction, RuntimeEvent};
use stremio_core::types::events::DismissedEventsBucket;
use stremio_core::types::library::LibraryBucket;
use stremio_core::types::notifications::NotificationsBucket;
use stremio_core::types::profile::{Profile, Settings};
use stremio_core::types::search_history::SearchHistoryBucket;
use stremio_core::types::server_urls::ServerUrlsBucket;
use stremio_core::types::streams::StreamsBucket;
use url::Url;

use crate::env::{self, XtremioEnv};
use crate::model::{parse_field, XtremioModel, XtremioModelField};
use crate::server;
use crate::state::AppState;

/// Capacity of the Runtime's event channel. `Runtime::emit` panics when it is
/// full, so the pump must always be running while the Runtime exists.
const EVENT_CHANNEL_CAPACITY: usize = 1000;
/// Events kept while no sink is attached (oldest dropped first).
const MAX_PENDING_EVENTS: usize = 1000;

/// Receives one serialized `RuntimeEvent`; returns `false` once closed.
pub type EventSink = Box<dyn Fn(String) -> bool + Send + Sync>;

/// The stremio-core half of [`AppState`]: the Runtime, where its events go
/// and the ones with nowhere to go yet. Three locks rather than one because
/// they are taken for unrelated reasons -- a dispatch reads the Runtime
/// while the pump is delivering an event -- and never nested.
#[derive(Default)]
pub struct CoreState {
    runtime: RwLock<Option<Runtime<XtremioEnv, XtremioModel>>>,
    event_sink: RwLock<Option<EventSink>>,
    pending_events: Mutex<VecDeque<String>>,
}

/// A poisoned lock only means a previous holder panicked; the value behind
/// it is still valid, so every accessor here reads through the poison.
impl CoreState {
    fn runtime(&self) -> RwLockReadGuard<'_, Option<Runtime<XtremioEnv, XtremioModel>>> {
        self.runtime
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn runtime_mut(&self) -> RwLockWriteGuard<'_, Option<Runtime<XtremioEnv, XtremioModel>>> {
        self.runtime
            .write()
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

    fn pending(&self) -> MutexGuard<'_, VecDeque<String>> {
        self.pending_events
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// Everything `init` needs; directories are chosen by the host (Dart).
#[derive(Clone, Debug)]
pub struct InitConfig {
    /// Persisted stremio-core buckets (`<key>.json`).
    pub storage_dir: PathBuf,
    /// Reserved for an HTTP cache; created but unused for now.
    pub cache_dir: PathBuf,
    /// Start the embedded server first and point the engine at it.
    pub server: Option<server::StartConfig>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InitOutcome {
    pub server_base_url: Option<Url>,
    pub schema_version: u32,
}

fn not_initialized() -> anyhow::Error {
    anyhow::anyhow!("core is not initialized")
}

/// Runs `f` against the running Runtime. No state at all and a state with no
/// Runtime in it are the same answer to the caller: the core is not up.
fn with_runtime<T>(
    f: impl FnOnce(&Runtime<XtremioEnv, XtremioModel>) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    let app = crate::state::current().ok_or_else(not_initialized)?;
    let guard = app.core.runtime();
    f(guard.as_ref().ok_or_else(not_initialized)?)
}

/// Whether `init` has completed and `shutdown` has not run since.
pub fn is_initialized() -> bool {
    crate::state::current().is_some_and(|app| app.core.runtime().is_some())
}

/// Installs the event sink, replaying anything buffered while none was set.
/// Called before `init` by design, which is what creates the state.
pub fn set_event_sink(sink: EventSink) {
    set_event_sink_in(&crate::state::state(), sink);
}

fn set_event_sink_in(app: &AppState, sink: EventSink) {
    let pending: Vec<String> = app.core.pending().drain(..).collect();
    let mut open = true;
    for event in pending {
        if !sink(event) {
            open = false;
            break;
        }
    }
    *app.core.sink_mut() = open.then_some(sink);
}

fn emit(app: &AppState, event: String) {
    let delivered = {
        let guard = app.core.sink();
        guard.as_ref().map(|sink| sink(event.clone()))
    };
    match delivered {
        Some(true) => {}
        Some(false) => {
            tracing::info!("core event sink closed; buffering events");
            *app.core.sink_mut() = None;
            buffer(app, event);
        }
        None => buffer(app, event),
    }
}

fn buffer(app: &AppState, event: String) {
    let mut pending = app.core.pending();
    if pending.len() >= MAX_PENDING_EVENTS {
        pending.pop_front();
    }
    pending.push_back(event);
}

fn hydrate<T: for<'de> Deserialize<'de> + Send + 'static>(
    key: &str,
) -> impl std::future::Future<Output = Option<T>> {
    let key = key.to_owned();
    async move {
        match XtremioEnv::get_storage::<T>(&key).await {
            Ok(value) => value,
            Err(EnvError::Serde(message)) => {
                tracing::warn!(key, %message, "persisted bucket unreadable; starting empty");
                None
            }
            Err(error) => {
                tracing::warn!(key, ?error, "persisted bucket unavailable; starting empty");
                None
            }
        }
    }
}

/// Whether `url` names this machine: the two loopback addresses and the
/// name that resolves to them. Shared with [`crate::addon_health`], which
/// needs the same answer for the opposite reason -- what is on loopback is
/// this app's own stub, never an addon whose reachability says anything.
pub(crate) fn is_loopback(url: &Url) -> bool {
    match url.host() {
        Some(url::Host::Ipv4(ip)) => ip.is_loopback(),
        Some(url::Host::Ipv6(ip)) => ip.is_loopback(),
        Some(url::Host::Domain(domain)) => domain.eq_ignore_ascii_case("localhost"),
        None => false,
    }
}

/// If the profile points at a loopback server (stremio-core's default), point
/// it at the embedded server instead. A user-configured remote server URL is
/// left alone.
pub fn retarget_loopback_server(profile: &mut Profile, embedded: &Url) {
    retarget_loopback_settings(&mut profile.settings, embedded);
}

/// [`retarget_loopback_server`] on the settings alone; `true` when changed.
fn retarget_loopback_settings(settings: &mut Settings, embedded: &Url) -> bool {
    let current = &settings.streaming_server_url;
    if is_loopback(current) && current != embedded {
        tracing::info!(from = %current, to = %embedded, "retargeting streaming server URL at the embedded server");
        settings.streaming_server_url = embedded.clone();
        true
    } else {
        false
    }
}

/// Re-applies the init-time retarget after stremio-core reset the settings
/// (login and logout both replace them with `Settings::default()`, whose
/// server URL is loopback:11470). Dispatches `UpdateSettings` with the
/// retargeted copy when the current URL is loopback but not the embedded
/// server; a remote URL, or no embedded server, leaves everything alone.
pub(crate) fn reapply_loopback_retarget(app: &AppState) {
    let Some(embedded) = server::base_url_in(app) else {
        return;
    };
    let guard = app.core.runtime();
    let Some(runtime) = guard.as_ref() else {
        return;
    };
    let mut settings = match runtime.model() {
        Ok(model) => model.ctx.profile.settings.clone(),
        Err(_) => return,
    };
    // The model read guard is released; `dispatch` takes the write lock.
    if retarget_loopback_settings(&mut settings, &embedded) {
        runtime.dispatch(RuntimeAction {
            field: Some(XtremioModelField::Ctx),
            action: Action::Ctx(ActionCtx::UpdateSettings(settings)),
        });
    }
}

/// Boots the engine. Idempotent: a second call returns the current outcome.
pub fn init(config: InitConfig) -> anyhow::Result<InitOutcome> {
    crate::logging::init();
    // The state may already exist: Dart subscribes to the event streams
    // before it calls `core_init`, and that is what created it.
    let app = crate::state::state();
    let already_up = app.core.runtime().is_some();
    if already_up {
        return Ok(InitOutcome {
            server_base_url: server::base_url_in(&app),
            schema_version: SCHEMA_VERSION,
        });
    }

    let server_base_url = match config.server {
        Some(server_config) => Some(server::start_in(&app, server_config)?),
        None => None,
    };

    env::set_storage_dir(&config.storage_dir)?;
    std::fs::create_dir_all(&config.cache_dir)
        .with_context(|| format!("create core cache dir {:?}", config.cache_dir))?;

    if let Err(error) = env::block_on(XtremioEnv::migrate_storage_schema()) {
        tracing::warn!(
            ?error,
            "storage schema migration failed; continuing with what is readable"
        );
    }

    let (profile, recent, library, streams, server_urls, notifications, search_history, dismissed) =
        env::block_on(async {
            futures::join!(
                hydrate::<Profile>(PROFILE_STORAGE_KEY),
                hydrate::<LibraryBucket>(LIBRARY_RECENT_STORAGE_KEY),
                hydrate::<LibraryBucket>(LIBRARY_STORAGE_KEY),
                hydrate::<StreamsBucket>(STREAMS_STORAGE_KEY),
                hydrate::<ServerUrlsBucket>(STREAMING_SERVER_URLS_STORAGE_KEY),
                hydrate::<NotificationsBucket>(NOTIFICATIONS_STORAGE_KEY),
                hydrate::<SearchHistoryBucket>(SEARCH_HISTORY_STORAGE_KEY),
                hydrate::<DismissedEventsBucket>(DISMISSED_EVENTS_STORAGE_KEY),
            )
        });

    // Beside the buckets, and for the same reason: nothing is written out
    // before the stored record has been read, or this process's first
    // minute of answers would replace all of it.
    crate::addon_health::load_in(&app);

    let mut profile = profile.unwrap_or_default();
    if let Some(embedded) = &server_base_url {
        retarget_loopback_server(&mut profile, embedded);
    }
    // The record is about addons this profile has. Once one has been gone
    // long enough that reinstalling it would not be "the same addon" any
    // more, its counts are only a host name the file keeps forever.
    // After the retarget, so the local addon is judged installed by the
    // URL the profile actually holds.
    crate::addon_health::prune_uninstalled_in(
        &app,
        &profile
            .addons
            .iter()
            .map(|addon| crate::addon_health::key_for(&addon.transport_url))
            .collect(),
    );
    let uid = profile.uid();
    let mut library_bucket = LibraryBucket::new(uid.clone(), vec![]);
    if let Some(recent) = recent {
        library_bucket.merge_bucket(recent);
    }
    if let Some(library) = library {
        library_bucket.merge_bucket(library);
    }

    let (model, effects) = XtremioModel::new(
        profile,
        library_bucket,
        streams.unwrap_or_else(|| StreamsBucket::new(uid.clone())),
        server_urls.unwrap_or_else(|| ServerUrlsBucket::new::<XtremioEnv>(uid.clone())),
        notifications
            .unwrap_or_else(|| NotificationsBucket::new::<XtremioEnv>(uid.clone(), vec![])),
        search_history.unwrap_or_else(|| SearchHistoryBucket::new(uid.clone())),
        dismissed.unwrap_or_else(|| DismissedEventsBucket::new(uid)),
    );

    let (runtime, events) = Runtime::<XtremioEnv, XtremioModel>::new(
        model,
        effects.into_iter().collect(),
        EVENT_CHANNEL_CAPACITY,
    );

    // The pump must outlive every Runtime clone: a full channel panics inside
    // `Runtime::emit`. Per-event work is contained so the task never dies.
    // It holds the state it was started for, so an event still in flight
    // when `shutdown` takes that state away is delivered to the sinks that
    // asked for it and not to whatever a later `init` installs.
    let pump = Arc::clone(&app);
    XtremioEnv::exec_concurrent(events.for_each(move |event| {
        let app = &pump;
        let _ = catch_unwind(AssertUnwindSafe(|| {
            match serde_json::to_string(&event) {
                Ok(json) => emit(app, json),
                Err(error) => tracing::warn!(%error, "could not serialize runtime event"),
            }
            // After the event is out: Dart sees the login/logout first and the
            // resulting `NewState`/`SettingsUpdated` behind it. The dispatch
            // only queues into this channel, so it cannot block the pump.
            if let RuntimeEvent::CoreEvent(
                Event::UserAuthenticated { .. } | Event::UserLoggedOut { .. },
            ) = &event
            {
                reapply_loopback_retarget(app);
            }
            if let RuntimeEvent::NewState(fields, ..) = &event {
                observe_addon_answers(app, fields);
            }
        }));
        futures::future::ready(())
    }));

    *app.core.runtime_mut() = Some(runtime);

    // The server persists its own pin set, but a registry entry can outlive
    // it (a purged cache dir, a downloads volume that was not mounted last
    // boot), so every unfinished download is pinned again. Off the boot
    // path: a pin blocks while a magnet resolves its metadata, and nothing
    // on screen waits for it.
    if server_base_url.is_some() {
        // Against the state this boot built, not whatever the process holds
        // when it gets there: a pin blocks until the tracker answers, so a
        // shutdown can retire this state first, and looking one up would
        // rebuild what the shutdown took.
        let booted = Arc::clone(&app);
        XtremioEnv::exec_concurrent(async move {
            if let Err(error) =
                tokio::task::spawn_blocking(move || crate::downloads::repin_unfinished_in(&booted))
                    .await
            {
                tracing::warn!(%error, "re-pinning the offline downloads panicked");
            }
        });
    }

    tracing::info!(?server_base_url, "stremio-core runtime started");
    Ok(InitOutcome {
        server_base_url,
        schema_version: SCHEMA_VERSION,
    })
}

/// Counts how the addons answered in the fields a `NewState` names.
///
/// Reads the model as it is now rather than as it was when the event was
/// emitted, which is what the edge detection in [`crate::addon_observer`]
/// is for. Safe to do from the pump: see this module's docs on why no
/// writer can be waiting on the pump's channel while holding the model's
/// write lock.
///
/// The model is let go before the answers are counted, and that is the
/// point of the two calls. Counting is what writes the record out -- an
/// `fsync` and a rename, up to once a minute -- and the model's read lock
/// held across that would park the next `Runtime::dispatch` (which wants
/// the write lock) and, behind it, every reader including `get_state`.
///
/// Nothing is counted before the Runtime has been installed (the pump is
/// started first, so the bootstrap effects' events arrive with no model to
/// read) or after `shutdown` has taken it away -- by which point the record
/// has already been written out.
fn observe_addon_answers(app: &AppState, fields: &[XtremioModelField]) {
    let sweeps = {
        let guard = app.core.runtime();
        let Some(runtime) = guard.as_ref() else {
            return;
        };
        let Ok(model) = runtime.model() else {
            return;
        };
        crate::addon_observer::sweeps(app, &model, fields)
    };
    crate::addon_observer::commit(app, sweeps);
}

/// `{"field": <model field | null>, "action": <stremio_core Action>}`.
#[derive(Deserialize)]
struct ActionEnvelope {
    #[serde(default)]
    field: Option<XtremioModelField>,
    action: Action,
}

/// Dispatches a JSON-encoded action into the Runtime.
pub fn dispatch(action_json: &str) -> anyhow::Result<()> {
    let mut deserializer = serde_json::Deserializer::from_str(action_json);
    let envelope: ActionEnvelope =
        serde_path_to_error::deserialize(&mut deserializer).map_err(|error| {
            anyhow::anyhow!(
                "invalid action JSON at `{}`: {}",
                error.path(),
                error.inner()
            )
        })?;
    with_runtime(|runtime| {
        runtime.dispatch(RuntimeAction {
            field: envelope.field,
            action: envelope.action,
        });
        Ok(())
    })
}

/// Serializes one model field (`snake_case` name) to JSON.
pub fn get_state(field: &str) -> anyhow::Result<String> {
    let field = parse_field(field)?;
    with_runtime(|runtime| {
        let model = runtime
            .model()
            .map_err(|_| anyhow::anyhow!("core model lock is poisoned; re-initialize"))?;
        model
            .get_state_json(&field)
            .context("serialize model field")
    })
}

/// Drops the Runtime (no more dispatches), writes out how the addons have
/// been answering and stops the embedded server. The tokio runtimes stay
/// alive for the process lifetime.
///
/// The whole [`AppState`] goes with it, and it goes *first*: from here on a
/// sink, a dispatch or a subscribe addresses a fresh state, never the one
/// being torn down. Whatever this call took is dropped when it returns.
pub fn shutdown() -> anyhow::Result<()> {
    let Some(app) = crate::state::take() else {
        return Ok(());
    };
    if app.core.runtime_mut().take().is_some() {
        tracing::info!("stremio-core runtime stopped");
    }
    // Whatever the throttle says: the last minute of answers is the part
    // that would otherwise never reach the file. Of *this* state, which is
    // the only one anything still counting can be counting into.
    crate::addon_health::flush_in(&app);
    server::stop_in(&app)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loopback_urls_are_retargeted_but_remote_ones_kept() {
        let embedded = Url::parse("http://127.0.0.1:43123/").unwrap();
        for loopback in [
            "http://127.0.0.1:11470/",
            "http://localhost:11470",
            "http://[::1]:11470/",
        ] {
            let mut profile = Profile::default();
            profile.settings.streaming_server_url = Url::parse(loopback).unwrap();
            retarget_loopback_server(&mut profile, &embedded);
            assert_eq!(
                profile.settings.streaming_server_url, embedded,
                "{loopback}"
            );
        }
        let mut profile = Profile::default();
        let remote = Url::parse("http://192.168.1.20:11470/").unwrap();
        profile.settings.streaming_server_url = remote.clone();
        retarget_loopback_server(&mut profile, &embedded);
        assert_eq!(profile.settings.streaming_server_url, remote);
    }

    /// Against a state of this test's own, not the process's: buffering is a
    /// property of an `AppState`, so nothing here has to be serialized
    /// against another test or run in a particular order.
    #[test]
    fn events_are_buffered_until_a_sink_arrives_and_bounded() {
        let app = AppState::default();
        for i in 0..(MAX_PENDING_EVENTS + 5) {
            emit(&app, format!("e{i}"));
        }
        assert_eq!(app.core.pending().len(), MAX_PENDING_EVENTS);
        assert_eq!(app.core.pending().front().unwrap(), "e5");

        let (tx, rx) = std::sync::mpsc::channel();
        set_event_sink_in(&app, Box::new(move |event| tx.send(event).is_ok()));
        let replayed: Vec<String> = rx.try_iter().collect();
        assert_eq!(replayed.len(), MAX_PENDING_EVENTS);
        assert_eq!(replayed[0], "e5");
        assert!(app.core.pending().is_empty());

        emit(&app, "live".into());
        assert_eq!(rx.try_iter().collect::<Vec<_>>(), vec!["live".to_owned()]);

        // A closed sink is dropped and events buffer again.
        drop(rx);
        emit(&app, "after-close".into());
        assert!(app.core.sink().is_none());
        assert_eq!(
            app.core.pending().iter().collect::<Vec<_>>(),
            vec!["after-close"]
        );
    }

    #[test]
    fn dispatch_and_get_state_fail_before_init() {
        // Runs in the lib test binary, where nothing calls `init`: whether
        // another test has created the state or not, its Runtime is `None`
        // and both answers are the same.
        let error = dispatch(r#"{"action":{"action":"Unload"}}"#).unwrap_err();
        assert!(error.to_string().contains("not initialized"), "{error}");
        let error = get_state("ctx").unwrap_err();
        assert!(error.to_string().contains("not initialized"), "{error}");
        let error = dispatch(r#"{"field":"board","action":{"action":"Nope"}}"#).unwrap_err();
        assert!(error.to_string().contains("invalid action JSON"), "{error}");
        let error = get_state("nope").unwrap_err();
        assert!(error.to_string().contains("unknown model field"), "{error}");
    }
}
