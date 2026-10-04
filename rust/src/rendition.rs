//! **The rendition producer: the picture repackaged, the sound copied or
//! converted** (stream-server `docs/design/renditions.md`, steps F2 and F3).
//!
//! The server owns a rendition's route, its stream, cut rule, fMP4 muxer and
//! ring; what it asks of the embedder is a [`Producer`]: given a reader over
//! the media id, a plan and a time, hand encoded samples to a
//! [`SampleSink`]. This is that producer for the plans with the picture
//! copied: `Copy`/`Copy` -- an H.264 or HEVC film with AAC sound in a
//! container the receiver will not take, its samples moved into the
//! server's fMP4 as they are -- and `Copy`/`AacStereo`, the same with the
//! sound decoded, mixed down and encoded as stereo AAC ([`crate::sound`]),
//! the same bytes whichever run makes them.
//!
//! # A run
//!
//! [`Producer::start`] answers at once and the run goes on **a thread of its
//! own** (`rendition`), which is the only thread that touches it: it opens
//! the job's [`stream_server::MediaReader`] through libavformat
//! ([`crate::libav::Demuxer`]: a custom `AVIOContext` whose read and seek
//! callbacks are the reader's blocking calls), picks the film's video stream and the audio stream the
//! viewer had ([`RenditionSpec::audio_track`], an ordinal among the audio
//! streams, as mpv numbers them), reports both formats, seeks to the sync
//! point at or before the run's start, and then reads packet after packet
//! into the sink. Reads and sink writes on one thread is what the server's
//! speed rule assumes: the time blocked in each is subtracted from the run's
//! busy time, once.
//!
//! - **Timestamps**: a packet's presentation time, rescaled from its
//!   stream's time base to microseconds, **less the container's start**
//!   (`AVFormatContext.start_time`), so the film begins at zero as mpv
//!   shows it and as the stream's segments are counted. A packet with no
//!   presentation time takes its decode time, and failing that the last
//!   one's plus its duration (laced Matroska audio). The server derives
//!   decode times itself (`mux.rs`), so only presentation times cross.
//! - **Codec configuration**: Matroska carries H.264 as an `avcC` and its
//!   samples length-prefixed. The server's muxer wants `csd-0`/`csd-1` --
//!   SPS and PPS in Annex-B -- and takes a sample as length-prefixed only
//!   when it does not begin with a start code, which a four-byte length of
//!   256 to 511 does (`00 00 01 xx`). So both are handed over in Annex-B
//!   ([`H264Config`]); no bitstream filter is needed for that. HEVC the
//!   same way ([`HevcConfig`]): Matroska's `hvcC` becomes `csd-0` -- the
//!   VPS, SPS and PPS, and the SEI messages beside them (an HDR10 encode's
//!   mastering display and light levels) -- in Annex-B, and the samples go
//!   over in Annex-B too, which the server's muxer turns back into the
//!   four-byte length prefixes its `hvc1` + `hvcC` declares (ISO/IEC
//!   14496-15). Main 10 and HDR pass through as they are: the bit depth
//!   and the colours are in the parameter sets, which the muxer reads into
//!   the `hvcC` and a `colr`. AAC's AudioSpecificConfig is the container's
//!   as it is.
//! - **Dolby Vision** is not signalled to the receiver: a film whose
//!   container declares it (a `dvcC`/`dvvC`, [`libav::DolbyVision`]) goes
//!   over as the HEVC it is underneath, and the Dolby Vision NAL units in
//!   its samples (types 62 and 63, the RPU and the enhancement layer, which
//!   an HEVC decoder ignores) are dropped. That is right for profiles 7 and
//!   8, whose base layer is HDR10, SDR or HLG; profile 5's base layer is
//!   only Dolby Vision's own IPT-PQ-c2, which a receiver showing it as HEVC
//!   shows in the wrong colours, so a base layer with no compatibility
//!   ([`DolbyVision::compatibility`] 0) is refused with a sentence
//!   ([`dolby_vision_refusal`]).
//! - **Sync samples** are the container's key flags, as the source's index
//!   is: Matroska marks HEVC's IRAP pictures (IDR, CRA, BLA) key, and its
//!   cues index them, so the cut rule's keys and the samples' agree.
//! - **Seek and restart**: a run starts where the server says (two seconds
//!   before the cut of the first segment it makes); the demuxer is put on
//!   the sync point at or before it and the server discards what precedes
//!   the cut. A run from the start seeks to the start too, as the first
//!   run does (below): a slot's bytes must not depend on which run made
//!   it, and a seek is not a read from the file's first byte -- zond's
//!   film's audio packet at -21 ms, before the first cluster's key, is not
//!   returned after a seek to the start, and slot 0 made again by a run
//!   that did not seek had one audio frame more.
//! - **The source's index**, for the run that fixes the rendition's byte
//!   layout (`Job::wants_index`, stream-server `docs/design/renditions.md`
//!   §2.8): the video's sync samples from libavformat's index -- an MP4's
//!   sample tables, an AVI's `idx1`, Matroska's cues, which libavformat
//!   reads only at a first seek, so a run from the start seeks to it --
//!   each with its byte position, which for Matroska is moved from the
//!   cluster to the block itself ([`crate::matroska`]). Before the first
//!   sample.
//! - **Stopping**: the sink answering [`Stopped`] (unpublished, superseded
//!   by a seek, let go while idle) ends the run where it is; so does the
//!   server cancelling the reader, which wakes a read parked on a missing
//!   piece and fails libavformat's read. The demuxer, its I/O context and
//!   the reader are dropped on this thread as the run returns.
//! - **The end** is told from a broken source: a source that fails answers
//!   libavformat `AVERROR(EIO)`, never its end of file, and libavformat
//!   hands that error back out of `av_read_frame` (measured for Matroska,
//!   broken at 63 points through a film). Only `AVERROR_EOF` is
//!   [`SampleSink::end`]; an end would tell the server the film is over at
//!   that segment.
//!
//! **No timer anywhere.** A stalled torrent blocks the read, and the run
//! waits for as long as it does; the viewer is the one who gives up.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use stream_server::{
    AudioPlan, Job, Producer, ProducerRefusal, RenditionSpec, Sample, SampleSink, Stopped,
    TrackFormat, TrackKind, VideoPlan,
};

use crate::libav::{self, Demuxer, DolbyVision, Kind, Libav, Next, StreamInfo};
use crate::sound::{self, AacEncoder, SoundConverter};
use std::collections::{HashMap, VecDeque};
use stream_server::IndexEntry;

/// What a viewer is told when this device has no FFmpeg to read with.
pub const UNAVAILABLE: &str =
    "This device cannot repackage films for the television: the player's FFmpeg is not one \
     this app can use.";
/// What a viewer is told for a plan this producer does not build.
pub const NOT_BUILT: &str =
    "Converting this film's picture for the television is not built yet; only repackaging \
     it and converting its sound are.";
/// What a viewer is told when this device has nothing to encode AAC with.
pub const NO_AAC_ENCODER: &str =
    "This device cannot convert the film's sound for the television: it has no AAC encoder \
     this app can use.";
/// The sound's conversion failed partway.
pub const SOUND_FAILED: &str = "Converting this film's sound for the television failed.";

/// The sentence for a film whose picture is `codec` (an `AVCodecID`),
/// which this producer does not copy.
pub fn video_refusal(codec: std::ffi::c_int) -> String {
    match libav::codec_name(codec) {
        Some(name) => {
            format!("This film's video is {name}, which xtremio can't convert for casting yet.")
        }
        None => {
            "This film's video is in a format xtremio can't convert for casting yet.".to_owned()
        }
    }
}

/// The sentence for a film whose sound is `codec` (an `AVCodecID`), which
/// this producer neither copies nor decodes.
pub fn audio_refusal(codec: std::ffi::c_int) -> String {
    match libav::codec_name(codec) {
        Some(name) => {
            format!("This film's sound is {name}, which xtremio can't convert for casting yet.")
        }
        None => {
            "This film's sound is in a format xtremio can't convert for casting yet.".to_owned()
        }
    }
}

/// The sentence for a Dolby Vision film whose base layer no decoder but
/// Dolby Vision's shows right, or `None` for one a copy carries.
pub fn dolby_vision_refusal(dolby_vision: Option<DolbyVision>) -> Option<String> {
    let dv = dolby_vision?;
    (dv.compatibility == 0).then(|| {
        format!(
            "This film's picture is Dolby Vision profile {}, which has no ordinary HDR or SDR \
             picture underneath: the television would show it in the wrong colours.",
            dv.profile
        )
    })
}
/// The film's header could not be read.
pub const UNREADABLE: &str = "This film could not be read to repackage it for the television.";
/// The source failed, or the file could not be read past a point.
pub const BROKEN: &str = "Reading this film for the television stopped partway: the source failed.";
/// The film could not be sought in for the receiver's position.
pub const UNSEEKABLE: &str =
    "This film cannot be started partway for the television: it has no index to seek by.";

/// Runs alive now: a run's thread counts itself in and out.
static RUNS: AtomicUsize = AtomicUsize::new(0);

/// How many runs are alive: a probe for the tests that a stopped run's
/// thread really ends. Nothing decides anything from it.
#[doc(hidden)]
pub fn live_runs() -> usize {
    RUNS.load(Ordering::SeqCst)
}

struct Live;

impl Live {
    fn enter() -> Self {
        RUNS.fetch_add(1, Ordering::SeqCst);
        Self
    }
}

impl Drop for Live {
    fn drop(&mut self) {
        RUNS.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Whether this process can repackage: a player has loaded libmpv and its
/// FFmpeg is the one [`crate::libav`] is bound to. What the app's cast
/// decision asks before it offers a rendition.
pub fn available() -> bool {
    Libav::registered().is_ok()
}

/// **The producer the app installs** (`ServerHandle::install_producer`, at
/// every server start): repackages `Copy`/`Copy`, refuses the rest.
pub struct Repackager {
    libav: fn() -> Result<&'static Libav, String>,
}

impl Repackager {
    /// Reads with the FFmpeg of the libmpv the player registered.
    pub fn registered() -> Arc<Self> {
        Arc::new(Self {
            libav: Libav::registered,
        })
    }
}

/// Why `spec` is not one this producer makes, if it is not.
fn refusal_for(spec: &RenditionSpec) -> Option<&'static str> {
    match (&spec.video, &spec.audio) {
        (VideoPlan::Copy, AudioPlan::Copy | AudioPlan::AacStereo { .. }) => None,
        _ => Some(NOT_BUILT),
    }
}

impl Producer for Repackager {
    fn start(&self, job: Job) -> Result<(), ProducerRefusal> {
        if let Some(sentence) = refusal_for(&job.spec) {
            return Err(ProducerRefusal(sentence.to_owned()));
        }
        let libav = (self.libav)().map_err(|error| {
            tracing::warn!(%error, "no FFmpeg to repackage with");
            ProducerRefusal(UNAVAILABLE.to_owned())
        })?;
        let live = Live::enter();
        std::thread::Builder::new()
            .name("rendition".to_owned())
            .spawn(move || {
                let _live = live;
                run(libav, job);
            })
            .map(drop)
            .map_err(|error| {
                tracing::warn!(%error, "could not start a rendition thread");
                ProducerRefusal(UNREADABLE.to_owned())
            })
    }
}

/// One run, on its own thread: open, then [`repackage`].
fn run(libav: &'static Libav, job: Job) {
    let Job {
        reader,
        spec,
        from,
        wants_index,
        sink,
    } = job;
    tracing::info!(from_ms = from.as_millis() as u64, "rendition run reading");
    let mut demuxer = match Demuxer::open(libav, reader) {
        Ok(demuxer) => demuxer,
        Err(error) => {
            tracing::warn!(%error, "a rendition's source could not be opened");
            sink.fail(UNREADABLE.to_owned());
            return;
        }
    };
    repackage(&mut demuxer, &spec, from, wants_index, sink);
}

// --- The run, over what it reads and where it writes -------------------------------

/// What a run reads: [`Demuxer`], or a fake in the tests.
pub trait Packets {
    fn streams(&self) -> &[StreamInfo];
    /// The container's first timestamp, microseconds: the film's zero.
    fn start_us(&self) -> i64;
    /// Move to the sync point at or before `at_us` on the film's clock.
    fn seek_us(&mut self, at_us: i64) -> Result<(), String>;
    fn read_packet(&mut self) -> Next;
    /// `video`'s sync samples where the source's index puts them, on the
    /// film's clock ([`film_index`]).
    fn index(&mut self, video: &StreamInfo) -> Vec<IndexEntry>;
    /// What converts `audio` to stereo AAC at `bitrate` for a run from
    /// `from_us`, or the sentence for why this device cannot.
    fn sound_converter(
        &self,
        audio: &StreamInfo,
        bitrate: u32,
        from_us: i64,
    ) -> Result<SoundConverter, String>;
}

impl<S: libav::Source> Packets for Demuxer<S> {
    fn streams(&self) -> &[StreamInfo] {
        Demuxer::streams(self)
    }

    fn start_us(&self) -> i64 {
        Demuxer::start_us(self)
    }

    fn seek_us(&mut self, at_us: i64) -> Result<(), String> {
        Demuxer::seek_us(self, at_us)
    }

    fn read_packet(&mut self) -> Next {
        Demuxer::read_packet(self)
    }

    fn index(&mut self, video: &StreamInfo) -> Vec<IndexEntry> {
        let entries = self.index_entries(video.index);
        let matroska = self.format_name().split(',').any(|name| name == "matroska");
        let blocks = if matroska {
            let mut read = |offset: u64, len: usize| self.read_source_at(offset, len);
            let got = crate::matroska::read_cues(&mut read);
            match got {
                Ok(Some(cues)) => {
                    let keys: Vec<(u64, u64)> = entries
                        .iter()
                        .filter_map(|entry| {
                            Some((
                                u64::try_from(entry.timestamp).ok()?,
                                u64::try_from(entry.pos).ok()?,
                            ))
                        })
                        .collect();
                    cues.blocks(&keys)
                }
                Ok(None) => HashMap::new(),
                Err(error) => {
                    tracing::warn!(%error, "a rendition's Matroska cues could not be read");
                    HashMap::new()
                }
            }
        } else {
            HashMap::new()
        };
        film_index(&entries, &blocks, video.time_base, self.start_us())
    }

    fn sound_converter(
        &self,
        audio: &StreamInfo,
        bitrate: u32,
        from_us: i64,
    ) -> Result<SoundConverter, String> {
        let unavailable = |error: String| {
            tracing::warn!(%error, "no FFmpeg to convert a rendition's sound with");
            UNAVAILABLE.to_owned()
        };
        let par = self.codec_parameters(audio.index).map_err(unavailable)?;
        let decoder = libav::SoundDecoder::new(par)
            .map_err(unavailable)?
            .ok_or_else(|| audio_refusal(audio.codec))?;
        let encoder = aac_encoder(self.libav(), bitrate)?;
        Ok(SoundConverter::new(
            Box::new(decoder),
            encoder,
            audio.time_base,
            self.start_us(),
            from_us,
        ))
    }
}

/// **The AAC encoder this device has**: Android's `MediaCodec` on a phone
/// (whose libmpv has no encoder), FFmpeg's own where the library has it (a
/// desktop's system FFmpeg); otherwise [`NO_AAC_ENCODER`].
fn aac_encoder(libav: &'static Libav, bitrate: u32) -> Result<Box<dyn AacEncoder>, String> {
    #[cfg(target_os = "android")]
    match crate::mediacodec::NdkAac::open(bitrate) {
        Ok((codec, delay)) => {
            return Ok(Box::new(crate::mediacodec::CodecAac::new(codec, delay)));
        }
        Err(error) => tracing::warn!(%error, "no MediaCodec AAC encoder"),
    }
    match libav::LibavAac::new(libav, bitrate) {
        Some(encoder) => Ok(Box::new(encoder)),
        None => Err(NO_AAC_ENCODER.to_owned()),
    }
}

/// **The index a rendition's layout mirrors**: the sync samples of
/// `entries` (one stream's, in its time base `time_base`), on the film's
/// clock (less `start_us`), each at its block's position in `blocks` when
/// the container's index put it at its cluster's (Matroska), else where
/// the index put it.
pub fn film_index(
    entries: &[libav::IndexEntry],
    blocks: &HashMap<(u64, u64), u64>,
    time_base: libav::Rational,
    start_us: i64,
) -> Vec<IndexEntry> {
    entries
        .iter()
        .filter(|entry| entry.keyframe)
        .filter_map(|entry| {
            let pos = u64::try_from(entry.pos).ok()?;
            let at = u64::try_from(entry.timestamp).ok();
            let pos = at
                .and_then(|at| blocks.get(&(at, pos)).copied())
                .unwrap_or(pos);
            Some(IndexEntry {
                pts_us: libav::to_us(entry.timestamp, time_base)? - start_us,
                pos,
            })
        })
        .collect()
}

/// Where a run writes: [`SampleSink`], or a fake in the tests.
pub trait Sink {
    fn format(&self, track: TrackKind, format: TrackFormat) -> Result<(), Stopped>;
    fn index(&self, entries: Vec<IndexEntry>) -> Result<(), Stopped>;
    fn sample(&self, sample: Sample) -> Result<(), Stopped>;
    fn end(self);
    fn fail(self, sentence: String);
}

impl Sink for SampleSink {
    fn format(&self, track: TrackKind, format: TrackFormat) -> Result<(), Stopped> {
        SampleSink::format(self, track, format)
    }

    fn index(&self, entries: Vec<IndexEntry>) -> Result<(), Stopped> {
        SampleSink::index(self, entries)
    }

    fn sample(&self, sample: Sample) -> Result<(), Stopped> {
        SampleSink::sample(self, sample)
    }

    fn end(self) {
        SampleSink::end(self);
    }

    fn fail(self, sentence: String) {
        SampleSink::fail(self, sentence);
    }
}

/// **A run**: formats, the seek, the source's index when `wants_index`,
/// then every packet of the two chosen streams into `sink`, until the sink
/// stops it, the film ends or the source fails.
pub fn repackage<P: Packets, K: Sink>(
    packets: &mut P,
    spec: &RenditionSpec,
    from: Duration,
    wants_index: bool,
    sink: K,
) {
    let mut chosen = match Chosen::of(packets.streams(), spec.audio_track, &spec.audio) {
        Ok(chosen) => chosen,
        Err(sentence) => {
            sink.fail(sentence);
            return;
        }
    };
    // AAC in ADTS (a transport stream's) has no AudioSpecificConfig in the
    // header: it is the first frame's ADTS header, so the run reads up to
    // that frame first and hands what it read out again after.
    let mut pending: VecDeque<Next> = VecDeque::new();
    if chosen.adts {
        loop {
            let next = packets.read_packet();
            let first_audio = match &next {
                Next::Packet(packet) if packet.stream == chosen.audio.index => {
                    Some(adts_config(&packet.data))
                }
                Next::Packet(_) => None,
                Next::End | Next::Failed(_) => Some(None),
            };
            pending.push_back(next);
            match first_audio {
                None => continue,
                Some(Some(config)) => {
                    chosen.set_audio_config(config);
                    break;
                }
                Some(None) => {
                    sink.fail(UNREADABLE.to_owned());
                    return;
                }
            }
        }
    }
    let from_us = i64::try_from(from.as_micros()).unwrap_or(i64::MAX);
    // The sound to convert, if it is: refused here, before any format, when
    // this device cannot.
    let mut converter = match &spec.audio {
        AudioPlan::Copy => None,
        AudioPlan::AacStereo { bitrate } => {
            match packets.sound_converter(&chosen.audio, *bitrate, from_us) {
                Ok(converter) => Some(converter),
                Err(sentence) => {
                    sink.fail(sentence);
                    return;
                }
            }
        }
    };
    if sink
        .format(TrackKind::Video, chosen.video_format.clone())
        .is_err()
        || sink
            .format(TrackKind::Audio, chosen.audio_format.clone())
            .is_err()
    {
        return;
    }
    // Every run seeks, so what was read ahead is from before wherever the
    // seek goes.
    pending.clear();
    if from_us > 0 {
        if let Err(error) = packets.seek_us(from_us) {
            tracing::warn!(%error, "a rendition's source could not be sought in");
            sink.fail(UNSEEKABLE.to_owned());
            return;
        }
    } else if let Err(error) = packets.seek_us(0) {
        // A run from the start seeks to it: a Matroska file's cues are read
        // at a first seek (the index), and every run from the start must
        // read what the first one did. One that fails costs the index, not
        // the run.
        tracing::warn!(%error, "a rendition's source could not be sought to its start");
    }
    if wants_index && sink.index(packets.index(&chosen.video)).is_err() {
        return;
    }
    let start = packets.start_us();
    let mut video_clock = Clock::default();
    let mut audio_clock = Clock::default();
    loop {
        let next = pending.pop_front().unwrap_or_else(|| packets.read_packet());
        let packet = match next {
            Next::Packet(packet) => packet,
            Next::End => {
                if let Some(converter) = &mut converter {
                    match converter.finish() {
                        Ok(samples) => {
                            for sample in samples {
                                if sink.sample(sample).is_err() {
                                    return;
                                }
                            }
                        }
                        Err(error) => {
                            tracing::warn!(%error, "a rendition's sound could not be converted");
                            sink.fail(SOUND_FAILED.to_owned());
                            return;
                        }
                    }
                }
                sink.end();
                return;
            }
            Next::Failed(error) => {
                tracing::warn!(%error, "a rendition's source stopped");
                sink.fail(BROKEN.to_owned());
                return;
            }
        };
        let (track, stream, clock) = if packet.stream == chosen.video.index {
            (TrackKind::Video, &chosen.video, &mut video_clock)
        } else if packet.stream == chosen.audio.index {
            (TrackKind::Audio, &chosen.audio, &mut audio_clock)
        } else {
            continue;
        };
        let Some(pts_us) = clock.pts_us(&packet, stream.time_base) else {
            continue;
        };
        if let (TrackKind::Audio, Some(converter)) = (track, &mut converter) {
            match converter.push(pts_us - start, packet) {
                Ok(samples) => {
                    for sample in samples {
                        if sink.sample(sample).is_err() {
                            return;
                        }
                    }
                }
                Err(error) => {
                    tracing::warn!(%error, "a rendition's sound could not be converted");
                    sink.fail(SOUND_FAILED.to_owned());
                    return;
                }
            }
            continue;
        }
        let (key, data) = match track {
            TrackKind::Video => (packet.key, chosen.config.sample(packet.data)),
            TrackKind::Audio if chosen.adts => (true, strip_adts(packet.data)),
            TrackKind::Audio => (true, packet.data),
        };
        let sample = Sample {
            track,
            pts_us: pts_us - start,
            key,
            data,
        };
        if sink.sample(sample).is_err() {
            return;
        }
    }
}

/// A track's clock: the last presentation time and duration, for a packet
/// that carries none.
#[derive(Default)]
struct Clock {
    last: Option<(i64, i64)>,
}

impl Clock {
    /// `packet`'s presentation time in microseconds (the container's, not
    /// yet rebased): its own, its decode time, or the last one's end.
    fn pts_us(&mut self, packet: &libav::Packet, time_base: libav::Rational) -> Option<i64> {
        let duration = libav::to_us(packet.duration, time_base).filter(|d| *d > 0);
        let pts = libav::to_us(packet.pts, time_base)
            .or_else(|| libav::to_us(packet.dts, time_base))
            .or_else(|| {
                self.last
                    .and_then(|(pts, duration)| (duration > 0).then_some(pts + duration))
            })?;
        let carried = duration.or(self.last.map(|(_, duration)| duration));
        self.last = Some((pts, carried.unwrap_or(0)));
        Some(pts)
    }
}

/// The two streams a run copies, with the formats the server is told.
struct Chosen {
    video: StreamInfo,
    audio: StreamInfo,
    config: VideoConfig,
    video_format: TrackFormat,
    audio_format: TrackFormat,
    /// The audio comes in ADTS frames, and its configuration is the first
    /// frame's header ([`adts_config`]).
    adts: bool,
}

impl Chosen {
    /// The film's video -- the first video stream that is not a cover
    /// picture -- and the `audio_track`-th audio stream, the video a codec
    /// a copy can carry and the audio one too unless `audio` converts it;
    /// or the sentence for why not.
    fn of(
        streams: &[StreamInfo],
        audio_track: u32,
        audio_plan: &AudioPlan,
    ) -> Result<Self, String> {
        let video = streams
            .iter()
            .find(|stream| stream.kind == Kind::Video && !stream.attached_picture)
            .ok_or("This film has no picture to send to the television.")?;
        let config = match video.codec {
            libav::AV_CODEC_ID_H264 => {
                VideoConfig::H264(H264Config::of(&video.extradata).ok_or(UNREADABLE)?)
            }
            libav::AV_CODEC_ID_HEVC => {
                if let Some(sentence) = dolby_vision_refusal(video.dolby_vision) {
                    return Err(sentence);
                }
                VideoConfig::Hevc(HevcConfig::of(&video.extradata).ok_or(UNREADABLE)?)
            }
            other => return Err(video_refusal(other)),
        };
        let audio = streams
            .iter()
            .filter(|stream| stream.kind == Kind::Audio)
            .nth(audio_track as usize)
            .ok_or("The sound track being played is not in the film any more.")?;
        let (audio_format, adts) = match audio_plan {
            AudioPlan::Copy if audio.codec != libav::AV_CODEC_ID_AAC => {
                return Err(audio_refusal(audio.codec));
            }
            AudioPlan::Copy => (
                TrackFormat::Aac {
                    sample_rate: audio.sample_rate,
                    channels: audio.channels.max(1),
                    csd0: audio.extradata.clone(),
                },
                audio.extradata.is_empty(),
            ),
            // What every conversion makes, whatever the encoder.
            AudioPlan::AacStereo { .. } => (
                TrackFormat::Aac {
                    sample_rate: libav::SOUND_RATE,
                    channels: libav::SOUND_CHANNELS as u32,
                    csd0: Bytes::from_static(&sound::AUDIO_SPECIFIC_CONFIG),
                },
                false,
            ),
        };
        Ok(Self {
            video_format: config.format(video.width, video.height),
            audio_format,
            adts,
            video: video.clone(),
            audio: audio.clone(),
            config,
        })
    }

    fn set_audio_config(&mut self, config: Bytes) {
        if let TrackFormat::Aac { csd0, .. } = &mut self.audio_format {
            *csd0 = config;
        }
    }
}

/// The AudioSpecificConfig an ADTS frame's header describes -- the object
/// type (its profile plus one), the sampling frequency index, the channel
/// configuration -- or `None` for a frame that is not ADTS.
pub fn adts_config(frame: &[u8]) -> Option<Bytes> {
    if frame.len() < 7 || frame[0] != 0xff || frame[1] & 0xf0 != 0xf0 {
        return None;
    }
    let object = (frame[2] >> 6) + 1;
    let frequency = (frame[2] >> 2) & 0x0f;
    let channels = ((frame[2] & 0x01) << 2) | (frame[3] >> 6);
    Some(Bytes::from(vec![
        (object << 3) | (frequency >> 1),
        ((frequency & 1) << 7) | (channels << 3),
    ]))
}

/// An ADTS frame's payload: its header (seven bytes, nine with a CRC) off.
/// A frame that is not ADTS is handed on as it is.
pub fn strip_adts(frame: Bytes) -> Bytes {
    if frame.len() < 7 || frame[0] != 0xff || frame[1] & 0xf0 != 0xf0 {
        return frame;
    }
    let header = if frame[1] & 0x01 == 1 { 7 } else { 9 };
    frame.slice(header.min(frame.len())..)
}

const START_CODE: [u8; 4] = [0, 0, 0, 1];

/// H.264's configuration as the server wants it -- SPS in `csd0`, PPS in
/// `csd1`, both Annex-B -- and how the container frames its samples.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct H264Config {
    pub csd0: Bytes,
    pub csd1: Bytes,
    /// The size of each NAL unit's length prefix in a sample (an `avcC`'s
    /// `lengthSizeMinusOne` + 1), or `None` for samples already in Annex-B.
    pub length_size: Option<usize>,
}

impl H264Config {
    /// From a container's H.264 extradata: an `avcC` (Matroska, MP4) or
    /// parameter sets in Annex-B (a transport stream's). `None` for
    /// anything else, or one with no SPS or no PPS.
    pub fn of(extradata: &[u8]) -> Option<Self> {
        let (sps, pps, length_size) = if starts_annex_b(extradata) {
            let mut sps = Vec::new();
            let mut pps = Vec::new();
            for unit in annex_b_units(extradata) {
                match unit.first().map(|header| header & 0x1f) {
                    Some(7) => sps.push(unit),
                    Some(8) => pps.push(unit),
                    _ => {}
                }
            }
            (sps, pps, None)
        } else {
            let (sps, pps, length_size) = avcc_sets(extradata)?;
            (sps, pps, Some(length_size))
        };
        if sps.is_empty() || pps.is_empty() {
            return None;
        }
        let annex_b = |units: &[&[u8]]| -> Bytes {
            let mut out = Vec::new();
            for unit in units {
                out.extend_from_slice(&START_CODE);
                out.extend_from_slice(unit);
            }
            Bytes::from(out)
        };
        Some(Self {
            csd0: annex_b(&sps),
            csd1: annex_b(&pps),
            length_size,
        })
    }

    /// A sample as the server takes it: Annex-B, each NAL unit behind a
    /// four-byte start code. A sample whose lengths run past its end keeps
    /// the units before the bad one.
    pub fn sample(&self, data: Bytes) -> Bytes {
        let Some(size) = self.length_size else {
            return data;
        };
        let mut out = Vec::with_capacity(data.len() + 8);
        for unit in length_prefixed_units(&data, size) {
            out.extend_from_slice(&START_CODE);
            out.extend_from_slice(unit);
        }
        Bytes::from(out)
    }
}

/// HEVC's configuration as the server wants it -- `csd0`, the VPS, SPS and
/// PPS and any SEI messages beside them, Annex-B -- and how the container
/// frames its samples.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HevcConfig {
    pub csd0: Bytes,
    /// The size of each NAL unit's length prefix in a sample (an `hvcC`'s
    /// `lengthSizeMinusOne` + 1), or `None` for samples already in Annex-B.
    pub length_size: Option<usize>,
}

/// HEVC NAL unit types (H.265 table 7-1) this producer reads.
const HEVC_VPS: u8 = 32;
const HEVC_SPS: u8 = 33;
const HEVC_PPS: u8 = 34;
const HEVC_PREFIX_SEI: u8 = 39;
const HEVC_SUFFIX_SEI: u8 = 40;
/// Unspecified in HEVC and ignored by its decoders; Dolby Vision's RPU
/// (62) and enhancement layer (63) in practice, dropped from samples.
const HEVC_UNSPECIFIED_62: u8 = 62;
const HEVC_UNSPECIFIED_63: u8 = 63;

fn hevc_type(unit: &[u8]) -> Option<u8> {
    unit.first().map(|header| (header >> 1) & 0x3f)
}

impl HevcConfig {
    /// From a container's HEVC extradata: an `hvcC` (Matroska, MP4) or
    /// parameter sets in Annex-B (a transport stream's). `None` for
    /// anything else, or one without a VPS, an SPS and a PPS.
    pub fn of(extradata: &[u8]) -> Option<Self> {
        let (units, length_size) = if starts_annex_b(extradata) {
            (annex_b_units(extradata), None)
        } else {
            let (units, length_size) = hvcc_units(extradata)?;
            (units, Some(length_size))
        };
        let kept: Vec<&[u8]> = units
            .into_iter()
            .filter(|unit| {
                matches!(
                    hevc_type(unit),
                    Some(HEVC_VPS | HEVC_SPS | HEVC_PPS | HEVC_PREFIX_SEI | HEVC_SUFFIX_SEI)
                )
            })
            .collect();
        for needed in [HEVC_VPS, HEVC_SPS, HEVC_PPS] {
            if !kept.iter().any(|unit| hevc_type(unit) == Some(needed)) {
                return None;
            }
        }
        let mut csd0 = Vec::new();
        for unit in kept {
            csd0.extend_from_slice(&START_CODE);
            csd0.extend_from_slice(unit);
        }
        Some(Self {
            csd0: Bytes::from(csd0),
            length_size,
        })
    }

    /// A sample as the server takes it: Annex-B, each NAL unit behind a
    /// four-byte start code, Dolby Vision's units (62, 63) left out.
    pub fn sample(&self, data: Bytes) -> Bytes {
        let units: Vec<&[u8]> = match self.length_size {
            Some(size) => length_prefixed_units(&data, size),
            None => annex_b_units(&data),
        };
        let kept = |unit: &[u8]| {
            !matches!(
                hevc_type(unit),
                Some(HEVC_UNSPECIFIED_62 | HEVC_UNSPECIFIED_63)
            )
        };
        if self.length_size.is_none() && units.iter().all(|unit| kept(unit)) {
            return data;
        }
        let mut out = Vec::with_capacity(data.len() + 8);
        for unit in units.into_iter().filter(|unit| kept(unit)) {
            out.extend_from_slice(&START_CODE);
            out.extend_from_slice(unit);
        }
        Bytes::from(out)
    }
}

/// The NAL units of a sample whose units each follow a `size`-byte length;
/// a length that runs past the end ends the sample there.
fn length_prefixed_units(data: &[u8], size: usize) -> Vec<&[u8]> {
    let mut units = Vec::new();
    let mut at = 0;
    while at + size <= data.len() {
        let len = data[at..at + size]
            .iter()
            .fold(0usize, |len, byte| (len << 8) | usize::from(*byte));
        at += size;
        let Some(unit) = data.get(at..at + len) else {
            break;
        };
        units.push(unit);
        at += len;
    }
    units
}

/// The NAL units of an `hvcC` (ISO/IEC 14496-15 §8.3.3.1), every array's,
/// and its NAL length size.
fn hvcc_units(hvcc: &[u8]) -> Option<(Vec<&[u8]>, usize)> {
    if hvcc.len() < 23 {
        return None;
    }
    let length_size = usize::from(hvcc[21] & 0x03) + 1;
    let arrays = hvcc[22];
    let mut at = 23;
    let mut units = Vec::new();
    let u16_at = |at: usize| -> Option<usize> {
        Some(usize::from(u16::from_be_bytes([
            *hvcc.get(at)?,
            *hvcc.get(at + 1)?,
        ])))
    };
    for _ in 0..arrays {
        let count = u16_at(at + 1)?;
        at += 3;
        for _ in 0..count {
            let len = u16_at(at)?;
            at += 2;
            units.push(hvcc.get(at..at + len)?);
            at += len;
        }
    }
    Some((units, length_size))
}

/// The video's configuration, by codec.
#[derive(Clone, Debug, PartialEq, Eq)]
enum VideoConfig {
    H264(H264Config),
    Hevc(HevcConfig),
}

impl VideoConfig {
    fn format(&self, width: u32, height: u32) -> TrackFormat {
        match self {
            Self::H264(h264) => TrackFormat::H264 {
                width,
                height,
                csd0: h264.csd0.clone(),
                csd1: h264.csd1.clone(),
            },
            Self::Hevc(hevc) => TrackFormat::Hevc {
                width,
                height,
                csd0: hevc.csd0.clone(),
            },
        }
    }

    fn sample(&self, data: Bytes) -> Bytes {
        match self {
            Self::H264(h264) => h264.sample(data),
            Self::Hevc(hevc) => hevc.sample(data),
        }
    }
}

fn starts_annex_b(data: &[u8]) -> bool {
    data.starts_with(&[0, 0, 1]) || data.starts_with(&[0, 0, 0, 1])
}

/// The NAL units of an Annex-B buffer, start codes off.
fn annex_b_units(data: &[u8]) -> Vec<&[u8]> {
    let mut starts = Vec::new();
    let mut at = 0;
    while at + 3 <= data.len() {
        if data[at..at + 3] == [0, 0, 1] {
            starts.push(at + 3);
            at += 3;
        } else {
            at += 1;
        }
    }
    starts
        .iter()
        .enumerate()
        .map(|(index, &start)| {
            let end = starts.get(index + 1).map_or(data.len(), |next| next - 3);
            let mut unit = &data[start..end];
            while let [rest @ .., 0] = unit {
                unit = rest;
            }
            unit
        })
        .filter(|unit| !unit.is_empty())
        .collect()
}

type AvccSets<'a> = (Vec<&'a [u8]>, Vec<&'a [u8]>, usize);

/// The SPS and PPS units of an `avcC` (ISO/IEC 14496-15 §5.3.3.1) and its
/// NAL length size.
fn avcc_sets(avcc: &[u8]) -> Option<AvccSets<'_>> {
    if avcc.len() < 7 || avcc[0] != 1 {
        return None;
    }
    let length_size = usize::from(avcc[4] & 0x03) + 1;
    let mut at = 5;
    let take = |count: usize, at: &mut usize| -> Option<Vec<&[u8]>> {
        let mut units = Vec::with_capacity(count);
        for _ in 0..count {
            let len = usize::from(u16::from_be_bytes([*avcc.get(*at)?, *avcc.get(*at + 1)?]));
            *at += 2;
            units.push(avcc.get(*at..*at + len)?);
            *at += len;
        }
        Some(units)
    };
    let sps_count = usize::from(avcc[at] & 0x1f);
    at += 1;
    let sps = take(sps_count, &mut at)?;
    let pps_count = usize::from(*avcc.get(at)?);
    at += 1;
    let pps = take(pps_count, &mut at)?;
    Some((sps, pps, length_size))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;

    const SPS: &[u8] = &[0x67, 0x64, 0x00, 0x0d, 0xac, 0xd9];
    const PPS: &[u8] = &[0x68, 0xeb, 0xe3];

    fn avcc(length_size: u8) -> Vec<u8> {
        let mut out = vec![1, 0x64, 0x00, 0x0d, 0xfc | (length_size - 1), 0xe1];
        out.extend_from_slice(&(SPS.len() as u16).to_be_bytes());
        out.extend_from_slice(SPS);
        out.push(1);
        out.extend_from_slice(&(PPS.len() as u16).to_be_bytes());
        out.extend_from_slice(PPS);
        out
    }

    fn annex_b(units: &[&[u8]]) -> Vec<u8> {
        units
            .iter()
            .flat_map(|unit| START_CODE.iter().chain(unit.iter()).copied())
            .collect()
    }

    /// **An `avcC` becomes Annex-B parameter sets, and a length-prefixed
    /// sample Annex-B units** -- including one whose four-byte length is
    /// 256 to 511, which reads as a start code (`00 00 01 xx`) and is why
    /// the server is never handed length-prefixed samples.
    #[test]
    fn an_avcc_and_its_samples_are_handed_over_in_annex_b() {
        let config = H264Config::of(&avcc(4)).expect("an avcC");
        assert_eq!(config.csd0.as_ref(), annex_b(&[SPS]).as_slice());
        assert_eq!(config.csd1.as_ref(), annex_b(&[PPS]).as_slice());
        assert_eq!(config.length_size, Some(4));

        let slice = vec![0x41u8; 300];
        let mut sample = (300u32).to_be_bytes().to_vec();
        assert_eq!(
            &sample[..3],
            &[0, 0, 1],
            "this length looks like a start code"
        );
        sample.extend_from_slice(&slice);
        sample.extend_from_slice(&2u32.to_be_bytes());
        sample.extend_from_slice(&[0x06, 0x05]);
        let out = config.sample(Bytes::from(sample));
        assert_eq!(out.as_ref(), annex_b(&[&slice, &[0x06, 0x05]]).as_slice());

        let two = H264Config::of(&avcc(2)).unwrap();
        let out = two.sample(Bytes::from_static(&[0, 3, 0x65, 1, 2, 0, 9]));
        assert_eq!(
            out.as_ref(),
            annex_b(&[&[0x65, 1, 2]]).as_slice(),
            "a length past the end keeps what came before it"
        );
    }

    #[test]
    fn annex_b_extradata_is_split_and_its_samples_pass_through() {
        let extradata = annex_b(&[SPS, PPS]);
        let config = H264Config::of(&extradata).expect("Annex-B extradata");
        assert_eq!(config.csd0.as_ref(), annex_b(&[SPS]).as_slice());
        assert_eq!(config.csd1.as_ref(), annex_b(&[PPS]).as_slice());
        assert_eq!(config.length_size, None);
        let sample = Bytes::from(annex_b(&[&[0x65, 7]]));
        assert_eq!(config.sample(sample.clone()), sample);
        assert_eq!(H264Config::of(&[1, 2, 3]), None);
        assert_eq!(H264Config::of(&annex_b(&[SPS])), None, "no PPS");
    }

    // --- The run, against a fake demuxer and a fake sink -------------------------

    fn stream(index: usize, kind: Kind, codec: i32) -> StreamInfo {
        StreamInfo {
            index,
            kind,
            codec,
            attached_picture: false,
            extradata: match kind {
                Kind::Video => Bytes::from(avcc(4)),
                Kind::Audio => Bytes::from_static(&[0x11, 0x90]),
                Kind::Other => Bytes::new(),
            },
            width: 320,
            height: 240,
            sample_rate: if kind == Kind::Audio { 48_000 } else { 0 },
            channels: if kind == Kind::Audio { 2 } else { 0 },
            time_base: libav::Rational { num: 1, den: 1000 },
            dolby_vision: None,
        }
    }

    fn packet(stream: usize, pts: i64, key: bool, data: &'static [u8]) -> Next {
        Next::Packet(libav::Packet {
            stream,
            pts,
            dts: libav::NOPTS,
            duration: 0,
            key,
            data: Bytes::from_static(data),
        })
    }

    struct FakePackets {
        streams: Vec<StreamInfo>,
        start_us: i64,
        queue: Vec<Next>,
        seeks: Vec<i64>,
        reads: usize,
        /// What [`Packets::index`] answers, and the streams it was asked of.
        index: Vec<IndexEntry>,
        indexed: Vec<usize>,
        /// A seek starts the queue again from this, as a seek to the
        /// start does.
        rewinds_to: Option<Vec<Next>>,
        /// What [`Packets::sound_converter`] makes, and what it was asked.
        sound: Option<fn() -> SoundConverter>,
        converted: RefCell<Vec<(usize, u32, i64)>>,
    }

    impl Packets for FakePackets {
        fn streams(&self) -> &[StreamInfo] {
            &self.streams
        }
        fn start_us(&self) -> i64 {
            self.start_us
        }
        fn seek_us(&mut self, at_us: i64) -> Result<(), String> {
            self.seeks.push(at_us);
            if let Some(all) = &self.rewinds_to {
                self.queue = all.clone();
            }
            Ok(())
        }
        fn read_packet(&mut self) -> Next {
            self.reads += 1;
            if self.queue.is_empty() {
                Next::End
            } else {
                self.queue.remove(0)
            }
        }
        fn index(&mut self, video: &StreamInfo) -> Vec<IndexEntry> {
            self.indexed.push(video.index);
            self.index.clone()
        }
        fn sound_converter(
            &self,
            audio: &StreamInfo,
            bitrate: u32,
            from_us: i64,
        ) -> Result<SoundConverter, String> {
            self.converted
                .borrow_mut()
                .push((audio.index, bitrate, from_us));
            match &self.sound {
                Some(make) => Ok(make()),
                None => Err(audio_refusal(audio.codec)),
            }
        }
    }

    #[derive(Debug, PartialEq)]
    enum Wrote {
        Format(TrackKind, TrackFormat),
        Index(Vec<IndexEntry>),
        Sample(TrackKind, i64, bool, Vec<u8>),
        End,
        Fail(String),
    }

    /// Records what it was handed; stops after `stop_after` samples.
    #[derive(Clone)]
    struct FakeSink {
        wrote: Rc<RefCell<Vec<Wrote>>>,
        stop_after: Option<usize>,
    }

    impl FakeSink {
        fn new(stop_after: Option<usize>) -> Self {
            Self {
                wrote: Rc::default(),
                stop_after,
            }
        }
        fn samples(&self) -> usize {
            self.wrote
                .borrow()
                .iter()
                .filter(|wrote| matches!(wrote, Wrote::Sample(..)))
                .count()
        }
    }

    impl Sink for FakeSink {
        fn format(&self, track: TrackKind, format: TrackFormat) -> Result<(), Stopped> {
            self.wrote.borrow_mut().push(Wrote::Format(track, format));
            Ok(())
        }
        fn index(&self, entries: Vec<IndexEntry>) -> Result<(), Stopped> {
            self.wrote.borrow_mut().push(Wrote::Index(entries));
            Ok(())
        }
        fn sample(&self, sample: Sample) -> Result<(), Stopped> {
            if self.stop_after.is_some_and(|after| self.samples() >= after) {
                return Err(Stopped);
            }
            self.wrote.borrow_mut().push(Wrote::Sample(
                sample.track,
                sample.pts_us,
                sample.key,
                sample.data.to_vec(),
            ));
            Ok(())
        }
        fn end(self) {
            self.wrote.borrow_mut().push(Wrote::End);
        }
        fn fail(self, sentence: String) {
            self.wrote.borrow_mut().push(Wrote::Fail(sentence));
        }
    }

    fn spec(audio_track: u32) -> RenditionSpec {
        RenditionSpec {
            duration_ms: 60_000,
            segment_ms: 6000,
            start_ms: 0,
            video: VideoPlan::Copy,
            audio: AudioPlan::Copy,
            audio_track,
        }
    }

    /// A film with a cover picture, the video, a subtitle and two audio
    /// streams, the container starting at -23 ms (an AAC encoder's
    /// priming, as ffmpeg writes it).
    fn film(queue: Vec<Next>) -> FakePackets {
        let mut cover = stream(0, Kind::Video, 7);
        cover.attached_picture = true;
        FakePackets {
            streams: vec![
                cover,
                stream(1, Kind::Video, libav::AV_CODEC_ID_H264),
                stream(2, Kind::Other, 0),
                stream(3, Kind::Audio, libav::AV_CODEC_ID_AAC),
                stream(4, Kind::Audio, libav::AV_CODEC_ID_AAC),
            ],
            start_us: -23_000,
            queue,
            seeks: Vec::new(),
            reads: 0,
            index: Vec::new(),
            indexed: Vec::new(),
            rewinds_to: None,
            sound: None,
            converted: RefCell::default(),
        }
    }

    const SLICE: &[u8] = &[0, 0, 0, 2, 0x65, 0x88];

    /// **A run reports both formats, then the two chosen streams' samples
    /// on the film's clock, and ends**: the cover picture, the subtitle and
    /// the other audio stream are skipped, the second audio stream is the
    /// one asked for, times are rebased so the container's start is zero,
    /// video goes over in Annex-B with the container's key flags, and audio
    /// as it is. A run from zero seeks to the start, as the first run does.
    #[test]
    fn a_run_copies_the_chosen_streams_on_the_films_clock() {
        let mut packets = film(vec![
            packet(0, 0, true, b"cover"),
            packet(1, 0, true, SLICE),
            packet(2, 0, true, b"subtitle"),
            packet(3, -23, true, b"other"),
            packet(4, -23, true, b"aac0"),
            packet(1, 120, false, SLICE),
            packet(4, 0, true, b"aac1"),
        ]);
        let sink = FakeSink::new(None);
        repackage(&mut packets, &spec(1), Duration::ZERO, false, sink.clone());
        let config = H264Config::of(&avcc(4)).unwrap();
        let annex = annex_b(&[&[0x65, 0x88]]);
        assert_eq!(
            *sink.wrote.borrow(),
            vec![
                Wrote::Format(
                    TrackKind::Video,
                    TrackFormat::H264 {
                        width: 320,
                        height: 240,
                        csd0: config.csd0.clone(),
                        csd1: config.csd1.clone(),
                    }
                ),
                Wrote::Format(
                    TrackKind::Audio,
                    TrackFormat::Aac {
                        sample_rate: 48_000,
                        channels: 2,
                        csd0: Bytes::from_static(&[0x11, 0x90]),
                    }
                ),
                Wrote::Sample(TrackKind::Video, 23_000, true, annex.clone()),
                Wrote::Sample(TrackKind::Audio, 0, true, b"aac0".to_vec()),
                Wrote::Sample(TrackKind::Video, 143_000, false, annex),
                Wrote::Sample(TrackKind::Audio, 23_000, true, b"aac1".to_vec()),
                Wrote::End,
            ]
        );
        assert_eq!(packets.seeks, vec![0]);
    }

    /// A run from N x T seeks there first -- on the film's clock; the
    /// demuxer adds the container's start -- and a sample with no time of
    /// its own (a lace's second frame) takes the last one's end.
    #[test]
    fn a_later_run_seeks_and_an_untimed_sample_follows_the_last() {
        let mut timed = packet(4, 6000, true, b"a");
        if let Next::Packet(packet) = &mut timed {
            packet.duration = 21;
        }
        let mut packets = film(vec![timed, packet(4, libav::NOPTS, true, b"b")]);
        let sink = FakeSink::new(None);
        repackage(
            &mut packets,
            &spec(1),
            Duration::from_secs(6),
            false,
            sink.clone(),
        );
        assert_eq!(packets.seeks, vec![6_000_000]);
        let times: Vec<i64> = sink
            .wrote
            .borrow()
            .iter()
            .filter_map(|wrote| match wrote {
                Wrote::Sample(_, pts, ..) => Some(*pts),
                _ => None,
            })
            .collect();
        assert_eq!(times, vec![6_023_000, 6_044_000]);
    }

    /// **The run that fixes the layout reports the video's index** -- after
    /// the formats, before the first sample -- having sought to the start,
    /// which is what makes libavformat read a Matroska file's cues; a run
    /// not asked for it seeks there the same and does not report.
    #[test]
    fn a_run_asked_for_the_index_reports_it_before_its_first_sample() {
        let mut packets = film(vec![packet(1, 0, true, SLICE)]);
        let entries = vec![
            IndexEntry {
                pts_us: 23_000,
                pos: 4_000,
            },
            IndexEntry {
                pts_us: 2_023_000,
                pos: 90_000,
            },
        ];
        packets.index = entries.clone();
        let sink = FakeSink::new(None);
        repackage(&mut packets, &spec(1), Duration::ZERO, true, sink.clone());
        assert_eq!(packets.seeks, vec![0]);
        assert_eq!(packets.indexed, vec![1], "the film's video stream");
        let wrote = sink.wrote.borrow();
        assert!(matches!(wrote[1], Wrote::Format(TrackKind::Audio, _)));
        assert_eq!(wrote[2], Wrote::Index(entries));
        assert!(matches!(wrote[3], Wrote::Sample(TrackKind::Video, ..)));
    }

    /// **The index on the film's clock, at each block's own position**:
    /// sync samples only, less the container's start, a Matroska cue's
    /// cluster moved to its block where the cues say.
    #[test]
    fn the_index_is_on_the_films_clock_at_the_blocks() {
        let ms = libav::Rational { num: 1, den: 1000 };
        let entries = [
            libav::IndexEntry {
                pos: 500,
                timestamp: 0,
                keyframe: true,
            },
            libav::IndexEntry {
                pos: 600,
                timestamp: 40,
                keyframe: false,
            },
            libav::IndexEntry {
                pos: 9_000,
                timestamp: 2_002,
                keyframe: true,
            },
            libav::IndexEntry {
                pos: 20_000,
                timestamp: 4_004,
                keyframe: true,
            },
        ];
        let blocks = HashMap::from([((2_002, 9_000), 9_000 + 12 + 3_000)]);
        assert_eq!(
            film_index(&entries, &blocks, ms, -21_000),
            vec![
                IndexEntry {
                    pts_us: 21_000,
                    pos: 500
                },
                IndexEntry {
                    pts_us: 2_023_000,
                    pos: 12_012
                },
                IndexEntry {
                    pts_us: 4_025_000,
                    pos: 20_000
                },
            ]
        );
    }

    /// **AAC in ADTS** (a transport stream's, no configuration in its
    /// header): the configuration is the first frame's header -- AAC-LC,
    /// 48 kHz, stereo here -- and every frame goes over without its header,
    /// seven bytes or nine with a CRC.
    #[test]
    fn adts_audio_is_configured_from_its_first_frame_and_unwrapped() {
        // LC (profile 1), 48 kHz (index 3), two channels, no CRC.
        let header = [0xff, 0xf1, 0x4c, 0x80, 0x02, 0x1f, 0xfc];
        assert_eq!(adts_config(&header).unwrap().as_ref(), &[0x11, 0x90]);
        let mut frame = header.to_vec();
        frame.extend_from_slice(b"aac");
        assert_eq!(strip_adts(Bytes::from(frame)).as_ref(), b"aac");
        let mut crc = header.to_vec();
        crc[1] = 0xf0;
        crc.extend_from_slice(&[0, 0]);
        crc.extend_from_slice(b"aac");
        assert_eq!(strip_adts(Bytes::from(crc)).as_ref(), b"aac");
        assert_eq!(adts_config(b"raw aac frame"), None);
        assert_eq!(strip_adts(Bytes::from_static(b"raw")).as_ref(), b"raw");

        // Read up to the first audio frame for the configuration, then (a
        // run from the start seeks to it) read again from the start.
        let queue = vec![
            packet(1, 0, true, SLICE),
            packet(4, 0, true, b"\xff\xf1\x4c\x80\x02\x1f\xfcaac"),
        ];
        let mut ts = film(queue.clone());
        ts.streams[4].extradata = Bytes::new();
        ts.rewinds_to = Some(queue);
        let sink = FakeSink::new(None);
        repackage(&mut ts, &spec(1), Duration::ZERO, false, sink.clone());
        assert_eq!(ts.seeks, vec![0]);
        let wrote = sink.wrote.borrow();
        assert!(matches!(
            &wrote[1],
            Wrote::Format(TrackKind::Audio, TrackFormat::Aac { csd0, .. }) if csd0.as_ref() == [0x11, 0x90]
        ));
        assert!(matches!(wrote[2], Wrote::Sample(TrackKind::Video, ..)));
        assert_eq!(wrote.len(), 5, "each packet once, then the end");
        assert_eq!(
            wrote[3],
            Wrote::Sample(TrackKind::Audio, 23_000, true, b"aac".to_vec())
        );
        drop(wrote);

        // Asked for the index, the run seeks back to the start: what it
        // read ahead for the configuration is read again, never handed out
        // twice.
        let queue = vec![
            packet(1, 0, true, SLICE),
            packet(4, 0, true, b"\xff\xf1\x4c\x80\x02\x1f\xfcaac"),
        ];
        let mut ts = film(queue.clone());
        ts.streams[4].extradata = Bytes::new();
        ts.rewinds_to = Some(queue);
        let sink = FakeSink::new(None);
        repackage(&mut ts, &spec(1), Duration::ZERO, true, sink.clone());
        assert_eq!(ts.seeks, vec![0]);
        assert_eq!(sink.samples(), 2, "each packet once");
    }

    /// **The sink stopping the run stops the reading**: no read after the
    /// write the sink refused, and no end.
    #[test]
    fn a_stopped_sink_ends_the_run_where_it_is() {
        let mut packets = film((0..10).map(|n| packet(1, n * 40, n == 0, SLICE)).collect());
        let sink = FakeSink::new(Some(3));
        repackage(&mut packets, &spec(0), Duration::ZERO, false, sink.clone());
        assert_eq!(sink.samples(), 3);
        assert_eq!(
            packets.reads, 4,
            "the fourth packet was refused, and nothing read after"
        );
        assert!(!sink.wrote.borrow().contains(&Wrote::End));
    }

    /// **A source that fails is a failure, never the end of the film**:
    /// an end would tell the server the film is over at that segment.
    #[test]
    fn a_failed_source_fails_the_run() {
        let mut packets = film(vec![
            packet(1, 0, true, SLICE),
            Next::Failed("the source failed".into()),
        ]);
        let sink = FakeSink::new(None);
        repackage(&mut packets, &spec(0), Duration::ZERO, false, sink.clone());
        assert_eq!(
            sink.wrote.borrow().last(),
            Some(&Wrote::Fail(BROKEN.to_owned()))
        );
        assert!(!sink.wrote.borrow().contains(&Wrote::End));
    }

    /// What this producer will not make is said before anything is read:
    /// another plan, another codec, a track that is not there.
    #[test]
    fn what_is_not_a_copy_is_refused_with_a_sentence() {
        assert_eq!(refusal_for(&spec(0)), None);
        let mut convert = spec(0);
        convert.audio = AudioPlan::AacStereo { bitrate: 192_000 };
        assert_eq!(refusal_for(&convert), None, "the sound converted");
        let mut transcode = spec(0);
        transcode.video = VideoPlan::H264 {
            width: 1280,
            height: 720,
            bitrate: 4_000_000,
        };
        assert_eq!(refusal_for(&transcode), Some(NOT_BUILT));

        // Each track it will not copy is named, in plain words.
        let refused = |change: &dyn Fn(&mut FakePackets)| -> Vec<Wrote> {
            let mut packets = film(Vec::new());
            change(&mut packets);
            let sink = FakeSink::new(None);
            repackage(&mut packets, &spec(0), Duration::ZERO, false, sink.clone());
            sink.wrote.take()
        };
        assert_eq!(
            refused(&|film| film.streams[1].codec = 226),
            vec![Wrote::Fail(
                "This film's video is AV1, which xtremio can't convert for casting yet.".to_owned()
            )]
        );
        assert_eq!(
            refused(&|film| film.streams[3].codec = 86056),
            vec![Wrote::Fail(
                "This film's sound is Dolby Digital Plus (E-AC3), which xtremio can't convert \
                 for casting yet."
                    .to_owned()
            )]
        );
        assert_eq!(
            refused(&|film| film.streams[3].codec = 0x7fff_0000),
            vec![Wrote::Fail(
                "This film's sound is in a format xtremio can't convert for casting yet."
                    .to_owned()
            )]
        );
        // HEVC whose configuration is not an `hvcC` cannot be read.
        assert_eq!(
            refused(&|film| film.streams[1].codec = libav::AV_CODEC_ID_HEVC),
            vec![Wrote::Fail(UNREADABLE.to_owned())]
        );

        let sink = FakeSink::new(None);
        repackage(
            &mut film(Vec::new()),
            &spec(2),
            Duration::ZERO,
            false,
            sink.clone(),
        );
        assert_eq!(
            *sink.wrote.borrow(),
            vec![Wrote::Fail(
                "The sound track being played is not in the film any more.".to_owned()
            )]
        );
    }

    // --- The sound converted ----------------------------------------------------

    /// A decoder that makes 1536 samples of silence per packet, stamped with
    /// the packet's time.
    struct SilentDecoder;
    impl sound::PcmDecoder for SilentDecoder {
        fn decode(&mut self, packets: &[libav::Packet]) -> Result<Vec<libav::Pcm>, String> {
            Ok(packets
                .iter()
                .map(|packet| libav::Pcm {
                    pts: packet.pts,
                    samples: vec![0.0; 1536 * 2],
                })
                .collect())
        }
    }

    /// An encoder with FFmpeg's priming whose frames are `b"aac"`.
    struct FixedEncoder;
    impl AacEncoder for FixedEncoder {
        fn delay(&self) -> i64 {
            1024
        }
        fn encode(&mut self, pcm: &[f32]) -> Result<Vec<Bytes>, String> {
            Ok(vec![Bytes::from_static(b"aac"); pcm.len() / 2048 + 1])
        }
    }

    fn silent_converter() -> SoundConverter {
        SoundConverter::new(
            Box::new(SilentDecoder),
            Box::new(FixedEncoder),
            libav::Rational { num: 1, den: 1000 },
            -23_000,
            0,
        )
    }

    /// **The sound converted, the picture copied**: a Dolby Digital Plus
    /// track asked to be converted reports the AAC-LC 48 kHz stereo every
    /// conversion makes -- not the source's -- the converter is asked for
    /// the chosen track at the plan's bitrate from the run's start, and the
    /// sink is handed the picture as it is and the converter's frames on
    /// the 1024-sample grid, never a source packet.
    #[test]
    fn a_run_converting_the_sound_hands_over_the_converters_frames() {
        let mut queue = vec![packet(1, 0, true, SLICE)];
        // AC3-like packets every 32 ms for 3 s, on stream 4 (the second
        // audio track, asked for).
        queue.extend((0..94).map(|n| packet(4, n * 32 - 23, true, b"eac3")));
        let mut packets = film(queue);
        packets.streams[4].codec = 86056;
        packets.streams[4].channels = 6;
        packets.streams[4].sample_rate = 44_100;
        packets.sound = Some(silent_converter);
        let mut convert = spec(1);
        convert.audio = AudioPlan::AacStereo { bitrate: 192_000 };
        let sink = FakeSink::new(None);
        repackage(&mut packets, &convert, Duration::ZERO, false, sink.clone());
        assert_eq!(*packets.converted.borrow(), vec![(4, 192_000, 0)]);
        let wrote = sink.wrote.borrow();
        assert_eq!(
            wrote[1],
            Wrote::Format(
                TrackKind::Audio,
                TrackFormat::Aac {
                    sample_rate: 48_000,
                    channels: 2,
                    csd0: Bytes::from_static(&[0x11, 0x90]),
                }
            )
        );
        assert!(matches!(
            wrote[2],
            Wrote::Sample(TrackKind::Video, 23_000, true, _)
        ));
        let audio: Vec<(i64, Vec<u8>)> = wrote
            .iter()
            .filter_map(|wrote| match wrote {
                Wrote::Sample(TrackKind::Audio, pts, true, data) => Some((*pts, data.clone())),
                Wrote::Sample(TrackKind::Audio, ..) => panic!("a frame not a sync sample"),
                _ => None,
            })
            .collect();
        assert!(audio.len() > 100, "{} frames", audio.len());
        for (n, (pts, data)) in audio.iter().enumerate() {
            assert_eq!(*pts, sound::frame_us(n as i64));
            assert_eq!(data, b"aac");
        }
        assert_eq!(wrote.last(), Some(&Wrote::End));
    }

    /// A track this device cannot convert is refused before any format,
    /// with the converter's sentence; a track copied is never handed to a
    /// converter.
    #[test]
    fn a_track_that_cannot_be_converted_is_refused_before_anything() {
        let mut packets = film(vec![packet(1, 0, true, SLICE)]);
        packets.streams[3].codec = 86060;
        let mut convert = spec(0);
        convert.audio = AudioPlan::AacStereo { bitrate: 192_000 };
        let sink = FakeSink::new(None);
        repackage(&mut packets, &convert, Duration::ZERO, false, sink.clone());
        assert_eq!(
            *sink.wrote.borrow(),
            vec![Wrote::Fail(
                "This film's sound is Dolby TrueHD, which xtremio can't convert for casting yet."
                    .to_owned()
            )]
        );
        let mut copied = film(vec![packet(1, 0, true, SLICE)]);
        repackage(
            &mut copied,
            &spec(0),
            Duration::ZERO,
            false,
            FakeSink::new(None),
        );
        assert!(copied.converted.borrow().is_empty());
    }

    // --- HEVC ---------------------------------------------------------------------

    const VPS: &[u8] = &[0x40, 0x01, 0x0c, 0x01, 0xff, 0xff];
    const HEVC_SPS: &[u8] = &[0x42, 0x01, 0x01, 0x02, 0x20];
    const HEVC_PPS: &[u8] = &[0x44, 0x01, 0xc1, 0x72];
    /// A prefix SEI: an HDR10 encode's light levels.
    const SEI: &[u8] = &[0x4e, 0x01, 0x90, 0x04, 0x03, 0xe8, 0x01, 0x90, 0x80];
    /// Dolby Vision's RPU, an unspecified NAL unit type (62) to HEVC.
    const RPU: &[u8] = &[0x7c, 0x01, 0x19, 0x08];
    /// An IDR slice.
    const IDR: &[u8] = &[0x26, 0x01, 0xaf, 0x09];

    /// An `hvcC` holding `arrays` (NAL unit type, units), with
    /// `length_size`-byte lengths in its samples.
    fn hvcc(length_size: u8, arrays: &[(u8, &[&[u8]])]) -> Vec<u8> {
        let mut out = vec![1, 0x02, 0x20, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 0x3c];
        out.extend_from_slice(&[0xf0, 0x00, 0xfc, 0xfd, 0xfa, 0xfa, 0x00, 0x00]);
        out.push(0x0c | (length_size - 1));
        out.push(arrays.len() as u8);
        for (kind, units) in arrays {
            out.push(0x80 | kind);
            out.extend_from_slice(&(units.len() as u16).to_be_bytes());
            for unit in *units {
                out.extend_from_slice(&(unit.len() as u16).to_be_bytes());
                out.extend_from_slice(unit);
            }
        }
        out
    }

    fn hdr10_hvcc(length_size: u8) -> Vec<u8> {
        hvcc(
            length_size,
            &[
                (32, &[VPS]),
                (33, &[HEVC_SPS]),
                (34, &[HEVC_PPS]),
                (39, &[SEI]),
            ],
        )
    }

    /// **An `hvcC` becomes `csd-0` in Annex-B** -- the parameter sets and
    /// the SEI beside them, in the record's order -- and a sample whose
    /// first length is 256 to 511, which reads as a start code, becomes
    /// Annex-B units the server cannot misread.
    #[test]
    fn an_hvcc_and_its_samples_are_handed_over_in_annex_b() {
        let config = HevcConfig::of(&hdr10_hvcc(4)).expect("an hvcC");
        assert_eq!(
            config.csd0.as_ref(),
            annex_b(&[VPS, HEVC_SPS, HEVC_PPS, SEI]).as_slice()
        );
        assert_eq!(config.length_size, Some(4));

        let slice = [IDR, &[0x55; 296]].concat();
        let mut sample = (slice.len() as u32).to_be_bytes().to_vec();
        assert_eq!(
            &sample[..3],
            &[0, 0, 1],
            "this length looks like a start code"
        );
        sample.extend_from_slice(&slice);
        let out = config.sample(Bytes::from(sample));
        assert_eq!(out.as_ref(), annex_b(&[&slice]).as_slice());

        let two = HevcConfig::of(&hdr10_hvcc(2)).unwrap();
        assert_eq!(two.length_size, Some(2));
        let mut sample = (IDR.len() as u16).to_be_bytes().to_vec();
        sample.extend_from_slice(IDR);
        assert_eq!(
            two.sample(Bytes::from(sample)).as_ref(),
            annex_b(&[IDR]).as_slice()
        );

        // A configuration short of a parameter set is not one.
        assert_eq!(
            HevcConfig::of(&hvcc(4, &[(32, &[VPS]), (33, &[HEVC_SPS])])),
            None,
            "no PPS"
        );
        assert_eq!(HevcConfig::of(&avcc(4)), None, "an avcC");
        // A transport stream's: Annex-B already, samples as they are.
        let annex = HevcConfig::of(&annex_b(&[VPS, HEVC_SPS, HEVC_PPS])).expect("Annex-B");
        assert_eq!(annex.length_size, None);
        let sample = Bytes::from(annex_b(&[IDR]));
        assert_eq!(annex.sample(sample.clone()), sample);
    }

    /// **Dolby Vision's units are left out of a copy**, length-prefixed or
    /// Annex-B: the RPU (62) and an enhancement layer (63) mean nothing to
    /// an HEVC decoder, and the picture is its base layer.
    #[test]
    fn dolby_visions_units_are_dropped_from_hevc_samples() {
        let el: &[u8] = &[0x7e, 0x01, 0x44];
        let config = HevcConfig::of(&hdr10_hvcc(4)).unwrap();
        let mut sample = Vec::new();
        for unit in [IDR, RPU, el] {
            sample.extend_from_slice(&(unit.len() as u32).to_be_bytes());
            sample.extend_from_slice(unit);
        }
        assert_eq!(
            config.sample(Bytes::from(sample)).as_ref(),
            annex_b(&[IDR]).as_slice()
        );
        let annex = HevcConfig::of(&annex_b(&[VPS, HEVC_SPS, HEVC_PPS])).unwrap();
        assert_eq!(
            annex.sample(Bytes::from(annex_b(&[IDR, RPU]))).as_ref(),
            annex_b(&[IDR]).as_slice()
        );
    }

    /// **An HEVC film is copied**: its format is the `hvcC`'s sets in
    /// Annex-B, its samples go over in Annex-B with their key flags.
    #[test]
    fn a_run_copies_hevc() {
        let mut packets = film(vec![
            packet(1, 0, true, &[0, 0, 0, 4, 0x26, 0x01, 0xaf, 0x09]),
            packet(1, 40, false, &[0, 0, 0, 3, 0x02, 0x01, 0xd0]),
        ]);
        packets.streams[1].codec = libav::AV_CODEC_ID_HEVC;
        packets.streams[1].extradata = Bytes::from(hdr10_hvcc(4));
        let sink = FakeSink::new(None);
        repackage(&mut packets, &spec(0), Duration::ZERO, false, sink.clone());
        let wrote = sink.wrote.borrow();
        assert_eq!(
            wrote[0],
            Wrote::Format(
                TrackKind::Video,
                TrackFormat::Hevc {
                    width: 320,
                    height: 240,
                    csd0: Bytes::from(annex_b(&[VPS, HEVC_SPS, HEVC_PPS, SEI])),
                }
            )
        );
        assert_eq!(
            wrote[2],
            Wrote::Sample(TrackKind::Video, 23_000, true, annex_b(&[IDR]))
        );
        assert_eq!(
            wrote[3],
            Wrote::Sample(
                TrackKind::Video,
                63_000,
                false,
                annex_b(&[&[0x02, 0x01, 0xd0]])
            )
        );
    }

    /// **Dolby Vision: profiles 7 and 8 are copied as their base layer,
    /// profile 5 is refused** -- it has no base layer any other decoder
    /// shows right -- with a sentence that says so.
    #[test]
    fn dolby_vision_without_a_compatible_base_layer_is_refused() {
        let run = |profile: u8, compatibility: u8| -> Vec<Wrote> {
            let mut packets = film(vec![packet(
                1,
                0,
                true,
                &[0, 0, 0, 4, 0x26, 0x01, 0xaf, 0x09],
            )]);
            packets.streams[1].codec = libav::AV_CODEC_ID_HEVC;
            packets.streams[1].extradata = Bytes::from(hdr10_hvcc(4));
            packets.streams[1].dolby_vision = Some(DolbyVision {
                profile,
                level: 6,
                compatibility,
            });
            let sink = FakeSink::new(None);
            repackage(&mut packets, &spec(0), Duration::ZERO, false, sink.clone());
            sink.wrote.take()
        };
        assert_eq!(
            run(5, 0),
            vec![Wrote::Fail(
                "This film's picture is Dolby Vision profile 5, which has no ordinary HDR or SDR \
                 picture underneath: the television would show it in the wrong colours."
                    .to_owned()
            )]
        );
        for (profile, compatibility) in [(8, 1), (8, 4), (7, 6)] {
            let wrote = run(profile, compatibility);
            assert!(
                matches!(
                    wrote[0],
                    Wrote::Format(TrackKind::Video, TrackFormat::Hevc { .. })
                ),
                "profile {profile}.{compatibility}: {wrote:?}"
            );
            assert_eq!(wrote.last(), Some(&Wrote::End));
        }
    }

    /// The record's bytes: version 1.0, profile 8, level 6, RPU and base
    /// layer present, compatibility 1 (HDR10).
    #[test]
    fn a_dolby_vision_record_reads_its_profile_and_compatibility() {
        let record = [1, 0, 8, 6, 1, 0, 1, 1, 0, 0, 0, 0];
        assert_eq!(
            DolbyVision::of_record(&record),
            Some(DolbyVision {
                profile: 8,
                level: 6,
                compatibility: 1
            })
        );
        assert_eq!(DolbyVision::of_record(&record[..7]), None);
    }
}
