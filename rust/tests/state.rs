//! The process state's lifetime: created once, adopted by `init`, taken
//! whole by `shutdown`, never inherited by the next `init`, and never put
//! back by work the shutdown outran.
//!
//! Its own test binary because it drives `core_init`/`core_shutdown`, which
//! own the process while they run.

use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::Arc;
use std::time::{Duration, Instant};

use url::Url;
use xtremio_core::addon_health::{self, Outcome, ResourceKind, Sweep, PREFS_KEY};
use xtremio_core::api::core::{core_init, core_is_initialized, core_shutdown, CoreConfig};
use xtremio_core::api::server::{server_base_url, ServerConfig};
use xtremio_core::state::{self, AppState};

/// Each boot gets its own directories, so a write the previous instance was
/// still finishing cannot be mistaken for state the next one inherited.
fn config(root: &std::path::Path, run: &str) -> CoreConfig {
    let root = root.join(run);
    CoreConfig {
        storage_dir: root.join("core").display().to_string(),
        cache_dir: root.join("cache").join("core").display().to_string(),
        server: Some(ServerConfig {
            config_dir: root.join("server").display().to_string(),
            cache_dir: root.join("cache").join("server").display().to_string(),
            port: 0,
            fallback_to_ephemeral: true,
        }),
    }
}

/// Whether the runtime pushed anything at all to this sink.
fn pumped_an_event(rx: &Receiver<String>) -> bool {
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        match rx.recv_timeout(Duration::from_millis(200)) {
            Ok(_) => return true,
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return false,
        }
    }
    false
}

/// Drains whatever the retired instance still had in flight, and returns
/// once nothing has arrived for `quiet`.
fn drain_until_quiet(rx: &Receiver<String>, quiet: Duration) {
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        match rx.recv_timeout(quiet) {
            Ok(_) => {}
            Err(_) => return,
        }
    }
}

/// The transport URL of the addon the sweep below is about.
const AN_ADDON: &str = "https://v3-cinemeta.strem.io/manifest.json";

/// Counts one answer into `app`, leaving the table with changes the file
/// does not have. The throttle keeps this out of the file (the table was
/// written -- loaded -- a moment ago at init), so the only write that can
/// follow is shutdown's forced one.
fn dirty_the_health_table(app: &AppState) {
    let mut sweep = Sweep::new();
    sweep.observe(
        &Url::parse(AN_ADDON).expect("parse"),
        ResourceKind::Catalog,
        Outcome::Answered,
    );
    assert!(
        addon_health::commit_in(app, sweep),
        "one addon answering is evidence"
    );
}

/// The addon keys the preferences file holds a health record for.
fn stored_health_keys() -> Vec<String> {
    let preferences = xtremio_core::prefs::get_all().expect("read preferences");
    let Some(serde_json::Value::Object(addons)) = preferences.get(PREFS_KEY) else {
        return vec![];
    };
    addons.keys().cloned().collect()
}

#[test]
fn init_creates_the_state_shutdown_takes_it_and_the_next_init_starts_clean() -> anyhow::Result<()> {
    let tmp = tempfile::tempdir()?;

    assert!(
        state::current().is_none(),
        "nothing has asked for a state yet"
    );
    // Observing is not creating: a read path must answer "not running"
    // rather than conjure a state to read.
    assert!(!core_is_initialized()?);
    assert_eq!(server_base_url()?, None);
    assert!(!xtremio_core::downloads::is_ticking());
    assert!(
        state::current().is_none(),
        "an observer must not create the state it is asking about"
    );

    // Dart's order: subscribe, then boot. The subscribe is what creates the
    // state, and `init` has to adopt that one -- a fresh value here would
    // throw away the sink and everything buffered into it.
    let (tx, rx) = mpsc::channel();
    xtremio_core::core::set_event_sink(Box::new(move |event| tx.send(event).is_ok()));
    let first = state::current().expect("the sink had somewhere to go");

    core_init(config(tmp.path(), "one"))?;
    assert!(core_is_initialized()?);
    let key = addon_health::key_for(&Url::parse(AN_ADDON).expect("parse"));
    assert!(
        Arc::ptr_eq(&first, &state::current().expect("init keeps a state")),
        "init adopted the state the subscriber created, rather than replacing it"
    );
    assert!(server_base_url()?.is_some());
    assert!(
        pumped_an_event(&rx),
        "the first runtime's events reached the first sink"
    );

    // Shutdown writes the addon-health table out whatever the throttle
    // says, so the table has to be dirty for that path to run at all --
    // otherwise this test would be asserting the invariant about a flush
    // that returned before touching the preferences file.
    dirty_the_health_table(&first);

    core_shutdown()?;
    assert!(
        state::current().is_none(),
        "shutdown took the whole state, not just the runtime"
    );
    assert!(!core_is_initialized()?);
    assert_eq!(server_base_url()?, None);
    assert!(
        state::current().is_none(),
        "and nothing on the way out put one back"
    );
    assert!(
        stored_health_keys().contains(&key),
        "the last answers never reached the file"
    );

    // A shutdown does not stop the background work of the instance it
    // retires: the downloads ticker is somewhere inside a blocking refresh,
    // the boot's re-pin inside a magnet the tracker has not answered yet.
    // Both go on addressing the state they were started for, which is what
    // they hold -- and asking that state anything must not build a new one,
    // which is exactly what the resurrecting `state::state` accessor does.
    // Driven here rather than raced: the window is real but it is
    // milliseconds wide, and a test that has to win it proves nothing on the
    // runs it loses.
    xtremio_core::downloads::ensure_ticker_in(&first);
    xtremio_core::downloads::repin_unfinished_in(&first);
    assert!(
        state::current().is_none(),
        "the retired instance's background work rebuilt the state shutdown took"
    );

    // Whatever the retired instance still had in flight lands in the sink
    // that asked for it; wait that out so what follows is unambiguous.
    drain_until_quiet(&rx, Duration::from_millis(500));

    // A second boot builds its own state. The first instance's sink is not
    // in it and cannot be pushed to again -- which is the whole reason
    // shutdown takes the value rather than emptying it.
    let (tx2, rx2) = mpsc::channel();
    xtremio_core::core::set_event_sink(Box::new(move |event| tx2.send(event).is_ok()));
    core_init(config(tmp.path(), "two"))?;
    let second = state::current().expect("a second init has a state");
    assert!(
        !Arc::ptr_eq(&first, &second),
        "and it is not the one shutdown took"
    );
    assert!(
        pumped_an_event(&rx2),
        "the second runtime's events reach the second sink"
    );
    assert!(
        rx.try_recv().is_err(),
        "the second runtime pushed nothing into the first instance's sink"
    );

    core_shutdown()?;
    assert!(state::current().is_none());
    core_shutdown()?; // no-op, and still nothing to inherit
    assert!(state::current().is_none());
    Ok(())
}
