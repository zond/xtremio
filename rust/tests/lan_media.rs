//! The LAN media listener over the FRB surface: the toggle round-trips, the
//! listener really is a second socket serving media routes only, and it is
//! off at every point where no cast session is running -- including right
//! after start-up and once the server has been shut down.
//!
//! Its own test binary, and so its own process: the embedded server is a
//! process-wide singleton and `embedded.rs` drives the same one.

use std::net::SocketAddr;

use reqwest::StatusCode;
use xtremio_core::api::server::{
    server_lan_media_base_url, server_lan_media_running, server_set_lan_media, server_settings,
    server_start, server_stop, ServerConfig,
};

fn config(root: &std::path::Path) -> ServerConfig {
    ServerConfig {
        config_dir: root.join("server").display().to_string(),
        cache_dir: root.join("cache").join("server").display().to_string(),
        port: 0,
        fallback_to_ephemeral: true,
    }
}

/// The listener binds every interface, so the way to reach it from this
/// process is loopback on the port it reported.
fn loopback(addr: &str) -> anyhow::Result<SocketAddr> {
    let addr: SocketAddr = addr.parse()?;
    Ok(SocketAddr::from(([127, 0, 0, 1], addr.port())))
}

async fn status_of(addr: SocketAddr, path: &str) -> anyhow::Result<StatusCode> {
    let client = reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(5))
        .build()?;
    Ok(client
        .get(format!("http://{addr}{path}"))
        .send()
        .await?
        .status())
}

/// Whether the server's persisted `lanMediaEnabled` veto is granted: the
/// permission the listener needs, which the toggle is expected to take back
/// whenever the listener goes off.
async fn lan_media_allowed() -> anyhow::Result<bool> {
    let settings: serde_json::Value =
        serde_json::from_str(&tokio::task::spawn_blocking(server_settings).await??)?;
    Ok(settings["lanMediaEnabled"] == serde_json::Value::Bool(true))
}

#[tokio::test]
async fn lan_media_toggles_and_is_off_around_the_session() -> anyhow::Result<()> {
    let tmp = tempfile::tempdir()?;
    assert!(
        !server_lan_media_running()?,
        "nothing on the LAN with no server at all"
    );

    tokio::task::spawn_blocking({
        let cfg = config(tmp.path());
        move || server_start(cfg)
    })
    .await??;

    // A configured `lan_media_addr` makes stream-server bind the listener at
    // boot, so "off at start-up" is a claim about what start does with it,
    // not about what the server would have done on its own.
    assert!(
        !server_lan_media_running()?,
        "the LAN listener was left running by start-up"
    );
    assert!(!lan_media_allowed().await?, "the veto is on at start-up");
    assert_eq!(
        tokio::task::spawn_blocking(|| server_lan_media_base_url(Some("127.0.0.1".to_owned())))
            .await??,
        None,
        "a base URL was offered with no listener behind it"
    );

    // On: an address comes back, the socket answers, and the permission the
    // server needs for it was taken along the way.
    let addr = tokio::task::spawn_blocking(|| server_set_lan_media(true))
        .await??
        .expect("an address after a start");
    assert!(server_lan_media_running()?);
    assert!(lan_media_allowed().await?);
    let socket = loopback(&addr)?;

    // Media routes only. `/heartbeat` is a control route and is not mounted
    // on this listener at all; `/proxy` is a media route deliberately left
    // off it, and answers a plain 404 rather than being reinterpreted as a
    // torrent path.
    assert_eq!(
        status_of(socket, "/heartbeat").await?,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        status_of(socket, "/proxy/d/http/example.com/a.mp4").await?,
        StatusCode::NOT_FOUND
    );

    // The URL a receiver is handed names an interface that can reach it.
    // 127.0.0.1 stands in for the receiver here: it is on a local interface's
    // subnet, which is exactly the property being tested.
    let base =
        tokio::task::spawn_blocking(|| server_lan_media_base_url(Some("127.0.0.1".to_owned())))
            .await??
            .expect("a base URL for a reachable peer");
    let base = url::Url::parse(&base)?;
    assert_eq!(base.scheme(), "http");
    assert_eq!(base.port(), Some(socket.port()));
    assert_ne!(
        base.host_str(),
        Some("0.0.0.0"),
        "the receiver was told the wildcard address"
    );
    assert_eq!(
        tokio::task::spawn_blocking(|| server_lan_media_base_url(Some(
            "not an address".to_owned()
        )))
        .await??,
        None,
        "a peer that is not an IP address has no URL"
    );
    // No peer at all -- what the Cast SDK leaves us with, since it reports no
    // receiver address: the host's best-effort interface, never loopback.
    let best_effort = tokio::task::spawn_blocking(|| server_lan_media_base_url(None))
        .await??
        .expect("a base URL with no peer named");
    let best_effort = url::Url::parse(&best_effort)?;
    assert_eq!(best_effort.port(), Some(socket.port()));
    assert_ne!(best_effort.host_str(), Some("127.0.0.1"));
    assert_ne!(best_effort.host_str(), Some("0.0.0.0"));

    // Idempotent in both directions.
    let again = tokio::task::spawn_blocking(|| server_set_lan_media(true)).await??;
    assert_eq!(again.as_deref(), Some(addr.as_str()));

    // Off: no address, nothing listening, and the veto back on.
    assert_eq!(
        tokio::task::spawn_blocking(|| server_set_lan_media(false)).await??,
        None
    );
    assert!(!server_lan_media_running()?);
    assert!(!lan_media_allowed().await?, "the veto was left granted");
    assert!(
        status_of(socket, "/heartbeat").await.is_err(),
        "the LAN socket still answers after the session ended"
    );
    assert_eq!(
        tokio::task::spawn_blocking(|| server_set_lan_media(false)).await??,
        None
    );

    // A session that is running when the app goes away: the shutdown takes
    // the listener with it, and the port really is free afterwards.
    let addr = tokio::task::spawn_blocking(|| server_set_lan_media(true))
        .await??
        .expect("an address after a restart");
    let socket = loopback(&addr)?;
    assert!(server_lan_media_running()?);
    tokio::task::spawn_blocking(server_stop).await??;
    assert!(
        !server_lan_media_running()?,
        "the LAN listener outlived the server"
    );
    assert!(
        status_of(socket, "/heartbeat").await.is_err(),
        "the LAN socket still answers after shutdown"
    );

    // With no server there is nothing to turn on, and saying so is better
    // than reporting a listener nobody could have started.
    let error = tokio::task::spawn_blocking(|| server_set_lan_media(true))
        .await?
        .unwrap_err();
    assert!(error.to_string().contains("not running"), "{error}");
    Ok(())
}
