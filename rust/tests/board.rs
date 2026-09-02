//! Network test: loads the Board (`CatalogsWithExtra` over the default
//! addons) and then a Search on the same model type, recording both states
//! as fixtures for the Dart tests. Ignored by default (needs internet); run
//! with `cargo test --test board -- --ignored --nocapture`.
//!
//! Both phases share one test function because the runtime is a process
//! singleton; each field is written to its own fixture file.

use std::time::{Duration, Instant};

use xtremio_core::api::core::{
    core_dispatch, core_get_state, core_init, core_shutdown, CoreConfig,
};
use xtremio_core::api::server::ServerConfig;

/// Catalogs 0..=2 of the default board (LoadRange's end is inclusive).
const BOARD_RANGE_END: usize = 2;
const SEARCH_QUERY: &str = "night of the living dead";
const SEARCH_HIT: &str = "tt0063350";

fn state(field: &str) -> serde_json::Value {
    serde_json::from_str(&core_get_state(field.to_owned()).expect(field)).expect("valid JSON")
}

fn write_fixture(name: &str, value: &serde_json::Value) -> anyhow::Result<()> {
    let fixtures = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    std::fs::create_dir_all(&fixtures)?;
    std::fs::write(fixtures.join(name), serde_json::to_vec_pretty(value)?)?;
    Ok(())
}

/// Every page that has been requested (`content != null`) is Ready or Err.
fn requested_pages_settled(model: &serde_json::Value) -> bool {
    model["catalogs"].as_array().is_some_and(|catalogs| {
        catalogs
            .iter()
            .flat_map(|pages| pages.as_array())
            .all(|pages| {
                pages.iter().all(|page| {
                    page["content"].is_null()
                        || matches!(page["content"]["type"].as_str(), Some("Ready" | "Err"))
                })
            })
    })
}

fn load_catalogs_with_extra(field: &str, extra: serde_json::Value) -> anyhow::Result<()> {
    // Same shape as `CoreActions.loadBoard` / `CoreActions.loadSearch`.
    core_dispatch(
        serde_json::json!({
            "field": field,
            "action": {
                "action": "Load",
                "args": {
                    "model": "CatalogsWithExtra",
                    "args": { "type": null, "extra": extra }
                }
            }
        })
        .to_string(),
    )
}

fn load_range(field: &str, start: usize, end: usize) -> anyhow::Result<()> {
    // Same shape as `CoreActions.loadBoardRange` / `loadSearchRange`.
    core_dispatch(
        serde_json::json!({
            "field": field,
            "action": {
                "action": "CatalogsWithExtra",
                "args": { "action": "LoadRange", "args": { "start": start, "end": end } }
            }
        })
        .to_string(),
    )
}

fn wait_until_settled(field: &str, deadline: Duration) -> serde_json::Value {
    let deadline = Instant::now() + deadline;
    loop {
        let model = state(field);
        if !model["catalogs"].as_array().is_some_and(Vec::is_empty)
            && requested_pages_settled(&model)
        {
            return model;
        }
        assert!(Instant::now() < deadline, "timed out: {model}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[test]
#[ignore = "needs internet access to the default Stremio addons"]
fn board_and_search_over_the_default_addons() -> anyhow::Result<()> {
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

    // Board: plan every catalog, then fetch only the first rows.
    load_catalogs_with_extra("board", serde_json::json!([]))?;
    let planned = state("board");
    let catalog_count = planned["catalogs"].as_array().expect("catalogs").len();
    assert!(catalog_count > BOARD_RANGE_END, "{planned}");
    assert!(
        planned["catalogs"]
            .as_array()
            .unwrap()
            .iter()
            .all(|pages| pages[0]["content"].is_null()),
        "nothing is fetched before LoadRange: {planned}"
    );
    load_range("board", 0, BOARD_RANGE_END)?;
    let board = wait_until_settled("board", Duration::from_secs(45));
    let labels = board["catalogLabels"].as_array().expect("catalogLabels");
    assert_eq!(labels.len(), catalog_count, "{board}");
    assert_eq!(labels[0]["name"], "Popular", "{}", labels[0]);
    assert_eq!(labels[0]["addonName"], "Cinemeta", "{}", labels[0]);
    for (index, pages) in board["catalogs"].as_array().unwrap().iter().enumerate() {
        let requested = !pages[0]["content"].is_null();
        assert_eq!(
            requested,
            index <= BOARD_RANGE_END,
            "catalog {index}: {pages}"
        );
    }
    assert!(
        board["catalogs"][0][0]["content"]["type"] == "Ready",
        "{}",
        board["catalogs"][0][0]
    );
    write_fixture("board_default_addons.json", &board)?;

    // Search: the same model type on its own field, all rows at once.
    core_dispatch(r#"{"field":"board","action":{"action":"Unload"}}"#.into())?;
    assert!(state("board")["selected"].is_null());
    load_catalogs_with_extra("search", serde_json::json!([["search", SEARCH_QUERY]]))?;
    let planned = state("search");
    let catalog_count = planned["catalogs"].as_array().expect("catalogs").len();
    assert!(catalog_count > 0, "{planned}");
    load_range("search", 0, catalog_count - 1)?;
    let search = wait_until_settled("search", Duration::from_secs(45));
    assert_eq!(
        search["selected"]["extra"],
        serde_json::json!([["search", SEARCH_QUERY]])
    );
    let found = search["catalogs"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|pages| pages[0]["content"]["content"].as_array())
        .flatten()
        .any(|item| item["id"] == SEARCH_HIT);
    assert!(found, "{SEARCH_HIT} not in any Ready page: {search}");
    write_fixture("search_default_addons.json", &search)?;

    core_shutdown()?;
    Ok(())
}
