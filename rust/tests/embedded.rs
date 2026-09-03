//! Embeds stream-server in-process through the FRB surface and drives it
//! over real HTTP on an ephemeral loopback port.
//!
//! The server is a process-wide singleton, so every scenario lives in one
//! test function to keep them from interfering.

use reqwest::StatusCode;
use xtremio_core::api::server::{
    server_base_url, server_cache_usage, server_clean_cache_now, server_settings, server_start,
    server_stop, server_storage_report, server_torrent_stats, server_update_settings, ServerConfig,
};

/// A well-known public-domain torrent (Night of the Living Dead), never
/// downloaded here: the stats calls only create its engine.
const INFO_HASH: &str = "11ea02584fa6351956f35671962ab46354d99060";

fn json(text: &str) -> serde_json::Value {
    serde_json::from_str(text).expect("valid JSON")
}

fn config(root: &std::path::Path) -> ServerConfig {
    ServerConfig {
        config_dir: root.join("server").display().to_string(),
        cache_dir: root.join("cache").join("server").display().to_string(),
        port: 0,
        fallback_to_ephemeral: true,
    }
}

/// `GET /heartbeat` without credentials: the status the server answers with.
/// The control API requires the per-launch bearer token, so a plain request
/// is refused (401); the media routes players fetch stay open.
async fn heartbeat_status(base_url: &str) -> anyhow::Result<StatusCode> {
    let client = reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(5))
        .build()?;
    Ok(client
        .get(format!("{base_url}heartbeat"))
        .send()
        .await?
        .status())
}

#[tokio::test]
async fn embedded_server_lifecycle() -> anyhow::Result<()> {
    let tmp = tempfile::tempdir()?;
    assert_eq!(server_base_url()?, None, "nothing running before start");

    // Start on an ephemeral port: URL is well-formed and the server answers.
    let url = tokio::task::spawn_blocking({
        let cfg = config(tmp.path());
        move || server_start(cfg)
    })
    .await??;
    let parsed = url::Url::parse(&url)?;
    assert_eq!(parsed.scheme(), "http");
    assert_eq!(parsed.host_str(), Some("127.0.0.1"));
    assert!(parsed.port().is_some_and(|port| port != 0));
    assert_eq!(server_base_url()?.as_deref(), Some(url.as_str()));
    assert!(tmp.path().join("server").is_dir(), "config dir created");
    assert!(
        tmp.path().join("cache/server").is_dir(),
        "cache dir created"
    );

    // Answering, and refusing a control request that carries no token.
    assert_eq!(heartbeat_status(&url).await?, StatusCode::UNAUTHORIZED);

    // The app's control plane is the library API, no token needed: settings
    // read and patched (the patch is validated and merged like POST
    // /settings), and a torrent's stats, whose first call creates the
    // engine and answers `resolvingMetadata` at once -- for the per-file
    // route too, so the caller needs no torrent-level fallback.
    let settings = json(&tokio::task::spawn_blocking(server_settings).await??);
    assert!(settings["btMaxConnections"].is_u64(), "{settings}");
    assert!(settings.get("cacheSize").is_some(), "{settings}");
    let patched = json(
        &tokio::task::spawn_blocking(|| {
            server_update_settings(r#"{"btMaxConnections": 77}"#.to_owned())
        })
        .await??,
    );
    assert_eq!(patched["btMaxConnections"], 77, "{patched}");
    assert_eq!(
        json(&tokio::task::spawn_blocking(server_settings).await??)["btMaxConnections"],
        77
    );
    let error = tokio::task::spawn_blocking(|| server_update_settings("nope".to_owned()))
        .await?
        .unwrap_err();
    assert!(error.to_string().contains("settings patch"), "{error}");

    let trackers = vec!["udp://tracker.opentrackr.org:1337/announce".to_owned()];
    let stats = json(
        &tokio::task::spawn_blocking({
            let trackers = trackers.clone();
            move || server_torrent_stats(INFO_HASH.to_owned(), None, trackers)
        })
        .await??,
    );
    assert_eq!(stats["infoHash"], INFO_HASH, "{stats}");
    assert_eq!(stats["phase"], "resolvingMetadata", "{stats}");
    assert!(stats.get("error").is_none(), "{stats}");
    let per_file = json(
        &tokio::task::spawn_blocking(move || {
            server_torrent_stats(INFO_HASH.to_owned(), Some(0), trackers)
        })
        .await??,
    );
    assert_eq!(per_file["phase"], "resolvingMetadata", "{per_file}");
    let error = tokio::task::spawn_blocking(|| {
        server_torrent_stats(INFO_HASH.to_owned(), Some(-1), vec![])
    })
    .await?
    .unwrap_err();
    assert!(error.to_string().contains("file index"), "{error}");

    // What the storage costs: the cache root the server was given, the
    // bytes under it (a fresh server has written a little), the limit from
    // its own `cacheSize`, and the volume it is on.
    let report = json(&tokio::task::spawn_blocking(server_storage_report).await??);
    assert_eq!(
        report["cacheDir"],
        tmp.path().join("cache/server").display().to_string(),
        "{report}"
    );
    assert!(report["cacheUsedBytes"].is_u64(), "{report}");
    assert_eq!(report["cacheComplete"], true, "{report}");
    assert!(
        report["cacheVolume"]["totalBytes"].as_u64().unwrap_or(0) > 0,
        "{report}"
    );
    // No downloadsDir is set here, so there is no second volume to name.
    assert!(report["downloadsVolume"].is_null(), "{report}");

    // What the cache occupies against its limit, read without evicting
    // anything: a fresh server has written a little and nothing is
    // protected (no live engine has any pinned file).
    let usage = json(&tokio::task::spawn_blocking(server_cache_usage).await??);
    assert!(usage["totalBytes"].is_u64(), "{usage}");
    assert_eq!(usage["protectedBytes"], 0, "{usage}");
    assert_eq!(usage["protectedFiles"], 0, "{usage}");

    // Cleaning now runs the eviction pass in place -- no restart, so the
    // server answers throughout and at the same URL afterwards.
    let cleaned = json(&tokio::task::spawn_blocking(server_clean_cache_now).await??);
    assert!(cleaned["total"].is_u64(), "{cleaned}");
    assert!(cleaned["freed"].is_u64(), "{cleaned}");
    assert!(cleaned["deleted"].is_u64(), "{cleaned}");
    assert_eq!(server_base_url()?.as_deref(), Some(url.as_str()));
    assert_eq!(heartbeat_status(&url).await?, StatusCode::UNAUTHORIZED);
    // Nothing about the running server changed: the settings patched above
    // are still there, unlike a restart which would merely have reloaded
    // them from disk.
    assert_eq!(
        json(&tokio::task::spawn_blocking(server_settings).await??)["btMaxConnections"],
        77
    );

    // Idempotent: a second start returns the same URL without restarting.
    let again = tokio::task::spawn_blocking({
        let cfg = config(tmp.path());
        move || server_start(cfg)
    })
    .await??;
    assert_eq!(again, url);

    // Stop joins the server thread; the port goes dark and the library
    // calls say so.
    tokio::task::spawn_blocking(server_stop).await??;
    assert_eq!(server_base_url()?, None);
    let error = tokio::task::spawn_blocking(server_settings)
        .await?
        .unwrap_err();
    assert!(error.to_string().contains("not running"), "{error}");
    let error =
        tokio::task::spawn_blocking(|| server_torrent_stats(INFO_HASH.to_owned(), None, vec![]))
            .await?
            .unwrap_err();
    assert!(error.to_string().contains("not running"), "{error}");
    assert!(
        heartbeat_status(&url).await.is_err(),
        "server still answering after stop"
    );

    // Stop when not running is a no-op, and a restart works.
    tokio::task::spawn_blocking(server_stop).await??;
    let restarted = tokio::task::spawn_blocking({
        let cfg = config(tmp.path());
        move || server_start(cfg)
    })
    .await??;
    assert_eq!(
        heartbeat_status(&restarted).await?,
        StatusCode::UNAUTHORIZED
    );
    tokio::task::spawn_blocking(server_stop).await??;
    Ok(())
}
