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

/// What the film is muxed into.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Container {
    /// Matroska with its cues at the end, as `ffmpeg` writes a file.
    Matroska,
    /// Matroska written to a pipe: no cues, nothing to seek by.
    MatroskaWithoutCues,
    /// An MPEG transport stream: no index, AAC in ADTS.
    TransportStream,
}

/// The film -- H.264 4:2:0 and stereo AAC at 48 kHz in Matroska, as a web
/// release has them -- or `None` without an `ffmpeg` that has libx264.
pub fn make_film(path: &Path) -> Option<()> {
    make(path, FILM_SECONDS, Container::Matroska)
}

/// A film `seconds` long in `container`, keys every 2 s (2.8 s when it is
/// longer than [`FILM_SECONDS`]) with B-frames between, or `None` without
/// an `ffmpeg` that has libx264.
pub fn make(path: &Path, seconds: u32, container: Container) -> Option<()> {
    let source = [
        "-v".to_owned(),
        "error".to_owned(),
        "-y".to_owned(),
        "-f".to_owned(),
        "lavfi".to_owned(),
        "-i".to_owned(),
        format!("testsrc=size=320x240:rate=25:duration={seconds}"),
        "-f".to_owned(),
        "lavfi".to_owned(),
        "-i".to_owned(),
        format!("sine=frequency=440:duration={seconds}"),
    ];
    // Long films are made fast; the short one as it always was.
    // Long films are made fast, with keys every 2.8 s -- off the 6 s grid,
    // as a real film's are; the short one as it always was.
    let long = seconds > FILM_SECONDS;
    let preset = if long { "ultrafast" } else { "medium" };
    let gop = if long { "70" } else { "50" };
    let codecs = [
        "-c:v",
        "libx264",
        "-preset",
        preset,
        "-pix_fmt",
        "yuv420p",
        "-g",
        gop,
        "-keyint_min",
        gop,
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
    ];
    let mut args: Vec<String> = source.to_vec();
    args.extend(codecs.iter().map(|arg| (*arg).to_owned()));
    let status = match container {
        Container::Matroska => {
            args.push(path.to_str()?.to_owned());
            std::process::Command::new("ffmpeg")
                .args(&args)
                .status()
                .ok()?
        }
        Container::TransportStream => {
            args.extend([
                "-f".to_owned(),
                "mpegts".to_owned(),
                path.to_str()?.to_owned(),
            ]);
            std::process::Command::new("ffmpeg")
                .args(&args)
                .status()
                .ok()?
        }
        Container::MatroskaWithoutCues => {
            args.extend(["-f".to_owned(), "matroska".to_owned(), "pipe:1".to_owned()]);
            std::process::Command::new("ffmpeg")
                .args(&args)
                .stdout(std::fs::File::create(path).ok()?)
                .status()
                .ok()?
        }
    };
    status.success().then_some(())
}
