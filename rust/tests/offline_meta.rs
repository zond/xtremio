//! A meta request the addon cannot answer is answered from the download
//! that kept the title's meta (`downloads::kept_meta`), which is what lets
//! the player build a library item -- and so record progress -- for a title
//! that was downloaded and is played with no network, without the title
//! ever being put into the library.
//!
//! Its own file because it boots the process's core, and the storage
//! directory and the running state are process-wide.

use http::Request;
use stremio_core::runtime::Env;
use stremio_core::types::addon::ResourceResponse;
use xtremio_core::api::core::{core_init, core_shutdown, CoreConfig};
use xtremio_core::env::XtremioEnv;

/// Nothing listens here: port 9 on loopback is the discard service, which no
/// test machine runs, so the fetch fails at once the way an offline one does.
const DEAD_ADDON: &str = "http://127.0.0.1:9/manifest.json";

#[test]
fn a_failed_meta_fetch_is_answered_from_the_download() -> anyhow::Result<()> {
    let tmp = tempfile::tempdir()?;
    let storage = tmp.path().join("storage");
    std::fs::create_dir_all(&storage)?;

    // The recorded registry, its film's meta taken from an addon that is
    // not there any more.
    let mut registry: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/downloads_registry.json"
        ))?)?;
    let film = &mut registry["items"]["tt0063350:tt0063350"];
    film["metaRequest"]["base"] = DEAD_ADDON.into();
    let kept_name = film["meta"]["name"].clone();
    std::fs::write(storage.join("downloads.json"), registry.to_string())?;

    core_init(CoreConfig {
        storage_dir: storage.display().to_string(),
        cache_dir: tmp.path().join("core-cache").display().to_string(),
        server: None,
    })?;

    let runtime = tokio::runtime::Runtime::new()?;
    let fetch = |url: &str| {
        let request = Request::get(url).body(()).expect("request");
        runtime.block_on(XtremioEnv::fetch::<(), ResourceResponse>(request))
    };

    // The film's own request: answered, in the addon's own shape.
    let answered = fetch("http://127.0.0.1:9/meta/movie/tt0063350.json");
    match answered {
        Ok(ResourceResponse::Meta { meta }) => {
            assert_eq!(meta.preview.id, "tt0063350");
            assert_eq!(serde_json::json!(meta.preview.name), kept_name);
        }
        other => panic!("expected the kept meta, got {other:?}"),
    }

    // A title nothing downloaded is still the failure it was.
    assert!(fetch("http://127.0.0.1:9/meta/movie/tt0000001.json").is_err());
    // And so is anything that is not a meta request.
    assert!(fetch("http://127.0.0.1:9/stream/movie/tt0063350.json").is_err());

    core_shutdown()?;
    Ok(())
}
