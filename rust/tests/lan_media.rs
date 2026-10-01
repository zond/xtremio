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

use xtremio_core::api::media::{
    media_publish, media_register_local_path, media_resolve, media_set_play, media_unpublish,
};
use xtremio_core::api::server::{
    server_lan_media_base_url, server_lan_media_bodies_served, server_lan_media_requests_served,
    server_lan_media_running, server_set_lan_media, server_settings, server_stop, ServerConfig,
};

/// The embedded server, started the way the app starts it but **joining no
/// swarm**: no public trackers, no DHT, no local discovery
/// (`xtremio_core::server::StartConfig::offline`). The torrents here are
/// built on the spot; announced, their info hashes went to the public
/// trackers and the DHT, and strangers dialled in.
fn server_start(config: ServerConfig) -> anyhow::Result<String> {
    xtremio_core::server::start(xtremio_core::server::StartConfig {
        config_dir: config.config_dir.into(),
        cache_dir: config.cache_dir.into(),
        offline: true,
    })
    .map(|url| url.to_string())
}

fn config(root: &std::path::Path) -> ServerConfig {
    ServerConfig {
        config_dir: root.join("server").display().to_string(),
        cache_dir: root.join("cache").join("server").display().to_string(),
    }
}

/// Where to reach the listener from this process: loopback on the port it
/// reported. A test's listener binds loopback only (`StartConfig::offline`);
/// the app's binds every interface, which loopback reaches as well.
fn loopback(addr: &str) -> anyhow::Result<SocketAddr> {
    let addr: SocketAddr = addr.parse()?;
    Ok(SocketAddr::from(([127, 0, 0, 1], addr.port())))
}

async fn status_of(addr: SocketAddr, path: &str) -> anyhow::Result<StatusCode> {
    let client = xtremio_core::env::http_client_builder()
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

/// The LAN listener can be made to arrange nothing: a `GET` for a torrent
/// is a `404` at once, and the create routes are not there -- without this,
/// any host on the network could make this device join a swarm of its
/// choosing for the length of a cast. The timing assertion is what tells
/// the two apart: a refusal answers at once, a creation waits on metadata.
///
/// Since stream-server's cast publish step (`ServerHandle::publish`,
/// `/cast/{token}`) the listener has no torrent route at all, so the
/// torrent paths below are a `404` whether or not the device holds the
/// torrent; what a cast is served is a published token
/// ([`a_published_id_is_served_by_its_token_and_nothing_else`]).
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
    // request may reach the network. The listener has no torrent route to
    // hand it to, so it is a plain 404 (see the TODO above).
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
    let client = xtremio_core::env::http_client_builder()
        .no_proxy()
        .build()?;
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

/// **A cast is a published id, served under its token and nothing else**
/// (stream-server `docs/lan-media.md`): the receiver's `GET` of
/// `/cast/<token>` is the file's bytes, and counts as a body; a `HEAD` is a
/// request and not a body; an unpublished token is a `404`, as is the id
/// itself on any path. A file on this device stands in for any id: the
/// route is one for every kind.
#[tokio::test]
async fn a_published_id_is_served_by_its_token_and_nothing_else() -> anyhow::Result<()> {
    let _serial = SERVER.lock().await;
    let tmp = tempfile::tempdir()?;
    tokio::task::spawn_blocking({
        let cfg = config(tmp.path());
        move || server_start(cfg)
    })
    .await??;
    let film: Vec<u8> = (0..200_000u32).map(|n| (n % 251) as u8).collect();
    let path = tmp.path().join("A Film.mp4");
    std::fs::write(&path, &film)?;
    let id = media_register_local_path(path.display().to_string(), None)?;
    let resolved: serde_json::Value = serde_json::from_str(
        &tokio::task::spawn_blocking({
            let id = id.clone();
            move || media_resolve(id)
        })
        .await??,
    )?;
    assert_eq!(resolved["len"], film.len() as u64, "{resolved}");
    assert_eq!(resolved["inProcess"], true);

    // No listener, nothing published.
    assert!(media_publish(id.clone()).is_err());

    let addr = tokio::task::spawn_blocking(|| server_set_lan_media(true))
        .await??
        .expect("an address after a start");
    let socket = loopback(&addr)?;
    media_set_play(id.clone(), "viewer.1".into(), "normal".into())?;
    let token = tokio::task::spawn_blocking({
        let id = id.clone();
        move || media_publish(id)
    })
    .await??;
    assert_ne!(token, id, "a token is never the id");

    let client = xtremio_core::env::http_client_builder()
        .no_proxy()
        .build()?;
    let head = client
        .head(format!("http://{socket}/cast/{token}"))
        .send()
        .await?;
    assert_eq!(head.status(), StatusCode::OK);
    assert_eq!(server_lan_media_bodies_served()?, 0, "a HEAD is no body");
    let body = client
        .get(format!("http://{socket}/cast/{token}"))
        .send()
        .await?;
    assert_eq!(body.status(), StatusCode::OK);
    assert_eq!(body.bytes().await?.as_ref(), film.as_slice());
    assert_eq!(server_lan_media_bodies_served()?, 1);
    assert!(server_lan_media_requests_served()? >= 2);
    assert_eq!(
        status_of(socket, &format!("/cast/{id}")).await?,
        StatusCode::NOT_FOUND,
        "the id names nothing on the LAN"
    );

    assert!(
        tokio::task::spawn_blocking({
            let token = token.clone();
            move || media_unpublish(token)
        })
        .await??
    );
    assert_eq!(
        status_of(socket, &format!("/cast/{token}")).await?,
        StatusCode::NOT_FOUND
    );
    assert!(!tokio::task::spawn_blocking(move || media_unpublish(token)).await??);

    tokio::task::spawn_blocking(|| server_set_lan_media(false)).await??;
    assert_eq!(server_lan_media_bodies_served()?, 0, "a stop resets it");
    tokio::task::spawn_blocking(server_stop).await??;
    Ok(())
}

/// A cast grants the server's `lanMediaEnabled` permission and the server
/// persists it; a process killed mid-cast never takes it back, and the
/// server loads the setting as it finds it and resets it for nobody. So
/// `server_start` clears it first thing -- without this, a device killed
/// mid-cast would report the permission granted at the next start, though
/// nothing is casting. The kill is staged with the server's own file: a
/// cast leaves `settings.json` with the permission granted, and that file
/// is put back after the orderly stop that cleared it, so the next start
/// finds exactly what a kill leaves.
#[tokio::test]
async fn a_kill_mid_cast_leaves_no_permission_behind_at_the_next_start() -> anyhow::Result<()> {
    let _serial = SERVER.lock().await;
    let tmp = tempfile::tempdir()?;
    let settings_file = tmp.path().join("server").join("settings.json");
    tokio::task::spawn_blocking({
        let cfg = config(tmp.path());
        move || server_start(cfg)
    })
    .await??;
    tokio::task::spawn_blocking(|| server_set_lan_media(true))
        .await??
        .expect("an address after a start");
    assert!(lan_media_allowed().await?);
    let mid_cast = std::fs::read(&settings_file)?;
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&mid_cast)?["lanMediaEnabled"],
        true,
        "the permission was granted but is not on disk, so a kill could not leave it"
    );

    // An orderly stop writes "no"; a kill writes nothing. Put back what the
    // cast had written.
    tokio::task::spawn_blocking(server_stop).await??;
    std::fs::write(&settings_file, mid_cast)?;

    tokio::task::spawn_blocking({
        let cfg = config(tmp.path());
        move || server_start(cfg)
    })
    .await??;
    assert!(!server_lan_media_running()?);
    assert!(
        !lan_media_allowed().await?,
        "the permission a kill left behind survived start-up"
    );
    let on_disk: serde_json::Value = serde_json::from_slice(&std::fs::read(&settings_file)?)?;
    assert_eq!(on_disk["lanMediaEnabled"], false, "cleared in memory only");
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

    // Nothing binds a configured `lan_media_addr` at boot, so a listener
    // that is off at start-up is the server's own doing. The veto being off
    // is the half start-up is responsible for, and the test below proves it
    // against a permission that was actually left behind.
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

    // Media routes only. `/settings` is a control route and is not mounted
    // on this listener at all; `/proxy` is a media route deliberately left
    // off it, and answers a plain 404 like every path but a published
    // `/cast/{token}`.
    assert_eq!(status_of(socket, "/settings").await?, StatusCode::NOT_FOUND);
    assert_eq!(
        status_of(socket, "/proxy/d/http/example.com/a.mp4").await?,
        StatusCode::NOT_FOUND
    );

    // Both of those were counted, refusals and all. The count is not about
    // what was served: it is the answer to "did the receiver reach this
    // device at all", which a receiver told an unroutable address never
    // does -- it hangs on the connect and reports nothing. Exactly two:
    // a test's listener is on loopback, so nothing else could have knocked.
    let served = server_lan_media_requests_served()?;
    assert_eq!(
        served, 2,
        "the two requests above, and only they, are counted"
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
    // no receiver address there and only the Android half reads one off the
    // route: still a URL. Which interface a wildcard-bound listener names
    // then is stream-server's ranking, tested there on built interface lists
    // (`lan_media::pick_host_ranks_what_a_receiver_could_reach`) rather than
    // on whatever network this machine is on; a listener bound to one
    // address, as a test's is, names that address.
    let best_effort = tokio::task::spawn_blocking(|| server_lan_media_base_url(None))
        .await??
        .expect("a base URL with no peer named");
    let best_effort = url::Url::parse(&best_effort)?;
    assert_eq!(best_effort.port(), Some(socket.port()));
    assert_eq!(best_effort.host_str(), Some("127.0.0.1"));

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
        status_of(socket, "/settings").await.is_err(),
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
        status_of(socket, "/settings").await.is_err(),
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
