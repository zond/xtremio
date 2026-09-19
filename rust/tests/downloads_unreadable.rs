//! What a server restart does to the bytes of downloads this build cannot
//! read.
//!
//! The server keeps no pin record of its own: every start sweeps the piece
//! store of everything the pin set it is handed does not claim, and that
//! set is read off the downloads registry (`downloads::pins`). So a
//! registry entry that is left out of the set -- a download a newer build
//! wrote, in a shape this one does not know -- is a film deleted by the
//! next launch, and a registry file that reads as "empty" is every film
//! deleted. This restarts a real server over such registries and looks at
//! the disk.
//!
//! The server and the storage directory are process globals, so it is one
//! test function in a binary of its own.

use xtremio_core::api::server::{server_start, server_stop, ServerConfig};

/// A torrent the registry names in a way this build cannot parse.
const NEWER: &str = "1111111111111111111111111111111111111111";
/// A torrent nothing names: the sweep's to take whenever it runs, which is
/// what shows that it did.
const UNNAMED: &str = "2222222222222222222222222222222222222222";

/// A piece of `info_hash` in the store, the way the server lays one out.
fn place_piece(cache_root: &std::path::Path, info_hash: &str) -> std::path::PathBuf {
    let piece = cache_root
        .join("rqbit-downloads")
        .join(".pieces")
        .join(info_hash)
        .join("0")
        .join("0");
    std::fs::create_dir_all(piece.parent().expect("a bucket")).expect("piece bucket");
    std::fs::write(&piece, [7u8; 16]).expect("write piece");
    piece
}

#[test]
fn a_restart_keeps_the_bytes_of_downloads_this_build_cannot_read() -> anyhow::Result<()> {
    let tmp = tempfile::tempdir()?;
    let storage = tmp.path().join("core");
    std::fs::create_dir_all(&storage)?;
    xtremio_core::env::set_storage_dir(&storage)?;
    let registry_file = storage.join("downloads.json");
    let cache_root = tmp.path().join("cache").join("server");
    let config = || ServerConfig {
        config_dir: tmp.path().join("server").display().to_string(),
        cache_dir: cache_root.display().to_string(),
    };
    // One launch over `registry`, with a piece of each torrent on disk going
    // in. Answers which of the two are still there once the server is up.
    let restart = |registry: &str| -> anyhow::Result<(bool, bool)> {
        std::fs::write(&registry_file, registry)?;
        let newer = place_piece(&cache_root, NEWER);
        let unnamed = place_piece(&cache_root, UNNAMED);
        server_start(config())?;
        let kept = (newer.is_file(), unnamed.is_file());
        server_stop()?;
        Ok(kept)
    };

    // A newer build's entry: no `metaId` and a state this build has never
    // heard of, so it does not parse -- but the file it names does, and the
    // launch is told to keep it. The unnamed torrent goes, so the sweep ran.
    let kept = restart(&format!(
        r#"{{"version":9,"items":{{"new:new":{{"videoId":"new","infoHash":"{NEWER}",
           "fileIdx":0,"state":"archived"}}}}}}"#
    ))?;
    assert_eq!(kept, (true, false), "the newer build's film survives");

    // One whose file cannot be told at all: the set cannot be known, so the
    // server is told nothing and keeps everything.
    let kept = restart(&format!(
        r#"{{"version":9,"items":{{"new:new":{{"metaId":"new","videoId":"new",
           "infoHash":"{NEWER}","fileIdx":{{"of":2}}}}}}}}"#
    ))?;
    assert_eq!(kept, (true, true), "an unknowable set sweeps nothing");

    // A file whose `items` is not an object is not an empty registry.
    let kept = restart(&format!(
        r#"{{"version":2,"items":[{{"metaId":"new","videoId":"new","infoHash":"{NEWER}"}}]}}"#
    ))?;
    assert_eq!(kept, (true, true), "a file of another shape sweeps nothing");
    assert!(
        std::fs::read_to_string(&registry_file)?.contains(r#""items":["#),
        "and it is left as it was"
    );

    // And the sweep this all guards against is real: a registry that reads
    // and names neither takes both.
    let kept = restart(r#"{"version":1,"items":{}}"#)?;
    assert_eq!(kept, (false, false));
    Ok(())
}
