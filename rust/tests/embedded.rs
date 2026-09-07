//! Embeds stream-server in-process through the FRB surface and drives it
//! over real HTTP on an ephemeral loopback port.
//!
//! The server is a process-wide singleton, so every scenario lives in one
//! test function to keep them from interfering.

use std::sync::{Arc, Mutex};

use reqwest::StatusCode;
use xtremio_core::api::server::{
    server_base_url, server_cache_usage, server_clean_cache_now, server_close_proxy_streams,
    server_dht_status, server_settings, server_start, server_stop, server_storage_report,
    server_torrent_stats, server_update_settings, ServerConfig,
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
        // Loopback: an ambient `HTTP_PROXY` would send a request meant for
        // the server this test started off the machine, and reqwest does
        // not exempt 127.0.0.1 from one.
        .no_proxy()
        .connect_timeout(std::time::Duration::from_secs(5))
        .build()?;
    Ok(client
        .get(format!("{base_url}heartbeat"))
        .send()
        .await?
        .status())
}

/// An origin that answers every request with a body it never finishes:
/// headers, a first few kilobytes, then silence forever. That is what a
/// stream a player is holding open looks like from this side, and the only
/// thing a close can be observed against -- an origin that ended would end
/// the stream by itself and prove nothing.
///
/// Every request line it was sent is recorded, so a test can also say what
/// did *not* reach it.
fn endless_origin(
    requests: Arc<Mutex<Vec<String>>>,
) -> std::io::Result<(std::net::SocketAddr, tokio::task::JoinHandle<()>)> {
    let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
    listener.set_nonblocking(true)?;
    let addr = listener.local_addr()?;
    let listener = tokio::net::TcpListener::from_std(listener)?;
    let task = tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            let requests = Arc::clone(&requests);
            tokio::spawn(async move {
                use tokio::io::{AsyncReadExt, AsyncWriteExt};
                let mut head = Vec::new();
                let mut byte = [0u8; 1];
                while !head.ends_with(b"\r\n\r\n") {
                    match socket.read(&mut byte).await {
                        Ok(0) | Err(_) => return,
                        Ok(_) => head.push(byte[0]),
                    }
                }
                let text = String::from_utf8_lossy(&head).into_owned();
                let line = text.lines().next().unwrap_or_default().to_owned();
                requests.lock().expect("origin log").push(line);
                // A `Content-Length` far larger than what is written, so
                // hyper keeps asking the body for more and the read stays
                // parked instead of completing.
                let response = "HTTP/1.1 200 OK\r\n\
                                Content-Type: video/mp4\r\n\
                                Content-Length: 1048576\r\n\
                                \r\n";
                if socket.write_all(response.as_bytes()).await.is_err()
                    || socket.write_all(&[0u8; 4096]).await.is_err()
                    || socket.flush().await.is_err()
                {
                    return;
                }
                std::future::pending::<()>().await;
            });
        }
    });
    Ok((addr, task))
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

    // The DHT's status, exactly the `dht` key of `GET /stats.json`: cheap
    // and synchronous, so unlike the calls above this is not spawned onto a
    // blocking thread. The hermetic test sandbox rarely has a real DHT
    // bootstrap within a test's lifetime, so only the shape is asserted,
    // never a particular node count or `everBootstrapped` value.
    let dht = json(&server_dht_status()?);
    assert!(dht["enabled"].is_boolean(), "{dht}");
    assert!(dht["nodes"].is_u64(), "{dht}");
    assert!(dht["nodesV6"].is_u64(), "{dht}");
    assert!(dht["everBootstrapped"].is_boolean(), "{dht}");

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

    // A player's stream, ended from here instead of waited out.
    //
    // The app mints a token per player, puts it in the `/proxy` URL that
    // player fetches (`p=`, a proxy parameter that never travels to the
    // origin), and closes by it on teardown -- so a player that is on its
    // way out stops reading now rather than after `network-timeout`, which
    // is deliberately long enough that a slow swarm is not mistaken for a
    // dead connection.
    let origin_requests = Arc::new(Mutex::new(Vec::new()));
    let (origin, origin_task) = endless_origin(Arc::clone(&origin_requests))?;
    let proxied = |token: &str, path: &str| {
        format!(
            "{url}proxy/d=http%3A%2F%2F127.0.0.1%3A{}&p={token}/{path}",
            origin.port()
        )
    };
    let client = reqwest::Client::builder()
        // Loopback: an ambient `HTTP_PROXY` would send a request meant for
        // the server this test started off the machine, and reqwest does
        // not exempt 127.0.0.1 from one.
        .no_proxy()
        .connect_timeout(std::time::Duration::from_secs(5))
        .build()?;
    let mut one = client.get(proxied("player-1", "film.mp4")).send().await?;
    let mut two = client.get(proxied("player-2", "film.mp4")).send().await?;
    assert_eq!(one.status(), StatusCode::OK);
    assert_eq!(two.status(), StatusCode::OK);
    // Both have their first bytes and are now parked on an origin that will
    // never speak again, which is the state a wedged player is in.
    assert!(one.chunk().await?.is_some(), "player one got no bytes");
    assert!(two.chunk().await?.is_some(), "player two got no bytes");
    // The token is ours and stops here: the origin was asked for the path
    // and nothing else.
    let asked = origin_requests.lock().expect("origin log").clone();
    assert_eq!(asked.len(), 2, "{asked:?}");
    for line in &asked {
        assert_eq!(line, "GET /film.mp4 HTTP/1.1", "{asked:?}");
    }

    assert_eq!(server_close_proxy_streams("player-1".to_owned())?, 1);
    // The read fails rather than ending cleanly: a body that stopped
    // politely is what the end of a film looks like, and that is the one
    // thing this must not be mistaken for.
    assert!(
        one.chunk().await.is_err(),
        "player one's read should have failed at once"
    );
    // Closing twice is harmless, and nobody else's stream was touched.
    assert_eq!(
        server_close_proxy_streams("player-1".to_owned())?,
        0,
        "nothing left to close"
    );
    assert_eq!(server_close_proxy_streams("unknown-player".to_owned())?, 0);
    // Player two is still live -- had the first close taken it too, it
    // would have left the registry and this would answer 0. Its own read is
    // deliberately not polled: the origin is silent, so a chunk that is
    // *supposed* to be there is a hang and not an assertion.
    assert_eq!(
        server_close_proxy_streams("player-2".to_owned())?,
        1,
        "the first close should not have touched the other player"
    );
    assert!(two.chunk().await.is_err(), "and now player two ends too");

    // What the app's own URL builder produces, byte for byte, reaching the
    // origin unchanged. This is the shape `lib/core/stream_proxy.dart`
    // writes -- the origin escaped into `d=`, the token beside it, then the
    // target's path and query exactly as they arrived -- and the escapes in
    // it are the ones that do not survive being decoded: `%2F` would become
    // a path separator, `%3D` would end a signature, `%23` would begin a
    // fragment and take the rest of the URL with it, and the `?d=1` would
    // once have been read as the target URL itself. Asserted here rather
    // than only in the Dart tests because it is the *pinned server* that
    // has to keep them, and a pin bump is exactly when that stops being
    // true quietly.
    let mut awkward = client
        .get(proxied(
            "player-3",
            "a%2Fb/sig%3Dx/film%20name%231.mkv?d=1&t=2",
        ))
        .send()
        .await?;
    assert_eq!(awkward.status(), StatusCode::OK);
    assert!(awkward.chunk().await?.is_some());
    assert_eq!(
        origin_requests
            .lock()
            .expect("origin log")
            .last()
            .map(String::as_str),
        Some("GET /a%2Fb/sig%3Dx/film%20name%231.mkv?d=1&t=2 HTTP/1.1")
    );
    assert_eq!(server_close_proxy_streams("player-3".to_owned())?, 1);
    origin_task.abort();

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
    // Unlike every other library call above, this one never errors: no
    // server to ask means no DHT to ask either, which answers the same as
    // a backend built with none -- information, not a failure.
    let dht = json(&server_dht_status()?);
    assert_eq!(dht["enabled"], false, "{dht}");
    assert_eq!(dht["everBootstrapped"], false, "{dht}");

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
