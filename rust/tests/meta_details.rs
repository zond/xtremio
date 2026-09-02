//! Network test: loads `MetaDetails` for a public-domain movie, then the
//! `Player` for one of its torrent streams, then reports progress so the item
//! enters `continue_watching_preview`, recording all three states as fixtures
//! for the Dart tests. Ignored by default (needs internet); run with
//! `cargo test --test meta_details -- --ignored --nocapture`.
//!
//! Night of the Living Dead (tt0063350) is public domain and the *default*
//! `org.stremio.pubdomainmovies` addon serves a torrent for it, so this needs
//! no third-party addon. Streams from the other default stream addons
//! (WatchHub externals, the embedded server's local addon) are recorded too.

use std::time::{Duration, Instant};

use xtremio_core::api::core::{
    core_dispatch, core_get_state, core_init, core_shutdown, CoreConfig,
};
use xtremio_core::api::server::ServerConfig;

const META_ID: &str = "tt0063350";

fn state(field: &str) -> serde_json::Value {
    serde_json::from_str(&core_get_state(field.to_owned()).expect(field)).expect("valid JSON")
}

fn write_fixture(name: &str, value: &serde_json::Value) -> anyhow::Result<()> {
    let fixtures = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    std::fs::create_dir_all(&fixtures)?;
    std::fs::write(fixtures.join(name), serde_json::to_vec_pretty(value)?)?;
    Ok(())
}

fn is_settled(loadable: &serde_json::Value) -> bool {
    matches!(loadable["content"]["type"].as_str(), Some("Ready" | "Err"))
}

#[test]
#[ignore = "needs internet access to the default Stremio addons"]
fn meta_details_and_player_for_a_public_domain_torrent() -> anyhow::Result<()> {
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

    // Same shape as `CoreActions.loadMetaDetails` on the Dart side.
    core_dispatch(
        serde_json::json!({
            "field": "meta_details",
            "action": {
                "action": "Load",
                "args": {
                    "model": "MetaDetails",
                    "args": {
                        "metaPath": { "resource": "meta", "type": "movie", "id": META_ID, "extra": [] },
                        "streamPath": null,
                        "guessStream": true
                    }
                }
            }
        })
        .to_string(),
    )?;

    // Wait for the meta item and for every stream addon to answer (or fail);
    // slow addons are given up on after the deadline as long as the torrent
    // stream we need is there.
    let deadline = Instant::now() + Duration::from_secs(45);
    let meta_details = loop {
        let meta_details = state("meta_details");
        let meta = &meta_details["metaItems"][0]["content"];
        assert_ne!(meta["type"], "Err", "meta errored: {meta}");
        let streams = meta_details["streams"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let meta_ready = meta["type"] == "Ready";
        let all_settled = !streams.is_empty() && streams.iter().all(is_settled);
        let torrent_ready = streams.iter().any(|loadable| {
            loadable["content"]["type"] == "Ready"
                && loadable["content"]["content"]
                    .as_array()
                    .is_some_and(|streams| streams.iter().any(|s| s["infoHash"].is_string()))
        });
        if meta_ready && (all_settled || (torrent_ready && Instant::now() >= deadline)) {
            break meta_details;
        }
        assert!(Instant::now() < deadline, "timed out: {meta_details}");
        std::thread::sleep(Duration::from_millis(100));
    };
    assert_eq!(
        meta_details["metaItems"][0]["content"]["content"]["id"],
        META_ID
    );
    assert_eq!(
        meta_details["selected"]["streamPath"]["id"], META_ID,
        "guessStream picked the movie"
    );
    write_fixture("meta_details_public_domain.json", &meta_details)?;

    // Pick the torrent stream and the addon request it came from.
    let (stream, stream_request) = meta_details["streams"]
        .as_array()
        .unwrap()
        .iter()
        .find_map(|loadable| {
            loadable["content"]["content"]
                .as_array()?
                .iter()
                .find(|s| s["infoHash"].is_string())
                .map(|s| (s.clone(), loadable["request"].clone()))
        })
        .expect("a torrent stream from the default addons");
    let meta_request = meta_details["metaItems"][0]["request"].clone();

    // Same shape as `CoreActions.loadPlayer`.
    core_dispatch(
        serde_json::json!({
            "field": "player",
            "action": {
                "action": "Load",
                "args": {
                    "model": "Player",
                    "args": {
                        "stream": stream,
                        "streamRequest": stream_request,
                        "metaRequest": meta_request,
                        "subtitlesPath": null
                    }
                }
            }
        })
        .to_string(),
    )?;

    let deadline = Instant::now() + Duration::from_secs(30);
    let player = loop {
        let player = state("player");
        match player["stream"]["type"].as_str() {
            Some("Ready") if player["metaItem"]["content"]["type"] == "Ready" => break player,
            Some("Err") => panic!("stream conversion errored: {}", player["stream"]),
            _ => {}
        }
        assert!(Instant::now() < deadline, "timed out: {player}");
        std::thread::sleep(Duration::from_millis(100));
    };
    // `Loadable<(StreamUrls, Stream<ConvertedStreamSource>)>`: a two-element
    // array. Note `StreamUrls` is snake_case (no `rename_all`), unlike the
    // rest of the model.
    let stream_urls = &player["stream"]["content"][0];
    let streaming_url = stream_urls["streaming_url"]
        .as_str()
        .unwrap_or_else(|| panic!("torrent streams resolve to a streaming server URL: {player}"));
    let server_url = state("ctx")["profile"]["settings"]["streamingServerUrl"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(
        streaming_url.starts_with(&server_url),
        "{streaming_url} is not under the embedded server {server_url}"
    );
    assert!(
        streaming_url.contains(stream["infoHash"].as_str().unwrap()),
        "{streaming_url}"
    );
    write_fixture("player_public_domain_torrent.json", &player)?;

    // Report a minute of playback and a pause: `PausedChanged` flushes the
    // library item (`Internal::UpdateLibraryItem` -> `LibraryChanged(true)`)
    // and the temp item, now with `timeOffset > 0`, enters continue watching.
    for action in [
        serde_json::json!({
            "action": "TimeChanged",
            "args": { "time": 60_000, "duration": 5_760_000, "device": "test" }
        }),
        serde_json::json!({ "action": "PausedChanged", "args": { "paused": true } }),
    ] {
        core_dispatch(
            serde_json::json!({
                "field": "player",
                "action": { "action": "Player", "args": action }
            })
            .to_string(),
        )?;
    }
    let deadline = Instant::now() + Duration::from_secs(10);
    let continue_watching = loop {
        let continue_watching = state("continue_watching_preview");
        if continue_watching["items"][0]["_id"] == META_ID {
            break continue_watching;
        }
        assert!(Instant::now() < deadline, "timed out: {continue_watching}");
        std::thread::sleep(Duration::from_millis(100));
    };
    let item = &continue_watching["items"][0];
    assert_eq!(item["state"]["timeOffset"], 60_000, "{item}");
    assert_eq!(item["state"]["duration"], 5_760_000, "{item}");
    assert_eq!(item["state"]["video_id"], META_ID, "{item}");
    assert_eq!(item["notifications"], 0, "{item}");
    write_fixture("continue_watching_preview.json", &continue_watching)?;

    core_shutdown()?;
    Ok(())
}
