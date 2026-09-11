//! The one order `core_init` must keep, in a process of its own.
//!
//! The server is handed the pin set at startup, and that set is read off the
//! downloads registry under `storage_dir`. `core_init` used to start the
//! server *before* setting that directory, so every real boot read no
//! registry, named no pins, and the server kept every torrent's data for
//! the life of the process: the launch sweep skipped, every torrent counted
//! as pinned, no owner ever reclaiming a byte. The integration test that
//! covered pins set the directory itself before calling in, which is the
//! one step the app does not take -- so this test does not either, and runs
//! in its own binary so no earlier test can have set it.
//!
//! What is observable is the launch sweep: handed a set (even an empty one)
//! it removes every piece directory the set does not claim before the
//! session opens; handed `None` it removes nothing.

use xtremio_core::api::core::{core_init, core_shutdown, CoreConfig};
use xtremio_core::api::server::ServerConfig;

const ORPHAN: &str = "1111111111111111111111111111111111111111";

#[test]
fn the_server_is_handed_the_pins_the_registry_names() -> anyhow::Result<()> {
    let tmp = tempfile::tempdir()?;
    let storage = tmp.path().join("storage");
    let cache_root = tmp.path().join("cache");
    std::fs::create_dir_all(&storage)?;

    // A registry that names nothing: an empty set, which is not "nobody told
    // me". Handed to the server, it claims no torrent and the sweep takes
    // every piece directory it finds.
    std::fs::write(
        storage.join("downloads.json"),
        br#"{"version":1,"items":{}}"#,
    )?;
    // Piece data of a torrent nothing claims, left by a previous process.
    let orphan = cache_root
        .join("rqbit-downloads")
        .join(".pieces")
        .join(ORPHAN)
        .join("0");
    std::fs::create_dir_all(&orphan)?;
    std::fs::write(orphan.join("0"), [7u8; 4096])?;

    // Exactly as the app boots: nothing has set the storage directory.
    assert!(xtremio_core::env::storage_dir().is_none());
    core_init(CoreConfig {
        storage_dir: storage.display().to_string(),
        cache_dir: tmp.path().join("core-cache").display().to_string(),
        server: Some(ServerConfig {
            config_dir: tmp.path().join("server").display().to_string(),
            cache_dir: cache_root.display().to_string(),
            port: 0,
            fallback_to_ephemeral: true,
        }),
    })?;

    assert!(
        !orphan.exists(),
        "the launch sweep ran, so the server was handed a pin set and not `None`"
    );
    core_shutdown()?;
    Ok(())
}
