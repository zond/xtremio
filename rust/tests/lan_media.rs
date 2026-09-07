//! The LAN media listener over the FRB surface: the toggle round-trips, the
//! listener really is a second socket serving media routes only, and it is
//! off at every point where no cast session is running -- including right
//! after start-up and once the server has been shut down.
//!
//! Its own test binary, and so its own process: the embedded server is a
//! process-wide singleton and `embedded.rs` drives the same one. The tests
//! in here take [`SERVER`] for the same reason, since the harness runs them
//! on separate threads and each starts and stops that one server.

use std::net::SocketAddr;

use reqwest::StatusCode;
use tokio::sync::Mutex;

/// Held for the length of each test: one embedded server per process, so
/// one test at a time. Tokio's, since it is held across the awaits.
static SERVER: Mutex<()> = Mutex::const_new(());

use xtremio_core::api::server::{
    server_lan_media_base_url, server_lan_media_requests_served, server_lan_media_running,
    server_set_lan_media, server_settings, server_start, server_stop, ServerConfig,
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
        // Loopback: an ambient `HTTP_PROXY` would send a request meant for
        // the server this test started off the machine, and reqwest does
        // not exempt 127.0.0.1 from one.
        .no_proxy()
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

/// The LAN listener serves the bytes of torrents this device already has
/// and can be made to arrange nothing (stream-server `388f68b`, in the pin
/// since 75c15dc): a `GET` for a hash the server does not hold is a `404`
/// at once, and the create routes are not there. Before that rev its stream
/// route was the loopback one, which *created* the torrent with the
/// request's trackers and answered only once its metadata resolved or
/// timed out -- so for the length of a cast any host on the network could
/// make this device join a swarm of its choosing. The timing assertion is
/// what tells the two apart: a lookup answers now, a creation waits on
/// metadata.
#[tokio::test]
async fn lan_listener_serves_only_torrents_the_device_already_has() -> anyhow::Result<()> {
    let _serial = SERVER.lock().await;
    let tmp = tempfile::tempdir()?;
    tokio::task::spawn_blocking({
        let cfg = config(tmp.path());
        move || server_start(cfg)
    })
    .await??;
    let addr = tokio::task::spawn_blocking(|| server_set_lan_media(true))
        .await??
        .expect("an address after a start");
    let socket = loopback(&addr)?;

    // An invented hash with an attacker's tracker on it: nothing about the
    // request may reach the network, so it has to be answered from what the
    // server holds, which is nothing.
    let unknown = "0123456789abcdef0123456789abcdef01234567";
    let started = std::time::Instant::now();
    let status = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        status_of(
            socket,
            &format!("/{unknown}/0?tr=http%3A%2F%2F127.0.0.1%3A9%2Fannounce"),
        ),
    )
    .await
    .expect("a lookup answers at once; a creation waits on metadata")?;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "an unknown hash is not created"
    );
    assert!(
        started.elapsed() < std::time::Duration::from_secs(5),
        "the answer took {:?}, which is a magnet being resolved",
        started.elapsed()
    );
    assert_eq!(
        status_of(socket, &format!("/stream/{unknown}/0")).await?,
        StatusCode::NOT_FOUND
    );

    // The create routes are control routes and are not mounted at all: a
    // 404 (or the stream route's 405 for a POST on a path it also matches),
    // never a 401 that would say the route exists behind a token.
    let client = reqwest::Client::builder().no_proxy().build()?;
    for path in [
        "/create".to_owned(),
        format!("/{unknown}/create"),
        "/rar/create".to_owned(),
        "/zip/create".to_owned(),
    ] {
        let status = client
            .post(format!("http://{socket}{path}"))
            .body("{}")
            .send()
            .await?
            .status();
        assert!(
            status == StatusCode::NOT_FOUND || status == StatusCode::METHOD_NOT_ALLOWED,
            "{path} answered {status} on the LAN listener"
        );
    }

    tokio::task::spawn_blocking(|| server_set_lan_media(false)).await??;
    tokio::task::spawn_blocking(server_stop).await??;
    Ok(())
}

#[tokio::test]
async fn lan_media_toggles_and_is_off_around_the_session() -> anyhow::Result<()> {
    let _serial = SERVER.lock().await;
    let tmp = tempfile::tempdir()?;
    assert!(
        !server_lan_media_running()?,
        "nothing on the LAN with no server at all"
    );
    assert_eq!(
        server_lan_media_requests_served()?,
        0,
        "a server that does not exist was asked for something"
    );

    tokio::task::spawn_blocking({
        let cfg = config(tmp.path());
        move || server_start(cfg)
    })
    .await??;

    // The pinned stream-server binds a configured `lan_media_addr` at boot
    // (from 02ec741 nothing does), so "off at start-up" is a claim about
    // what start does with it, not about what the server would have done on
    // its own -- and the veto being off is the half that matters on either.
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
    assert_eq!(
        server_lan_media_requests_served()?,
        0,
        "a session began having already been asked for something"
    );
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

    // Both of those were counted, refusals and all. The count is not about
    // what was served: it is the answer to "did the receiver reach this
    // device at all", which a receiver told an unroutable address never
    // does -- it hangs on the connect and reports nothing. Greater rather
    // than equal because this listener is bound to every interface, and
    // whatever else is on the LAN is welcome to knock.
    let served = server_lan_media_requests_served()?;
    assert!(
        served >= 2,
        "the two requests above went uncounted ({served})"
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
    // No peer at all -- what iOS leaves us with, since the Cast SDK reports
    // no receiver address there and only the Android half now reads one off
    // the route: the host's best-ranked interface, never loopback.
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
    assert_eq!(
        server_lan_media_requests_served()?,
        0,
        "the last session's count was handed to this one"
    );
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
