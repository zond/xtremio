//! The stored record is not allowed to outlive the profile.
//!
//! Its own test binary because it drives `core_init`/`core_shutdown`, which
//! own the process while they run.

use chrono::{Duration, Utc};
use serde_json::json;
use stremio_core::types::profile::Profile;
use url::Url;
use xtremio_core::addon_health::{self, key_for, Outcome, ResourceKind, Table, PREFS_KEY};
use xtremio_core::api::core::{core_init, core_shutdown, CoreConfig};
use xtremio_core::state;

fn addon(url: &str) -> Url {
    Url::parse(url).expect("parse")
}

/// A record for `url` as it stood `age_days` ago, and nothing since.
fn aged(table: &mut Table, url: &str, age_days: i64) -> String {
    let key = key_for(&addon(url));
    table.record(
        &key,
        ResourceKind::Catalog,
        Outcome::Answered,
        Utc::now() - Duration::days(age_days),
    );
    key
}

/// A profile-less boot: the engine and its storage, without the embedded
/// server, which has nothing to do with what is remembered about addons.
fn config(root: &std::path::Path) -> CoreConfig {
    CoreConfig {
        storage_dir: root.join("core").display().to_string(),
        cache_dir: root.join("cache").display().to_string(),
        server: None,
    }
}

#[test]
fn init_forgets_the_addons_the_profile_has_not_had_for_a_month() -> anyhow::Result<()> {
    let tmp = tempfile::tempdir()?;
    let storage = tmp.path().join("core");
    std::fs::create_dir_all(&storage)?;

    // Whatever a default profile installs is what `init` will find
    // installed; the record for one of them must survive however old it is,
    // because the addon is still there to be judged.
    let still_installed = Profile::default()
        .addons
        .iter()
        .map(|addon| addon.transport_url.clone())
        .find(|url| url.scheme() == "https")
        .map(|url| key_for(&url))
        .expect("the default profile installs an addon on the network");

    let mut table = Table::default();
    table.record(
        &still_installed,
        ResourceKind::Catalog,
        Outcome::Answered,
        Utc::now() - Duration::days(400),
    );
    let long_gone = aged(
        &mut table,
        "https://long-gone.example.com/manifest.json",
        40,
    );
    let just_uninstalled = aged(&mut table, "https://recent.example.com/manifest.json", 5);
    std::fs::write(
        storage.join("xtremio_prefs.json"),
        json!({ PREFS_KEY: table.to_value() }).to_string(),
    )?;

    core_init(config(tmp.path()))?;
    let app = state::current().expect("init has a state");
    let table = addon_health::table_in(&app);

    assert!(
        table.get(&long_gone).is_none(),
        "an addon gone for a month is still remembered: {:?}",
        table.keys().collect::<Vec<_>>()
    );
    assert!(
        table.get(&just_uninstalled).is_some(),
        "an addon uninstalled last week was forgotten straight away"
    );
    assert!(
        table.get(&still_installed).is_some(),
        "an installed addon's history was pruned for being old"
    );

    core_shutdown()?;
    Ok(())
}
