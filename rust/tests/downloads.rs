//! Offline downloads end to end, hermetically: a torrent built here, its data
//! placed where the embedded server keeps torrents, and no peer, tracker or
//! network involved at any point.
//!
//! The server and the storage directory are process globals, so the whole
//! lifecycle lives in one test function. `POST /create` is the one thing done
//! over HTTP: it is how a *known* torrent (metadata and all) gets into the
//! session without waiting 90 s for a magnet nobody can answer, and it has no
//! `ServerHandle` method. Everything the app itself does goes through the FFI
//! surface, as it must.

use std::collections::BTreeMap;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use xtremio_core::api::core::{core_init, core_shutdown, CoreConfig};
use xtremio_core::api::downloads::{
    downloads_add, downloads_list, downloads_remove, downloads_set_dir,
};
use xtremio_core::api::server::{server_start, ServerConfig};

/// Whole 16 KiB pieces per file, so no piece straddles the two and "this
/// file is complete" means only its own bytes are on disk.
const PIECE: usize = 16 * 1024;
const HAVE_LEN: usize = 2 * PIECE;
const MISSING_LEN: usize = 3 * PIECE;

fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| tokio::runtime::Runtime::new().expect("test runtime"))
}

fn json(text: &str) -> serde_json::Value {
    serde_json::from_str(text).expect("valid JSON")
}

/// Deterministic, non-trivial payload so the piece hashes mean something.
fn write_payload(path: &std::path::Path, len: usize) {
    let data: Vec<u8> = (0..len).map(|i| (i % 251) as u8).collect();
    std::fs::write(path, data).expect("write payload");
}

/// A real multi-file torrent (correct piece hashes) over the files in `dir`,
/// whose name is the folder librqbit will put them in.
fn real_torrent(dir: &std::path::Path) -> (Vec<u8>, String) {
    runtime().block_on(async {
        let torrent = librqbit::create_torrent(
            dir,
            librqbit::CreateTorrentOptions {
                name: None,
                trackers: Vec::new(),
                piece_length: Some(PIECE as u32),
            },
            &librqbit::spawn_utils::BlockingSpawner::new(1),
        )
        .await
        .expect("create torrent");
        (
            torrent.as_bytes().expect("serialize").to_vec(),
            torrent.info_hash().as_string(),
        )
    })
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// `POST /create` with the server's bearer token: registers a torrent whose
/// metadata is already known. The token never leaves this process (it is not
/// on the FFI surface at all), so the test reads it the way `Env::fetch`
/// does and never prints it.
fn create_torrent_on_server(base_url: &url::Url, torrent: &[u8]) -> serde_json::Value {
    let token = xtremio_core::server::token_for(base_url).expect("server token");
    runtime().block_on(async {
        reqwest::Client::new()
            .post(base_url.join("create").expect("create URL"))
            .bearer_auth(token)
            .json(&serde_json::json!({ "torrent": hex(torrent) }))
            .send()
            .await
            .expect("POST /create")
            .error_for_status()
            .expect("create succeeded")
            .json()
            .await
            .expect("create JSON")
    })
}

fn list() -> serde_json::Value {
    json(&downloads_list().expect("downloads_list"))
}

fn add(meta_id: &str, info_hash: &str, file_idx: usize) -> serde_json::Value {
    let request = serde_json::json!({
        "metaId": meta_id,
        "videoId": meta_id,
        "type": "movie",
        "name": format!("{meta_id} the film"),
        "poster": "https://example.invalid/poster.jpg",
        "stream": {
            "infoHash": info_hash,
            "fileIdx": file_idx,
            "name": "Test",
            "announce": [],
        },
        "meta": { "id": meta_id, "type": "movie", "name": "Snapshot" },
        "streamRequest": { "base": "https://addon.invalid/manifest.json" },
        "metaRequest": { "base": "https://cinemeta.invalid/manifest.json" },
    });
    json(&downloads_add(request.to_string()).expect("downloads_add"))
}

/// Index of the torrent file called `name`, as the create response reports
/// them (file order is whatever the directory walk produced).
fn file_index(stats: &serde_json::Value, name: &str) -> usize {
    stats["files"]
        .as_array()
        .expect("files")
        .iter()
        .position(|file| file["name"] == name)
        .unwrap_or_else(|| panic!("no file {name} in {stats}"))
}

/// Polls the list until `key`'s entry satisfies `done`, or gives up.
fn wait_for(key: &str, what: &str, done: impl Fn(&serde_json::Value) -> bool) -> serde_json::Value {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let items = list();
        let entry = items["items"][key].clone();
        if done(&entry) {
            return entry;
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for {what}: {entry}"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[test]
fn offline_downloads_lifecycle() -> anyhow::Result<()> {
    let tmp = tempfile::tempdir()?;
    let storage = tmp.path().join("core");
    xtremio_core::env::set_storage_dir(&storage)?;
    let registry_file = storage.join("downloads.json");

    // A two-file torrent, with only the first file's data already on disk in
    // the folder librqbit manages: one download is instantly complete, the
    // other can never finish (nobody is seeding), which is exactly the pair
    // the registry has to tell apart.
    let content = tmp.path().join("Test Show");
    std::fs::create_dir_all(&content)?;
    write_payload(&content.join("have.bin"), HAVE_LEN);
    write_payload(&content.join("missing.bin"), MISSING_LEN);
    let (torrent, info_hash) = real_torrent(&content);

    let cache_root = tmp.path().join("cache").join("server");
    let managed = cache_root.join("rqbit-downloads").join("Test Show");
    std::fs::create_dir_all(&managed)?;
    std::fs::copy(content.join("have.bin"), managed.join("have.bin"))?;

    let base_url = url::Url::parse(&server_start(ServerConfig {
        config_dir: tmp.path().join("server").display().to_string(),
        cache_dir: cache_root.display().to_string(),
        port: 0,
        fallback_to_ephemeral: true,
    })?)?;
    let created = create_torrent_on_server(&base_url, &torrent);
    assert_eq!(created["infoHash"], info_hash, "{created}");
    let have_idx = file_index(&created, "have.bin");
    let missing_idx = file_index(&created, "missing.bin");

    // Nothing pinned yet.
    assert_eq!(list()["items"], serde_json::json!({}));
    assert!(
        !registry_file.exists(),
        "no file until there is something in it"
    );

    // A stream that is not a torrent is the one thing that raises.
    let error = downloads_add(
        serde_json::json!({
            "metaId": "tt1", "videoId": "tt1", "stream": {"url": "https://example.invalid/x.mkv"}
        })
        .to_string(),
    )
    .unwrap_err();
    assert!(error.to_string().contains("infoHash"), "{error}");
    let error = downloads_add("{".to_owned()).unwrap_err();
    assert!(
        error.to_string().contains("invalid download request"),
        "{error}"
    );

    // Add both. The pin answers at once (the metadata is known), with the
    // file's place on disk.
    let added = add("tt-have", &info_hash, have_idx);
    assert_eq!(added["ok"], true, "{added}");
    assert_eq!(added["key"], "tt-have:tt-have");
    assert_eq!(
        added["entry"]["path"],
        managed.join("have.bin").to_string_lossy().as_ref(),
        "{added}"
    );
    assert_eq!(added["entry"]["infoHash"], info_hash);
    assert_eq!(added["entry"]["fileIdx"], have_idx);
    assert_eq!(added["entry"]["size"], HAVE_LEN);
    assert!(added["entry"]["createdAt"].is_string(), "{added}");
    // The stream, meta and requests are kept verbatim for Load Player.
    assert_eq!(added["entry"]["stream"]["infoHash"], info_hash);
    assert_eq!(added["entry"]["meta"]["name"], "Snapshot");
    assert_eq!(
        added["entry"]["metaRequest"]["base"],
        "https://cinemeta.invalid/manifest.json"
    );

    let added = add("tt-missing", &info_hash, missing_idx);
    assert_eq!(added["ok"], true, "{added}");
    assert_eq!(
        added["entry"]["path"],
        managed.join("missing.bin").to_string_lossy().as_ref(),
        "{added}"
    );

    // A file the torrent does not have is a failure the UI can show, not an
    // exception: `ok: false` with a classified error.
    let refused = add("tt-nope", &info_hash, 99);
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["error"]["kind"], "fileNotFound", "{refused}");
    assert_eq!(refused["error"]["fileIdx"], 99);
    assert!(refused["error"]["message"].is_string(), "{refused}");
    assert_eq!(list()["items"]["tt-nope:tt-nope"], serde_json::Value::Null);

    // The one whose bytes are there completes once the check is done; the
    // one whose bytes are not stays queued or downloading, with a path
    // either way.
    let complete = wait_for("tt-have:tt-have", "have.bin to complete", |entry| {
        entry["state"] == "complete"
    });
    assert_eq!(complete["downloaded"], HAVE_LEN, "{complete}");
    assert!(complete["completedAt"].is_string(), "{complete}");
    let pending = list()["items"]["tt-missing:tt-missing"].clone();
    assert!(
        pending["state"] == "queued" || pending["state"] == "downloading",
        "{pending}"
    );
    assert!(pending["path"].is_string(), "{pending}");
    assert_eq!(pending["size"], MISSING_LEN, "{pending}");
    assert!(pending["completedAt"].is_null(), "{pending}");

    // The registry is on disk, versioned, keyed by meta and video.
    let persisted = json(&std::fs::read_to_string(&registry_file)?);
    assert_eq!(persisted["version"], 1, "{persisted}");
    let keys: Vec<&str> = persisted["items"]
        .as_object()
        .expect("items")
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(keys, ["tt-have:tt-have", "tt-missing:tt-missing"]);

    // Unpinning without deleting keeps the bytes and forgets the entry.
    let removed = json(&downloads_remove("tt-have:tt-have".into(), false)?);
    assert_eq!(
        removed,
        serde_json::json!({"removed": true, "unpinned": true, "deletedFiles": false})
    );
    assert!(managed.join("have.bin").is_file(), "the file stays");
    assert_eq!(list()["items"]["tt-have:tt-have"], serde_json::Value::Null);

    // Removing something the registry does not have is not an error.
    let removed = json(&downloads_remove("tt-have:tt-have".into(), true)?);
    assert_eq!(removed["removed"], false, "{removed}");
    assert!(managed.join("have.bin").is_file(), "and touches nothing");

    // Re-adding keeps the original `createdAt`... after re-adding it under a
    // key that never left, which is what a retry looks like.
    let created_at = list()["items"]["tt-missing:tt-missing"]["createdAt"].clone();
    let readded = add("tt-missing", &info_hash, missing_idx);
    assert_eq!(readded["entry"]["createdAt"], created_at, "{readded}");

    // With `deleteFiles` the bytes go. The other file of the same torrent is
    // still pinned, so only this one is deleted and the torrent lives on.
    add("tt-have", &info_hash, have_idx);
    let removed = json(&downloads_remove("tt-have:tt-have".into(), true)?);
    assert_eq!(removed["removed"], true, "{removed}");
    assert_eq!(removed["deletedFiles"], true, "{removed}");
    assert!(!managed.join("have.bin").exists(), "the file is gone");
    assert!(
        managed.join("missing.bin").exists(),
        "the still-pinned file of the same torrent stays"
    );

    // Progress events: the ticker is running (something is unfinished), so a
    // registry that disagrees with the server is corrected and the change is
    // pushed. Written straight into the registry to make the change certain
    // -- with nobody seeding, the real download never moves a byte.
    let (tx, rx) = std::sync::mpsc::channel();
    xtremio_core::downloads::set_event_sink(Box::new(move |event| tx.send(event).is_ok()));
    xtremio_core::downloads::update(|registry| {
        let entry = registry
            .items
            .get_mut("tt-missing:tt-missing")
            .expect("the pending entry");
        entry.downloaded = 123_456;
        Ok(())
    })?;
    let event = json(
        &rx.recv_timeout(Duration::from_secs(30))
            .expect("a progress event"),
    );
    assert_eq!(event["version"], 1, "{event}");
    assert_eq!(
        event["items"]["tt-missing:tt-missing"]["downloaded"], 0,
        "the live number replaced the bogus one: {event}"
    );
    assert!(
        event["items"]["tt-have:tt-have"].is_null(),
        "only what changed is pushed: {event}"
    );

    // Re-pinning at init: the server forgets a pin (as a purged cache dir or
    // an absent downloads volume would make it), and the registry puts it
    // back.
    xtremio_core::server::unpin_download(&info_hash, missing_idx, false)?;
    assert!(
        xtremio_core::server::downloads()?.is_empty(),
        "the pin is gone from the server"
    );
    xtremio_core::downloads::repin_unfinished();
    let pins = xtremio_core::server::downloads()?;
    assert_eq!(pins.len(), 1, "{pins:?}");
    assert_eq!(pins[0].file_idx, missing_idx);

    // And booting is what does that in the app: `core_init` starts the
    // re-pin behind it, so the pin comes back without anything on screen
    // having waited for a magnet to resolve.
    xtremio_core::server::unpin_download(&info_hash, missing_idx, false)?;
    assert!(xtremio_core::server::downloads()?.is_empty());
    core_init(CoreConfig {
        storage_dir: storage.display().to_string(),
        cache_dir: tmp.path().join("cache").join("core").display().to_string(),
        server: Some(ServerConfig {
            config_dir: tmp.path().join("server").display().to_string(),
            cache_dir: cache_root.display().to_string(),
            port: 0,
            fallback_to_ephemeral: true,
        }),
    })?;
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let pins = xtremio_core::server::downloads()?;
        if pins.len() == 1 && pins[0].file_idx == missing_idx {
            break;
        }
        assert!(Instant::now() < deadline, "init never re-pinned: {pins:?}");
        std::thread::sleep(Duration::from_millis(100));
    }

    // The destination directory goes through the server's own validation.
    let error = downloads_set_dir(Some("relative/dir".into())).unwrap_err();
    assert!(error.to_string().contains("absolute"), "{error}");
    let destination = tmp.path().join("offline");
    let settings = json(&downloads_set_dir(Some(destination.display().to_string()))?);
    assert_eq!(
        settings["downloadsDir"],
        destination.to_string_lossy().as_ref(),
        "{settings}"
    );
    assert!(destination.is_dir(), "created on the spot");

    // A registry the app cannot read must not take the app down with it: the
    // list is empty rather than an error, and the next write starts over.
    let good = std::fs::read_to_string(&registry_file)?;
    std::fs::write(&registry_file, b"{ this is not JSON")?;
    assert_eq!(
        list()["items"],
        serde_json::json!({}),
        "corrupt reads empty"
    );

    // An older, thinner entry -- only the fields version 1 requires -- still
    // loads, with defaults for everything it does not carry.
    std::fs::write(
        &registry_file,
        br#"{"version":0,"items":{"old:old":{"metaId":"old","videoId":"old","infoHash":"deadbeef"}}}"#,
    )?;
    let old = list()["items"]["old:old"].clone();
    assert_eq!(old["infoHash"], "deadbeef", "{old}");
    assert_eq!(old["state"], "queued", "{old}");
    assert_eq!(old["fileIdx"], 0, "{old}");
    assert!(old["path"].is_null(), "{old}");

    // And the registry the test built is still readable after a full reload.
    std::fs::write(&registry_file, good)?;
    let reloaded = xtremio_core::downloads::load()?;
    let keys: Vec<&str> = reloaded.items.keys().map(String::as_str).collect();
    assert_eq!(keys, ["tt-missing:tt-missing"]);
    let entry = &reloaded.items["tt-missing:tt-missing"];
    assert_eq!(entry.info_hash, info_hash);
    assert_eq!(entry.file_idx, missing_idx);
    assert_eq!(entry.stream["infoHash"], info_hash.as_str());
    assert_eq!(entry.meta.as_ref().expect("meta")["name"], "Snapshot");
    assert_eq!(reloaded.items.values().map(|_| ()).count(), 1);
    assert_eq!(
        entry.extra,
        BTreeMap::new(),
        "nothing unknown was invented on the way through"
    );

    core_shutdown()?;
    Ok(())
}
