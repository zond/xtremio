//! The library and the addon models through the FRB surface.
//!
//! `library_follows_add_and_remove` runs offline in `cargo test`: it loads
//! `LibraryWithFilters`, adds a movie and a series through `Ctx` actions and
//! removes one again, checking that `library` follows and that items without
//! progress stay out of `continue_watching_preview`.
//!
//! `record_library_and_addons_fixtures` is the network recorder for the Dart
//! tests (ignored by default; run with
//! `cargo test --test library_addons -- --ignored --nocapture`). It writes
//! `ctx_logged_out.json`, `installed_addons_default.json`,
//! `addon_details_cinemeta.json`, `remote_addons_community.json` (trimmed to
//! [`COMMUNITY_ITEMS`] entries) and `library_default.json`. The recorder runs
//! without the embedded server so the recorded `streamingServerUrl` is
//! stremio-core's default rather than an ephemeral port.
//!
//! `ctx_logged_in.json` is hand-authored (a fake account modelled on
//! stremio-core's `unit_tests/ctx/authenticate.rs`); `logged_in_fixture_is_a_
//! valid_profile` keeps it deserializable.

use std::time::{Duration, Instant};

use stremio_core::types::profile::Profile;
use xtremio_core::api::core::{
    core_dispatch, core_get_state, core_init, core_shutdown, CoreConfig,
};
use xtremio_core::api::server::ServerConfig;

const CINEMETA: &str = "https://v3-cinemeta.strem.io/manifest.json";
/// How many descriptors of the community catalog the fixture keeps.
const COMMUNITY_ITEMS: usize = 20;

fn fixtures_dir() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

fn state(field: &str) -> serde_json::Value {
    serde_json::from_str(&core_get_state(field.to_owned()).expect(field)).expect("valid JSON")
}

fn write_fixture(name: &str, value: &serde_json::Value) -> anyhow::Result<()> {
    let fixtures = fixtures_dir();
    std::fs::create_dir_all(&fixtures)?;
    std::fs::write(fixtures.join(name), serde_json::to_vec_pretty(value)?)?;
    Ok(())
}

fn read_fixture(name: &str) -> anyhow::Result<serde_json::Value> {
    Ok(serde_json::from_slice(&std::fs::read(
        fixtures_dir().join(name),
    )?)?)
}

fn dispatch(envelope: serde_json::Value) -> anyhow::Result<()> {
    core_dispatch(envelope.to_string())
}

/// `{"field":"ctx","action":{"action":"Ctx","args":<action>}}`: the shape
/// of every `CoreActions` Ctx builder.
fn ctx_action(action: serde_json::Value) -> serde_json::Value {
    serde_json::json!({
        "field": "ctx",
        "action": { "action": "Ctx", "args": action }
    })
}

fn load(field: &str, model: &str, args: serde_json::Value) -> anyhow::Result<()> {
    dispatch(serde_json::json!({
        "field": field,
        "action": { "action": "Load", "args": { "model": model, "args": args } }
    }))
}

/// Same shape as `CoreActions.loadLibrary(LibraryRequest())`.
fn load_library() -> anyhow::Result<()> {
    load(
        "library",
        "LibraryWithFilters",
        serde_json::json!({ "request": { "type": null, "sort": "lastwatched", "page": 1 } }),
    )
}

fn wait_for(
    field: &str,
    deadline: Duration,
    ready: impl Fn(&serde_json::Value) -> bool,
) -> serde_json::Value {
    let deadline = Instant::now() + deadline;
    loop {
        let value = state(field);
        if ready(&value) {
            return value;
        }
        assert!(Instant::now() < deadline, "timed out on {field}: {value}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn library_ids(library: &serde_json::Value) -> Vec<String> {
    library["catalog"]
        .as_array()
        .expect("catalog")
        .iter()
        .map(|item| item["_id"].as_str().expect("_id").to_owned())
        .collect()
}

/// A movie preview from the recorded Discover page and a series from the
/// recorded Board: raw `MetaItemPreview` JSON, which is what `AddToLibrary`
/// takes.
fn fixture_previews() -> anyhow::Result<(serde_json::Value, serde_json::Value)> {
    let discover = read_fixture("discover_cinemeta_top.json")?;
    let movie = discover["catalog"][0]["content"]["content"][0].clone();
    assert_eq!(movie["type"], "movie", "{movie}");
    let board = read_fixture("board_default_addons.json")?;
    let series = board["catalogs"]
        .as_array()
        .expect("catalogs")
        .iter()
        .find(|pages| pages[0]["request"]["path"]["type"] == "series")
        .map(|pages| pages[0]["content"]["content"][0].clone())
        .expect("a Ready series catalog in the board fixture");
    assert_eq!(series["type"], "series", "{series}");
    Ok((movie, series))
}

/// Loads the library, adds the two fixture titles and waits until both are
/// in `library.catalog`; returns the (movie id, series id) and the state.
fn add_fixture_titles() -> anyhow::Result<(String, String, serde_json::Value)> {
    load_library()?;
    let library = state("library");
    assert_eq!(
        library["selected"]["request"]["type"],
        serde_json::Value::Null
    );
    assert_eq!(library["selected"]["request"]["sort"], "lastwatched");
    assert_eq!(library["selected"]["request"]["page"], 1);
    assert_eq!(library["catalog"], serde_json::json!([]), "{library}");
    assert_eq!(
        library["selectable"]["types"],
        serde_json::json!([{
            "type": null, "selected": true,
            "request": { "type": null, "sort": "lastwatched", "page": 1 }
        }]),
        "an empty library offers only the `all` type: {library}"
    );
    let sorts = library["selectable"]["sorts"].as_array().expect("sorts");
    assert_eq!(sorts.len(), 6, "{library}");
    assert_eq!(sorts[0]["sort"], "lastwatched");
    assert_eq!(sorts[0]["selected"], true);
    assert!(
        library["selectable"]
            .as_object()
            .is_some_and(|s| s.contains_key("next_page")),
        "LibraryWithFilters has no rename_all: {library}"
    );
    assert_eq!(library["selectable"]["next_page"], serde_json::Value::Null);

    let (movie, series) = fixture_previews()?;
    let movie_id = movie["id"].as_str().unwrap().to_owned();
    let series_id = series["id"].as_str().unwrap().to_owned();
    // Same shape as `CoreActions.addToLibrary(meta.json)`.
    dispatch(ctx_action(
        serde_json::json!({ "action": "AddToLibrary", "args": movie }),
    ))?;
    dispatch(ctx_action(
        serde_json::json!({ "action": "AddToLibrary", "args": series }),
    ))?;
    let library = wait_for("library", Duration::from_secs(10), |library| {
        library["catalog"].as_array().is_some_and(|c| c.len() == 2)
    });
    let mut ids = library_ids(&library);
    ids.sort();
    let mut expected = vec![movie_id.clone(), series_id.clone()];
    expected.sort();
    assert_eq!(ids, expected, "{library}");
    Ok((movie_id, series_id, library))
}

#[test]
fn library_follows_add_and_remove() -> anyhow::Result<()> {
    let tmp = tempfile::tempdir()?;
    core_init(CoreConfig {
        storage_dir: tmp.path().join("core").display().to_string(),
        cache_dir: tmp.path().join("cache").display().to_string(),
        server: Some(ServerConfig {
            config_dir: tmp.path().join("server").display().to_string(),
            cache_dir: tmp.path().join("cache/server").display().to_string(),
            port: 0,
            fallback_to_ephemeral: true,
        }),
    })?;

    let (movie_id, series_id, library) = add_fixture_titles()?;
    for item in library["catalog"].as_array().unwrap() {
        assert_eq!(item["removed"], false, "{item}");
        assert_eq!(item["temp"], false, "{item}");
        assert_eq!(item["state"]["timeOffset"], 0, "{item}");
        assert_eq!(item["state"]["timesWatched"], 0, "{item}");
        assert!(item["_mtime"].is_string(), "{item}");
        assert!(
            item["state"]["lastWatched"].is_string(),
            "added = watched now: {item}"
        );
    }
    // Both types show up as filters, `all` first.
    let types: Vec<_> = library["selectable"]["types"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["type"].clone())
        .collect();
    assert_eq!(
        types,
        serde_json::json!([null, "movie", "series"])
            .as_array()
            .unwrap()
            .clone(),
        "{library}"
    );
    // Nothing was played, so continue watching stays empty even though the
    // library changed.
    assert_eq!(
        state("continue_watching_preview")["items"],
        serde_json::json!([])
    );

    // Same shape as `CoreActions.removeFromLibrary(id)`.
    dispatch(ctx_action(
        serde_json::json!({ "action": "RemoveFromLibrary", "args": movie_id }),
    ))?;
    let library = wait_for("library", Duration::from_secs(10), |library| {
        library["catalog"].as_array().is_some_and(|c| c.len() == 1)
    });
    assert_eq!(library_ids(&library), vec![series_id]);
    assert_eq!(
        library["selectable"]["types"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["type"].clone())
            .collect::<Vec<_>>(),
        vec![serde_json::Value::Null, serde_json::json!("series")]
    );
    assert_eq!(
        state("continue_watching_preview")["items"],
        serde_json::json!([])
    );

    // Unload clears only this field.
    dispatch(serde_json::json!({ "field": "library", "action": { "action": "Unload" } }))?;
    let library = state("library");
    assert!(library["selected"].is_null(), "{library}");
    assert_eq!(library["catalog"], serde_json::json!([]));

    core_shutdown()?;
    Ok(())
}

#[test]
fn logged_in_fixture_is_a_valid_profile() -> anyhow::Result<()> {
    let ctx = read_fixture("ctx_logged_in.json")?;
    let profile: Profile = serde_json::from_value(ctx["profile"].clone())?;
    let auth = profile.auth.expect("auth");
    assert_eq!(auth.user.email, "user@example.com");
    assert_eq!(auth.user.id.to_string(), "fake_user_id");
    assert!(profile.addons.len() >= 2, "carries the official addons");
    assert!(!profile.addons_locked);
    // The logged-out fixture is the same profile without an account.
    let ctx = read_fixture("ctx_logged_out.json")?;
    let profile: Profile = serde_json::from_value(ctx["profile"].clone())?;
    assert!(profile.auth.is_none());
    Ok(())
}

#[test]
#[ignore = "needs internet access to Cinemeta"]
fn record_library_and_addons_fixtures() -> anyhow::Result<()> {
    let tmp = tempfile::tempdir()?;
    core_init(CoreConfig {
        storage_dir: tmp.path().join("core").display().to_string(),
        cache_dir: tmp.path().join("cache").display().to_string(),
        server: None,
    })?;

    // A fresh, anonymous profile: `{profile, notifications, events}`.
    let ctx = state("ctx");
    assert!(ctx["profile"]["auth"].is_null(), "{ctx}");
    assert_eq!(ctx["profile"]["addonsLocked"], false);
    assert_eq!(
        ctx["profile"]["settings"]["streamingServerUrl"],
        "http://127.0.0.1:11470/"
    );
    let addon_count = ctx["profile"]["addons"].as_array().expect("addons").len();
    assert!(addon_count >= 2, "{ctx}");
    write_fixture("ctx_logged_out.json", &ctx)?;

    // Installed addons: no network, follows the profile.
    load(
        "installed_addons",
        "InstalledAddonsWithFilters",
        serde_json::json!({ "request": { "type": null } }),
    )?;
    let installed = state("installed_addons");
    assert_eq!(
        installed["selected"]["request"]["type"],
        serde_json::Value::Null
    );
    assert_eq!(
        installed["catalog"].as_array().expect("catalog").len(),
        addon_count,
        "{installed}"
    );
    assert_eq!(installed["catalog"][0]["transportUrl"], CINEMETA);
    assert_eq!(installed["catalog"][0]["flags"]["protected"], true);
    assert_eq!(
        installed["selectable"]["types"][0]["type"],
        serde_json::Value::Null
    );
    assert_eq!(installed["selectable"]["types"][0]["selected"], true);
    write_fixture("installed_addons_default.json", &installed)?;

    // Addon details for an installed addon: local copy + fetched manifest.
    load(
        "addon_details",
        "AddonDetails",
        serde_json::json!({ "transportUrl": CINEMETA }),
    )?;
    let details = wait_for("addon_details", Duration::from_secs(30), |details| {
        matches!(
            details["remoteAddon"]["content"]["type"].as_str(),
            Some("Ready" | "Err")
        )
    });
    assert_eq!(details["selected"]["transportUrl"], CINEMETA);
    assert_eq!(details["localAddon"]["transportUrl"], CINEMETA);
    assert_eq!(
        details["remoteAddon"]["transport_url"], CINEMETA,
        "DescriptorLoadable has no rename_all: {details}"
    );
    assert_eq!(
        details["remoteAddon"]["content"]["type"], "Ready",
        "{details}"
    );
    let remote = &details["remoteAddon"]["content"]["content"];
    assert_eq!(remote["manifest"]["id"], "com.linvo.cinemeta");
    assert_eq!(
        remote["flags"]["protected"], true,
        "flags come from OFFICIAL_ADDONS when the URL matches"
    );
    write_fixture("addon_details_cinemeta.json", &details)?;

    // The community catalog (Cinemeta's `addon_catalog` resource), trimmed.
    load(
        "remote_addons",
        "CatalogWithFilters",
        serde_json::json!({ "request": {
            "base": CINEMETA,
            "path": { "resource": "addon_catalog", "type": "all", "id": "community", "extra": [] }
        } }),
    )?;
    let mut remote_addons = wait_for("remote_addons", Duration::from_secs(30), |remote| {
        matches!(
            remote["catalog"][0]["content"]["type"].as_str(),
            Some("Ready" | "Err")
        )
    });
    assert_eq!(
        remote_addons["selected"]["request"]["path"]["id"],
        "community"
    );
    assert_eq!(
        remote_addons["catalog"][0]["content"]["type"], "Ready",
        "{remote_addons}"
    );
    let items = remote_addons["catalog"][0]["content"]["content"]
        .as_array_mut()
        .expect("descriptors");
    assert!(items.len() > COMMUNITY_ITEMS, "{}", items.len());
    items.truncate(COMMUNITY_ITEMS);
    for item in items.iter() {
        assert!(item["manifest"]["id"].is_string(), "{item}");
        assert!(item["transportUrl"].is_string(), "{item}");
    }
    assert!(
        remote_addons["selectable"]["catalogs"]
            .as_array()
            .is_some_and(|c| c.iter().any(|c| c["catalog"] == "Community")),
        "{remote_addons}"
    );
    write_fixture("remote_addons_community.json", &remote_addons)?;

    // The library with a movie and a series just added.
    let (movie_id, _, library) = add_fixture_titles()?;
    write_fixture("library_default.json", &library)?;
    dispatch(ctx_action(
        serde_json::json!({ "action": "RemoveFromLibrary", "args": movie_id }),
    ))?;
    wait_for("library", Duration::from_secs(10), |library| {
        library["catalog"].as_array().is_some_and(|c| c.len() == 1)
    });

    core_shutdown()?;
    Ok(())
}
