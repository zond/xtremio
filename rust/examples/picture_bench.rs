//! **The picture converter's bench, on a phone**: a file read with the
//! NDK's `AMediaExtractor` (or libavformat, `--libmpv`), its picture
//! converted segment by segment by `xtremio_core::picture::Converter` over
//! Android's codecs, through the server's own driver
//! (`stream_server::ConvertedPicture`). It prints one JSON object.
//!
//! ```text
//! picture_bench <path> <target> <bitrate> [--grid-ms N] [--operating-rate R]
//!               [--priority P] [--from-segment K] [--libmpv PATH] [--software]
//! ```
//!
//! - `target` is the wire name: `h264High`, `hevcMain` or `hevcMain10`.
//! - The segments mirror the film's sync samples: a cut at each sync sample
//!   at least `--grid-ms` (1000) after the last cut. This is the bench's
//!   own grid, so 1 s segments can be measured although a converted
//!   rendition's layout has a longer floor.
//! - `--from-segment K` starts the run at segment K, the way a seek does:
//!   the file is sought two seconds before K's cut, and pictures before it
//!   are decoded and dropped. Compare the segment hashes with a run from
//!   the start.
//! - `--operating-rate` and `--priority` go on every codec's format.
//! - `--libmpv PATH` reads the file with the libavformat inside that
//!   libmpv (the app's, pushed to the phone), as a rendition run does. That
//!   is the way to read an AVI, which `AMediaExtractor` does not open. The
//!   picture is decoded in software where the phone has no hardware
//!   decoder for its codec (MPEG-4 Part 2, DivX 3, MPEG-2), as the producer
//!   decides it.
//! - `--software` decodes in software whatever the codec (with `--libmpv`).
//!
//! Build: `cargo ndk -t arm64-v8a build --release --example picture_bench`.
//! On a desktop it says there is no NDK and exits 1.

use std::collections::BTreeMap;
use std::ffi::{c_char, c_int, c_void, CStr};
use std::os::fd::AsRawFd;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use bytes::Bytes;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use stream_server::{
    Converted, ConvertedPicture, PictureConverter, PictureEvent, PictureTarget, Segments,
    SourcePicture,
};
use xtremio_core::libav::{self, Demuxer, Kind, Libav, Next, StreamInfo};
use xtremio_core::ndk_media::{ndk, MediaFormat};
use xtremio_core::picture::{
    has_sei, Colour, Converter, EncoderConfig, NdkCodecs, PictureSource, SoftCodecs, VideoCodecs,
};
use xtremio_core::rendition::PictureInput;

/// How far before a segment's cut a run from it seeks: the server's
/// `SEEK_BACK`.
const SEEK_BACK_US: i64 = 2_000_000;

fn main() {
    match bench() {
        Ok(report) => println!("{}", serde_json::to_string_pretty(&report).unwrap()),
        Err(error) => {
            println!("{}", json!({ "error": error }));
            std::process::exit(1);
        }
    }
}

struct Args {
    path: String,
    target: PictureTarget,
    bitrate: u32,
    grid_ms: i64,
    operating_rate: Option<f32>,
    priority: Option<i32>,
    from_segment: u64,
    libmpv: Option<String>,
    software: bool,
}

fn args() -> Result<Args, String> {
    let usage = "picture_bench <path> <target> <bitrate> [--grid-ms N] [--operating-rate R] \
                 [--priority P] [--from-segment K] [--libmpv PATH] [--software]";
    let mut all = std::env::args().skip(1);
    let mut positional = Vec::new();
    let mut parsed = Args {
        path: String::new(),
        target: PictureTarget::HevcMain,
        bitrate: 0,
        grid_ms: 1000,
        operating_rate: None,
        priority: None,
        from_segment: 0,
        libmpv: None,
        software: false,
    };
    while let Some(arg) = all.next() {
        let mut value = |name: &str| all.next().ok_or(format!("{name} needs a value; {usage}"));
        match arg.as_str() {
            "--grid-ms" => parsed.grid_ms = number(&value("--grid-ms")?)?,
            "--operating-rate" => {
                parsed.operating_rate = Some(number(&value("--operating-rate")?)?)
            }
            "--priority" => parsed.priority = Some(number(&value("--priority")?)?),
            "--from-segment" => parsed.from_segment = number(&value("--from-segment")?)?,
            "--libmpv" => parsed.libmpv = Some(value("--libmpv")?),
            "--software" => parsed.software = true,
            _ => positional.push(arg),
        }
    }
    let [path, target, bitrate] = <[String; 3]>::try_from(positional).map_err(|_| usage)?;
    parsed.path = path;
    parsed.target = serde_json::from_value(Value::String(target.clone()))
        .map_err(|_| format!("{target} is not h264High, hevcMain or hevcMain10"))?;
    parsed.bitrate = number(&bitrate)?;
    if parsed.grid_ms <= 0 {
        return Err("--grid-ms must be positive".to_owned());
    }
    if parsed.software && parsed.libmpv.is_none() {
        return Err(
            "--software needs --libmpv: the software decoder is libmpv's FFmpeg".to_owned(),
        );
    }
    Ok(parsed)
}

fn number<T: std::str::FromStr>(text: &str) -> Result<T, String> {
    text.parse().map_err(|_| format!("{text} is not a number"))
}

// --- AMediaExtractor --------------------------------------------------------------

/// The `libmediandk.so` functions the bench reads a file with, each read
/// as its `NdkMediaExtractor.h` or `NdkMediaFormat.h` signature.
struct Extractor {
    delete: unsafe extern "C" fn(*mut c_void) -> c_int,
    track_count: unsafe extern "C" fn(*mut c_void) -> usize,
    track_format: unsafe extern "C" fn(*mut c_void, usize) -> *mut c_void,
    select_track: unsafe extern "C" fn(*mut c_void, usize) -> c_int,
    read_sample_data: unsafe extern "C" fn(*mut c_void, *mut u8, usize) -> isize,
    sample_flags: unsafe extern "C" fn(*mut c_void) -> u32,
    sample_time: unsafe extern "C" fn(*mut c_void) -> i64,
    advance: unsafe extern "C" fn(*mut c_void) -> bool,
    seek_to: unsafe extern "C" fn(*mut c_void, i64, c_int) -> c_int,
    format_get_string: unsafe extern "C" fn(*mut c_void, *const c_char, *mut *const c_char) -> bool,
    format_get_float: unsafe extern "C" fn(*mut c_void, *const c_char, *mut f32) -> bool,
    format_get_int64: unsafe extern "C" fn(*mut c_void, *const c_char, *mut i64) -> bool,
    extractor: *mut c_void,
    _file: std::fs::File,
    _library: libloading::Library,
}

const SAMPLE_FLAG_SYNC: u32 = 1;
const SEEK_PREVIOUS_SYNC: c_int = 0;

impl Extractor {
    fn open(path: &str) -> Result<Self, String> {
        let file = std::fs::File::open(path).map_err(|error| format!("{path}: {error}"))?;
        let len = file.metadata().map_err(|error| error.to_string())?.len();
        // SAFETY: the platform's media library, each symbol read as its
        // header's signature; the extractor is this value's, deleted on drop.
        unsafe {
            let library = libloading::Library::new("libmediandk.so")
                .map_err(|error| format!("no libmediandk.so: {error}"))?;
            macro_rules! symbol {
                ($name:literal) => {
                    *library
                        .get(concat!($name, "\0").as_bytes())
                        .map_err(|error| format!("{}: {error}", $name))?
                };
            }
            let new: unsafe extern "C" fn() -> *mut c_void = symbol!("AMediaExtractor_new");
            let set_fd: unsafe extern "C" fn(*mut c_void, c_int, i64, i64) -> c_int =
                symbol!("AMediaExtractor_setDataSourceFd");
            let extractor = new();
            if extractor.is_null() {
                return Err("no extractor".to_owned());
            }
            let opened = Self {
                delete: symbol!("AMediaExtractor_delete"),
                track_count: symbol!("AMediaExtractor_getTrackCount"),
                track_format: symbol!("AMediaExtractor_getTrackFormat"),
                select_track: symbol!("AMediaExtractor_selectTrack"),
                read_sample_data: symbol!("AMediaExtractor_readSampleData"),
                sample_flags: symbol!("AMediaExtractor_getSampleFlags"),
                sample_time: symbol!("AMediaExtractor_getSampleTime"),
                advance: symbol!("AMediaExtractor_advance"),
                seek_to: symbol!("AMediaExtractor_seekTo"),
                format_get_string: symbol!("AMediaFormat_getString"),
                format_get_float: symbol!("AMediaFormat_getFloat"),
                format_get_int64: symbol!("AMediaFormat_getInt64"),
                extractor,
                _file: file,
                _library: library,
            };
            let fd = opened._file.as_raw_fd();
            if set_fd(extractor, fd, 0, len as i64) != 0 {
                return Err(format!("{path} could not be read"));
            }
            Ok(opened)
        }
    }

    /// The first video track: its index and format.
    fn video(&self) -> Result<(usize, MediaFormat, String), String> {
        let ndk = ndk()?;
        // SAFETY: a live extractor; each format is ours, deleted by
        // `MediaFormat`.
        unsafe {
            for track in 0..(self.track_count)(self.extractor) {
                let Some(format) =
                    MediaFormat::from_raw(ndk, (self.track_format)(self.extractor, track))
                else {
                    continue;
                };
                let mime = self.string(&format, c"mime").unwrap_or_default();
                if mime.starts_with("video/") {
                    return Ok((track, format, mime));
                }
            }
        }
        Err("the file has no video track".to_owned())
    }

    fn string(&self, format: &MediaFormat, key: &CStr) -> Option<String> {
        let mut out: *const c_char = std::ptr::null();
        // SAFETY: a live format; the string is the format's, copied here.
        unsafe {
            ((self.format_get_string)(format.as_ptr(), key.as_ptr(), &mut out) && !out.is_null())
                .then(|| CStr::from_ptr(out).to_string_lossy().into_owned())
        }
    }

    fn float(&self, format: &MediaFormat, key: &CStr) -> Option<f32> {
        let mut out = 0f32;
        // SAFETY: a live format and out-value.
        unsafe { (self.format_get_float)(format.as_ptr(), key.as_ptr(), &mut out) }.then_some(out)
    }

    fn int64(&self, format: &MediaFormat, key: &CStr) -> Option<i64> {
        let mut out = 0i64;
        // SAFETY: a live format and out-value.
        unsafe { (self.format_get_int64)(format.as_ptr(), key.as_ptr(), &mut out) }.then_some(out)
    }

    fn select(&self, track: usize) -> Result<(), String> {
        // SAFETY: a live extractor and a track it listed.
        (unsafe { (self.select_track)(self.extractor, track) } == 0)
            .then_some(())
            .ok_or("the track could not be selected".to_owned())
    }

    fn seek(&self, at_us: i64) {
        // SAFETY: a live extractor.
        unsafe { (self.seek_to)(self.extractor, at_us, SEEK_PREVIOUS_SYNC) };
    }

    /// The current sample's time, whether it is a sync sample, and its
    /// bytes read into `buffer`; `None` at the end.
    fn sample(&self, buffer: &mut Vec<u8>) -> Option<(i64, bool, usize)> {
        // SAFETY: a live extractor; the read writes at most `capacity`.
        unsafe {
            let size = (self.read_sample_data)(self.extractor, buffer.as_mut_ptr(), buffer.len());
            if size < 0 {
                return None;
            }
            let time = (self.sample_time)(self.extractor);
            let sync = (self.sample_flags)(self.extractor) & SAMPLE_FLAG_SYNC != 0;
            Some((time, sync, size as usize))
        }
    }

    /// Steps past the current sample; false at the end.
    fn next(&self) -> bool {
        // SAFETY: a live extractor.
        unsafe { (self.advance)(self.extractor) }
    }
}

impl Drop for Extractor {
    fn drop(&mut self) {
        // SAFETY: this value's own extractor, deleted once.
        unsafe { (self.delete)(self.extractor) };
    }
}

// --- What the converter did -------------------------------------------------------

/// [`NdkCodecs`] with each encoder's set-up timed.
struct Timed {
    codecs: NdkCodecs,
    setup_ms: Arc<Mutex<Vec<f64>>>,
}

impl VideoCodecs for Timed {
    type Codec = <NdkCodecs as VideoCodecs>::Codec;
    type Decoder = <NdkCodecs as VideoCodecs>::Decoder;
    type Surface = <NdkCodecs as VideoCodecs>::Surface;

    fn decoder(
        &mut self,
        source: &PictureSource,
        surface: Option<&Self::Surface>,
        p010: bool,
    ) -> Result<Self::Codec, String> {
        self.codecs.decoder(source, surface, p010)
    }

    fn encoder(
        &mut self,
        config: &EncoderConfig,
        surface: bool,
    ) -> Result<(Self::Codec, Option<Self::Surface>), String> {
        let started = Instant::now();
        let made = self.codecs.encoder(config, surface);
        self.setup_ms
            .lock()
            .unwrap()
            .push(started.elapsed().as_secs_f64() * 1000.0);
        made
    }

    fn set_output_surface(
        &mut self,
        decoder: &mut Self::Codec,
        surface: &Self::Surface,
    ) -> Result<(), String> {
        self.codecs.set_output_surface(decoder, surface)
    }
}

/// A converter whose events are also kept, for the report.
struct Recording<C> {
    converter: C,
    events: Arc<Mutex<Vec<PictureEvent>>>,
}

impl<C: PictureConverter> PictureConverter for Recording<C> {
    fn push(
        &mut self,
        picture: SourcePicture,
        segments: &Segments,
    ) -> Result<Vec<PictureEvent>, String> {
        let events = self.converter.push(picture, segments)?;
        self.events.lock().unwrap().extend(events.iter().cloned());
        Ok(events)
    }

    fn finish(&mut self, segments: &Segments) -> Result<Vec<PictureEvent>, String> {
        let events = self.converter.finish(segments)?;
        self.events.lock().unwrap().extend(events.iter().cloned());
        Ok(events)
    }
}

#[derive(Default)]
struct SegmentReport {
    csd: Option<Bytes>,
    bytes: usize,
    pictures: usize,
    first_pts: Option<i64>,
    last_pts: Option<i64>,
    first_key: Option<bool>,
    first_sample_sei: Vec<u8>,
    hash: Sha256,
    done: Option<(u32, u32)>,
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// The SEI payload types (137, 144) an Annex-B buffer carries.
fn sei_types(annex_b: &[u8]) -> Vec<u8> {
    [137u8, 144]
        .into_iter()
        .filter(|kind| has_sei(annex_b, *kind))
        .collect()
}

// --- libavformat --------------------------------------------------------------

/// A file as libavformat reads it.
struct FileSource {
    file: std::fs::File,
    len: u64,
}

impl libav::Source for FileSource {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        std::io::Read::read(&mut self.file, buf)
    }

    fn seek(&mut self, offset: u64) -> std::io::Result<u64> {
        std::io::Seek::seek(&mut self.file, std::io::SeekFrom::Start(offset))
    }

    fn length(&self) -> u64 {
        self.len
    }
}

/// What the bench reads the film's pictures with.
enum Reader {
    Extractor {
        extractor: Extractor,
        buffer: Vec<u8>,
    },
    /// libavformat, as a rendition run reads: each picture on the film's
    /// clock, a packet without a presentation time at its decode time, and
    /// failing that the last one's plus its duration.
    Libav {
        demuxer: Demuxer<FileSource>,
        video: Box<StreamInfo>,
        input: Box<PictureInput>,
        last: Option<(i64, i64)>,
    },
}

impl Reader {
    fn seek(&mut self, at_us: i64) -> Result<(), String> {
        match self {
            Self::Extractor { extractor, .. } => {
                extractor.seek(at_us);
                Ok(())
            }
            Self::Libav { demuxer, last, .. } => {
                *last = None;
                demuxer.seek_us(at_us)
            }
        }
    }

    /// The next picture, or `None` at the end.
    fn next(&mut self) -> Option<SourcePicture> {
        match self {
            Self::Extractor { extractor, buffer } => {
                let (pts_us, key, size) = extractor.sample(buffer)?;
                let picture = SourcePicture {
                    pts_us,
                    key,
                    data: Bytes::copy_from_slice(&buffer[..size]),
                };
                // At the end the next read answers nothing.
                extractor.next();
                Some(picture)
            }
            Self::Libav {
                demuxer,
                video,
                input,
                last,
            } => loop {
                let packet = match demuxer.read_packet() {
                    Next::Packet(packet) => packet,
                    Next::End | Next::Failed(_) => return None,
                };
                if packet.stream != video.index {
                    continue;
                }
                let duration = libav::to_us(packet.duration, video.time_base).filter(|d| *d > 0);
                let Some(pts) = libav::to_us(packet.pts, video.time_base)
                    .or_else(|| libav::to_us(packet.dts, video.time_base))
                    .or_else(|| last.map(|(pts, duration)| pts + duration))
                else {
                    continue;
                };
                *last = Some((pts, duration.or(last.map(|(_, d)| d)).unwrap_or(0)));
                return Some(SourcePicture {
                    pts_us: pts - demuxer.start_us(),
                    key: packet.key,
                    data: input.sample(packet.data),
                });
            },
        }
    }
}

/// What the bench converts: the reader, the decoder's and encoders' keys,
/// the codec parameters when the picture is decoded in software, and what
/// the report says of the source.
struct Film {
    reader: Reader,
    source: PictureSource,
    config: EncoderConfig,
    software: Option<libav::CodecParameters>,
    duration_us: Option<i64>,
}

fn open_extractor(args: &Args) -> Result<Film, String> {
    let extractor = Extractor::open(&args.path)?;
    let (track, format, mime) = extractor.video()?;
    extractor.select(track)?;
    let int = |key: &CStr| format.i32(key);
    let width = int(c"width").ok_or("no width")? as u32;
    let height = int(c"height").ok_or("no height")? as u32;
    let frame_rate = int(c"frame-rate")
        .map(|rate| rate as f32)
        .or_else(|| extractor.float(&format, c"frame-rate"))
        .unwrap_or(30.0);
    let duration_us = extractor.int64(&format, c"durationUs");
    let colour = Colour {
        standard: int(c"color-standard"),
        transfer: int(c"color-transfer"),
        range: int(c"color-range"),
    };
    let csd: Vec<Bytes> = [c"csd-0", c"csd-1"]
        .into_iter()
        .filter_map(|key| format.buffer(key).map(Bytes::from))
        .collect();
    let mime: &'static str = match mime.as_str() {
        "video/avc" => "video/avc",
        "video/hevc" => "video/hevc",
        "video/av01" => "video/av01",
        "video/x-vnd.on2.vp9" => "video/x-vnd.on2.vp9",
        other => {
            return Err(format!(
                "the extractor reads {other}, which no hardware decoder here takes; pass --libmpv"
            ))
        }
    };
    let max_input = int(c"max-input-size").unwrap_or(0).max(4 << 20) as usize;
    let source = PictureSource {
        mime,
        width,
        height,
        frame_rate,
        csd,
        colour,
        decode_times: false,
    };
    let config = EncoderConfig {
        target: args.target,
        width,
        height,
        bitrate: args.bitrate,
        frame_rate,
        colour,
        hdr_static_info: format.buffer(c"hdr-static-info").map(Bytes::from),
    };
    Ok(Film {
        reader: Reader::Extractor {
            extractor,
            buffer: vec![0u8; max_input],
        },
        source,
        config,
        software: None,
        duration_us,
    })
}

fn open_libav(args: &Args, libmpv: &str) -> Result<Film, String> {
    let libav: &'static Libav = Box::leak(Box::new(Libav::load(libmpv)?));
    let file =
        std::fs::File::open(&args.path).map_err(|error| format!("{}: {error}", args.path))?;
    let len = file.metadata().map_err(|error| error.to_string())?.len();
    let mut demuxer = Demuxer::open(libav, FileSource { file, len })?;
    let video = demuxer
        .streams()
        .iter()
        .find(|stream| stream.kind == Kind::Video && !stream.attached_picture)
        .ok_or("the file has no video stream")?
        .clone();
    let hardware = xtremio_core::picture::support().decodes;
    let mut input = PictureInput::of(&video, args.target, args.bitrate, &hardware, args.software)?;
    let software = if input.software {
        if !libav::decodes_picture(libav, video.codec) {
            return Err(format!("{libmpv} has no decoder for codec {}", video.codec));
        }
        Some(demuxer.codec_parameters(video.index)?)
    } else {
        None
    };
    // As the producer does: a first picture without a presentation time
    // (an AVI's) means the pictures are timed by decode order.
    input.source.decode_times = loop {
        match demuxer.read_packet() {
            Next::Packet(packet) if packet.stream == video.index => {
                break packet.pts == libav::NOPTS;
            }
            Next::Packet(_) => continue,
            Next::End | Next::Failed(_) => break false,
        }
    };
    demuxer.seek_us(0)?;
    let duration_us = demuxer.duration_us();
    let (source, config) = (input.source.clone(), input.config.clone());
    Ok(Film {
        reader: Reader::Libav {
            demuxer,
            video: Box::new(video),
            input: Box::new(input),
            last: None,
        },
        source,
        config,
        software,
        duration_us,
    })
}

fn bench() -> Result<Value, String> {
    let args = args()?;
    let Film {
        mut reader,
        source,
        config,
        software,
        duration_us,
    } = match &args.libmpv {
        None => open_extractor(&args)?,
        Some(libmpv) => open_libav(&args, libmpv)?,
    };
    let (width, height, frame_rate, mime) =
        (source.width, source.height, source.frame_rate, source.mime);
    let decode_times = source.decode_times;
    let encoded = (config.width, config.height);
    let frame_us = (1_000_000.0 / frame_rate) as i64;

    // The sync samples, and the grid that mirrors them.
    let mut syncs = Vec::new();
    while let Some(picture) = reader.next() {
        if picture.key {
            syncs.push(picture.pts_us);
        }
    }
    let grid_us = args.grid_ms * 1000;
    let mut cuts = vec![i64::MIN];
    let mut last = *syncs.first().ok_or("the file has no sync sample")?;
    for &sync in &syncs[1..] {
        if sync - last >= grid_us {
            cuts.push(sync);
            last = sync;
        }
    }
    if args.from_segment >= cuts.len() as u64 {
        return Err(format!(
            "--from-segment {} is past the last of {} segments",
            args.from_segment,
            cuts.len()
        ));
    }
    let segments = Segments::new(cuts.clone().into(), args.from_segment);
    let from_us = if args.from_segment == 0 {
        0
    } else {
        cuts[args.from_segment as usize] - SEEK_BACK_US
    };
    reader.seek(from_us.max(0))?;

    let setup_ms = Arc::new(Mutex::new(Vec::new()));
    let events = Arc::new(Mutex::new(Vec::new()));
    let mut codecs = NdkCodecs::new()?;
    codecs.operating_rate = args.operating_rate;
    codecs.priority = args.priority;
    let timed = Timed {
        codecs,
        setup_ms: setup_ms.clone(),
    };
    let decoder = if software.is_some() {
        "software"
    } else {
        "hardware"
    };
    let converter: Box<dyn PictureConverter> = match software {
        None => Box::new(Converter::new(timed, source, config)),
        Some(par) => {
            let (width, height) = (config.width, config.height);
            let codecs = SoftCodecs::new(timed, par, width, height);
            Box::new(Converter::new(codecs, source, config))
        }
    };
    let converter = Recording {
        converter,
        events: events.clone(),
    };
    let mut driver = ConvertedPicture::new(converter, segments.clone(), args.target);

    let started = Instant::now();
    let mut samples = 0usize;
    let mut converted = Vec::new();
    while let Some(picture) = reader.next() {
        converted.extend(driver.push(picture)?);
        samples += 1;
    }
    converted.extend(driver.finish()?);
    let wall_s = started.elapsed().as_secs_f64();

    let mut reports: BTreeMap<u64, SegmentReport> = BTreeMap::new();
    for event in events.lock().unwrap().iter() {
        match event {
            PictureEvent::Config { segment, csd, .. } => {
                reports.entry(*segment).or_default().csd = Some(csd.clone());
            }
            PictureEvent::Picture {
                segment,
                pts_us,
                key,
                data,
            } => {
                let report = reports.entry(*segment).or_default();
                if report.first_key.is_none() {
                    report.first_key = Some(*key);
                    report.first_sample_sei = sei_types(data);
                }
                report.first_pts.get_or_insert(*pts_us);
                report.last_pts = Some(*pts_us);
                report.bytes += data.len();
                report.pictures += 1;
                report.hash.update(data);
            }
            PictureEvent::SegmentDone {
                segment,
                pictures_in,
                pictures_out,
            } => {
                reports.entry(*segment).or_default().done = Some((*pictures_in, *pictures_out));
            }
        }
    }
    let first_csd = reports.values().find_map(|report| report.csd.clone());
    let csd_identical = reports
        .values()
        .filter_map(|report| report.csd.as_ref())
        .all(|csd| Some(csd) == first_csd.as_ref());
    let mut ratios = Vec::new();
    let mut rows = Vec::new();
    let mut media_us = 0i64;
    for (segment, report) in reports {
        let start = cuts[segment as usize].max(report.first_pts.unwrap_or(0));
        let end = cuts
            .get(segment as usize + 1)
            .copied()
            .unwrap_or_else(|| report.last_pts.unwrap_or(start) + frame_us);
        let seconds = (end - start).max(1) as f64 / 1e6;
        media_us += end - start;
        let ratio = report.bytes as f64 / (seconds * f64::from(args.bitrate) / 8.0);
        if report.pictures > 0 {
            ratios.push(ratio);
        }
        rows.push(json!({
            "segment": segment,
            "startUs": start,
            "seconds": seconds,
            "pictures": report.pictures,
            "bytes": report.bytes,
            "ratio": ratio,
            "firstIsKey": report.first_key,
            "firstSampleSei": report.first_sample_sei,
            "in": report.done.map(|done| done.0),
            "out": report.done.map(|done| done.1),
            "sha256": hex(&report.hash.finalize()),
        }));
    }
    let setup = setup_ms.lock().unwrap().clone();
    let samples_out = converted
        .iter()
        .filter(|item| matches!(item, Converted::Sample(_)))
        .count();
    Ok(json!({
        "path": args.path,
        "target": args.target,
        "bitrate": args.bitrate,
        "gridMs": args.grid_ms,
        "fromSegment": args.from_segment,
        "operatingRate": args.operating_rate,
        "priority": args.priority,
        "source": {
            "mime": mime,
            "decoder": decoder,
            "decodeTimes": decode_times,
            "width": width,
            "height": height,
            "encodedWidth": encoded.0,
            "encodedHeight": encoded.1,
            "frameRate": frame_rate,
            "durationUs": duration_us,
            "syncSamples": syncs.len(),
        },
        "segments": cuts.len(),
        "samplesIn": samples,
        "samplesOut": samples_out,
        "wallS": wall_s,
        "mediaS": media_us as f64 / 1e6,
        "speed": media_us as f64 / 1e6 / wall_s,
        "ratioMax": ratios.iter().copied().fold(0.0, f64::max),
        "ratioMean": ratios.iter().sum::<f64>() / ratios.len().max(1) as f64,
        "encoderSetupMs": {
            "count": setup.len(),
            "mean": setup.iter().sum::<f64>() / setup.len().max(1) as f64,
            "max": setup.iter().copied().fold(0.0, f64::max),
        },
        "csdHex": first_csd.as_deref().map(hex),
        "csdIdentical": csd_identical,
        "csdSei": first_csd.as_deref().map(sei_types),
        "perSegment": rows,
    }))
}
