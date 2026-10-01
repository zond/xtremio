//! **A rendition, end to end on this machine**: an H.264 + AAC Matroska
//! film made by `ffmpeg`, registered by path, published as a rendition,
//! and fetched the way a Cast receiver fetches it -- playlist, init
//! segment, media segments -- off the LAN listener, with the app's
//! producer (`xtremio_core::rendition`) reading it through the FFmpeg in a
//! real libmpv. What comes back is checked by `ffprobe` and decoded by
//! `ffmpeg`, so a muxer or producer bug is not mirrored by the code that
//! checks it.
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
use film::{libmpv_name, make_film, run};

/// Three-second segments over the 13 s film ([`film::FILM_SECONDS`]).
const SEGMENT_MS: u64 = 3000;
/// mpv's duration of it: the container's, from the AAC priming on.
const DURATION_MS: u64 = 13_021;

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
/// milliseconds (rounded), and whether it is a key.
#[derive(Clone, Debug, PartialEq)]
struct Probed {
    pts_ms: Option<i64>,
    dts_ms: Option<i64>,
    key: bool,
}

/// The packets of `kind` (`v` or `a`) in `file`, in file order, and the
/// codec `ffprobe` names.
fn probe(file: &Path, kind: &str) -> (String, Vec<Probed>) {
    let out = run(
        "ffprobe",
        &[
            "-v",
            "error",
            "-select_streams",
            &format!("{kind}:0"),
            "-show_entries",
            "stream=codec_name:packet=pts_time,dts_time,flags",
            "-of",
            "json",
            file.to_str().unwrap(),
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

/// The `tfdt` of track 1 (video) in a media segment, in its 90 kHz
/// ticks: where the segment's video begins. Walks the boxes by hand.
fn video_tfdt(segment: &[u8]) -> Option<u64> {
    fn boxes(data: &[u8]) -> Vec<([u8; 4], &[u8])> {
        let mut out = Vec::new();
        let mut at = 0;
        while at + 8 <= data.len() {
            let size = u32::from_be_bytes(data[at..at + 4].try_into().unwrap()) as usize;
            if size < 8 || at + size > data.len() {
                break;
            }
            out.push((
                data[at + 4..at + 8].try_into().unwrap(),
                &data[at + 8..at + size],
            ));
            at += size;
        }
        out
    }
    let moof = boxes(segment)
        .into_iter()
        .find(|(kind, _)| kind == b"moof")?
        .1;
    for (kind, traf) in boxes(moof) {
        if &kind != b"traf" {
            continue;
        }
        let inner = boxes(traf);
        let tfhd = inner.iter().find(|(kind, _)| kind == b"tfhd")?.1;
        if u32::from_be_bytes(tfhd[4..8].try_into().unwrap()) != 1 {
            continue;
        }
        let tfdt = inner.iter().find(|(kind, _)| kind == b"tfdt")?.1;
        return Some(if tfdt[0] == 1 {
            u64::from_be_bytes(tfdt[4..12].try_into().unwrap())
        } else {
            u64::from(u32::from_be_bytes(tfdt[4..8].try_into().unwrap()))
        });
    }
    None
}

fn wait_for(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(60);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// GETs `path` off the LAN listener at `addr`, expecting a 200.
fn get(runtime: &tokio::runtime::Runtime, addr: &str, path: &str) -> Vec<u8> {
    let client = xtremio_core::env::http_client_builder()
        .no_proxy()
        .build()
        .unwrap();
    runtime.block_on(async {
        let response = client
            .get(format!("http://{addr}{path}"))
            .send()
            .await
            .expect("the listener answered");
        assert_eq!(response.status(), 200, "GET {path}");
        response.bytes().await.unwrap().to_vec()
    })
}

fn spec(start_ms: u64) -> String {
    serde_json::json!({
        "durationMs": DURATION_MS,
        "segmentMs": SEGMENT_MS,
        "startMs": start_ms,
        "video": "copy",
        "audio": "copy",
        "audioTrack": 0,
    })
    .to_string()
}

#[test]
fn an_h264_aac_matroska_film_is_repackaged_into_the_hls_a_receiver_fetches() -> anyhow::Result<()> {
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

    let id = xtremio_core::api::media::media_register_local_path(film.display().to_string(), None)?;
    let token = xtremio_core::api::media::media_publish_rendition(id.clone(), spec(0))?;
    let base = format!("/cast/{token}/hls");

    // The playlist: ceil(d / T) segments.
    let playlist = String::from_utf8(get(&runtime, &lan, &format!("{base}/index.m3u8")))?;
    let count = DURATION_MS.div_ceil(SEGMENT_MS);
    assert_eq!(playlist.matches(".m4s").count() as u64, count, "{playlist}");

    // The init segment, then every segment in order, as a receiver plays.
    let init = get(&runtime, &lan, &format!("{base}/init.mp4"));
    let segments: Vec<Vec<u8>> = (0..count)
        .map(|n| get(&runtime, &lan, &format!("{base}/{n}.m4s")))
        .collect();
    let out = tmp.path().join("out.mp4");
    let mut whole = init.clone();
    for segment in &segments {
        whole.extend_from_slice(segment);
    }
    std::fs::write(&out, &whole)?;

    // **The same samples, on the film's clock.** Every packet of the
    // source is there, once, with its key flag; times are the container's
    // less its start (-21 ms, the AAC priming), which is the clock mpv
    // shows and the playlist is written on.
    let (source_video_codec, source_video) = probe(&film, "v");
    let (source_audio_codec, source_audio) = probe(&film, "a");
    let (video_codec, video) = probe(&out, "v");
    let (audio_codec, audio) = probe(&out, "a");
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
    // a receiver's MSE does not: it presents at `tfdt` plus the offset.
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

    // **Each segment begins at the first key at or after N x T.**
    let keys: Vec<i64> = rebased(&source_video)
        .into_iter()
        .filter(|(_, key)| *key)
        .map(|(pts, _)| pts)
        .collect();
    for (n, segment) in segments.iter().enumerate() {
        let cut = keys
            .iter()
            .find(|key| **key >= n as i64 * SEGMENT_MS as i64)
            .copied()
            .expect("a key in every segment of this film");
        assert_eq!(video_tfdt(segment), Some(cut as u64 * 90), "segment {n}");
    }

    // **And it decodes**: every packet, no error.
    let decoded = run(
        "ffmpeg",
        &[
            "-v",
            "error",
            "-i",
            out.to_str().unwrap(),
            "-f",
            "null",
            "-",
        ],
    )
    .expect("ffmpeg ran");
    assert!(decoded.status.success());
    assert_eq!(
        String::from_utf8_lossy(&decoded.stderr),
        "",
        "decode errors"
    );

    // **A run that starts partway seeks, and makes the same segments**: a
    // receiver handed the film at 7 s asks for the init segment (the first
    // run starts at segment 2, a seek to 6 s), then segment 2; and then
    // segment 0 -- behind the ring, a seek back to the start. The cut rule
    // is a function of N and the film alone, so the bytes are the ones the
    // run from the start made.
    let later = xtremio_core::api::media::media_publish_rendition(id.clone(), spec(7000))?;
    let later_base = format!("/cast/{later}/hls");
    assert_eq!(get(&runtime, &lan, &format!("{later_base}/init.mp4")), init);
    assert_eq!(
        get(&runtime, &lan, &format!("{later_base}/2.m4s")),
        segments[2]
    );
    assert_eq!(
        get(&runtime, &lan, &format!("{later_base}/0.m4s")),
        segments[0]
    );

    // **Unpublishing ends the runs**: their threads return, whatever they
    // were blocked in.
    assert!(xtremio_core::api::media::media_unpublish(token)?);
    assert!(xtremio_core::api::media::media_unpublish(later)?);
    wait_for("every rendition run to end", || {
        xtremio_core::rendition::live_runs() == 0
    });

    // SAFETY: the handle, destroyed once.
    unsafe { (mpv.terminate_destroy)(ctx) };
    xtremio_core::api::server::server_stop()?;
    Ok(())
}
