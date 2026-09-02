//! Boots the real stremio-core Runtime against the embedded server (ephemeral
//! port, temp dirs) through the FRB surface. The core is a process singleton,
//! so all phases share one test function; the Cinemeta network test lives in
//! its own binary (tests/cinemeta.rs).

use std::sync::mpsc;
use std::time::{Duration, Instant};

use stremio_core::types::profile::Profile;
use xtremio_core::api::core::{
    core_dispatch, core_get_state, core_init, core_is_initialized, core_shutdown, CoreConfig,
};
use xtremio_core::api::server::{server_base_url, ServerConfig};

fn config(root: &std::path::Path) -> CoreConfig {
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

fn state(field: &str) -> serde_json::Value {
    serde_json::from_str(&core_get_state(field.to_owned()).expect(field)).expect("valid JSON")
}

fn wait_for_ready_settings() -> serde_json::Value {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let server = state("streaming_server");
        match server["settings"]["type"].as_str() {
            Some("Ready") => return server,
            Some("Err") => panic!("settings errored: {}", server["settings"]),
            _ => {}
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for streaming server settings: {server}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn core_lifecycle() -> anyhow::Result<()> {
    let tmp = tempfile::tempdir()?;

    // Before init: no runtime, nothing running.
    assert!(!core_is_initialized()?);
    assert!(core_dispatch(r#"{"action":{"action":"Unload"}}"#.into()).is_err());
    assert!(core_get_state("ctx".into()).is_err());

    // Subscribe first (as Dart does), then boot.
    let (tx, rx) = mpsc::channel();
    xtremio_core::core::set_event_sink(Box::new(move |event| tx.send(event).is_ok()));

    let result = core_init(config(tmp.path()))?;
    assert!(core_is_initialized()?);
    assert_eq!(
        result.schema_version,
        stremio_core::constants::SCHEMA_VERSION
    );
    let url = result.server_base_url.clone().expect("embedded server URL");
    assert_eq!(server_base_url()?.as_deref(), Some(url.as_str()));
    assert!(
        tmp.path().join("core/schema_version.json").is_file(),
        "migrations ran"
    );

    // The engine fetched /settings from the embedded server through our Env.
    let server = wait_for_ready_settings();
    assert_eq!(server["baseUrl"], url, "{server}");
    assert!(server["settings"]["content"].is_object(), "{server}");

    // The default (loopback) profile URL was retargeted at the embedded server.
    let ctx = state("ctx");
    assert_eq!(ctx["profile"]["settings"]["streamingServerUrl"], url);

    // Events: a NewState naming streaming_server arrived.
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut saw_streaming_server = false;
    while !saw_streaming_server && Instant::now() < deadline {
        if let Ok(event) = rx.recv_timeout(Duration::from_millis(200)) {
            let event: serde_json::Value = serde_json::from_str(&event)?;
            assert!(
                matches!(event["name"].as_str(), Some("NewState" | "CoreEvent")),
                "{event}"
            );
            if event["name"] == "NewState"
                && event["args"]
                    .as_array()
                    .is_some_and(|fields| fields.iter().any(|f| f == "streaming_server"))
            {
                saw_streaming_server = true;
            }
        }
    }
    assert!(saw_streaming_server, "no NewState for streaming_server");

    // Dispatch: malformed -> error naming the path; well-formed -> Ok + event.
    let error =
        core_dispatch(r#"{"field":"board","action":{"action":"Nope"}}"#.into()).unwrap_err();
    assert!(error.to_string().contains("invalid action JSON"), "{error}");
    let error =
        core_dispatch(r#"{"field":"nope","action":{"action":"Unload"}}"#.into()).unwrap_err();
    assert!(error.to_string().contains("field"), "{error}");
    assert!(core_get_state("nope".into()).is_err());
    core_dispatch(r#"{"field":"discover","action":{"action":"Unload"}}"#.into())?;
    let discover = state("discover");
    assert!(discover["selected"].is_null(), "{discover}");

    // Every field serializes.
    for field in [
        "ctx",
        "continue_watching_preview",
        "board",
        "search",
        "discover",
        "meta_details",
        "streaming_server",
        "player",
        "library",
        "installed_addons",
        "remote_addons",
        "addon_details",
    ] {
        assert!(state(field).is_object(), "{field}");
    }

    // Login and logout reset the settings to stremio-core's defaults, whose
    // server URL is loopback:11470; the pump must retarget them at the
    // embedded (here: ephemeral-port) server again. Offline stand-in for the
    // reset: UpdateSettings with the default URL, then a Logout while logged
    // out, which still emits UserLoggedOut.
    let mut settings = state("ctx")["profile"]["settings"].clone();
    settings["streamingServerUrl"] = serde_json::json!("http://127.0.0.1:11470/");
    core_dispatch(
        serde_json::json!({
            "field": "ctx",
            "action": {
                "action": "Ctx",
                "args": { "action": "UpdateSettings", "args": settings },
            },
        })
        .to_string(),
    )?;
    assert_eq!(
        state("ctx")["profile"]["settings"]["streamingServerUrl"],
        "http://127.0.0.1:11470/"
    );
    core_dispatch(
        r#"{"field":"ctx","action":{"action":"Ctx","args":{"action":"Logout"}}}"#.into(),
    )?;
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let ctx = state("ctx");
        if ctx["profile"]["settings"]["streamingServerUrl"] == url {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "settings were not retargeted after UserLoggedOut: {}",
            ctx["profile"]["settings"]
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    // The streaming_server model follows the profile back to the embedded
    // server (its detour to 11470 may have left an Err in between).
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let server = state("streaming_server");
        if server["baseUrl"] == url && server["settings"]["type"] == "Ready" {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "streaming_server did not follow the retarget: {server}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    // The real thing: Logout from a non-default profile replaces the settings
    // with stremio-core's defaults (a remote URL does not survive a logout),
    // and the pump then retargets the default loopback URL at the embedded
    // server.
    let mut settings = state("ctx")["profile"]["settings"].clone();
    settings["streamingServerUrl"] = serde_json::json!("http://192.168.1.20:11470/");
    core_dispatch(
        serde_json::json!({
            "field": "ctx",
            "action": {
                "action": "Ctx",
                "args": { "action": "UpdateSettings", "args": settings },
            },
        })
        .to_string(),
    )?;
    assert_eq!(
        state("ctx")["profile"]["settings"]["streamingServerUrl"],
        "http://192.168.1.20:11470/"
    );
    core_dispatch(
        r#"{"field":"ctx","action":{"action":"Ctx","args":{"action":"Logout"}}}"#.into(),
    )?;
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let ctx = state("ctx");
        if ctx["profile"]["settings"]["streamingServerUrl"] == url {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "settings were not retargeted after a real logout reset: {}",
            ctx["profile"]["settings"]
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    // Idempotent init keeps the same server.
    let again = core_init(config(tmp.path()))?;
    assert_eq!(again.server_base_url.as_deref(), Some(url.as_str()));

    // Shutdown tears down runtime and server.
    core_shutdown()?;
    assert!(!core_is_initialized()?);
    assert!(core_get_state("ctx".into()).is_err());
    assert_eq!(server_base_url()?, None);
    core_shutdown()?; // no-op

    // A persisted remote server URL must survive init untouched.
    let tmp2 = tempfile::tempdir()?;
    let mut profile = Profile::default();
    profile.settings.streaming_server_url = url::Url::parse("http://192.168.1.20:11470/")?;
    std::fs::create_dir_all(tmp2.path().join("core"))?;
    std::fs::write(
        tmp2.path().join("core/profile.json"),
        serde_json::to_vec(&profile)?,
    )?;
    std::fs::write(
        tmp2.path().join("core/schema_version.json"),
        stremio_core::constants::SCHEMA_VERSION.to_string(),
    )?;
    let result = core_init(config(tmp2.path()))?;
    assert!(result.server_base_url.is_some());
    let ctx = state("ctx");
    assert_eq!(
        ctx["profile"]["settings"]["streamingServerUrl"],
        "http://192.168.1.20:11470/"
    );
    core_shutdown()?;
    Ok(())
}
