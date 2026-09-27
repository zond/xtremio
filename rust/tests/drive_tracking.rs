//! A Google Drive play records progress: loaded with the stream request
//! `driveStreamRequest` builds (`lib/core/drive_playback.dart`), the core's
//! player keeps a time offset on the library item and names the episode as
//! the video being watched -- which is what the resume position, the
//! watched mark, Continue Watching and the up-next all read.
//!
//! Without a stream request the player's `TimeChanged` does nothing at all,
//! whatever the meta says, so this is the test that fails if a Drive play
//! is loaded without one.
//!
//! Its own file because it boots the process's core, and the storage
//! directory and the running state are process-wide. It needs no network:
//! the meta addon is dead and the meta is answered from a hand-written
//! downloads registry (`downloads::kept_meta`), as `offline_meta.rs` does.

use std::time::{Duration, Instant};

use xtremio_core::api::core::{
    core_dispatch, core_get_state, core_init, core_shutdown, CoreConfig,
};

/// Nothing listens here (see `offline_meta.rs`): the meta fetch fails at
/// once and the registry answers it.
const DEAD_ADDON: &str = "http://127.0.0.1:9/manifest.json";

/// `driveTrackingManifestUrl` in `lib/core/drive_playback.dart`.
const DRIVE_TRACKING_MANIFEST: &str = "https://xtremio-xervice.web.app/manifest.json";

const SERIES_ID: &str = "tt0903747";
const EPISODE_ID: &str = "tt0903747:1:1";

fn state(field: &str) -> serde_json::Value {
    serde_json::from_str(&core_get_state(field.to_owned()).expect(field)).expect("valid JSON")
}

fn player_action(action: serde_json::Value) -> anyhow::Result<()> {
    core_dispatch(
        serde_json::json!({
            "field": "player",
            "action": { "action": "Player", "args": action }
        })
        .to_string(),
    )?;
    Ok(())
}

#[test]
fn a_drive_play_keeps_its_place() -> anyhow::Result<()> {
    let tmp = tempfile::tempdir()?;
    let storage = tmp.path().join("storage");
    std::fs::create_dir_all(&storage)?;

    // The recorded registry, with its episode's meta addon swapped for one
    // that answers nothing.
    let mut registry: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/downloads_registry.json"
        ))?)?;
    let episode = &mut registry["items"][format!("{SERIES_ID}:{EPISODE_ID}")];
    episode["metaRequest"]["base"] = DEAD_ADDON.into();
    std::fs::write(storage.join("downloads.json"), registry.to_string())?;

    core_init(CoreConfig {
        storage_dir: storage.display().to_string(),
        server: None,
    })?;

    // Same shape as `CoreActions.loadPlayer` from Details' `_playDrive`:
    // the Drive file as a URL stream, the title's meta, and our request.
    core_dispatch(
        serde_json::json!({
            "field": "player",
            "action": {
                "action": "Load",
                "args": {
                    "model": "Player",
                    "args": {
                        "stream": { "url": "xtremio-drive:abc", "name": "S01E01.mkv" },
                        "streamRequest": {
                            "base": DRIVE_TRACKING_MANIFEST,
                            "path": {
                                "resource": "stream",
                                "type": "series",
                                "id": EPISODE_ID,
                                "extra": []
                            }
                        },
                        "metaRequest": {
                            "base": DEAD_ADDON,
                            "path": {
                                "resource": "meta",
                                "type": "series",
                                "id": SERIES_ID,
                                "extra": []
                            }
                        },
                        "subtitlesPath": null
                    }
                }
            }
        })
        .to_string(),
    )?;

    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let player = state("player");
        if player["metaItem"]["content"]["type"] == "Ready" {
            break;
        }
        assert!(Instant::now() < deadline, "the meta never loaded: {player}");
        std::thread::sleep(Duration::from_millis(50));
    }

    for time in [10_000, 20_000, 30_000] {
        player_action(serde_json::json!({
            "action": "TimeChanged",
            "args": { "time": time, "duration": 2_700_000, "device": "test" }
        }))?;
    }

    let player = state("player");
    let item = &player["libraryItem"];
    assert_eq!(item["_id"], SERIES_ID, "{player}");
    assert_eq!(item["state"]["timeOffset"], 30_000, "{item}");
    assert_eq!(item["state"]["duration"], 2_700_000, "{item}");
    assert_eq!(item["state"]["video_id"], EPISODE_ID, "{item}");

    core_shutdown()?;
    Ok(())
}
