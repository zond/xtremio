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
//!
//! The `#[ignore]`d recorder at the bottom writes the registry fixture the
//! Dart tests read. It takes the same globals, so it runs on its own.

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

fn add_stream(meta_id: &str, stream: serde_json::Value) -> serde_json::Value {
    let request = serde_json::json!({
        "metaId": meta_id,
        "videoId": meta_id,
        "type": "movie",
        "name": format!("{meta_id} the film"),
        "poster": "https://example.invalid/poster.jpg",
        "stream": stream,
        "meta": { "id": meta_id, "type": "movie", "name": "Snapshot" },
        "streamRequest": { "base": "https://addon.invalid/manifest.json" },
        "metaRequest": { "base": "https://cinemeta.invalid/manifest.json" },
    });
    json(&downloads_add(request.to_string()).expect("downloads_add"))
}

fn add(meta_id: &str, info_hash: &str, file_idx: usize) -> serde_json::Value {
    add_stream(
        meta_id,
        serde_json::json!({
            "infoHash": info_hash,
            "fileIdx": file_idx,
            "name": "Test",
            "announce": [],
        }),
    )
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

    // A stream that names no file downloads the file it would *play*: the
    // player asks the server for `/{infoHash}/-1`, which resolves to the
    // `fileMustInclude` match or the largest media file, so pinning file 0
    // would keep -- and later delete -- a different file than the one that
    // streamed. The torrent's file order is the directory walk's, so both
    // rules are checked: whichever file sits at index 0, one of them names
    // the other.
    let largest_idx = created["files"]
        .as_array()
        .expect("files")
        .iter()
        .enumerate()
        .max_by_key(|(_, file)| file["length"].as_u64().unwrap_or_default())
        .map(|(idx, _)| idx)
        .expect("a largest file");
    assert_eq!(largest_idx, missing_idx, "missing.bin is the bigger file");

    let filtered = add_stream(
        "tt-filtered",
        serde_json::json!({
            "infoHash": info_hash, "announce": [], "fileMustInclude": ["have"],
        }),
    );
    assert_eq!(filtered["ok"], true, "{filtered}");
    assert_eq!(filtered["entry"]["fileIdx"], have_idx, "{filtered}");
    assert_eq!(filtered["entry"]["size"], HAVE_LEN, "{filtered}");

    let resolved = add_stream(
        "tt-largest",
        serde_json::json!({"infoHash": info_hash, "name": "Test", "announce": []}),
    );
    assert_eq!(resolved["entry"]["fileIdx"], largest_idx, "{resolved}");
    assert_eq!(resolved["entry"]["size"], MISSING_LEN, "{resolved}");

    // The explicit `-1` the player's URL carries means the same thing.
    let sentinel = add_stream(
        "tt-sentinel",
        serde_json::json!({"infoHash": info_hash, "fileIdx": -1, "announce": []}),
    );
    assert_eq!(sentinel["entry"]["fileIdx"], largest_idx, "{sentinel}");

    for key in ["tt-filtered", "tt-largest", "tt-sentinel"] {
        json(&downloads_remove(format!("{key}:{key}"), false)?);
    }
    assert!(
        xtremio_core::server::downloads()?.is_empty(),
        "the probes left no pin behind"
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

    // Pressing Download again on a finished title -- the button is not
    // disabled yet, or the user is retrying after a scare -- is a retry of
    // the same file, not a new download. `pin_download` relocating the
    // torrent can answer `checking`, which says nothing about the bytes, so
    // the row has to keep what it already knew; the date it finished above
    // all, since that is set once and could never be recovered.
    let readded = add("tt-have", &info_hash, have_idx);
    assert_eq!(
        readded["entry"]["completedAt"], complete["completedAt"],
        "the date it finished survived the re-add: {readded}"
    );
    assert_eq!(readded["entry"]["state"], "complete", "{readded}");
    assert_eq!(readded["entry"]["downloaded"], HAVE_LEN, "{readded}");

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

    // One file, two metas -- the same torrent offered as a stream of a
    // Cinemeta id and of an anime id -- is one pin on the server, which
    // keeps a plain set with no reference count. Dropping one of the two
    // entries must leave the pin, and the bytes, to the other: unpinning
    // here would delete the survivor's file underneath a row still claiming
    // a complete download that nothing will ever correct.
    add("tt-shared-a", &info_hash, have_idx);
    add("tt-shared-b", &info_hash, have_idx);
    let removed = json(&downloads_remove("tt-shared-a:tt-shared-a".into(), true)?);
    assert_eq!(
        removed,
        serde_json::json!({"removed": true, "unpinned": false, "deletedFiles": false}),
        "the pin the other entry names is not this entry's to drop"
    );
    assert!(
        managed.join("have.bin").is_file(),
        "and its bytes are still there"
    );
    let pins = xtremio_core::server::downloads()?;
    assert!(
        pins.iter().any(|pin| pin.file_idx == have_idx),
        "the server still pins the file the survivor plays: {pins:?}"
    );
    assert_eq!(
        list()["items"]["tt-shared-b:tt-shared-b"]["fileIdx"],
        have_idx,
        "and the survivor is still on record"
    );
    // The last entry naming it does take the pin with it.
    let removed = json(&downloads_remove("tt-shared-b:tt-shared-b".into(), false)?);
    assert_eq!(removed["unpinned"], true, "{removed}");
    assert!(managed.join("have.bin").is_file(), "without the bytes");

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

    // Pressing Download on a second stream for the same title replaces the
    // entry -- and has to release the pin it replaces. The registry is keyed
    // by meta and video, the server's pins by (infoHash, fileIdx), so a pin
    // left behind keeps a whole torrent downloading, exempt from every
    // sweeper, with nothing in the registry naming it and no way for the UI
    // to reach it again.
    add("tt-swap", &info_hash, have_idx);
    let pins = xtremio_core::server::downloads()?;
    assert_eq!(pins.len(), 2, "both files are pinned now: {pins:?}");
    let swapped = add("tt-swap", &info_hash, missing_idx);
    assert_eq!(swapped["entry"]["fileIdx"], missing_idx, "{swapped}");
    let pins = xtremio_core::server::downloads()?;
    assert_eq!(pins.len(), 1, "the replaced pin is gone: {pins:?}");
    assert_eq!(pins[0].file_idx, missing_idx, "{pins:?}");
    // Dropped from the registry directly: removing it through the FFI would
    // unpin the file `tt-missing` also names, which the rest of this test
    // needs pinned.
    xtremio_core::downloads::update(|registry| {
        registry.items.remove("tt-swap:tt-swap");
        Ok(())
    })?;

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

    // A refresh that finds work re-arms the progress poll. With nothing
    // unfinished on record the ticker stops; the next list -- which flips an
    // entry back to unfinished against the server's live stats -- has to
    // start it again, or that row sits at its stale numbers for the rest of
    // the session with no event ever pushed.
    let recorded = std::fs::read_to_string(&registry_file)?;
    std::fs::write(&registry_file, br#"{"version":1,"items":{}}"#)?;
    let deadline = Instant::now() + Duration::from_secs(30);
    while xtremio_core::downloads::is_ticking() {
        assert!(Instant::now() < deadline, "the ticker never stopped");
        std::thread::sleep(Duration::from_millis(100));
    }
    std::fs::write(
        &registry_file,
        format!(
            r#"{{"version":1,"items":{{"stale:stale":{{"metaId":"stale","videoId":"stale",
               "infoHash":"{info_hash}","fileIdx":{missing_idx},"state":"complete",
               "size":1,"downloaded":1}}}}}}"#
        ),
    )?;
    let entry = list()["items"]["stale:stale"].clone();
    assert_ne!(
        entry["state"], "complete",
        "the live stats corrected it: {entry}"
    );
    assert!(
        xtremio_core::downloads::is_ticking(),
        "and the poll that pushes what happens next is running again"
    );
    std::fs::write(&registry_file, recorded)?;

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
    // list is empty rather than an error, and the next write starts over --
    // but the file itself is moved aside first, not overwritten, so its
    // bytes are still there to recover a pin from.
    let good = std::fs::read_to_string(&registry_file)?;
    std::fs::write(&registry_file, b"{ this is not JSON")?;
    assert_eq!(
        list()["items"],
        serde_json::json!({}),
        "corrupt reads empty"
    );
    let aside: Vec<std::path::PathBuf> = std::fs::read_dir(&storage)?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("downloads.json.corrupt-"))
        })
        .collect();
    assert_eq!(aside.len(), 1, "{aside:?}");
    assert_eq!(std::fs::read_to_string(&aside[0])?, "{ this is not JSON");
    assert!(!registry_file.exists(), "and the unreadable file is gone");

    // An entry a *newer* build wrote is kept as it is, not dropped and then
    // erased by the next write: the server is still pinning it.
    std::fs::write(
        &registry_file,
        br#"{"version":9,"items":{"new:new":{"metaId":"new","videoId":"new","fileIdx":{"of":2}}}}"#,
    )?;
    assert_eq!(list()["items"], serde_json::json!({}), "unreadable to us");
    xtremio_core::downloads::update(|registry| {
        registry.items.remove("nothing:nothing");
        Ok(())
    })?;
    add("tt-rewrite", &info_hash, have_idx);
    let after = json(&std::fs::read_to_string(&registry_file)?);
    assert_eq!(
        after["items"]["new:new"]["fileIdx"],
        serde_json::json!({"of": 2}),
        "the entry survived a rewrite: {after}"
    );
    assert_eq!(after["version"], 9, "{after}");
    json(&downloads_remove("tt-rewrite:tt-rewrite".into(), true)?);

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

/// A payload whose first `valid` bytes hash as the torrent says and whose
/// tail does not: a file caught halfway, with whole pieces on disk and whole
/// pieces still missing. `0xff` never occurs in a valid payload byte.
fn write_partial(path: &std::path::Path, len: usize, valid: usize) {
    let mut data: Vec<u8> = (0..len).map(|i| (i % 251) as u8).collect();
    data[valid..].fill(0xff);
    std::fs::write(path, data).expect("write partial payload");
}

fn write_fixture(name: &str, value: &serde_json::Value) -> anyhow::Result<()> {
    let fixtures = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    std::fs::create_dir_all(&fixtures)?;
    std::fs::write(fixtures.join(name), serde_json::to_vec_pretty(value)?)?;
    Ok(())
}

/// Records `tests/fixtures/downloads_registry.json`, what `downloads_list`
/// answers, for the Dart tests over `DownloadView`:
/// `cargo test --test downloads -- --ignored --nocapture`.
///
/// Hermetic like the lifecycle test above -- two torrents built here, no
/// peer, no tracker, no network -- but ignored all the same, because the
/// storage directory and the embedded server are process globals and it
/// cannot share a run with the test that also takes them.
///
/// The three rows are the three shapes a downloads list has to draw: a movie
/// that finished, an episode partway through (its first two pieces are on
/// disk, its last one is not), and an episode with nothing on disk yet. The
/// paths are this recorder's temporary directory; nothing reads them back as
/// a location, only as the string a row shows.
#[test]
#[ignore = "rewrites a committed fixture, and takes the process globals the lifecycle test takes"]
fn record_registry_fixture() -> anyhow::Result<()> {
    let tmp = tempfile::tempdir()?;
    let storage = tmp.path().join("core");
    xtremio_core::env::set_storage_dir(&storage)?;

    let movie_name = "Night.of.the.Living.Dead.1968.1080p.BluRay";
    let movie_file = "night.of.the.living.dead.1968.1080p.mkv";
    let movie_dir = tmp.path().join(movie_name);
    std::fs::create_dir_all(&movie_dir)?;
    write_payload(&movie_dir.join(movie_file), HAVE_LEN);
    write_payload(&movie_dir.join("sample.mkv"), PIECE);
    let (movie_torrent, movie_hash) = real_torrent(&movie_dir);

    let series_name = "Breaking.Bad.S01.1080p.BluRay";
    let first = "Breaking.Bad.S01E01.1080p.mkv";
    let second = "Breaking.Bad.S01E02.1080p.mkv";
    let series_dir = tmp.path().join(series_name);
    std::fs::create_dir_all(&series_dir)?;
    write_payload(&series_dir.join(first), MISSING_LEN);
    write_payload(&series_dir.join(second), HAVE_LEN);
    let (series_torrent, series_hash) = real_torrent(&series_dir);

    // What the torrent engine already has: the whole movie, and the first
    // two pieces of the first episode.
    let cache_root = tmp.path().join("cache").join("server");
    let managed = cache_root.join("rqbit-downloads");
    std::fs::create_dir_all(managed.join(movie_name))?;
    std::fs::copy(
        movie_dir.join(movie_file),
        managed.join(movie_name).join(movie_file),
    )?;
    std::fs::create_dir_all(managed.join(series_name))?;
    write_partial(
        &managed.join(series_name).join(first),
        MISSING_LEN,
        2 * PIECE,
    );

    let base_url = url::Url::parse(&server_start(ServerConfig {
        config_dir: tmp.path().join("server").display().to_string(),
        cache_dir: cache_root.display().to_string(),
        port: 0,
        fallback_to_ephemeral: true,
    })?)?;
    let movie_stats = create_torrent_on_server(&base_url, &movie_torrent);
    let series_stats = create_torrent_on_server(&base_url, &series_torrent);
    let movie_idx = file_index(&movie_stats, movie_file);
    let first_idx = file_index(&series_stats, first);
    let second_idx = file_index(&series_stats, second);

    let trackers = serde_json::json!(["udp://tracker.invalid:1337/announce"]);
    let added = json(&downloads_add(
        serde_json::json!({
            "metaId": "tt0063350",
            "videoId": "tt0063350",
            "type": "movie",
            "name": "Night of the Living Dead",
            "poster": "https://images.metahub.space/poster/medium/tt0063350/img",
            "stream": {
                "infoHash": movie_hash,
                "fileIdx": movie_idx,
                "name": "Torrent",
                "title": "1080p BluRay\n👤 12 💾 1.4 GB",
                "announce": trackers,
                "behaviorHints": {"filename": movie_file, "bingeGroup": "pdm-1080p"},
            },
            "meta": {
                "id": "tt0063350",
                "type": "movie",
                "name": "Night of the Living Dead",
                "poster": "https://images.metahub.space/poster/medium/tt0063350/img",
                "releaseInfo": "1968",
            },
            "streamRequest": {
                "base": "https://public-domain-movies.now.sh/manifest.json",
                "path": {"resource": "stream", "type": "movie", "id": "tt0063350", "extra": []},
            },
            "metaRequest": {
                "base": "https://v3-cinemeta.strem.io/manifest.json",
                "path": {"resource": "meta", "type": "movie", "id": "tt0063350", "extra": []},
            },
        })
        .to_string(),
    )?);
    assert_eq!(added["ok"], true, "{added}");

    for (video_id, file, file_idx, episode) in [
        (
            "tt0903747:1:1",
            first,
            first_idx,
            ("Pilot", 1, 1, "Breaking Bad: Pilot"),
        ),
        (
            "tt0903747:1:2",
            second,
            second_idx,
            (
                "Cat's in the Bag...",
                1,
                2,
                "Breaking Bad: Cat's in the Bag...",
            ),
        ),
    ] {
        let (title, season, number, name) = episode;
        let added = json(&downloads_add(
            serde_json::json!({
                "metaId": "tt0903747",
                "videoId": video_id,
                "type": "series",
                "name": name,
                "poster": "https://images.metahub.space/poster/medium/tt0903747/img",
                "stream": {
                    "infoHash": series_hash,
                    "fileIdx": file_idx,
                    "name": "Torrent",
                    "title": format!("S{season:02}E{number:02} 1080p BluRay"),
                    "announce": trackers,
                    "behaviorHints": {"filename": file},
                },
                "meta": {
                    "id": "tt0903747",
                    "type": "series",
                    "name": "Breaking Bad",
                    "poster": "https://images.metahub.space/poster/medium/tt0903747/img",
                    "videos": [{
                        "id": video_id,
                        "title": title,
                        "season": season,
                        "episode": number,
                    }],
                },
                "streamRequest": {
                    "base": "https://torrentio.invalid/manifest.json",
                    "path": {"resource": "stream", "type": "series", "id": video_id, "extra": []},
                },
                "metaRequest": {
                    "base": "https://v3-cinemeta.strem.io/manifest.json",
                    "path": {"resource": "meta", "type": "series", "id": "tt0903747", "extra": []},
                },
            })
            .to_string(),
        )?);
        assert_eq!(added["ok"], true, "{added}");
    }

    wait_for("tt0063350:tt0063350", "the movie to finish", |entry| {
        entry["state"] == "complete"
    });
    let partial = wait_for("tt0903747:tt0903747:1:1", "the pieces on disk", |entry| {
        entry["downloaded"] == 2 * PIECE
    });
    assert_eq!(partial["state"], "downloading", "{partial}");
    let pending = wait_for("tt0903747:tt0903747:1:2", "the empty episode", |entry| {
        entry["size"] == HAVE_LEN
    });
    assert_eq!(pending["downloaded"], 0, "{pending}");

    let registry = list();
    write_fixture("downloads_registry.json", &registry)?;
    println!("recorded downloads_registry.json: {registry:#}");
    Ok(())
}
