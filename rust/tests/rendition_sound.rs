//! **A rendition whose sound is converted, end to end on this machine**
//! (stream-server `docs/design/renditions.md`, step F3): H.264 films with
//! Dolby Digital Plus 5.1, Dolby Digital 5.1, DTS 5.1, TrueHD 5.1 and AAC
//! 5.1 sound in Matroska, and Dolby Digital and AAC 5.1 in MP4, made by
//! `ffmpeg`, published as renditions that convert the sound to stereo AAC
//! and copy the picture, and read as a Cast receiver reads them, off the
//! LAN listener -- with the
//! app's producer decoding through the FFmpeg in a real libmpv and encoding
//! with that FFmpeg's own AAC encoder (a desktop's; a phone's is
//! `MediaCodec`).
//!
//! The films flash white for one frame at every whole second and click on
//! every channel at the same instant, so **picture and sound line up** can
//! be measured in what comes back: by `ffmpeg` decoding it, never by the
//! code under test.
//!
//! Needs a libmpv whose FFmpeg is the 6.x this build reads, with the AAC
//! encoder and the four Dolby/DTS encoders (`-strict -2` for DTS and
//! TrueHD), and `ffmpeg`/`ffprobe`; says so and passes without them.

use std::ffi::{c_char, c_int, c_void, CString};
use std::path::Path;
use std::time::{Duration, Instant};

use xtremio_core::server::StartConfig;

#[path = "support/film.rs"]
mod film;
use film::{libmpv_name, run};

/// The films' length: five 6 s segments.
const SECONDS: u32 = 30;
const SEGMENT_MS: u64 = 6000;
/// One video frame at 25 frames a second, in seconds.
const FRAME_S: f64 = 0.04;

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

/// The sound a film is made with: `ffmpeg`'s encoder arguments.
#[derive(Clone, Copy, Debug)]
struct Sound {
    name: &'static str,
    args: &'static [&'static str],
}

const SOUNDS: [Sound; 5] = [
    Sound {
        name: "eac3",
        args: &["-c:a", "eac3", "-ac", "6"],
    },
    Sound {
        name: "ac3",
        args: &["-c:a", "ac3", "-ac", "6"],
    },
    Sound {
        name: "dts",
        args: &["-c:a", "dca", "-strict", "-2", "-ac", "6"],
    },
    Sound {
        name: "truehd",
        args: &["-c:a", "truehd", "-strict", "-2", "-ac", "6"],
    },
    // AAC itself, with six channels: copied it would reach a receiver as
    // 5.1, which zond's television (sound over Bluetooth) is not known to
    // play, so the app asks for it converted like any other.
    Sound {
        name: "aac51",
        args: &["-c:a", "aac", "-ac", "6"],
    },
];

/// A film `seconds` long: `testsrc` in H.264 at 25 frames a second (a
/// picture with something in it: a slot of a near-empty picture is a few
/// kilobytes and a megabyte of padding, and `ffmpeg` reading it over HTTP
/// goes back for the sound it passed), keys every 2 s, a
/// white frame at every whole second (the frame within 20 ms of it, so a
/// time's rounding never whitens two) and a 1 ms click on all six channels
/// at the same instant, in `path` (its extension the container).
fn make(path: &Path, seconds: u32, sound: Sound) -> Option<()> {
    let picture = format!(
        "testsrc=s=320x240:r=25:d={seconds},\
         drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='lt(mod(t+0.02\\,1)\\,0.04)'"
    );
    let click =
        format!("aevalsrc=exprs='if(lt(mod(t\\,1)\\,0.001)\\,0.9\\,0)':s=48000:c=5.1:d={seconds}");
    let mut args = vec![
        "-v",
        "error",
        "-y",
        "-f",
        "lavfi",
        "-i",
        &picture,
        "-f",
        "lavfi",
        "-i",
        &click,
        "-c:v",
        "libx264",
        "-preset",
        "ultrafast",
        "-g",
        "50",
        "-keyint_min",
        "50",
        "-sc_threshold",
        "0",
    ];
    args.extend_from_slice(sound.args);
    let path = path.to_str()?;
    args.push(path);
    run("ffmpeg", &args)?.status.success().then_some(())
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

fn get(runtime: &tokio::runtime::Runtime, url: &str, range: Option<(u64, u64)>) -> (u16, Vec<u8>) {
    runtime.block_on(async {
        let request = client().get(url);
        let request = match range {
            Some((from, to)) => request.header("range", format!("bytes={from}-{to}")),
            None => request,
        };
        let response = request.send().await.expect("the listener answered");
        let status = response.status().as_u16();
        (status, response.bytes().await.unwrap().to_vec())
    })
}

/// A rendition that copies the picture and converts the sound.
fn spec(duration_ms: u64) -> String {
    serde_json::json!({
        "durationMs": duration_ms,
        "segmentMs": SEGMENT_MS,
        "startMs": 0,
        "video": "copy",
        "audio": {"aacStereo": {"bitrate": 192_000}},
        "audioTrack": 0,
    })
    .to_string()
}

/// The top-level boxes of `data`: (type, offset, size).
fn boxes(data: &[u8]) -> Vec<([u8; 4], usize, usize)> {
    let mut out = Vec::new();
    let mut at = 0;
    while at + 8 <= data.len() {
        let size = u32::from_be_bytes(data[at..at + 4].try_into().unwrap()) as usize;
        if size < 8 {
            break;
        }
        out.push((data[at + 4..at + 8].try_into().unwrap(), at, size));
        at += size;
    }
    out
}

/// Where the header ends and each slot begins, from the video's `sidx`.
fn slots(file: &[u8]) -> Vec<(usize, usize)> {
    let all = boxes(file);
    let (_, at, size) = *all.iter().find(|(kind, ..)| kind == b"sidx").unwrap();
    let body = &file[at + 8..at + size];
    // Version 1: 4 flags, 4 reference id, 4 timescale, 8 earliest, 8 first
    // offset, 2 reserved, 2 count, then 12 bytes a reference.
    let first_offset = u64::from_be_bytes(body[20..28].try_into().unwrap()) as usize;
    let count = u16::from_be_bytes(body[30..32].try_into().unwrap()) as usize;
    let mut start = at + size + first_offset;
    let mut slots: Vec<(usize, usize)> = Vec::new();
    for k in 0..count {
        let entry = 32 + k * 12;
        let size =
            (u32::from_be_bytes(body[entry..entry + 4].try_into().unwrap()) & 0x7fff_ffff) as usize;
        let duration = u32::from_be_bytes(body[entry + 4..entry + 8].try_into().unwrap());
        // A slot is two references: its opening `moof`, which carries its
        // duration, and the rest of it, which lasts nothing (`sidx_slots`
        // in tests/rendition.rs says why).
        match slots.last_mut() {
            Some(slot) if duration == 0 => slot.1 += size,
            _ => slots.push((start, size)),
        }
        start += size;
    }
    slots
}

fn stream_start(file: &str, kind: &str) -> f64 {
    let out = run(
        "ffprobe",
        &[
            "-v",
            "error",
            "-select_streams",
            &format!("{kind}:0"),
            "-show_entries",
            "stream=start_time",
            "-of",
            "csv=p=0",
            file,
        ],
    )
    .expect("ffprobe ran");
    String::from_utf8_lossy(&out.stdout)
        .trim()
        .parse()
        .unwrap_or(0.0)
}

/// Times (seconds, on `file`'s clock) of every white frame and every click
/// in it, by `ffmpeg`'s decoding.
fn flashes_and_clicks(file: &str) -> (Vec<f64>, Vec<f64>) {
    let video = run(
        "ffmpeg",
        &[
            "-v",
            "error",
            "-i",
            file,
            "-map",
            "0:v:0",
            "-vf",
            "scale=4:4",
            "-fps_mode",
            "passthrough",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "gray",
            "-",
        ],
    )
    .expect("ffmpeg ran");
    assert!(
        video.status.success(),
        "{}",
        String::from_utf8_lossy(&video.stderr)
    );
    let video_start = stream_start(file, "v");
    let flashes = video
        .stdout
        .chunks(16)
        .enumerate()
        .filter(|(_, frame)| frame.iter().map(|v| u32::from(*v)).sum::<u32>() / 16 > 200)
        .map(|(n, _)| video_start + n as f64 * FRAME_S)
        .collect();
    let audio = run(
        "ffmpeg",
        &[
            "-v", "error", "-i", file, "-map", "0:a:0", "-ac", "1", "-ar", "48000", "-f", "f32le",
            "-",
        ],
    )
    .expect("ffmpeg ran");
    assert!(
        audio.status.success(),
        "{}",
        String::from_utf8_lossy(&audio.stderr)
    );
    let audio_start = stream_start(file, "a");
    let samples: Vec<f32> = audio
        .stdout
        .as_chunks::<4>()
        .0
        .iter()
        .map(|b| f32::from_le_bytes(*b))
        .collect();
    let mut clicks = Vec::new();
    let mut last = -1.0f64;
    for (n, sample) in samples.iter().enumerate() {
        let at = audio_start + n as f64 / 48_000.0;
        if sample.abs() > 0.2 && at - last > 0.5 {
            clicks.push(at);
            last = at;
        }
    }
    (flashes, clicks)
}

/// How far each click is from the nearest flash, seconds: picture and
/// sound out of step by this much.
fn offsets(flashes: &[f64], clicks: &[f64]) -> Vec<f64> {
    clicks
        .iter()
        .filter_map(|click| {
            flashes
                .iter()
                .map(|flash| click - flash)
                .min_by(|a, b| a.abs().total_cmp(&b.abs()))
        })
        .collect()
}

/// What `ffprobe` says of `file`'s sound: codec, profile, rate, channels.
fn sound_facts(file: &str) -> serde_json::Value {
    let out = run(
        "ffprobe",
        &[
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_entries",
            "stream=codec_name,profile,sample_rate,channels",
            "-of",
            "json",
            file,
        ],
    )
    .expect("ffprobe ran");
    serde_json::from_slice::<serde_json::Value>(&out.stdout).unwrap()["streams"][0].clone()
}

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

/// Where each of `ffmpeg -ss <at> -i <url>`'s requests began.
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

#[test]
fn dolby_and_dts_sound_is_converted_to_stereo_aac_in_step_with_the_picture() -> anyhow::Result<()> {
    let name = libmpv_name();
    let Some(mpv) = load_mpv(&name) else {
        eprintln!("SKIPPED: no libmpv to load as {name} (set XTREMIO_LIBMPV)");
        return Ok(());
    };
    match xtremio_core::libav::Libav::load(&name) {
        Err(error) => {
            eprintln!("SKIPPED: {name}'s FFmpeg is not the one this build reads: {error}");
            return Ok(());
        }
        Ok(libav) if !libav.has_aac_encoder() => {
            eprintln!("SKIPPED: {name}'s FFmpeg has no AAC encoder");
            return Ok(());
        }
        Ok(_) => {}
    }
    let tmp = tempfile::tempdir()?;
    let films: Vec<(Sound, std::path::PathBuf)> = SOUNDS
        .iter()
        .map(|sound| (*sound, tmp.path().join(format!("{}.mkv", sound.name))))
        .collect();
    for (sound, path) in &films {
        if make(path, SECONDS, *sound).is_none() || run("ffprobe", &["-version"]).is_none() {
            eprintln!(
                "SKIPPED: no ffmpeg with libx264 and the {} encoder",
                sound.name
            );
            return Ok(());
        }
    }
    let mp4 = tmp.path().join("ac3.mp4");
    make(&mp4, SECONDS, SOUNDS[1]).expect("ffmpeg made the MP4");
    let aac_mp4 = tmp.path().join("aac51.mp4");
    make(&aac_mp4, SECONDS, SOUNDS[4]).expect("ffmpeg made the 5.1 AAC MP4");
    let runtime = tokio::runtime::Runtime::new()?;
    xtremio_core::server::start(StartConfig {
        config_dir: tmp.path().join("server"),
        cache_dir: tmp.path().join("cache"),
        offline: true,
    })?;
    let lan =
        xtremio_core::api::server::server_set_lan_media(true)?.expect("the listener's address");
    let lan = format!("127.0.0.1:{}", lan.parse::<std::net::SocketAddr>()?.port());
    let ctx = mpv.player();
    xtremio_core::api::media::mpv_stream_register(ctx as i64, name.clone())?;
    let publish = |path: &Path| -> anyhow::Result<String> {
        let id =
            xtremio_core::api::media::media_register_local_path(path.display().to_string(), None)?;
        let token =
            xtremio_core::api::media::media_publish_rendition(id, spec(u64::from(SECONDS) * 1000))?;
        Ok(format!("http://{lan}/cast/{token}/stream.mp4"))
    };

    for (sound, path) in films
        .iter()
        .map(|(sound, path)| (sound.name, path.clone()))
        .chain([
            ("ac3 in mp4", mp4.clone()),
            ("aac51 in mp4", aac_mp4.clone()),
        ])
    {
        let url = publish(&path)?;
        let (status, whole) = get(&runtime, &url, None);
        assert_eq!(status, 200, "{sound}");
        let out = tmp
            .path()
            .join(format!("{}.out.mp4", sound.replace(' ', "_")));
        std::fs::write(&out, &whole)?;
        let out_path = out.to_str().unwrap();

        // **Stereo AAC-LC at 48 kHz**, the picture as it was.
        let facts = sound_facts(out_path);
        assert_eq!(facts["codec_name"], "aac", "{sound}: {facts}");
        assert_eq!(facts["profile"], "LC", "{sound}: {facts}");
        assert_eq!(facts["sample_rate"], "48000", "{sound}: {facts}");
        assert_eq!(facts["channels"], 2, "{sound}: {facts}");
        decodes(out_path);

        // **In step with the picture, as the source is**: every click as
        // far from its flash as the source's own, as `ffmpeg` plays the
        // source, give or take 3 ms -- a fraction of a frame -- and as many
        // as the film has (one a second). (The source's own is not zero
        // for DTS: `ffmpeg`'s DTS encoder's delay, 512 samples, is in its
        // packets and nothing in Matroska says so.)
        let (flashes, clicks) = flashes_and_clicks(path.to_str().unwrap());
        let mut source = offsets(&flashes, &clicks);
        source.sort_by(f64::total_cmp);
        let source = source[source.len() / 2];
        assert!(
            source.abs() < FRAME_S,
            "{sound}: the source is {source} s off"
        );
        let in_step = |off: &[f64]| off.iter().all(|off| (off - source).abs() < 0.003);
        let (flashes, clicks) = flashes_and_clicks(out_path);
        assert_eq!(flashes.len(), SECONDS as usize, "{sound}: {flashes:?}");
        assert!(
            clicks.len() + 1 >= SECONDS as usize,
            "{sound}: {} clicks {clicks:?}",
            clicks.len()
        );
        let off = offsets(&flashes, &clicks);
        assert!(
            in_step(&off),
            "{sound}: clicks off their flashes by {off:?}, the source's by {source}"
        );

        // **And from every slot alone** -- the header and that slot, as a
        // receiver has it after a seek: in step there too, and decoding.
        let layout = slots(&whole);
        let header = layout[0].0;
        assert!(layout.len() >= 5, "{sound}: {} slots", layout.len());
        for (n, (at, size)) in layout.iter().enumerate() {
            let mut alone = whole[..header].to_vec();
            alone.extend_from_slice(&whole[*at..at + size]);
            let path = tmp.path().join(format!("slot{n}.mp4"));
            std::fs::write(&path, alone)?;
            let path = path.to_str().unwrap();
            decodes(path);
            let (flashes, clicks) = flashes_and_clicks(path);
            let off = offsets(&flashes, &clicks);
            assert!(
                !off.is_empty() && in_step(&off),
                "{sound}, slot {n}: clicks off their flashes by {off:?}, the source's by {source}"
            );
        }

        // **The same bytes whichever run makes them**: fresh renditions of
        // the same film, each read first from a different slot -- a run
        // started there, its sound converted from there -- are the same
        // file, slot for slot.
        for first in [layout.len() - 1, 2, 1] {
            let again = publish(&path)?;
            let (at, size) = layout[first];
            let (status, slot) = get(&runtime, &again, Some((at as u64, (at + size - 1) as u64)));
            assert_eq!(status, 206);
            assert!(
                slot == whole[at..at + size],
                "{sound}: slot {first}, made first by its own run, differs"
            );
            let (_, again_whole) = get(&runtime, &again, None);
            assert!(
                again_whole == whole,
                "{sound}: the file read after slot {first}"
            );
        }

        // **A seek is one jump**: `ffmpeg -ss` asks for the start and the
        // target slot, nothing between (Matroska's cues mirrored; an MP4's
        // sample tables are its index the same way).
        let ranges = ffmpeg_seek_ranges(&url, 20);
        assert!(
            ranges.len() <= 2 && ranges.windows(2).all(|pair| pair[1] > pair[0]),
            "{sound}: ffmpeg -ss 20 asked {ranges:?}"
        );
    }

    xtremio_core::api::server::server_set_lan_media(false)?;
    wait_for("every rendition run to end", || {
        xtremio_core::rendition::live_runs() == 0
    });
    // SAFETY: the handle, destroyed once.
    unsafe { (mpv.terminate_destroy)(ctx) };
    xtremio_core::api::server::server_stop()?;
    Ok(())
}

/// **Serves one film as a rendition with its sound converted**, for a
/// television's hand test: writes the URL (and `path`, `port`) to
/// `XTREMIO_RENDITION_OUT` and serves until a file named `stop` appears
/// there:
///
/// `XTREMIO_RENDITION_FILE=film.mkv XTREMIO_RENDITION_OUT=/tmp/r cargo test
/// --test rendition_sound serve -- --ignored --nocapture`
#[test]
#[ignore]
fn serve_a_converted_rendition_until_told_to_stop() -> anyhow::Result<()> {
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
    let token = xtremio_core::api::media::media_publish_rendition(id, spec(duration_ms as u64))?;
    let path = format!("/cast/{token}/stream.mp4");
    let port = lan.rsplit(':').next().unwrap_or_default().to_owned();
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
