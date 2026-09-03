//! What the server's storage currently costs, and how much room is left.
//!
//! The first question about a playback that misbehaves is whether the
//! device is full: bytes arriving with no verified progress is what failing
//! writes look like, and a cache well over its limit is what a cleaner that
//! reclaims nothing looks like. Neither was anywhere in a report.
//!
//! The numbers are read here rather than in Dart because the app never
//! speaks HTTP to the server and has no business walking its directories
//! from the other side of the FFI (`AGENTS.md`, "The app never speaks HTTP
//! to the embedded server"). The cache root and the limit come from the
//! server's own settings over its library API; the size on disk and the
//! free space are this crate's own measurements, since stream-server
//! exposes neither today.

use std::path::{Path, PathBuf};

use serde::Serialize;

/// How deep the cache walk goes. The torrent cache is
/// `<root>/rqbit-downloads/<info hash>/<the torrent's own layout>`, which
/// is shallow; a bound keeps a symlinked loop or a surprising layout from
/// turning a report into a filesystem crawl.
const MAX_DEPTH: usize = 8;

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
            free_bytes: existing.and_then(|dir| fs4::available_space(dir).ok()),
            total_bytes: existing.and_then(|dir| fs4::total_space(dir).ok()),
        }
    }

    /// Whether this is, as far as free and total space can tell, the same
    /// filesystem as `other`. Used only to leave a second line out of a
    /// report when it would say the same thing twice.
    fn looks_like(&self, other: &Volume) -> bool {
        self.total_bytes == other.total_bytes && self.free_bytes == other.free_bytes
    }
}

/// What the server's storage costs right now.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StorageReport {
    /// The server's `cacheRoot` setting: where the torrent cache lives.
    pub cache_dir: String,
    /// What is under it, in bytes, not counting the downloads directory
    /// when that sits inside it (offline downloads are not cache and the
    /// server's cleaner does not count them either).
    pub cache_used_bytes: u64,
    /// The `cacheSize` setting, or null for "no limit". Bytes.
    pub cache_limit_bytes: Option<u64>,
    /// Whether the walk saw everything it meant to. False when something
    /// could not be read, which makes `cache_used_bytes` a floor rather
    /// than a total.
    pub cache_complete: bool,
    /// The volume the cache is on.
    pub cache_volume: Volume,
    /// Where offline downloads go, and the volume that is on -- null when
    /// the server has no `downloadsDir` set (downloads then live with the
    /// cache), and left out when it is the same filesystem as the cache's,
    /// since a second identical line explains nothing.
    pub downloads_volume: Option<Volume>,
}

/// Reads the report. Blocks: it asks the server for its settings and walks
/// the cache directory, so it belongs on an FRB worker, never on the UI
/// thread. Errors only when the server is not running -- there is no cache
/// root to name then, and inventing one would be a lie about which
/// directory the numbers are from.
pub fn report() -> anyhow::Result<StorageReport> {
    let settings = crate::server::settings()?;
    let cache_dir = PathBuf::from(&settings.cache_root);
    let downloads_dir = settings.downloads_dir.as_ref().map(PathBuf::from);
    let (cache_used_bytes, cache_complete) = directory_size(&cache_dir, downloads_dir.as_deref());
    let cache_volume = Volume::of(&cache_dir);
    let downloads_volume = downloads_dir
        .as_deref()
        .map(Volume::of)
        .filter(|volume| !volume.looks_like(&cache_volume));
    Ok(StorageReport {
        cache_dir: cache_dir.to_string_lossy().to_string(),
        cache_used_bytes,
        cache_limit_bytes: cache_limit_bytes(settings.cache_size),
        cache_complete,
        cache_volume,
        downloads_volume,
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

/// The bytes under `root`, skipping `skip` (the downloads directory, when
/// it is inside), and whether the whole tree could be read.
///
/// Sizes are the files' own lengths, not their allocated blocks: it is the
/// same number the server's cleaner compares against `cacheSize`, which is
/// what makes "17 GB against a 10 GB limit" a statement about the same two
/// things. Symlinks are not followed and not counted, so nothing outside
/// the cache is ever attributed to it and no loop can be walked.
fn directory_size(root: &Path, skip: Option<&Path>) -> (u64, bool) {
    let mut total = 0;
    let mut complete = true;
    let mut stack = vec![(root.to_path_buf(), 0usize)];
    while let Some((dir, depth)) = stack.pop() {
        if skip.is_some_and(|skip| dir == skip) {
            continue;
        }
        let entries = match std::fs::read_dir(&dir) {
            Ok(entries) => entries,
            // A root that is not there yet costs nothing and is not a
            // failure; anything else read the tree short.
            Err(error) if error.kind() == std::io::ErrorKind::NotFound && dir == root => continue,
            Err(_) => {
                complete = false;
                continue;
            }
        };
        for entry in entries {
            let Ok(entry) = entry else {
                complete = false;
                continue;
            };
            let Ok(metadata) = entry.metadata_no_follow() else {
                complete = false;
                continue;
            };
            if metadata.is_symlink() {
                continue;
            }
            if metadata.is_dir() {
                if depth + 1 > MAX_DEPTH {
                    complete = false;
                    continue;
                }
                stack.push((entry.path(), depth + 1));
            } else if metadata.is_file() {
                total += metadata.len();
            }
        }
    }
    (total, complete)
}

/// `symlink_metadata` on a directory entry, spelled as an extension so the
/// walk reads as one thing.
trait EntryMetadata {
    fn metadata_no_follow(&self) -> std::io::Result<std::fs::Metadata>;
}

impl EntryMetadata for std::fs::DirEntry {
    fn metadata_no_follow(&self) -> std::io::Result<std::fs::Metadata> {
        std::fs::symlink_metadata(self.path())
    }
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
    fn sums_the_files_under_a_root_and_skips_the_downloads_dir() {
        let root = tempfile::tempdir().unwrap();
        let cache = root.path().join("cache");
        std::fs::create_dir_all(cache.join("rqbit-downloads/abc")).unwrap();
        std::fs::write(cache.join("rqbit-downloads/abc/piece"), vec![0u8; 1000]).unwrap();
        std::fs::write(cache.join("session.db"), vec![0u8; 24]).unwrap();
        // Offline downloads are not cache: the server's own cleaner walks
        // past them, and a report that counted them would say the cache is
        // over its limit when it is not.
        let downloads = cache.join("downloads");
        std::fs::create_dir_all(&downloads).unwrap();
        std::fs::write(downloads.join("film.mkv"), vec![0u8; 5000]).unwrap();

        assert_eq!(directory_size(&cache, Some(&downloads)), (1024, true));
        assert_eq!(directory_size(&cache, None), (6024, true));
    }

    #[test]
    fn a_root_that_is_not_there_costs_nothing_and_is_not_a_failure() {
        let root = tempfile::tempdir().unwrap();
        assert_eq!(directory_size(&root.path().join("gone"), None), (0, true));
    }

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
