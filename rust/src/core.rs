//! The stremio-core `Runtime` for this process: init, dispatch, state reads,
//! the runtime-event pump, and shutdown.
//!
//! Boot order (mirrors stremio-core-web's `initialize_runtime`): start the
//! embedded server -> point storage at the app dir -> run schema migrations
//! -> hydrate the persisted buckets -> retarget a loopback server URL at the
//! embedded server -> build the model -> `Runtime::new` -> pump events.
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

use std::collections::VecDeque;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::{Mutex, RwLock};

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

/// Capacity of the Runtime's event channel. `Runtime::emit` panics when it is
/// full, so the pump must always be running while the Runtime exists.
const EVENT_CHANNEL_CAPACITY: usize = 1000;
/// Events kept while no sink is attached (oldest dropped first).
const MAX_PENDING_EVENTS: usize = 1000;

/// Receives one serialized `RuntimeEvent`; returns `false` once closed.
pub type EventSink = Box<dyn Fn(String) -> bool + Send + Sync>;

static RUNTIME: RwLock<Option<Runtime<XtremioEnv, XtremioModel>>> = RwLock::new(None);
static EVENT_SINK: RwLock<Option<EventSink>> = RwLock::new(None);
static PENDING_EVENTS: Mutex<VecDeque<String>> = Mutex::new(VecDeque::new());

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

fn runtime_guard() -> std::sync::RwLockReadGuard<'static, Option<Runtime<XtremioEnv, XtremioModel>>>
{
    RUNTIME
        .read()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Whether `init` has completed and `shutdown` has not run since.
pub fn is_initialized() -> bool {
    runtime_guard().is_some()
}

/// Installs the event sink, replaying anything buffered while none was set.
pub fn set_event_sink(sink: EventSink) {
    let pending: Vec<String> = PENDING_EVENTS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .drain(..)
        .collect();
    let mut open = true;
    for event in pending {
        if !sink(event) {
            open = false;
            break;
        }
    }
    *EVENT_SINK
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = open.then_some(sink);
}

fn emit(event: String) {
    let delivered = {
        let guard = EVENT_SINK
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        guard.as_ref().map(|sink| sink(event.clone()))
    };
    match delivered {
        Some(true) => {}
        Some(false) => {
            tracing::info!("core event sink closed; buffering events");
            *EVENT_SINK
                .write()
                .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
            buffer(event);
        }
        None => buffer(event),
    }
}

fn buffer(event: String) {
    let mut pending = PENDING_EVENTS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
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

fn is_loopback(url: &Url) -> bool {
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
fn reapply_loopback_retarget() {
    let Some(embedded) = server::base_url() else {
        return;
    };
    let guard = runtime_guard();
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
    if is_initialized() {
        return Ok(InitOutcome {
            server_base_url: server::base_url(),
            schema_version: SCHEMA_VERSION,
        });
    }

    let server_base_url = match config.server {
        Some(server_config) => Some(server::start(server_config)?),
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

    let mut profile = profile.unwrap_or_default();
    if let Some(embedded) = &server_base_url {
        retarget_loopback_server(&mut profile, embedded);
    }
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
    XtremioEnv::exec_concurrent(events.for_each(|event| {
        let _ = catch_unwind(AssertUnwindSafe(|| {
            match serde_json::to_string(&event) {
                Ok(json) => emit(json),
                Err(error) => tracing::warn!(%error, "could not serialize runtime event"),
            }
            // After the event is out: Dart sees the login/logout first and the
            // resulting `NewState`/`SettingsUpdated` behind it. The dispatch
            // only queues into this channel, so it cannot block the pump.
            if let RuntimeEvent::CoreEvent(
                Event::UserAuthenticated { .. } | Event::UserLoggedOut { .. },
            ) = &event
            {
                reapply_loopback_retarget();
            }
        }));
        futures::future::ready(())
    }));

    *RUNTIME
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(runtime);
    tracing::info!(?server_base_url, "stremio-core runtime started");
    Ok(InitOutcome {
        server_base_url,
        schema_version: SCHEMA_VERSION,
    })
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
    let guard = runtime_guard();
    let runtime = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("core is not initialized"))?;
    runtime.dispatch(RuntimeAction {
        field: envelope.field,
        action: envelope.action,
    });
    Ok(())
}

/// Serializes one model field (`snake_case` name) to JSON.
pub fn get_state(field: &str) -> anyhow::Result<String> {
    let field = parse_field(field)?;
    let guard = runtime_guard();
    let runtime = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("core is not initialized"))?;
    let model = runtime
        .model()
        .map_err(|_| anyhow::anyhow!("core model lock is poisoned; re-initialize"))?;
    model
        .get_state_json(&field)
        .context("serialize model field")
}

/// Drops the Runtime (no more dispatches) and stops the embedded server.
/// The tokio runtimes stay alive for the process lifetime.
pub fn shutdown() -> anyhow::Result<()> {
    let runtime = RUNTIME
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .take();
    if runtime.is_some() {
        tracing::info!("stremio-core runtime stopped");
    }
    server::stop()
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

    #[test]
    fn events_are_buffered_until_a_sink_arrives_and_bounded() {
        // Isolated from the Runtime: exercise emit/buffer directly.
        *EVENT_SINK.write().unwrap() = None;
        PENDING_EVENTS.lock().unwrap().clear();
        for i in 0..(MAX_PENDING_EVENTS + 5) {
            emit(format!("e{i}"));
        }
        assert_eq!(PENDING_EVENTS.lock().unwrap().len(), MAX_PENDING_EVENTS);
        assert_eq!(PENDING_EVENTS.lock().unwrap().front().unwrap(), "e5");

        let (tx, rx) = std::sync::mpsc::channel();
        set_event_sink(Box::new(move |event| tx.send(event).is_ok()));
        let replayed: Vec<String> = rx.try_iter().collect();
        assert_eq!(replayed.len(), MAX_PENDING_EVENTS);
        assert_eq!(replayed[0], "e5");
        assert!(PENDING_EVENTS.lock().unwrap().is_empty());

        emit("live".into());
        assert_eq!(rx.try_iter().collect::<Vec<_>>(), vec!["live".to_owned()]);

        // A closed sink is dropped and events buffer again.
        drop(rx);
        emit("after-close".into());
        assert!(EVENT_SINK.read().unwrap().is_none());
        assert_eq!(
            PENDING_EVENTS.lock().unwrap().iter().collect::<Vec<_>>(),
            vec!["after-close"]
        );
        PENDING_EVENTS.lock().unwrap().clear();
    }

    #[test]
    fn dispatch_and_get_state_fail_before_init() {
        // Runs in the lib test binary where init is never called.
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
