//! Network test: loads Cinemeta's `movie/top` catalog into `discover`.
//! Ignored by default (needs internet); run with
//! `cargo test --test cinemeta -- --ignored --nocapture`.
//! Writes the resulting state to `tests/fixtures/discover_cinemeta_top.json`
//! for Dart fixture-driven tests.

use std::time::{Duration, Instant};

use xtremio_core::api::core::{
    core_dispatch, core_get_state, core_init, core_shutdown, CoreConfig,
};
use xtremio_core::api::server::ServerConfig;

#[test]
#[ignore = "needs internet access to v3-cinemeta.strem.io"]
fn discover_loads_cinemeta_top_movies() -> anyhow::Result<()> {
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

    core_dispatch(
        serde_json::json!({
            "field": "discover",
            "action": {
                "action": "Load",
                "args": {
                    "model": "CatalogWithFilters",
                    "args": {
                        "request": {
                            "base": "https://v3-cinemeta.strem.io/manifest.json",
                            "path": { "resource": "catalog", "type": "movie", "id": "top", "extra": [] }
                        }
                    }
                }
            }
        })
        .to_string(),
    )?;

    let deadline = Instant::now() + Duration::from_secs(30);
    let discover = loop {
        let discover: serde_json::Value =
            serde_json::from_str(&core_get_state("discover".into())?)?;
        // `catalog` is a Vec of pages; the first page is the one we loaded.
        let content = &discover["catalog"][0]["content"];
        match content["type"].as_str() {
            Some("Ready") => break discover,
            Some("Err") => panic!("catalog errored: {content}"),
            _ => {}
        }
        assert!(Instant::now() < deadline, "timed out: {discover}");
        std::thread::sleep(Duration::from_millis(100));
    };
    let items = discover["catalog"][0]["content"]["content"]
        .as_array()
        .expect("items array");
    assert!(!items.is_empty(), "no items: {discover}");
    assert!(items[0]["name"].is_string(), "{}", items[0]);

    let fixtures = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    std::fs::create_dir_all(&fixtures)?;
    std::fs::write(
        fixtures.join("discover_cinemeta_top.json"),
        serde_json::to_vec_pretty(&discover)?,
    )?;
    core_shutdown()?;
    Ok(())
}
