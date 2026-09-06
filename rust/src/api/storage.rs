//! FRB surface for one question the player has to be able to ask on its
//! own: how much room is left on the volume it is about to write a cache
//! file to.
//!
//! Everything else about storage in this app is a question *about the
//! embedded server* -- `server_storage_report` walks the server's cache
//! root and needs the server running to name it. The player's demuxer cache
//! is neither: it is written by libmpv into the app's own cache directory,
//! for streams that need never have gone near the server (an addon's own
//! HTTP URL, an offline `file://`). So this is a free-space reading and
//! nothing else, and it answers with the server stopped.

use std::path::Path;

use crate::guard::guarded_ok;

/// Bytes the volume holding `path` will still give an unprivileged writer,
/// or `null` when that cannot be read.
///
/// This is `statvfs`'s `f_frsize * f_bavail` through `fs4`
/// (`crate::storage::free_bytes`) -- `df`'s Available column, and the same
/// call the embedded server's cache cleaner caps itself with, so the two
/// budgets on one device are measured against one number.
///
/// `path` need not exist yet: the deepest ancestor that does is what gets
/// asked, since a directory nobody has created is still on a volume.
///
/// `null` means unreadable, not full. A caller must leave whatever it would
/// have done alone rather than treat it as no room.
///
/// Signed, because `u64` crosses FRB as a Dart `BigInt` and free space is
/// arithmetic the player does on every tick; `i64` crosses as
/// `PlatformInt64`, which is a plain `int` on every platform this app is
/// built for. A volume with more than eight exabytes free would read as
/// unreadable, which leaves the caller doing nothing -- the same answer it
/// would sensibly give to that much room anyway.
///
/// One `statvfs`. Cheap enough to ask on a timer -- unlike
/// `server_cache_usage`, which is a directory walk -- but it is still a
/// syscall that can block on a slow filesystem, so it stays on an FRB
/// worker rather than being `#[frb(sync)]`.
pub fn volume_free_bytes(path: String) -> anyhow::Result<Option<i64>> {
    guarded_ok(|| {
        crate::storage::free_bytes(Path::new(&path)).and_then(|bytes| i64::try_from(bytes).ok())
    })
}
