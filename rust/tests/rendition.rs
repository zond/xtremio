//! **A rendition, end to end on this machine**: H.264 + AAC films made by
//! `ffmpeg` -- Matroska with cues, Matroska without, a transport stream --
//! registered by path, published as renditions, and read the way a Cast
//! receiver reads a file -- `HEAD`, ranges, a seek by the `sidx` -- off the
//! LAN listener, with the app's producer (`xtremio_core::rendition`)
//! reading them through the FFmpeg in a real libmpv. What comes back is
//! checked by `ffprobe` and decoded by `ffmpeg`, so a muxer or producer bug
//! is not mirrored by the code that checks it.
//!
//! The libmpv is the system's (`libmpv.so.2`, or `XTREMIO_LIBMPV`), loaded
//! by registering the `xtremio` protocol on a handle of it, exactly as a
//! player does; its FFmpeg is found through it, as on Android. It needs a
//! libmpv whose FFmpeg is the 6.x this build is bound to, and `ffmpeg` and
//! `ffprobe`, and says so and passes without them (CI's runners have
//! none). No network at any point.

use std::ffi::{c_char, c_int, c_void, CString};
use std::path::Path;
use std::time::{Duration, Instant};

use xtremio_core::server::StartConfig;

#[path = "support/film.rs"]
mod film;
use film::{libmpv_name, make, make_film, run, Container};

/// Three-second segments over the 13 s film ([`film::FILM_SECONDS`]).
const SEGMENT_MS: u64 = 3000;
/// mpv's duration of it: the container's, from the AAC priming on.
const DURATION_MS: u64 = 13_021;
/// The long films: six minutes, so a seek to 5:00 is a jump.
const LONG_SECONDS: u32 = 360;

struct Mpv {
    create: unsafe extern "C" fn() -> *mut c_void,
    initialize: unsafe extern "C" fn(*mut c_void) -> c_int,
    set_option_string: unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char) -> c_int,
    terminate_destroy: unsafe extern "C" fn(*mut c_void),
    _library: libloading::Library,
}

fn load_mpv(name: &str) -> Option<Mpv> {
    // SAFETY: loading libmpv runs its initialisers, which have no
    // preconditions; every symbol is cast to its `client.h` type.
    unsafe {
        let library = libloading::Library::new(name).ok()?;
        Some(Mpv {
            create: *library.get(b"mpv_create\0").ok()?,
            initialize: *library.get(b"mpv_initialize\0").ok()?,
            set_option_string: *library.get(b"mpv_set_option_string\0").ok()?,
            terminate_destroy: *library.get(b"mpv_terminate_destroy\0").ok()?,
            _library: library,
        })
    }
}

impl Mpv {
    /// An initialised handle with no picture and no sound: what the
    /// protocol is registered on, as a player's is.
    fn player(&self) -> *mut c_void {
        // SAFETY: libmpv's documented order: create, options, initialize.
        unsafe {
            let ctx = (self.create)();
            assert!(!ctx.is_null());
            for (name, value) in [("vo", "null"), ("ao", "null")] {
                let (name, value) = (CString::new(name).unwrap(), CString::new(value).unwrap());
                assert_eq!(
                    (self.set_option_string)(ctx, name.as_ptr(), value.as_ptr()),
                    0
                );
            }
            assert_eq!((self.initialize)(ctx), 0);
            ctx
        }
    }
}

/// One packet as `ffprobe` reports it: presentation and decode time in
/// milliseconds (rounded), whether it is a key, and where it is.
#[derive(Clone, Debug, PartialEq)]
struct Probed {
    pts_ms: Option<i64>,
    dts_ms: Option<i64>,
    key: bool,
    pos: Option<u64>,
}

/// The packets of `kind` (`v` or `a`) in `file`, in file order, and the
/// codec `ffprobe` names.
fn probe(file: &str, kind: &str) -> (String, Vec<Probed>) {
    let out = run(
        "ffprobe",
        &[
            "-v",
            "error",
            "-select_streams",
            &format!("{kind}:0"),
            "-show_entries",
            "stream=codec_name:packet=pts_time,dts_time,flags,pos",
            "-of",
            "json",
            file,
        ],
    )
    .expect("ffprobe ran");
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let json: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    let ms = |value: &serde_json::Value| {
        value
            .as_str()
            .and_then(|text| text.parse::<f64>().ok())
            .map(|seconds| (seconds * 1000.0).round() as i64)
    };
    let packets = json["packets"]
        .as_array()
        .unwrap()
        .iter()
        .map(|packet| Probed {
            pts_ms: ms(&packet["pts_time"]),
            dts_ms: ms(&packet["dts_time"]),
            key: packet["flags"].as_str().unwrap_or("").starts_with('K'),
            pos: packet["pos"].as_str().and_then(|pos| pos.parse().ok()),
        })
        .collect();
    (
        json["streams"][0]["codec_name"]
            .as_str()
            .unwrap_or("")
            .to_owned(),
        packets,
    )
}

/// The boxes at one level of `data`: type, offset, size.
fn boxes(data: &[u8]) -> Vec<([u8; 4], usize, usize)> {
    let mut out = Vec::new();
    let mut at = 0;
    while at + 8 <= data.len() {
        let size = u32::from_be_bytes(data[at..at + 4].try_into().unwrap()) as usize;
        if size < 8 || at + size > data.len() {
            break;
        }
        out.push((data[at + 4..at + 8].try_into().unwrap(), at, size));
        at += size;
    }
    out
}

/// The `tfdt` of track 1 (video) in a fragment, in its 90 kHz ticks:
/// where the fragment's video begins.
fn video_tfdt(fragment: &[u8]) -> Option<u64> {
    let (_, at, size) = *boxes(fragment).iter().find(|(kind, ..)| kind == b"moof")?;
    let moof = &fragment[at + 8..at + size];
    for (kind, at, size) in boxes(moof) {
        if &kind != b"traf" {
            continue;
        }
        let traf = &moof[at + 8..at + size];
        let inner = boxes(traf);
        let (_, tfhd, _) = *inner.iter().find(|(kind, ..)| kind == b"tfhd")?;
        if u32::from_be_bytes(traf[tfhd + 12..tfhd + 16].try_into().unwrap()) != 1 {
            continue;
        }
        let (_, tfdt, _) = *inner.iter().find(|(kind, ..)| kind == b"tfdt")?;
        let body = &traf[tfdt + 8..];
        return Some(if body[0] == 1 {
            u64::from_be_bytes(body[4..12].try_into().unwrap())
        } else {
            u64::from(u32::from_be_bytes(body[4..8].try_into().unwrap()))
        });
    }
    None
}

/// A rendition file's parts: the init segment, and each slot as
/// `(offset, size)` by its `sidx`.
struct Layout {
    init: usize,
    slots: Vec<(usize, usize)>,
}

impl Layout {
    fn of(file: &[u8]) -> Self {
        let top = boxes(file);
        let kinds: Vec<&[u8; 4]> = top.iter().take(3).map(|(kind, ..)| kind).collect();
        assert_eq!(kinds, [b"ftyp", b"moov", b"sidx"]);
        let (_, sidx, sidx_size) = top[2];
        let body = &file[sidx + 8..sidx + sidx_size];
        let count = u16::from_be_bytes([body[30], body[31]]) as usize;
        let mut offset = sidx + sidx_size;
        let slots = (0..count)
            .map(|k| {
                let at = 32 + k * 12;
                let size = u32::from_be_bytes(body[at..at + 4].try_into().unwrap()) as usize;
                let slot = (offset, size);
                offset += size;
                slot
            })
            .collect();
        assert_eq!(
            offset,
            file.len(),
            "the sidx's slots end where the file does"
        );
        Self {
            init: top[1].1 + top[1].2,
            slots,
        }
    }

    /// Slot `n`'s fragment: its bytes up to the `free` box that pads it.
    /// It opens with its `moof` -- no `styp` -- where the slot opens at its
    /// `sidx` label (a mirrored layout's): FFmpeg read a `moof` a `styp`
    /// kept apart from its `sidx` reference twice, and lost its index's
    /// order on a seek back.
    fn fragment<'a>(&self, file: &'a [u8], n: usize) -> &'a [u8] {
        let (offset, size) = self.slots[n];
        let slot = &file[offset..offset + size];
        let parts = boxes(slot);
        let kinds: Vec<&[u8; 4]> = parts.iter().map(|(kind, ..)| kind).collect();
        assert_eq!(kinds, [b"moof", b"mdat", b"free"], "slot {n}");
        &slot[..parts[2].1]
    }
}

/// Each track's clock (its `mdhd` timescale), from a file's first bytes.
fn clocks(head: &[u8]) -> Vec<u32> {
    let (_, at, size) = *boxes(head)
        .iter()
        .find(|(kind, ..)| kind == b"moov")
        .expect("a moov in the first bytes");
    let moov = &head[at..at + size];
    moov.windows(4)
        .enumerate()
        .filter(|(_, window)| *window == b"mdhd")
        .map(|(at, _)| {
            let clock = at + 8 + if moov[at + 4] == 1 { 16 } else { 8 };
            u32::from_be_bytes(moov[clock..clock + 4].try_into().unwrap())
        })
        .collect()
}

/// The slot sizes a file's `sidx` gives, from its first bytes.
fn sidx_sizes(head: &[u8]) -> Vec<u32> {
    let (_, sidx, _) = *boxes(head)
        .iter()
        .find(|(kind, ..)| kind == b"sidx")
        .expect("a sidx in the first bytes");
    let body = &head[sidx + 8..];
    let count = u16::from_be_bytes([body[30], body[31]]) as usize;
    (0..count)
        .map(|k| u32::from_be_bytes(body[32 + k * 12..36 + k * 12].try_into().unwrap()))
        .collect()
}

fn wait_for(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(60);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn client() -> reqwest::Client {
    xtremio_core::env::http_client_builder()
        .no_proxy()
        .build()
        .unwrap()
}

/// A `GET` of `url` with `range` if any: the status, the length it says,
/// the body.
fn get(
    runtime: &tokio::runtime::Runtime,
    url: &str,
    range: Option<(u64, u64)>,
) -> (u16, Option<u64>, Vec<u8>) {
    runtime.block_on(async {
        let request = client().get(url);
        let request = match range {
            Some((from, to)) => request.header("range", format!("bytes={from}-{to}")),
            None => request,
        };
        let response = request.send().await.expect("the listener answered");
        let status = response.status().as_u16();
        let length = response.content_length();
        (status, length, response.bytes().await.unwrap().to_vec())
    })
}

fn spec(duration_ms: u64, segment_ms: u64) -> String {
    serde_json::json!({
        "durationMs": duration_ms,
        "segmentMs": segment_ms,
        "startMs": 0,
        "video": "copy",
        "audio": "copy",
        "audioTrack": 0,
    })
    .to_string()
}

/// How `ffprobe` seeks to 5:00 in `url` over HTTP: the requests it made
/// and the first video packet's time after the seek, in seconds.
fn ffprobe_seek(url: &str) -> (usize, f64) {
    let out = run(
        "ffprobe",
        &[
            "-v",
            "debug",
            "-read_intervals",
            "300%+#1",
            "-select_streams",
            "v",
            "-show_entries",
            "packet=pts_time",
            "-of",
            "csv=p=0",
            url,
        ],
    )
    .expect("ffprobe ran");
    assert!(out.status.success());
    let log = String::from_utf8_lossy(&out.stderr);
    let requests = log.matches("request: GET").count();
    let first = String::from_utf8_lossy(&out.stdout)
        .lines()
        .next()
        .and_then(|line| line.trim().parse::<f64>().ok())
        .expect("a packet after the seek");
    (requests, first)
}

/// Where the video lands after each of `seeks` (seconds), in order, in
/// one `ffprobe` that first reads the film's first 16 s: the TV's remote
/// seeks, forward then back.
fn ffprobe_seeks(url: &str, seeks: &[u32]) -> Vec<f64> {
    let intervals: Vec<String> = std::iter::once("%+16".to_owned())
        .chain(seeks.iter().map(|at| format!("{at}%+#1")))
        .collect();
    let out = run(
        "ffprobe",
        &[
            "-v",
            "error",
            "-read_intervals",
            &intervals.join(","),
            "-select_streams",
            "v",
            "-show_entries",
            "packet=pts_time",
            "-of",
            "csv=p=0",
            url,
        ],
    )
    .expect("ffprobe ran");
    assert!(out.status.success());
    let times: Vec<f64> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|line| line.trim().parse::<f64>().ok())
        .collect();
    times[times.len() - seeks.len()..].to_vec()
}

/// Where each of `ffmpeg -ss <at> -i <url>`'s requests began, decoding a
/// second of every stream from there.
fn ffmpeg_seek_ranges(url: &str, at: u32) -> Vec<u64> {
    let out = run(
        "ffmpeg",
        &[
            "-v",
            "debug",
            "-ss",
            &at.to_string(),
            "-i",
            url,
            "-t",
            "1",
            "-f",
            "null",
            "-",
        ],
    )
    .expect("ffmpeg ran");
    assert!(out.status.success());
    String::from_utf8_lossy(&out.stderr)
        .lines()
        .filter_map(|line| line.strip_prefix("Range: bytes="))
        .filter_map(|range| range.split('-').next()?.parse().ok())
        .collect()
}

/// `ffmpeg` decodes `input` whole with nothing to say.
fn decodes(input: &str) {
    let decoded =
        run("ffmpeg", &["-v", "error", "-i", input, "-f", "null", "-"]).expect("ffmpeg ran");
    assert!(decoded.status.success(), "{input}");
    assert_eq!(
        String::from_utf8_lossy(&decoded.stderr),
        "",
        "decode errors in {input}"
    );
}

#[test]
fn h264_aac_films_are_repackaged_into_files_a_receiver_seeks_in() -> anyhow::Result<()> {
    let name = libmpv_name();
    let Some(mpv) = load_mpv(&name) else {
        eprintln!("SKIPPED: no libmpv to load as {name} (set XTREMIO_LIBMPV)");
        return Ok(());
    };
    if let Err(error) = xtremio_core::libav::Libav::load(&name) {
        eprintln!("SKIPPED: {name}'s FFmpeg is not the one this build reads: {error}");
        return Ok(());
    }
    let tmp = tempfile::tempdir()?;
    let film = tmp.path().join("film.mkv");
    if make_film(&film).is_none() || run("ffprobe", &["-version"]).is_none() {
        eprintln!("SKIPPED: no ffmpeg with libx264, or no ffprobe");
        return Ok(());
    }
    let runtime = tokio::runtime::Runtime::new()?;

    xtremio_core::server::start(StartConfig {
        config_dir: tmp.path().join("server"),
        cache_dir: tmp.path().join("cache"),
        offline: true,
    })?;
    let lan =
        xtremio_core::api::server::server_set_lan_media(true)?.expect("the listener's address");
    let lan = format!("127.0.0.1:{}", lan.parse::<std::net::SocketAddr>()?.port());

    // **Nothing to repackage with until a player has loaded libmpv**: the
    // library's path is Dart's to tell, through the protocol's registration.
    assert!(!xtremio_core::api::media::media_renditions_available()?);
    let ctx = mpv.player();
    xtremio_core::api::media::mpv_stream_register(ctx as i64, name.clone())?;
    assert!(xtremio_core::api::media::media_renditions_available()?);

    let publish = |path: &Path, duration_ms: u64, segment_ms: u64| -> anyhow::Result<String> {
        let id =
            xtremio_core::api::media::media_register_local_path(path.display().to_string(), None)?;
        let token =
            xtremio_core::api::media::media_publish_rendition(id, spec(duration_ms, segment_ms))?;
        Ok(format!("http://{lan}/cast/{token}/stream.mp4"))
    };

    // --- The short film: every packet, the cuts, the layout, the ranges ---------

    let url = publish(&film, DURATION_MS, SEGMENT_MS)?;
    // The length, before a byte of the file: what a receiver's HEAD reads.
    let head = runtime.block_on(async { client().head(&url).send().await })?;
    assert_eq!(head.status(), 200);
    assert_eq!(head.headers()["accept-ranges"], "bytes");
    let (status, whole_length, whole) = get(&runtime, &url, None);
    assert_eq!(status, 200);
    assert_eq!(whole_length, Some(whole.len() as u64));
    let head_length: Option<u64> = head.headers()["content-length"].to_str()?.parse().ok();
    assert_eq!(head_length, whole_length);
    let layout = Layout::of(&whole);
    let out = tmp.path().join("out.mp4");
    std::fs::write(&out, &whole)?;

    // **The same samples, on the film's clock.** Every packet of the
    // source is there, once, with its key flag; times are the container's
    // less its start (-21 ms, the AAC priming), which is the clock mpv
    // shows and the segments are cut on.
    let film_path = film.to_str().unwrap();
    let out_path = out.to_str().unwrap();
    let (source_video_codec, source_video) = probe(film_path, "v");
    let (source_audio_codec, source_audio) = probe(film_path, "a");
    let (video_codec, video) = probe(out_path, "v");
    let (audio_codec, audio) = probe(out_path, "a");
    assert_eq!(
        (source_video_codec.as_str(), source_audio_codec.as_str()),
        ("h264", "aac")
    );
    assert_eq!(
        (video_codec.as_str(), audio_codec.as_str()),
        ("h264", "aac")
    );
    let start_ms = source_audio[0].pts_ms.unwrap();
    assert!(
        start_ms < 0,
        "the film starts before zero (the AAC priming), so the rebasing is tested"
    );
    let rebased = |packets: &[Probed]| -> Vec<(i64, bool)> {
        let mut out: Vec<(i64, bool)> = packets
            .iter()
            .map(|packet| (packet.pts_ms.unwrap() - start_ms, packet.key))
            .collect();
        out.sort_unstable();
        out
    };
    let sorted = |packets: &[Probed]| -> Vec<(i64, bool)> {
        let mut out: Vec<(i64, bool)> = packets
            .iter()
            .map(|packet| (packet.pts_ms.unwrap(), packet.key))
            .collect();
        out.sort_unstable();
        out
    };
    assert_eq!(video.len(), source_video.len());
    // Video as a shape: every frame, its key flag, its distance from the
    // first. Where the first one sits is the `tfdt` check below, because
    // ffmpeg's MP4 demuxer moves a track whose composition offsets go
    // negative (`trun` version 1, B-frames) by its own reorder shift, which
    // a receiver's demuxer does not: it presents at `tfdt` plus the offset.
    let from_first = |packets: Vec<(i64, bool)>| -> Vec<(i64, bool)> {
        let first = packets[0].0;
        packets
            .into_iter()
            .map(|(pts, key)| (pts - first, key))
            .collect()
    };
    assert_eq!(
        from_first(sorted(&video)),
        from_first(rebased(&source_video))
    );
    assert_eq!(audio.len(), source_audio.len());
    assert_eq!(
        sorted(&audio)
            .iter()
            .map(|(pts, _)| *pts)
            .collect::<Vec<_>>(),
        rebased(&source_audio)
            .iter()
            .map(|(pts, _)| *pts)
            .collect::<Vec<_>>()
    );
    // Decode order is a clock that only moves on.
    let dts: Vec<i64> = video.iter().map(|packet| packet.dts_ms.unwrap()).collect();
    assert!(dts.windows(2).all(|pair| pair[0] < pair[1]), "{dts:?}");

    // **Each slot begins at the first indexed key at or after N x T**, each
    // a different key -- keys every 2 s, slots every 3 s: 0, 4, 6, 10, 12
    // -- and its slot is that key's span of the source plus the headroom
    // (8 KiB and a 64th), the key's position moved from its cluster to its
    // block by the cue.
    let keys: Vec<(i64, u64)> = source_video
        .iter()
        .filter(|packet| packet.key)
        .map(|packet| (packet.pts_ms.unwrap() - start_ms, packet.pos.unwrap()))
        .collect();
    let mut cuts: Vec<(i64, u64)> = vec![keys[0]];
    for n in 1.. {
        let Some(key) = keys
            .iter()
            .find(|(pts, _)| *pts >= n * SEGMENT_MS as i64 && *pts > cuts.last().unwrap().0)
        else {
            break;
        };
        if cuts.last() != Some(key) {
            cuts.push(*key);
        }
    }
    assert_eq!(
        cuts.iter().map(|(pts, _)| pts / 1000).collect::<Vec<_>>(),
        vec![0, 4, 6, 10, 12]
    );
    assert_eq!(layout.slots.len(), cuts.len());
    let film_len = std::fs::metadata(&film)?.len();
    for (n, (pts, pos)) in cuts.iter().enumerate() {
        let fragment = layout.fragment(&whole, n);
        assert_eq!(
            video_tfdt(fragment),
            Some(*pts as u64 * 90),
            "slot {n}'s tfdt"
        );
        let end = cuts.get(n + 1).map_or(film_len, |(_, pos)| *pos);
        let span = end - pos;
        let mirrored = span + 8 * 1024 + span / 64;
        let size = layout.slots[n].1 as u64;
        assert!(
            size.abs_diff(mirrored) <= 32,
            "slot {n} is {size} bytes, the source's span mirrored is {mirrored}"
        );
    }

    // **And it decodes**: every packet, no error, read as the one file it
    // is -- and from every slot's start, each fragment after the init
    // segment alone.
    decodes(out_path);
    for n in 0..layout.slots.len() {
        let mut alone = whole[..layout.init].to_vec();
        alone.extend_from_slice(layout.fragment(&whole, n));
        let path = tmp.path().join(format!("slot{n}.mp4"));
        std::fs::write(&path, alone)?;
        decodes(path.to_str().unwrap());
    }

    // **Every range is the file's bytes**, however it is asked for: a range
    // across a slot boundary, one inside it, and the last bytes.
    let boundary = layout.slots[2].0 as u64;
    for (from, to) in [
        (boundary - 5_000, boundary + 5_000),
        (boundary - 10, boundary + 100_000),
        (whole.len() as u64 - 16, whole.len() as u64 - 1),
    ] {
        let to = to.min(whole.len() as u64 - 1);
        let (status, _, bytes) = get(&runtime, &url, Some((from, to)));
        assert_eq!(status, 206);
        assert!(bytes == whole[from as usize..=to as usize], "{from}-{to}");
    }

    // A fresh rendition of the same film, read from its last slot first --
    // a run started there -- is the same file.
    let again = publish(&film, DURATION_MS, SEGMENT_MS)?;
    let last = layout.slots[4].0 as u64;
    let (_, _, tail) = get(&runtime, &again, Some((last, whole.len() as u64 - 1)));
    assert!(tail == whole[last as usize..], "the last slot, made first");
    let (_, _, again_whole) = get(&runtime, &again, None);
    assert!(again_whole == whole, "the same file");

    // --- The long films: a seek by the sidx, with and without an index -------

    for (container, file) in [
        (Container::Matroska, "long.mkv"),
        (Container::MatroskaWithoutCues, "nocues.mkv"),
        (Container::TransportStream, "long.ts"),
    ] {
        let path = tmp.path().join(file);
        make(&path, LONG_SECONDS, container).expect("ffmpeg made the long film");
        let url = publish(&path, u64::from(LONG_SECONDS) * 1000, 6000)?;
        // Mirrored from the cues, the slots follow the keys' spans; with no
        // index (no cues, a transport stream) they are estimated: equal, in
        // proportion to time, all but the last.
        let (_, _, head) = get(&runtime, &url, Some((0, 64 * 1024 - 1)));
        // **Every track on the video's clock**: FFmpeg before 6.0 (the
        // Chromecast with Google TV's) places the sound by the video's
        // `sidx` times unscaled; on 48 kHz a seek to 85 s read on from 45.
        assert_eq!(clocks(&head), [90_000, 90_000], "{file}");
        // Estimated, the sound has a `sidx` of its own, labelled early, so
        // its slot is never one before the picture's; mirrored, one.
        let indexes = boxes(&head)
            .iter()
            .filter(|(kind, ..)| kind == b"sidx")
            .count();
        let mirrored = container == Container::Matroska;
        assert_eq!(indexes, if mirrored { 1 } else { 2 }, "{file}");
        let sizes = sidx_sizes(&head);
        assert_eq!(sizes.len(), LONG_SECONDS as usize / 6, "{file}");
        let middle = &sizes[1..sizes.len() - 1];
        let equal = middle.iter().max().unwrap() - middle.iter().min().unwrap() <= 1;
        assert_eq!(equal, container != Container::Matroska, "{file}: {sizes:?}");
        // **One jump to the slot that holds 5:00**: the start, a peek at
        // the end, the first fragment, the jump -- and a spare.
        let (requests, landed) = ffprobe_seek(&url);
        eprintln!("{file}: ffprobe sought to 5:00 in {requests} requests, landing at {landed} s");
        assert!(
            requests <= 6,
            "{file}: ffprobe made {requests} requests to seek to 5:00"
        );
        // Keys every 2.8 s. Mirrored, the key at or before 5:00 (299.66 s);
        // estimated -- each slot labelled a GOP (10 s) after its cut -- a
        // key in the slot before, a segment and a GOP early at most.
        let earliest = if container == Container::Matroska {
            297.0
        } else {
            300.0 - 6.0 - 10.0
        };
        assert!(
            (earliest..=300.0).contains(&landed),
            "{file}: the seek landed at {landed} s"
        );
        // **Every stream sought lands in that slot**: `ffmpeg -ss` seeks the
        // sound too, to the sync sample's time; with no sound at or before
        // it in the slot, it went back to what it read at the start.
        // So: never back. Mirrored, the start and the jump and nothing
        // else; estimated (slots labelled a GOP late), on forward from the
        // slot before to the sync sample.
        let ranges = ffmpeg_seek_ranges(&url, 60);
        assert!(
            ranges.windows(2).all(|pair| pair[1] > pair[0]) && (!mirrored || ranges.len() == 2),
            "{file}: ffmpeg -ss 60 asked {ranges:?}"
        );
        // **Seeks forward, then back to what was not read** (zond's TV:
        // 1:55, 7:05, 8:41, then 0:43, which sat buffering): mirrored,
        // each lands on the key at or before it, a slot back at most.
        // With a styp before each moof FFmpeg landed the seek back at 16 s,
        // the end of what it read first. Estimated slots keep the styp
        // (FFmpeg 4.4 would time them by their late labels) and still do.
        if mirrored {
            let seeks = [100, 250, 330, 43, 30];
            let landed = ffprobe_seeks(&url, &seeks);
            for (at, landed) in seeks.iter().zip(&landed) {
                let at = f64::from(*at);
                assert!(
                    (at - 6.0 - 2.8..=at).contains(landed),
                    "{file}: seeks {seeks:?} landed at {landed:?}"
                );
            }
        }
        decodes(&url);
    }

    // **Unpublishing ends a file being read, and its run**: the thread
    // returns, whatever it was blocked in.
    let id = xtremio_core::api::media::media_register_local_path(film.display().to_string(), None)?;
    let reading = xtremio_core::api::media::media_publish_rendition(
        id.clone(),
        spec(DURATION_MS, SEGMENT_MS),
    )?;
    let body_broke = runtime.block_on(async {
        let mut response = client()
            .get(format!("http://{lan}/cast/{reading}/stream.mp4"))
            .send()
            .await
            .expect("the listener answered");
        assert_eq!(response.status(), 200);
        response.chunk().await.expect("a first chunk");
        let unpublished = tokio::task::spawn_blocking({
            let reading = reading.clone();
            move || xtremio_core::api::media::media_unpublish(reading)
        })
        .await
        .unwrap()
        .unwrap();
        assert!(unpublished);
        loop {
            match response.chunk().await {
                Ok(Some(_)) => continue,
                Ok(None) => return false,
                Err(_) => return true,
            }
        }
    });
    assert!(body_broke, "a cut file ended cleanly");
    xtremio_core::api::server::server_set_lan_media(false)?;
    wait_for("every rendition run to end", || {
        xtremio_core::rendition::live_runs() == 0
    });

    // SAFETY: the handle, destroyed once.
    unsafe { (mpv.terminate_destroy)(ctx) };
    xtremio_core::api::server::server_stop()?;
    Ok(())
}

/// **Not a test: a rendition served from this machine**, for playing it
/// in a browser or on a television before the app casts it
/// (`docs/CASTING.md`). Publishes a rendition of `XTREMIO_RENDITION_FILE`
/// (an H.264 + AAC film: Matroska, MP4 or a transport stream) on the LAN
/// listener -- loopback, so a television reaches it through `adb reverse`
/// -- writes the file's path and the listener's port into
/// `XTREMIO_RENDITION_OUT` (`path`, `port`, and `url`, the whole URL on
/// this machine), and serves until a file named `stop` appears there:
///
/// `XTREMIO_RENDITION_FILE=film.mkv XTREMIO_RENDITION_OUT=/tmp/r cargo
/// test --test rendition serve -- --ignored --nocapture`
///
/// The file is the rendition a receiver gets: a length, ranges, a `sidx`;
/// seek in it with the television's remote.
#[test]
#[ignore]
fn serve_a_rendition_until_told_to_stop() -> anyhow::Result<()> {
    let file = std::path::PathBuf::from(std::env::var("XTREMIO_RENDITION_FILE")?);
    let out = std::path::PathBuf::from(std::env::var("XTREMIO_RENDITION_OUT")?);
    std::fs::create_dir_all(&out)?;
    let name = libmpv_name();
    let mpv = load_mpv(&name).expect("a libmpv");
    let runtime = tokio::runtime::Runtime::new()?;
    let tmp = tempfile::tempdir()?;
    xtremio_core::server::start(StartConfig {
        config_dir: tmp.path().join("server"),
        cache_dir: tmp.path().join("cache"),
        offline: true,
    })?;
    let lan = xtremio_core::api::server::server_set_lan_media(true)?.expect("an address");
    let lan = format!("127.0.0.1:{}", lan.parse::<std::net::SocketAddr>()?.port());
    let ctx = mpv.player();
    xtremio_core::api::media::mpv_stream_register(ctx as i64, name)?;
    let libav = xtremio_core::libav::Libav::registered().map_err(anyhow::Error::msg)?;
    let duration_ms = xtremio_core::libav::Demuxer::open(
        libav,
        std::io::Cursor::new(bytes::Bytes::from(std::fs::read(&file)?)),
    )
    .map_err(anyhow::Error::msg)?
    .duration_us()
    .expect("a duration")
        / 1000;
    let id = xtremio_core::api::media::media_register_local_path(file.display().to_string(), None)?;
    let token =
        xtremio_core::api::media::media_publish_rendition(id, spec(duration_ms as u64, 6000))?;
    let path = format!("/cast/{token}/stream.mp4");
    let port = lan.rsplit(':').next().unwrap_or_default().to_owned();
    // A HEAD, so a file that would not answer says so here.
    let head =
        runtime.block_on(async { client().head(format!("http://{lan}{path}")).send().await })?;
    assert_eq!(head.status(), 200);
    std::fs::write(out.join("path"), &path)?;
    std::fs::write(out.join("port"), &port)?;
    std::fs::write(out.join("url"), format!("http://{lan}{path}"))?;
    eprintln!(
        "serving http://{lan}{path} ({duration_ms} ms, {} bytes) until {} exists",
        head.headers()["content-length"].to_str().unwrap_or("?"),
        out.join("stop").display()
    );
    while !out.join("stop").exists() {
        std::thread::sleep(Duration::from_millis(200));
    }
    Ok(())
}
