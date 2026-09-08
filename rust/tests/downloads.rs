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

use std::collections::{BTreeMap, BTreeSet};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use xtremio_core::api::core::{core_init, core_shutdown, CoreConfig};
use xtremio_core::api::downloads::{
    downloads_add, downloads_list, downloads_open, downloads_remove,
};
use xtremio_core::api::server::{
    server_settings, server_start, server_update_settings, ServerConfig,
};

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
/// whose name is the folder librqbit will put them in. The files come back
/// in the torrent's own order with their lengths, which is what turns a
/// file name into the range of pieces that hold it.
fn real_torrent(dir: &std::path::Path) -> (Vec<u8>, String, Vec<(String, u64)>) {
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
        let files = torrent
            .as_info()
            .info
            .data
            .files
            .as_ref()
            .expect("a multi-file torrent")
            .iter()
            .map(|file| {
                let name = file
                    .path
                    .iter()
                    .map(|part| String::from_utf8_lossy(part.as_ref()).into_owned())
                    .collect::<Vec<_>>()
                    .join("/");
                (name, file.length)
            })
            .collect();
        (
            torrent.as_bytes().expect("serialize").to_vec(),
            torrent.info_hash().as_string(),
            files,
        )
    })
}

/// Puts the pieces of `name` on disk where the server keeps torrent data:
/// `<root>/rqbit-downloads/.pieces/<info hash>/<piece / 1000>/<piece>`, one
/// file per whole piece, which is the one layout there is -- the streaming
/// cache and a kept download are the same pieces in the same store.
///
/// Both payloads here are exact multiples of [`PIECE`], so every piece of a
/// file holds that file's bytes alone and "this file is complete" means
/// only its own pieces are down.
/// `pieces` caps how many of the file's own pieces are placed, which is
/// what a download caught halfway looks like now: whole pieces on disk and
/// whole pieces missing, with no partial file anywhere.
/// The pieces `name` occupies, in the torrent's own numbering.
fn piece_range(files: &[(String, u64)], name: &str) -> std::ops::Range<u32> {
    let mut offset = 0u64;
    for (file, length) in files {
        if file == name {
            let first = (offset / PIECE as u64) as u32;
            return first..first + (*length / PIECE as u64) as u32;
        }
        offset += length;
    }
    panic!("no file {name} in {files:?}");
}

/// How many of `pieces` are on the disk, which is what "this file's bytes
/// are here" means with a piece store: there is no file to stat.
fn pieces_on_disk(root: &std::path::Path, info_hash: &str, pieces: std::ops::Range<u32>) -> usize {
    let dir = root
        .join("rqbit-downloads")
        .join(".pieces")
        .join(info_hash.to_ascii_lowercase());
    pieces
        .filter(|piece| {
            dir.join((piece / 1000).to_string())
                .join(piece.to_string())
                .is_file()
        })
        .count()
}

fn place_pieces(
    root: &std::path::Path,
    info_hash: &str,
    files: &[(String, u64)],
    name: &str,
    pieces: Option<u32>,
) {
    let mut offset = 0u64;
    for (file, length) in files {
        if file != name {
            offset += length;
            continue;
        }
        let dir = root
            .join("rqbit-downloads")
            .join(".pieces")
            .join(info_hash.to_ascii_lowercase());
        let first = (offset / PIECE as u64) as u32;
        let whole = (*length / PIECE as u64) as u32;
        for index in 0..pieces.unwrap_or(whole).min(whole) {
            let piece = first + index;
            let bucket = dir.join((piece / 1000).to_string());
            std::fs::create_dir_all(&bucket).expect("piece bucket");
            let start = index as usize * PIECE;
            let data: Vec<u8> = (start..start + PIECE).map(|i| (i % 251) as u8).collect();
            std::fs::write(bucket.join(piece.to_string()), data).expect("write piece");
        }
        return;
    }
    panic!("no file {name} in {files:?}");
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
        // Loopback, and only loopback: a client built the plain way picks up
        // `HTTP_PROXY`/`ALL_PROXY` from the environment and reqwest does not
        // exempt 127.0.0.1 from them, so this request to the server this test
        // just started would leave the machine. That is how a test whose whole
        // claim is "no network involved at any point" became a test that hangs
        // for as long as a filtering proxy takes to not answer -- and the bound
        // below is the second half of the same lesson: a local call that has
        // not answered in ten seconds is not going to.
        let client = reqwest::Client::builder()
            .no_proxy()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .expect("HTTP client");
        client
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

/// `GET`s a media URL the way the player does: no bearer token (the media
/// routes are the open ones), no proxy, and a bound short enough that a
/// route which decided to *fetch* rather than read fails the test instead
/// of hanging on a magnet nobody can answer.
fn fetch(url: &url::Url) -> (u16, Vec<u8>) {
    runtime().block_on(async {
        let client = reqwest::Client::builder()
            .no_proxy()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .expect("HTTP client");
        let response = client
            .get(url.clone())
            .send()
            .await
            .expect("GET the media route");
        let status = response.status().as_u16();
        (status, response.bytes().await.expect("body").to_vec())
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
    let (torrent, info_hash, files) = real_torrent(&content);

    let cache_root = tmp.path().join("cache").join("server");
    // What the backend *calls* each file. A name, not a file: nothing is
    // ever written there, and the entry carries it so a listing can show
    // one. The bytes are the pieces placed above.
    let named = cache_root.join("rqbit-downloads").join("Test Show");
    let have_pieces = piece_range(&files, "have.bin");

    let base_url = url::Url::parse(&server_start(ServerConfig {
        config_dir: tmp.path().join("server").display().to_string(),
        cache_dir: cache_root.display().to_string(),
        port: 0,
        fallback_to_ephemeral: true,
    })?)?;
    // After the server is up, not before: a start-up sweep deletes the
    // pieces of every torrent the session does not know about yet, and
    // these are placed for a torrent it is about to be told about.
    place_pieces(&cache_root, &info_hash, &files, "have.bin", None);
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
        named.join("have.bin").to_string_lossy().as_ref(),
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

    // Every key one entry is written with. The Dart side reads these names
    // off `downloads_list`, and its fixture is only a recording of them, so
    // a rename over there has to fail here -- on every `cargo test`, not
    // only when the recorder is run by hand.
    let listed = list();
    let keys: BTreeSet<&str> = listed["items"]["tt-have:tt-have"]
        .as_object()
        .expect("an entry is an object")
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(
        keys,
        BTreeSet::from([
            "metaId",
            "videoId",
            "type",
            "name",
            "poster",
            "stream",
            "infoHash",
            "fileIdx",
            "announce",
            "path",
            "size",
            "downloaded",
            "state",
            "error",
            "createdAt",
            "completedAt",
            "lastPlayedAt",
            "meta",
            "streamRequest",
            "metaRequest",
        ]),
        "the wire names Dart reads"
    );

    let added = add("tt-missing", &info_hash, missing_idx);
    assert_eq!(added["ok"], true, "{added}");
    assert_eq!(
        added["entry"]["path"],
        named.join("missing.bin").to_string_lossy().as_ref(),
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

    // Playing it off the device: there is no file to open -- the bytes are
    // pieces in the server's store -- so a finished download answers the
    // embedded server's media route for its own torrent and file, which
    // reads those pieces with no peer and no network. It records that it
    // was played; nothing else in the registry is touched, and the stamp is
    // on the disk, not only in the answer.
    assert!(complete["lastPlayedAt"].is_null(), "{complete}");
    assert!(
        !named.join("have.bin").exists(),
        "no whole file is ever written at the name the entry carries"
    );
    let opened = json(&downloads_open("tt-have:tt-have".into())?);
    assert_eq!(opened["ok"], true, "{opened}");
    assert_eq!(opened["key"], "tt-have:tt-have");
    let played_url = url::Url::parse(opened["url"].as_str().expect("a URL"))?;
    assert_eq!(
        played_url,
        base_url.join(&format!("{info_hash}/{have_idx}"))?,
        "the URL is this server's media route for the file: {opened}"
    );
    let played_at = opened["entry"]["lastPlayedAt"].clone();
    assert!(played_at.is_string(), "{opened}");
    assert_eq!(
        json(&std::fs::read_to_string(&registry_file)?)["items"]["tt-have:tt-have"]["lastPlayedAt"],
        played_at,
        "the stamp is on disk, not only in the answer"
    );

    // And the URL is fetched, because "it plays off the pieces already
    // here" is a claim about what happens on the wire and a URL string
    // proves none of it. Whole file, byte for byte, from a torrent with no
    // tracker in it and no peer anywhere: every byte came off this disk.
    let (status, body) = fetch(&played_url);
    assert_eq!(status, 200, "the media route serves it");
    assert_eq!(body.len(), HAVE_LEN, "the whole file came back");
    assert_eq!(
        body,
        (0..HAVE_LEN).map(|i| (i % 251) as u8).collect::<Vec<u8>>(),
        "and it is the payload that was written, not something refetched"
    );

    // Everything that is not a whole download on this device is a refusal
    // with a reason, never an exception and never a dead player: an
    // unfinished download and an entry the registry does not have. A
    // refusal stamps nothing.
    let refused = json(&downloads_open("tt-missing:tt-missing".into())?);
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["reason"], "incomplete", "{refused}");
    let refused = json(&downloads_open("tt-nothing:tt-nothing".into())?);
    assert_eq!(refused["reason"], "unknown", "{refused}");

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

    // A row saying `complete` is not on its own a reason to hand that URL
    // out, and this is the case that proves it: the pin is dropped while
    // the pieces are left where they are (`deleteFiles: false`), which is
    // the shape of a root that moved out from under a download -- the
    // registry still says `complete` and the session holds nothing.
    //
    // Handing back a URL here would not 404. On loopback the media route
    // creates what it is asked for, so it would start a magnet add from a
    // bare info hash with no trackers on it and block until the metadata
    // timeout, behind a screen that says the film is on the device.
    //
    // The ticker is running (tt-missing is unfinished) and cannot correct
    // this row either: `refresh` folds in the rows the server *lists*, and
    // with no pin for (info_hash, have_idx) there is nothing to match.
    xtremio_core::server::unpin_download(&info_hash, have_idx, false)?;
    let refused = json(&downloads_open("tt-have:tt-have".into())?);
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["reason"], "notHeld", "{refused}");
    assert!(
        refused["url"].is_null(),
        "and nothing to play it with: {refused}"
    );
    assert_eq!(
        list()["items"]["tt-have:tt-have"]["state"],
        "complete",
        "the row itself is untouched -- the refusal is what the server holds"
    );

    // What corrects the row is the boot reconciliation, and what it must
    // not do is fetch the film again: the entry is marked gone, with no
    // bytes and no completion date, and no pin is issued for it. A row that
    // went back to `queued` would be a whole download restarted on whatever
    // connection the device is on, asked for by nobody.
    xtremio_core::downloads::reconcile_pins();
    let gone = list()["items"]["tt-have:tt-have"].clone();
    assert_eq!(gone["state"], "gone", "{gone}");
    assert_eq!(gone["downloaded"], 0, "{gone}");
    assert!(gone["completedAt"].is_null(), "{gone}");
    assert!(gone["error"].is_string(), "with a reason on it: {gone}");
    let pins = xtremio_core::server::downloads()?;
    assert!(
        pins.iter().all(|pin| pin.file_idx != have_idx),
        "and nothing was re-pinned to get it back: {pins:?}"
    );
    let refused = json(&downloads_open("tt-have:tt-have".into())?);
    assert_eq!(refused["reason"], "incomplete", "{refused}");

    // And it stays inert: the *next* boot must not pick it up either. A
    // gone row that counted as unfinished would be re-pinned by every boot
    // from here on, which is the same unasked-for download arriving a
    // launch later.
    xtremio_core::downloads::reconcile_pins();
    assert_eq!(
        list()["items"]["tt-have:tt-have"]["state"],
        "gone",
        "a second boot leaves it where the first one put it"
    );
    let pins = xtremio_core::server::downloads()?;
    assert!(
        pins.iter().all(|pin| pin.file_idx != have_idx),
        "and pins nothing for it: {pins:?}"
    );

    // The pieces were never deleted, so what comes next is a re-pin of a
    // file that is all there -- and the row has to come back with it.
    assert_eq!(
        pieces_on_disk(&cache_root, &info_hash, have_pieces.clone()),
        have_pieces.len(),
        "the bytes are still on disk; it is the pin that went"
    );

    // And what the re-add has to be able to come back from: the pin gone
    // with the pieces left where they are.
    let readded = add("tt-have", &info_hash, have_idx);
    assert_eq!(readded["ok"], true, "the download comes back: {readded}");
    wait_for("tt-have:tt-have", "have.bin to be whole again", |entry| {
        entry["state"] == "complete"
    });

    // Unpinning without deleting keeps the bytes and forgets the entry.
    let removed = json(&downloads_remove("tt-have:tt-have".into(), false)?);
    assert_eq!(
        removed,
        serde_json::json!({"removed": true, "unpinned": true, "deletedFiles": false})
    );
    assert_eq!(
        pieces_on_disk(&cache_root, &info_hash, have_pieces.clone()),
        have_pieces.len(),
        "the pieces stay"
    );
    assert_eq!(list()["items"]["tt-have:tt-have"], serde_json::Value::Null);

    // Removing something the registry does not have is not an error.
    let removed = json(&downloads_remove("tt-have:tt-have".into(), true)?);
    assert_eq!(removed["removed"], false, "{removed}");
    assert_eq!(
        pieces_on_disk(&cache_root, &info_hash, have_pieces.clone()),
        have_pieces.len(),
        "and touches nothing"
    );

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
    assert_eq!(
        pieces_on_disk(&cache_root, &info_hash, have_pieces.clone()),
        have_pieces.len(),
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
    assert_eq!(
        pieces_on_disk(&cache_root, &info_hash, have_pieces.clone()),
        have_pieces.len(),
        "without the bytes"
    );

    // With `deleteFiles` the bytes go. The other file of the same torrent is
    // still pinned, so only this one is deleted and the torrent lives on.
    add("tt-have", &info_hash, have_idx);
    let removed = json(&downloads_remove("tt-have:tt-have".into(), true)?);
    assert_eq!(removed["removed"], true, "{removed}");
    assert_eq!(removed["deletedFiles"], true, "{removed}");
    assert_eq!(
        pieces_on_disk(&cache_root, &info_hash, have_pieces.clone()),
        0,
        "its pieces are gone"
    );
    let pins = xtremio_core::server::downloads()?;
    assert!(
        pins.iter().any(|pin| pin.file_idx == missing_idx),
        "the still-pinned file of the same torrent is untouched: {pins:?}"
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

    // A refused pin leaves the row that was there: the registry is written
    // before the pin is asked for, so a refusal has to put things back, and
    // a title with a download must not lose it to a second stream the
    // server would not take.
    let before = list()["items"]["tt-missing:tt-missing"].clone();
    let refused = add("tt-missing", &info_hash, 99);
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(
        list()["items"]["tt-missing:tt-missing"],
        before,
        "the row the refused pin would have replaced is as it was"
    );

    // The two windows a kill can land in, each reproduced as what the disk
    // holds afterwards, and each finished by what the next boot runs first
    // (`reconcile_pins` is what `core_init` starts behind itself).
    //
    // Removing: the row is marked before the server is asked and dropped
    // after it answers. Died in between, the row says a removal was meant,
    // and the boot carries it out -- whether or not the unpin had happened
    // -- instead of re-pinning a download the user cancelled and
    // restarting it on metered data.
    for (variant, unpinned_before_the_kill) in [("after the unpin", true), ("before it", false)] {
        let key = format!("tt-doomed-{unpinned_before_the_kill}");
        add(&key, &info_hash, have_idx);
        let row = format!("{key}:{key}");
        xtremio_core::downloads::update(|registry| {
            registry
                .items
                .get_mut(&row)
                .expect("the doomed row")
                .pending_removal = Some(xtremio_core::downloads::PendingRemoval {
                delete_files: false,
            });
            Ok(())
        })?;
        assert!(
            list()["items"][&row].is_null(),
            "a row on its way out is not listed ({variant})"
        );
        if unpinned_before_the_kill {
            xtremio_core::server::unpin_download(&info_hash, have_idx, false)?;
        }
        xtremio_core::downloads::reconcile_pins();
        let pins = xtremio_core::server::downloads()?;
        assert!(
            pins.iter().all(|pin| pin.file_idx != have_idx),
            "the cancelled download was not restarted ({variant}): {pins:?}"
        );
        assert!(
            !xtremio_core::downloads::load()?.items.contains_key(&row),
            "and the row is gone ({variant})"
        );
    }

    // Swapping: the row names the new file before the new pin is taken and
    // remembers the old one under `replaces` until the new pin is in. Died
    // between the row and the pin, the boot pins what the row names and
    // then releases what it used to -- so neither window of a swap leaves a
    // pin nothing names, nor a title with neither file wanted.
    add("tt-swap2", &info_hash, have_idx);
    xtremio_core::downloads::update(|registry| {
        let entry = registry
            .items
            .get_mut("tt-swap2:tt-swap2")
            .expect("the swapping row");
        entry.file_idx = missing_idx;
        entry.state = xtremio_core::downloads::State::Queued;
        entry.replaces = Some(xtremio_core::downloads::Replaced {
            info_hash: info_hash.clone(),
            file_idx: have_idx,
        });
        Ok(())
    })?;
    let pins = xtremio_core::server::downloads()?;
    assert!(
        pins.iter().any(|pin| pin.file_idx == have_idx),
        "the old pin is still the server's before the boot: {pins:?}"
    );
    xtremio_core::downloads::reconcile_pins();
    let pins = xtremio_core::server::downloads()?;
    assert_eq!(pins.len(), 1, "the swap is finished: {pins:?}");
    assert_eq!(pins[0].file_idx, missing_idx, "{pins:?}");
    assert!(
        xtremio_core::downloads::load()?.items["tt-swap2:tt-swap2"]
            .replaces
            .is_none(),
        "and the debt is paid"
    );
    xtremio_core::downloads::update(|registry| {
        registry.items.remove("tt-swap2:tt-swap2");
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
    let rows = event["progress"].as_array().expect("the rows that moved");
    assert_eq!(rows.len(), 1, "only what changed is pushed: {event}");
    assert_eq!(rows[0]["key"], "tt-missing:tt-missing", "{event}");
    assert_eq!(
        rows[0]["downloaded"], 0,
        "the live number replaced the bogus one: {event}"
    );
    assert!(
        rows[0]["meta"].is_null() && rows[0]["stream"].is_null(),
        "and a tick carries what moves, not the whole entry: {event}"
    );

    // Re-pinning at init: the server forgets a pin (as a purged cache dir or
    // an absent downloads volume would make it), and the registry puts it
    // back.
    xtremio_core::server::unpin_download(&info_hash, missing_idx, false)?;
    assert!(
        xtremio_core::server::downloads()?.is_empty(),
        "the pin is gone from the server"
    );
    xtremio_core::downloads::reconcile_pins();
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

    // Where torrent data lives is one setting, `cacheRoot`, and the app
    // reaches it the way it reaches every other one. It is the only
    // validated key: a path the server cannot use fails the whole update
    // rather than being ignored, and one it can use is created on the spot
    // and stored resolved.
    let settings = json(&server_settings()?);
    assert_eq!(
        settings["cacheRoot"],
        stream_server::resolved_path(&cache_root)
            .to_string_lossy()
            .as_ref(),
        "the root starts as the directory the app configured: {settings}"
    );
    assert_eq!(
        settings["downloadsDir"],
        serde_json::Value::Null,
        "and there is no second location to be distinct from: {settings}"
    );
    let error = server_update_settings(r#"{"cacheRoot":"relative/dir"}"#.into()).unwrap_err();
    assert!(error.to_string().contains("absolute"), "{error}");
    assert_eq!(
        json(&server_settings()?)["cacheRoot"],
        settings["cacheRoot"],
        "a root the server refused changed nothing"
    );
    let elsewhere = tmp.path().join("elsewhere");
    let patched = json(&server_update_settings(
        serde_json::json!({ "cacheRoot": elsewhere.display().to_string() }).to_string(),
    )?);
    assert_eq!(
        patched["cacheRoot"],
        stream_server::resolved_path(&elsewhere)
            .to_string_lossy()
            .as_ref(),
        "{patched}"
    );
    assert!(elsewhere.is_dir(), "created on the spot");
    // Put it back: the running session is still on the old root (librqbit
    // cannot be moved), and the rest of this test downloads through it.
    server_update_settings(
        serde_json::json!({ "cacheRoot": cache_root.display().to_string() }).to_string(),
    )?;

    // Nothing about a folder is written down beside the entries any more.
    let on_disk = json(&std::fs::read_to_string(&registry_file)?);
    assert_eq!(
        on_disk
            .as_object()
            .map(|file| file.keys().cloned().collect::<Vec<_>>()),
        Some(vec!["items".to_string(), "version".to_string()]),
        "the registry holds entries and a version, and nothing else: {on_disk}"
    );

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

    // A removal the server cannot be asked about raises and removes nothing
    // -- and leaves an ordinary row behind, not one marked as leaving, which
    // the next boot would otherwise finish for a request that failed.
    assert!(downloads_remove("tt-missing:tt-missing".into(), false).is_err());
    let reloaded = xtremio_core::downloads::load()?;
    let entry = &reloaded.items["tt-missing:tt-missing"];
    assert!(
        entry.pending_removal.is_none(),
        "a refused removal marks nothing: {entry:?}"
    );
    Ok(())
}

/// Rewrites the two things a recording captures that say nothing about the
/// contract and differ on every run: the fresh temporary directory in every
/// `path`, and the wall clock in `createdAt`/`completedAt`. With them fixed,
/// re-recording an unchanged registry leaves the file byte-identical -- and
/// re-recording is safe, instead of turning the Dart tests that quote a path
/// or a date red for a change that touched neither.
///
/// The stamps go up in entry order, because that is what a list sorted
/// newest-first has to sort back; the sub-second digits are the server's own
/// nanosecond precision, which a Dart `DateTime` truncates to microseconds.
fn stabilize(registry: &mut serde_json::Value, tmp: &std::path::Path) {
    const ROOT: &str = "/downloads";
    let tmp = tmp.display().to_string();
    let Some(items) = registry
        .get_mut("items")
        .and_then(serde_json::Value::as_object_mut)
    else {
        return;
    };
    for (index, (_key, entry)) in items.iter_mut().enumerate() {
        if let Some(path) = entry.get("path").and_then(serde_json::Value::as_str) {
            entry["path"] = serde_json::Value::String(path.replace(&tmp, ROOT));
        }
        let stamp = format!("2026-01-01T00:00:{index:02}.123456789Z");
        for key in ["createdAt", "completedAt"] {
            if entry.get(key).is_some_and(serde_json::Value::is_string) {
                entry[key] = serde_json::Value::String(stamp.clone());
            }
        }
    }
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
/// paths are fixed by [`stabilize`]; nothing reads them back as a location,
/// only as the string a row shows.
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
    let (movie_torrent, movie_hash, movie_files) = real_torrent(&movie_dir);

    let series_name = "Breaking.Bad.S01.1080p.BluRay";
    let first = "Breaking.Bad.S01E01.1080p.mkv";
    let second = "Breaking.Bad.S01E02.1080p.mkv";
    let series_dir = tmp.path().join(series_name);
    std::fs::create_dir_all(&series_dir)?;
    write_payload(&series_dir.join(first), MISSING_LEN);
    write_payload(&series_dir.join(second), HAVE_LEN);
    let (series_torrent, series_hash, series_files) = real_torrent(&series_dir);

    // What the torrent engine already has: the whole movie, and the first
    // two pieces of the first episode.
    let cache_root = tmp.path().join("cache").join("server");

    let base_url = url::Url::parse(&server_start(ServerConfig {
        config_dir: tmp.path().join("server").display().to_string(),
        cache_dir: cache_root.display().to_string(),
        port: 0,
        fallback_to_ephemeral: true,
    })?)?;
    // After the server is up: its start-up sweep takes the pieces of any
    // torrent the session does not know about.
    place_pieces(&cache_root, &movie_hash, &movie_files, movie_file, None);
    place_pieces(&cache_root, &series_hash, &series_files, first, Some(2));
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

    let mut registry = list();
    stabilize(&mut registry, tmp.path());
    write_fixture("downloads_registry.json", &registry)?;
    println!("recorded downloads_registry.json: {registry:#}");
    Ok(())
}
