//! Embeds stream-server in-process through the FRB surface and drives it
//! over real HTTP on an ephemeral loopback port.
//!
//! The server is a process-wide singleton, so every scenario lives in one
//! test function to keep them from interfering.

use reqwest::StatusCode;
use xtremio_core::api::server::{server_base_url, server_start, server_stop, ServerConfig};

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

    // Idempotent: a second start returns the same URL without restarting.
    let again = tokio::task::spawn_blocking({
        let cfg = config(tmp.path());
        move || server_start(cfg)
    })
    .await??;
    assert_eq!(again, url);

    // Stop joins the server thread; the port goes dark.
    tokio::task::spawn_blocking(server_stop).await??;
    assert_eq!(server_base_url()?, None);
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
