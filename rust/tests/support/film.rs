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

/// What the film's picture is encoded as.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Video {
    /// H.264 4:2:0 by libx264.
    H264,
    /// HEVC Main 10 by libx265, tagged HDR10 (BT.2020, PQ, a mastering
    /// display and light levels in its headers), with x265's open GOPs: a
    /// key after the first is a CRA.
    HevcHdr10,
}

/// A film `seconds` long in `container`, keys every 2 s (2.8 s when it is
/// longer than [`FILM_SECONDS`]) with B-frames between, or `None` without
/// an `ffmpeg` that has libx264.
pub fn make(path: &Path, seconds: u32, container: Container) -> Option<()> {
    make_with(path, seconds, container, Video::H264, &[])
}

/// [`make`] with the picture `video`, and `extra` arguments before the
/// output (stream metadata), or `None` without an `ffmpeg` that has the
/// encoder.
pub fn make_with(
    path: &Path,
    seconds: u32,
    container: Container,
    video: Video,
    extra: &[&str],
) -> Option<()> {
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
    let x265 = format!(
        "log-level=error:keyint={gop}:min-keyint={gop}:scenecut=0:bframes=3:\
         colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:\
         master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):\
         max-cll=1000,400"
    );
    let picture: Vec<&str> = match video {
        Video::H264 => vec![
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
        ],
        Video::HevcHdr10 => vec![
            "-c:v",
            "libx265",
            "-preset",
            preset,
            "-pix_fmt",
            "yuv420p10le",
            "-x265-params",
            &x265,
        ],
    };
    let sound = ["-c:a", "aac", "-ac", "2", "-ar", "48000"];
    let mut args: Vec<String> = source.to_vec();
    args.extend(
        picture
            .iter()
            .chain(&sound)
            .chain(extra)
            .map(|arg| (*arg).to_owned()),
    );
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

/// The track title [`with_dolby_vision`] replaces; give it to [`make_with`]
/// as `-metadata:s:v:0 title=...` and `-write_crc32 0`.
pub const DOLBY_VISION_PLACEHOLDER: &str = "DOLBYVISIONPLACEHOLDER0123456789ABCDEFGH";

/// `file` (Matroska made with [`DOLBY_VISION_PLACEHOLDER`] as its video
/// track's title) declaring Dolby Vision `profile` with base layer
/// compatibility `compatibility`: the title's `Name` element is overwritten,
/// at the same length, by a `BlockAdditionMapping` carrying a `dvcC` record
/// and a `Void` -- which `ffmpeg` cannot write from the command line -- so
/// no offset in the file moves.
pub fn with_dolby_vision(file: &[u8], profile: u8, compatibility: u8) -> Vec<u8> {
    let title = DOLBY_VISION_PLACEHOLDER.as_bytes();
    let at = file
        .windows(title.len())
        .position(|window| window == title)
        .expect("the placeholder title");
    // Name: ID 0x536E, a one-byte size.
    assert_eq!(&file[at - 3..at], &[0x53, 0x6e, 0x80 | title.len() as u8]);
    let (start, total) = (at - 3, 3 + title.len());
    let level = 6u8;
    let record: Vec<u8> = [
        &[
            1,
            0,
            (profile << 1) | (level >> 5),
            ((level & 0x1f) << 3) | 0b101, // RPU and base layer present
            compatibility << 4,
        ][..],
        &[0; 19],
    ]
    .concat();
    let mut inner = vec![0x41, 0xe7, 0x84];
    inner.extend_from_slice(b"dvcC");
    inner.extend_from_slice(&[0x41, 0xed, 0x80 | record.len() as u8]);
    inner.extend_from_slice(&record);
    let mut element = vec![0x41, 0xe4, 0x80 | inner.len() as u8];
    element.extend_from_slice(&inner);
    let pad = total - element.len();
    element.extend_from_slice(&[0xec, 0x80 | (pad - 2) as u8]);
    element.resize(total, 0);
    let mut out = file.to_vec();
    out[start..start + total].copy_from_slice(&element);
    out
}
