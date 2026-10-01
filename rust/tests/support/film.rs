//! What the FFmpeg tests share: the libmpv to load and the film to read.
//! A test binary takes it with `#[path = "support/film.rs"] mod film;`.

#![allow(dead_code)]

use std::path::Path;

/// How long the film is: keys every 2 s (B-frames between), so 3 s
/// segments' cuts fall on keys that are not on the grid.
pub const FILM_SECONDS: u32 = 13;

/// The name libmpv is loaded by: `XTREMIO_LIBMPV`, else the soname.
pub fn libmpv_name() -> String {
    std::env::var("XTREMIO_LIBMPV").unwrap_or_else(|_| "libmpv.so.2".to_owned())
}

/// `program` with `args`, or `None` when there is no such program.
pub fn run(program: &str, args: &[&str]) -> Option<std::process::Output> {
    std::process::Command::new(program).args(args).output().ok()
}

/// The film -- H.264 4:2:0 and stereo AAC at 48 kHz in Matroska, as a web
/// release has them -- or `None` without an `ffmpeg` that has libx264.
pub fn make_film(path: &Path) -> Option<()> {
    let out = run(
        "ffmpeg",
        &[
            "-v",
            "error",
            "-y",
            "-f",
            "lavfi",
            "-i",
            &format!("testsrc=size=320x240:rate=25:duration={FILM_SECONDS}"),
            "-f",
            "lavfi",
            "-i",
            &format!("sine=frequency=440:duration={FILM_SECONDS}"),
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-g",
            "50",
            "-keyint_min",
            "50",
            "-sc_threshold",
            "0",
            "-bf",
            "2",
            "-c:a",
            "aac",
            "-ac",
            "2",
            "-ar",
            "48000",
            path.to_str()?,
        ],
    )?;
    out.status.success().then_some(())
}
