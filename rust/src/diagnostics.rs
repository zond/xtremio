//! What this binary was built from, for the Diagnostics screen.
//!
//! A bug report from a phone is worth little without the revisions behind
//! it, and the two that matter -- the embedded stream-server and
//! stremio-core -- are git pins rather than versions, so Cargo has no
//! environment variable for them. The manifest is embedded at compile time
//! instead and read back here, which cannot drift from what was actually
//! built.

/// This crate's own `Cargo.toml`, as it was when this binary was compiled.
const MANIFEST: &str = include_str!("../Cargo.toml");

/// The build facts the app puts at the top of a copied diagnostics report.
pub struct BuildInfo {
    /// `xtremio_core`'s crate version.
    pub core_version: String,
    /// The git revision the embedded stream-server is pinned to.
    pub stream_server_rev: Option<String>,
    /// The git revision stremio-core is pinned to.
    pub stremio_core_rev: Option<String>,
}

pub fn build_info() -> BuildInfo {
    BuildInfo {
        core_version: env!("CARGO_PKG_VERSION").to_owned(),
        stream_server_rev: pinned_rev(MANIFEST, "stream-server"),
        stremio_core_rev: pinned_rev(MANIFEST, "stremio-core"),
    }
}

/// The `rev = "..."` of the dependency line naming `name` in `manifest`, or
/// nothing when that dependency stops being a git pin.
fn pinned_rev(manifest: &str, name: &str) -> Option<String> {
    let prefix = format!("{name} = ");
    let line = manifest
        .lines()
        .find(|line| line.trim_start().starts_with(&prefix))?;
    let rev = line.split_once("rev = \"")?.1.split('"').next()?;
    Some(rev.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_pins_out_of_the_embedded_manifest() {
        let info = build_info();
        assert_eq!(info.core_version, env!("CARGO_PKG_VERSION"));
        for rev in [&info.stream_server_rev, &info.stremio_core_rev] {
            let rev = rev.as_deref().expect("a git pin");
            assert_eq!(rev.len(), 40, "{rev}");
            assert!(rev.chars().all(|c| c.is_ascii_hexdigit()), "{rev}");
        }
        // The patch section's own `stremio-watched-bitfield` is a path
        // dependency with no rev, and naming it must not find one.
        assert_eq!(pinned_rev(MANIFEST, "stremio-watched-bitfield"), None);
        assert_eq!(pinned_rev(MANIFEST, "not-a-dependency"), None);
    }
}
