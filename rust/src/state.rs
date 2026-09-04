//! The state this process owns, in one value.
//!
//! Everything the crate keeps between FFI calls -- the stremio-core
//! `Runtime` and its event sink, the embedded server's handle, the downloads
//! registry's locks and its progress sink, the preferences file's lock, the
//! addon-health counts and what the event pump has already seen -- lives
//! in one [`AppState`],
//! grouped by the concern that owns it, behind one process static. That is
//! the whole point: "who owns this, and when does it go away" has a single
//! answer instead of one per `static`.
//!
//! Lifetime: `crate::core::init` creates it -- or, before that, whichever
//! call first needs it, because Dart subscribes to the event streams
//! *before* `core_init` and buffering an event has to have somewhere to put
//! it -- and `crate::core::shutdown` takes it out with [`take`]. The next
//! `init` therefore starts from a fresh value and cannot inherit the
//! previous instance's sinks, buffered events or ticker flag.
//!
//! It is handed out as an `Arc` and every lock is a field *inside* that
//! value, never around it: a caller clones the `Arc` (a read lock held for
//! that long and no longer) and then takes only the one lock it needs, so
//! nothing coarse is held across the server's blocking library calls. Work
//! that outlives a shutdown -- the runtime-event pump, the downloads ticker
//! -- keeps its own `Arc` and goes on addressing the state it was started
//! for, which by then nobody else can reach; [`is_current`] is how such a
//! task notices it has been retired.

use std::sync::{Arc, RwLock, RwLockReadGuard, RwLockWriteGuard};

/// Everything this process keeps between calls, by concern.
#[derive(Default)]
pub struct AppState {
    /// The stremio-core runtime, its event sink and the pending buffer.
    pub core: crate::core::CoreState,
    /// The embedded stream-server's handle while it runs.
    pub server: crate::server::ServerState,
    /// The offline-downloads registry's locks, progress sink and ticker.
    pub downloads: crate::downloads::DownloadsState,
    /// The preferences file's lock.
    pub prefs: crate::prefs::PrefsState,
    /// How each installed addon has been answering, and when it was last
    /// written out.
    pub addon_health: crate::addon_health::AddonHealthState,
    /// What the runtime pump has already seen each addon answer, so the
    /// same settled answer is never counted twice.
    pub addon_observer: crate::addon_observer::ObserverState,
}

/// The one process static. `None` until something needs the state, and
/// again after [`take`]; a `LazyLock` could not answer the second half.
static APP: RwLock<Option<Arc<AppState>>> = RwLock::new(None);

/// A poisoned lock only means a previous holder panicked; the `Option`
/// behind it is still a valid value.
fn read() -> RwLockReadGuard<'static, Option<Arc<AppState>>> {
    APP.read().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn write() -> RwLockWriteGuard<'static, Option<Arc<AppState>>> {
    APP.write().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// The process state, creating it if there is none. For callers that
/// *install* something (init, the server's start, a sink); an observer wants
/// [`current`], which does not resurrect a state after shutdown.
pub fn state() -> Arc<AppState> {
    if let Some(app) = current() {
        return app;
    }
    let mut guard = write();
    // Another thread may have won the race between the two locks.
    Arc::clone(guard.get_or_insert_with(|| Arc::new(AppState::default())))
}

/// The process state, or `None` when nothing has created one -- which is
/// what "not initialized" looks like to an observer.
pub fn current() -> Option<Arc<AppState>> {
    read().clone()
}

/// Removes the state from the process and hands it to the caller, whose job
/// it then is to tear down what it holds. The next [`state`] builds a fresh
/// one, so nothing installed before this point can be reached again.
pub fn take() -> Option<Arc<AppState>> {
    write().take()
}

/// Whether `app` is still *the* process state. A background task started
/// against one instance uses this to notice that a shutdown retired it.
pub fn is_current(app: &Arc<AppState>) -> bool {
    read()
        .as_ref()
        .is_some_and(|current| Arc::ptr_eq(current, app))
}
