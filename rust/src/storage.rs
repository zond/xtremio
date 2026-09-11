//! What the server's storage currently costs, and how much room is left.
//!
//! The first question about a playback that misbehaves is whether the
//! device is full: bytes arriving with no verified progress is what failing
//! writes look like, and a cache well over its limit is what a server that
//! reclaims nothing looks like. Neither was anywhere in a report.
//!
//! The numbers are read here rather than in Dart because the app never
//! speaks HTTP to the server and has no business walking its directories
//! from the other side of the FFI (`AGENTS.md`, "The app never speaks HTTP
//! to the embedded server"). The cache root, the limit and what the cache
//! occupies come from the server over its library API; the free and total
//! space of the volume are this crate's own measurements.

use std::path::{Path, PathBuf};

use serde::Serialize;

/// One filesystem's room, as `statvfs` sees it. `None` for a path that
/// cannot be asked about (it is gone, or the platform will not say), which
/// the report shows as unknown rather than as zero -- a volume nobody could
/// measure is not a full one.
#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Volume {
    pub path: String,
    pub free_bytes: Option<u64>,
    pub total_bytes: Option<u64>,
}

impl Volume {
    fn of(path: &Path) -> Self {
        // Ask about the deepest ancestor that exists: a cache root the
        // server has not created yet still sits on a volume.
        let existing = existing_ancestor(path);
        Self {
            path: path.to_string_lossy().to_string(),
            free_bytes: free_bytes(path),
            total_bytes: existing.and_then(|dir| fs4::total_space(dir).ok()),
        }
    }
}

/// What the server's storage costs right now.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StorageReport {
    /// The server's `cacheRoot` setting: **the one root**, where every
    /// byte a torrent puts on this device lives -- the piece store the
    /// streaming cache and the kept downloads share, the session's own
    /// records, and what `/proxy` cached.
    pub cache_dir: String,
    /// What the cache occupies, in bytes: the server's own figure, the
    /// `totalBytes` of `server_cache_usage` taken on this call. The storage
    /// screen shows the two side by side, and two counts of one cache that
    /// disagree by construction are a contradiction on the one screen that
    /// exists to explain it.
    pub cache_used_bytes: u64,
    /// The `cacheSize` setting, or null for "no limit". Bytes.
    pub cache_limit_bytes: Option<u64>,
    /// The volume the root is on. There is one, so there is one line.
    pub cache_volume: Volume,
}

/// Reads the report. Blocks: it asks the server for its settings and its
/// usage, so it belongs on an FRB worker, never on the UI thread. Errors
/// only when the server is not running -- there is no cache root to name
/// then, and inventing one would be a lie about which directory the
/// numbers are from.
///
/// The size is not walked for. The server counts what its owners hold
/// without listing the tree, and a walk here was a `stat` of every piece
/// file -- tens of thousands on a phone -- to arrive at a second figure
/// that could not agree with the first: it counted apparent lengths where
/// the server counts allocated blocks, and whatever lies under the root
/// that no owner holds.
pub fn report() -> anyhow::Result<StorageReport> {
    let settings = crate::server::settings()?;
    let usage = crate::server::cache_usage()?;
    let cache_dir = PathBuf::from(&settings.cache_root);
    Ok(StorageReport {
        cache_dir: cache_dir.to_string_lossy().to_string(),
        cache_used_bytes: usage.total_bytes,
        cache_limit_bytes: cache_limit_bytes(settings.cache_size),
        cache_volume: Volume::of(&cache_dir),
    })
}

/// The `cacheSize` setting as a byte cap: `None` (and a negative or
/// non-finite value) is "no limit", which is what the server's own
/// `cache_size_bytes` saturates to.
fn cache_limit_bytes(cache_size: Option<f64>) -> Option<u64> {
    match cache_size {
        Some(bytes) if bytes.is_finite() && bytes >= 0.0 => Some(bytes as u64),
        _ => None,
    }
}

/// Bytes the volume holding `path` will still give an unprivileged writer,
/// or `None` when that cannot be read (the path is on nothing that exists,
/// or the platform will not say).
///
/// `fs4::available_space` is `statvfs`'s `f_frsize * f_bavail` -- `df`'s
/// Available column, root's reserve excluded -- which is the same call and
/// the same crate the embedded server's cache cleaner caps itself with
/// (`server/src/cache_cleaner.rs`, `CACHE_FREE_SPACE_FLOOR`). Deliberately
/// the same one: a report puts this number next to the floor the cleaner
/// is enforcing, and two answers to "how much room is left" taken from
/// different places would drift apart on the one screen that exists to
/// explain a device with no room left.
///
/// **It sees what no directory can.** It counts the volume's free blocks,
/// so a file that was unlinked while some process still holds it open
/// costs room here and has no name under any directory. Measured rather
/// than assumed (`free_space_counts_a_file_no_directory_can_see`), because
/// it used to be the whole point: mpv unlinked its demuxer cache the
/// instant it created it (`demuxer-cache-unlink-files=immediate`), and 256 MiB
/// written through such an fd moved `f_frsize * f_bavail` by 268439552
/// bytes, every one of which came back when the fd closed. **That writer
/// is gone.** The player keeps no disk cache at all now, so there is one
/// budget on this device -- the server's cache against `cacheSize` -- and
/// a gap between the two readings is somebody else's deleted-but-open
/// file rather than ours. Which is still worth knowing when a report's
/// two numbers disagree, and is why the measurement stays.
///
/// `None`, never 0, on failure: a volume nobody could measure is not a
/// full one, and a report that showed it as full would accuse a device
/// whose filesystem simply will not answer.
pub fn free_bytes(path: &Path) -> Option<u64> {
    // Ask about the deepest ancestor that exists: a directory nobody has
    // created yet still sits on a volume.
    existing_ancestor(path).and_then(|dir| fs4::available_space(dir).ok())
}

/// The deepest existing ancestor of `path`, itself included. A volume can
/// be asked about through a directory that is on it; a path that is not
/// there yet has to be asked about through its parent.
fn existing_ancestor(path: &Path) -> Option<&Path> {
    let mut candidate = Some(path);
    while let Some(dir) = candidate {
        if dir.exists() {
            return Some(dir);
        }
        candidate = dir.parent();
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_limit_is_the_setting_and_none_means_no_limit() {
        assert_eq!(
            cache_limit_bytes(Some(10.0 * 1024.0 * 1024.0 * 1024.0)),
            Some(10_737_418_240)
        );
        assert_eq!(cache_limit_bytes(Some(0.0)), Some(0));
        assert_eq!(cache_limit_bytes(None), None);
        assert_eq!(cache_limit_bytes(Some(f64::NAN)), None);
        assert_eq!(cache_limit_bytes(Some(-1.0)), None);
    }

    /// Why a free-space reading and a directory walk can disagree at all:
    /// a file unlinked the instant it is created is invisible to any walk,
    /// but its blocks are held until the fd closes and `f_bavail` counts
    /// them the whole time. Driven here rather than read off a manual,
    /// with the `open`/`unlink`/write order mpv used when it was the one
    /// doing this -- it no longer is, and the property outlives it: the
    /// two numbers in a storage report are not measuring the same thing,
    /// and this is the shape of the difference.
    ///
    /// The tolerance is half of what is written, in both directions,
    /// because the volume is shared with whatever else the machine is
    /// doing: only another process moving more than 16 MiB the *opposite*
    /// way inside this test's few hundred milliseconds could break it.
    #[cfg(unix)]
    #[test]
    fn free_space_counts_a_file_no_directory_can_see() {
        const WRITTEN: u64 = 32 * 1024 * 1024;
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("demuxer-cache");
        let mut file = std::fs::File::create(&path).unwrap();
        std::fs::remove_file(&path).unwrap();
        assert!(!path.exists(), "the cache file has no name any more");

        let before = free_bytes(root.path()).expect("a tempdir is on a volume");
        std::io::Write::write_all(&mut file, &vec![0u8; WRITTEN as usize]).unwrap();
        file.sync_all().unwrap();
        let during = free_bytes(root.path()).unwrap();
        assert!(
            during + WRITTEN / 2 < before,
            "an unlinked file still costs the volume: {before} -> {during}"
        );

        drop(file);
        let after = free_bytes(root.path()).unwrap();
        assert!(
            after > during + WRITTEN / 2,
            "closing the fd gives the blocks back: {during} -> {after}"
        );
    }

    #[test]
    fn a_path_on_no_volume_at_all_reads_as_unknown_rather_than_full() {
        // Relative, and nothing of that name in the working directory: the
        // ancestor walk runs out before it finds anything to ask about.
        // Unreadable must not be reported as zero -- a caller would then
        // refuse a cache on a device that has plenty of room.
        assert_eq!(free_bytes(Path::new("xtremio-no-such-path-4c1f")), None);
    }

    #[test]
    fn a_volume_is_asked_about_through_the_deepest_directory_that_exists() {
        let root = tempfile::tempdir().unwrap();
        let missing = root.path().join("not/here/yet");
        assert_eq!(existing_ancestor(&missing), Some(root.path()));
        let volume = Volume::of(&missing);
        assert_eq!(volume.path, missing.to_string_lossy());
        assert!(volume.total_bytes.is_some_and(|total| total > 0));
    }
}
