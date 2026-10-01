//! **The rendition producer: repackaging, nothing decoded** (stream-server
//! `docs/design/renditions.md`, step F2).
//!
//! The server owns a rendition's route, its stream, cut rule, fMP4 muxer and
//! ring; what it asks of the embedder is a [`Producer`]: given a reader over
//! the media id, a plan and a time, hand encoded samples to a
//! [`SampleSink`]. This is that producer for the one plan F2 builds,
//! `Copy`/`Copy` -- an H.264 + AAC film in a container the receiver will
//! not take, its samples moved into the server's fMP4 as they are.
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
//!   ([`H264Config`]); no bitstream filter is needed for that. AAC's
//!   AudioSpecificConfig is the container's as it is.
//! - **Seek and restart**: a run at segment N starts at N x T; the
//!   demuxer is put on the sync point at or before it and the server
//!   discards what precedes the cut. Segment 0 needs no seek.
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

use crate::libav::{self, Demuxer, Kind, Libav, Next, StreamInfo};

/// What a viewer is told when this device has no FFmpeg to read with.
pub const UNAVAILABLE: &str =
    "This device cannot repackage films for the television: the player's FFmpeg is not one \
     this app can use.";
/// What a viewer is told for a plan this producer does not build.
pub const NOT_BUILT: &str =
    "Converting this film's picture or sound for the television is not built yet; only \
     repackaging is.";
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
        (VideoPlan::Copy, AudioPlan::Copy) => None,
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
    repackage(&mut demuxer, &spec, from, sink);
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
}

/// Where a run writes: [`SampleSink`], or a fake in the tests.
pub trait Sink {
    fn format(&self, track: TrackKind, format: TrackFormat) -> Result<(), Stopped>;
    fn sample(&self, sample: Sample) -> Result<(), Stopped>;
    fn end(self);
    fn fail(self, sentence: String);
}

impl Sink for SampleSink {
    fn format(&self, track: TrackKind, format: TrackFormat) -> Result<(), Stopped> {
        SampleSink::format(self, track, format)
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

/// **A run**: formats, the seek, then every packet of the two chosen
/// streams into `sink`, until the sink stops it, the film ends or the
/// source fails.
pub fn repackage<P: Packets, K: Sink>(
    packets: &mut P,
    spec: &RenditionSpec,
    from: Duration,
    sink: K,
) {
    let chosen = match Chosen::of(packets.streams(), spec.audio_track) {
        Ok(chosen) => chosen,
        Err(sentence) => {
            sink.fail(sentence);
            return;
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
    let from_us = i64::try_from(from.as_micros()).unwrap_or(i64::MAX);
    if from_us > 0 {
        if let Err(error) = packets.seek_us(from_us) {
            tracing::warn!(%error, "a rendition's source could not be sought in");
            sink.fail(UNSEEKABLE.to_owned());
            return;
        }
    }
    let start = packets.start_us();
    let mut video_clock = Clock::default();
    let mut audio_clock = Clock::default();
    loop {
        let packet = match packets.read_packet() {
            Next::Packet(packet) => packet,
            Next::End => {
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
        let (key, data) = match track {
            TrackKind::Video => (packet.key, chosen.h264.sample(packet.data)),
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
    h264: H264Config,
    video_format: TrackFormat,
    audio_format: TrackFormat,
}

impl Chosen {
    /// The film's video -- the first video stream that is not a cover
    /// picture -- and the `audio_track`-th audio stream, each the codec a
    /// copy can carry; or the sentence for why not.
    fn of(streams: &[StreamInfo], audio_track: u32) -> Result<Self, String> {
        let video = streams
            .iter()
            .find(|stream| stream.kind == Kind::Video && !stream.attached_picture)
            .ok_or("This film has no picture to send to the television.")?;
        if video.codec != libav::AV_CODEC_ID_H264 {
            return Err(NOT_BUILT.to_owned());
        }
        let audio = streams
            .iter()
            .filter(|stream| stream.kind == Kind::Audio)
            .nth(audio_track as usize)
            .ok_or("The sound track being played is not in the film any more.")?;
        if audio.codec != libav::AV_CODEC_ID_AAC {
            return Err(NOT_BUILT.to_owned());
        }
        if audio.extradata.is_empty() {
            return Err(UNREADABLE.to_owned());
        }
        let h264 = H264Config::of(&video.extradata).ok_or(UNREADABLE)?;
        Ok(Self {
            video_format: TrackFormat::H264 {
                width: video.width,
                height: video.height,
                csd0: h264.csd0.clone(),
                csd1: h264.csd1.clone(),
            },
            audio_format: TrackFormat::Aac {
                sample_rate: audio.sample_rate,
                channels: audio.channels.max(1),
                csd0: audio.extradata.clone(),
            },
            video: video.clone(),
            audio: audio.clone(),
            h264,
        })
    }
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
        let mut at = 0;
        while at + size <= data.len() {
            let len = data[at..at + size]
                .iter()
                .fold(0usize, |len, byte| (len << 8) | usize::from(*byte));
            at += size;
            let Some(unit) = data.get(at..at + len) else {
                break;
            };
            out.extend_from_slice(&START_CODE);
            out.extend_from_slice(unit);
            at += len;
        }
        Bytes::from(out)
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
    }

    #[derive(Debug, PartialEq)]
    enum Wrote {
        Format(TrackKind, TrackFormat),
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
        }
    }

    const SLICE: &[u8] = &[0, 0, 0, 2, 0x65, 0x88];

    /// **A run reports both formats, then the two chosen streams' samples
    /// on the film's clock, and ends**: the cover picture, the subtitle and
    /// the other audio stream are skipped, the second audio stream is the
    /// one asked for, times are rebased so the container's start is zero,
    /// video goes over in Annex-B with the container's key flags, and audio
    /// as it is. A run from zero does not seek.
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
        repackage(&mut packets, &spec(1), Duration::ZERO, sink.clone());
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
        assert!(packets.seeks.is_empty());
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
        repackage(&mut packets, &spec(1), Duration::from_secs(6), sink.clone());
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

    /// **The sink stopping the run stops the reading**: no read after the
    /// write the sink refused, and no end.
    #[test]
    fn a_stopped_sink_ends_the_run_where_it_is() {
        let mut packets = film((0..10).map(|n| packet(1, n * 40, n == 0, SLICE)).collect());
        let sink = FakeSink::new(Some(3));
        repackage(&mut packets, &spec(0), Duration::ZERO, sink.clone());
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
        repackage(&mut packets, &spec(0), Duration::ZERO, sink.clone());
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
        assert_eq!(refusal_for(&convert), Some(NOT_BUILT));

        let mut hevc = film(Vec::new());
        hevc.streams[1].codec = libav::AV_CODEC_ID_HEVC;
        let sink = FakeSink::new(None);
        repackage(&mut hevc, &spec(0), Duration::ZERO, sink.clone());
        assert_eq!(
            *sink.wrote.borrow(),
            vec![Wrote::Fail(NOT_BUILT.to_owned())]
        );

        let sink = FakeSink::new(None);
        repackage(
            &mut film(Vec::new()),
            &spec(2),
            Duration::ZERO,
            sink.clone(),
        );
        assert_eq!(
            *sink.wrote.borrow(),
            vec![Wrote::Fail(
                "The sound track being played is not in the film any more.".to_owned()
            )]
        );
    }
}
