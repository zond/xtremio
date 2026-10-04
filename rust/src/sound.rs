//! **A rendition's sound, converted to stereo AAC** (stream-server
//! `docs/design/renditions.md`, step F3): the film's audio track -- Dolby
//! Digital, Dolby Digital Plus, DTS, TrueHD, Opus, FLAC, MP3, PCM, AAC with
//! more than two channels -- decoded, mixed down to stereo at 48 kHz and
//! encoded as AAC-LC, while the picture is copied as it is.
//!
//! # The same bytes, whichever run makes them
//!
//! A rendition is one file a receiver seeks in by bytes, so a slot's bytes
//! must be the same whenever it is made: by the run that read on into it,
//! or by a run started at it after a seek (stream-server §2.8, *The same
//! bytes every time*). A copy has that for free. A codec does not: what an
//! encoder makes of a frame depends on everything it was fed before, and a
//! decoder's first frames depend on where it began.
//!
//! So the sound is made in **chunks on a fixed grid** of the film's clock,
//! and each chunk from nothing:
//!
//! - **The grid.** AAC frames of 1024 samples at 48 kHz, frame `i` covering
//!   `[i x 1024, (i + 1) x 1024)` samples from the film's zero; its time is
//!   `i x 64000 / 3` microseconds, rounded, which the server's 90 kHz clock
//!   reads as exactly `i x 1920`. A chunk is [`CHUNK_FRAMES`] frames.
//! - **A chunk from a fresh decoder**, fed from the first packet at or
//!   after [`DECODE_PREROLL`] (plus the encoder's) before the chunk: what a
//!   decoder makes of its first packets (an AC3 frame's overlap with the one
//!   before, TrueHD's wait for a major sync, Opus's prediction) is in that
//!   pre-roll, and from the same first packet it makes the same sound. The
//!   packets it is fed end at a bound that is also a function of the chunk,
//!   so nothing about the run -- where it began, what it read ahead -- is
//!   in them.
//! - **The sound placed by its timestamps**: the decoder's first frame at
//!   its presentation time, the rest after it sample by sample, placed
//!   anew only where the two disagree by more than [`DRIFT`] (a gap in the
//!   track); the window the encoder is given is silence where nothing was
//!   decoded.
//! - **A fresh encoder**, fed from [`ENCODE_PREROLL`] frames before the
//!   chunk -- so the first kept frame's transform window, and the one
//!   before it a decoder overlaps it with, saw the real sound -- to two
//!   frames past it, then flushed. Its output frame `j` is the sound at
//!   `start + j x 1024 - delay` (the encoder's priming, [`AacEncoder::delay`]:
//!   1024 for FFmpeg's, 1600 for Android's FDK), so where the input starts
//!   is chosen to put the kept frames on the grid, and the frames before
//!   them -- the priming and the pre-roll -- are discarded by count.
//! - **A chunk is made only when the run read what it needs**: a packet from
//!   before its decoder pre-roll (or the run began at the film's start,
//!   where every run sees the same first packet), and one far enough past
//!   it ([`READY_MARGIN`]) or the film's end. A chunk a run cannot make the
//!   canonical way is not made at all: the chunks a run started two seconds
//!   before its first cut (`SEEK_BACK`) needs are always makeable, since a
//!   chunk and its pre-rolls span [`CHUNK_FRAMES`] frames plus about 0.45 s.
//!
//! Neighbouring chunks come from different encoders. Each saw the sound on
//! both sides of the seam, so a decoder's overlap of the last frame of one
//! with the first of the next adds up to the sound, as it does across the
//! segments of an HLS encode made the same way.
//!
//! # What it costs
//!
//! Each chunk decodes its pre-roll again (about 0.45 s per 1.02 s chunk;
//! decoding Dolby or DTS is cheap) and encodes two frames more than it
//! keeps. The chunk's sound waits until a packet [`READY_MARGIN`] past it
//! is read: about 1.5 s of film behind the picture in what the sink is
//! handed, which the server's cut rule already waits for (a segment is
//! complete once the sound reaches the next cut).

use std::collections::VecDeque;

use bytes::Bytes;
use stream_server::{Sample, TrackKind};

use crate::libav::{self, Pcm, Rational, SOUND_CHANNELS, SOUND_RATE};

/// Samples in an AAC frame.
pub const FRAME: i64 = 1024;
/// Frames in a chunk: about a second (1.024 s at 48 kHz).
pub const CHUNK_FRAMES: i64 = 48;
/// Samples in a chunk.
pub const CHUNK: i64 = CHUNK_FRAMES * FRAME;
/// Frames of real sound an encoder is fed before the first frame kept.
pub const ENCODE_PREROLL: i64 = 2;
/// Frames an encoder is fed past the last frame kept.
pub const ENCODE_TAIL: i64 = 2;
/// Samples a decoder is fed before the encoder's input begins: TrueHD's
/// major syncs are well inside it, and an AC3 or DTS frame's dependence on
/// the one before is one frame.
pub const DECODE_PREROLL: i64 = 19_200;
/// Samples past the encoder's input a packet must be read before a chunk
/// is made: what a decoder that holds a frame back needs.
pub const READY_MARGIN: i64 = 12_000;
/// How far apart, in samples, the decoded sound's count and a frame's own
/// timestamp may be before the frame is placed at its timestamp: more than
/// a timestamp's rounding (Matroska's are milliseconds), less than a gap.
pub const DRIFT: i64 = 1920;
/// AAC-LC, 48 kHz, two channels: the AudioSpecificConfig of every converted
/// track (object type 2, frequency index 3, channel configuration 2).
pub const AUDIO_SPECIFIC_CONFIG: [u8; 2] = [0x11, 0x90];

/// What a [`SoundConverter`] decodes with: one stream's packets to 48 kHz
/// stereo, **from a fresh state on every call**.
pub trait PcmDecoder: Send {
    fn decode(&mut self, packets: &[libav::Packet]) -> Result<Vec<Pcm>, String>;
}

/// What a [`SoundConverter`] encodes with: 48 kHz stereo to raw AAC-LC
/// frames, **from a fresh state on every call**, flushed at its end.
pub trait AacEncoder: Send {
    /// The encoder's priming, in samples: output frame `j` of a call is the
    /// sound that began `j x 1024 - delay` samples into its input.
    fn delay(&self) -> i64;
    /// `pcm` -- interleaved stereo, a whole number of frames -- encoded:
    /// every frame in order, the priming first.
    fn encode(&mut self, pcm: &[f32]) -> Result<Vec<Bytes>, String>;
}

impl PcmDecoder for libav::SoundDecoder {
    fn decode(&mut self, packets: &[libav::Packet]) -> Result<Vec<Pcm>, String> {
        libav::SoundDecoder::decode(self, packets)
    }
}

impl AacEncoder for libav::LibavAac {
    fn delay(&self) -> i64 {
        i64::from(Self::DELAY)
    }

    fn encode(&mut self, pcm: &[f32]) -> Result<Vec<Bytes>, String> {
        libav::LibavAac::encode(self, pcm)
    }
}

/// Frame `index`'s time on the film's clock, microseconds: `index` x 1024
/// samples at 48 kHz, rounded to the nearest.
pub fn frame_us(index: i64) -> i64 {
    (2 * index * FRAME * 1_000_000 + i64::from(SOUND_RATE)).div_euclid(2 * i64::from(SOUND_RATE))
}

/// A time on the film's clock in microseconds, as a 48 kHz sample index,
/// rounded to the nearest.
pub fn sample_at(us: i64) -> i64 {
    let rate = i128::from(SOUND_RATE);
    ((2 * i128::from(us) * rate + 1_000_000).div_euclid(2_000_000)) as i64
}

/// Whether `us` (microseconds) is at or after sample `sample`, exactly.
fn at_or_after(us: i64, sample: i64) -> bool {
    i128::from(us) * i128::from(SOUND_RATE) >= i128::from(sample) * 1_000_000
}

/// **What a chunk is made from**: where the encoder's input begins, how
/// long it is, which of its output frames are kept, and where the decoder's
/// packets begin and end -- all a function of the chunk and the encoder's
/// delay alone.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ChunkPlan {
    pub chunk: i64,
    /// The chunk's first sample.
    pub start: i64,
    /// The sample the encoder's input begins at.
    pub input_start: i64,
    /// The encoder's input, in samples: a whole number of frames.
    pub input_len: i64,
    /// The first output frame kept: the chunk's first frame.
    pub first_kept: usize,
    /// The decoder is fed packets at or after this sample...
    pub decode_from: i64,
    /// ... and before this one.
    pub decode_until: i64,
}

impl ChunkPlan {
    pub fn of(chunk: i64, delay: i64) -> Self {
        let start = chunk * CHUNK;
        // The input must start where `input_start + j x 1024 - delay` lands
        // on the grid for some `j`: `delay` past a frame boundary, at least
        // ENCODE_PREROLL frames before the chunk.
        let pad = (FRAME - delay.rem_euclid(FRAME)).rem_euclid(FRAME);
        let input_start = start - ENCODE_PREROLL * FRAME - pad;
        let first_kept = (start - input_start + delay) / FRAME;
        let input_len = (first_kept + CHUNK_FRAMES + ENCODE_TAIL) * FRAME;
        let input_end = input_start + input_len;
        Self {
            chunk,
            start,
            input_start,
            input_len,
            first_kept: first_kept as usize,
            decode_from: input_start - DECODE_PREROLL,
            decode_until: input_end + READY_MARGIN,
        }
    }

    pub fn end(&self) -> i64 {
        self.start + CHUNK
    }
}

/// **The decoded sound in the encoder's window**: `blocks` (in decode
/// order, their `pts` in `time_base`, the container starting at
/// `start_us`) placed on the film's 48 kHz clock -- the first block at its
/// time, each after it where the last ended unless its own time disagrees
/// by more than [`DRIFT`] -- and cut to `len` samples from `from`;
/// silence where nothing was decoded. Also answers the sample after the
/// last one decoded, if any was.
pub fn place(
    blocks: &[Pcm],
    time_base: Rational,
    start_us: i64,
    from: i64,
    len: i64,
) -> (Vec<f32>, Option<i64>) {
    let mut window = vec![0f32; len as usize * SOUND_CHANNELS];
    let mut at: Option<i64> = None;
    for block in blocks {
        let stamped = libav::to_us(block.pts, time_base).map(|us| sample_at(us - start_us));
        let position = match (at, stamped) {
            (None, None) => continue,
            (None, Some(stamped)) => stamped,
            (Some(at), Some(stamped)) if (stamped - at).abs() > DRIFT => stamped,
            (Some(at), _) => at,
        };
        let count = (block.samples.len() / SOUND_CHANNELS) as i64;
        let first = (from - position).clamp(0, count);
        let last = (from + len - position).clamp(0, count);
        if first < last {
            let into = (position + first - from) as usize * SOUND_CHANNELS;
            let span = (last - first) as usize * SOUND_CHANNELS;
            window[into..into + span].copy_from_slice(
                &block.samples[first as usize * SOUND_CHANNELS..last as usize * SOUND_CHANNELS],
            );
        }
        at = Some(position + count);
    }
    (window, at)
}

/// **One run's sound conversion**: audio packets in, the converted AAC
/// frames out as samples for the sink, chunk by chunk ([`ChunkPlan`]).
pub struct SoundConverter {
    decoder: Box<dyn PcmDecoder>,
    encoder: Box<dyn AacEncoder>,
    time_base: Rational,
    /// The container's first timestamp: the film's zero.
    start_us: i64,
    /// The run began at the film's start: its first packet is every such
    /// run's, so the first chunks need nothing before it.
    from_start: bool,
    /// Chunks wholly before this sample are not made: nothing in them is
    /// asked of this run.
    needed_from: i64,
    /// Read and not yet behind every chunk still to make: (film time in
    /// microseconds, the packet).
    packets: VecDeque<(i64, libav::Packet)>,
    /// The earliest and latest film times read.
    first_us: Option<i64>,
    high_us: Option<i64>,
    next: i64,
}

impl SoundConverter {
    /// A conversion for a run from `from_us` on the film's clock, of a
    /// stream in `time_base` in a container starting at `start_us`.
    pub fn new(
        decoder: Box<dyn PcmDecoder>,
        encoder: Box<dyn AacEncoder>,
        time_base: Rational,
        start_us: i64,
        from_us: i64,
    ) -> Self {
        let needed_from = sample_at(from_us.max(0));
        Self {
            decoder,
            encoder,
            time_base,
            start_us,
            from_start: from_us <= 0,
            needed_from,
            packets: VecDeque::new(),
            first_us: None,
            high_us: None,
            next: 0,
        }
    }

    /// One audio packet, at `film_us` on the film's clock; answers the
    /// frames of every chunk it made ready, in order.
    pub fn push(&mut self, film_us: i64, packet: libav::Packet) -> Result<Vec<Sample>, String> {
        self.first_us.get_or_insert(film_us);
        self.high_us = Some(self.high_us.map_or(film_us, |high| high.max(film_us)));
        self.packets.push_back((film_us, packet));
        let mut out = Vec::new();
        loop {
            let plan = ChunkPlan::of(self.next, self.encoder.delay());
            let high = self.high_us.unwrap_or(i64::MIN);
            if !at_or_after(high, plan.decode_until) {
                return Ok(out);
            }
            self.make(&plan, false, &mut out)?;
            self.next += 1;
        }
    }

    /// The film ended: every chunk with sound in it, made from what is
    /// left, its frames past the sound's end left out.
    pub fn finish(&mut self) -> Result<Vec<Sample>, String> {
        let mut out = Vec::new();
        let Some(high) = self.high_us else {
            return Ok(out);
        };
        let last = sample_at(high);
        loop {
            let plan = ChunkPlan::of(self.next, self.encoder.delay());
            if plan.start > last {
                return Ok(out);
            }
            self.make(&plan, true, &mut out)?;
            self.next += 1;
        }
    }

    /// Whether this run read what `plan` must be made from.
    fn can_make(&self, plan: &ChunkPlan) -> bool {
        self.from_start
            || self
                .first_us
                .is_some_and(|first| !at_or_after(first, plan.decode_from))
    }

    fn make(
        &mut self,
        plan: &ChunkPlan,
        at_end: bool,
        out: &mut Vec<Sample>,
    ) -> Result<(), String> {
        let wanted = plan.end() > self.needed_from && self.can_make(plan);
        if wanted {
            let packets: Vec<libav::Packet> = self
                .packets
                .iter()
                .filter(|(us, _)| at_or_after(*us, plan.decode_from))
                .filter(|(us, _)| !at_or_after(*us, plan.decode_until))
                .map(|(_, packet)| packet.clone())
                .collect();
            let blocks = self.decoder.decode(&packets)?;
            let (window, sound_end) = place(
                &blocks,
                self.time_base,
                self.start_us,
                plan.input_start,
                plan.input_len,
            );
            let frames = self.encoder.encode(&window)?;
            let kept = frames
                .get(plan.first_kept..plan.first_kept + CHUNK_FRAMES as usize)
                .ok_or_else(|| {
                    format!(
                        "the AAC encoder made {} frames of {}",
                        frames.len(),
                        plan.first_kept + CHUNK_FRAMES as usize
                    )
                })?;
            for (offset, frame) in kept.iter().enumerate() {
                let index = plan.chunk * CHUNK_FRAMES + offset as i64;
                // At the end, nothing past the last sound decoded: the
                // chunk's window runs on in silence.
                if at_end && sound_end.is_none_or(|end| index * FRAME >= end) {
                    break;
                }
                out.push(Sample {
                    track: TrackKind::Audio,
                    pts_us: frame_us(index),
                    key: true,
                    data: frame.clone(),
                });
            }
        }
        // What no chunk after this one is fed any more.
        let next_from = ChunkPlan::of(plan.chunk + 1, self.encoder.delay()).decode_from;
        while self
            .packets
            .front()
            .is_some_and(|(us, _)| !at_or_after(*us, next_from))
        {
            self.packets.pop_front();
        }
        Ok(())
    }
}

/// Interleaved float to 16-bit PCM, little-endian: what Android's AAC
/// encoder takes. Rounded and clamped, the same for the same input.
pub fn to_s16le(pcm: &[f32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(pcm.len() * 2);
    for sample in pcm {
        let scaled = (sample * 32767.0).round().clamp(-32768.0, 32767.0) as i16;
        out.extend_from_slice(&scaled.to_le_bytes());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    const MS: Rational = Rational { num: 1, den: 1000 };

    #[test]
    fn frames_sit_on_the_grid_the_servers_90_khz_clock_reads_exactly() {
        assert_eq!(frame_us(0), 0);
        assert_eq!(frame_us(1), 21_333);
        assert_eq!(frame_us(2), 42_667);
        assert_eq!(frame_us(3), 64_000);
        for index in [1, 7, 48, 12_345, 1_000_001] {
            // The server's `ticks`: rounded to the nearest 90 kHz tick.
            let ticks = (frame_us(index) * 90_000 + 500_000) / 1_000_000;
            assert_eq!(ticks, index * 1920, "frame {index}");
        }
        assert_eq!(sample_at(1_000_000), 48_000);
        assert_eq!(sample_at(21_333), 1024);
        assert_eq!(sample_at(-21_000), -1008);
    }

    /// **The priming is discarded by count, and the kept frames are the
    /// chunk's on the grid**, for FFmpeg's encoder (1024) and Android's FDK
    /// (1600, not a whole frame): the kept frame `first_kept` is the sound
    /// at the chunk's start, at least two frames of real sound fed before
    /// it, the input a whole number of frames reaching two past the chunk.
    #[test]
    fn a_chunks_plan_puts_the_kept_frames_on_the_grid() {
        for delay in [0, 1024, 1600, 2048, 2112] {
            for chunk in [0, 1, 37] {
                let plan = ChunkPlan::of(chunk, delay);
                assert_eq!(plan.start, chunk * CHUNK);
                let kept_at = plan.input_start + plan.first_kept as i64 * FRAME - delay;
                assert_eq!(kept_at, plan.start, "delay {delay}, chunk {chunk}");
                assert!(plan.start - plan.input_start >= ENCODE_PREROLL * FRAME);
                assert!(plan.start - plan.input_start < (ENCODE_PREROLL + 1) * FRAME);
                assert_eq!(plan.input_len % FRAME, 0);
                let last_kept_end =
                    plan.input_start + (plan.first_kept as i64 + CHUNK_FRAMES) * FRAME - delay;
                assert_eq!(last_kept_end, plan.end());
                assert_eq!(
                    plan.input_start + plan.input_len,
                    plan.end() + delay + ENCODE_TAIL * FRAME
                );
                assert_eq!(plan.decode_from, plan.input_start - DECODE_PREROLL);
            }
        }
        assert_eq!(ChunkPlan::of(0, 1024).first_kept, 3);
        assert_eq!(ChunkPlan::of(0, 1600).first_kept, 4);
    }

    /// The budget the server's `SEEK_BACK` leaves: a run starts two seconds
    /// before its first cut, and the sound it must make begins 64 ms before
    /// the cut. The chunk that holds that, with both pre-rolls, must start
    /// well inside the two seconds, whatever the cut.
    #[test]
    fn the_chunk_a_runs_first_cut_needs_is_inside_its_two_seconds() {
        for delay in [1024, 1600] {
            for cut_ms in [6_000, 6_100, 7_023, 12_000, 299_660] {
                let cut = sample_at(cut_ms * 1000);
                let needed = cut - sample_at(64_000);
                let plan = ChunkPlan::of(needed.div_euclid(CHUNK), delay);
                let run_starts = cut - 2 * i64::from(SOUND_RATE);
                assert!(
                    plan.decode_from - run_starts > i64::from(SOUND_RATE) * 4 / 10,
                    "cut {cut_ms} ms, delay {delay}: pre-roll begins {} samples into the run",
                    plan.decode_from - run_starts
                );
            }
        }
    }

    fn pcm(pts: i64, samples: usize, value: f32) -> Pcm {
        Pcm {
            pts,
            samples: vec![value; samples * SOUND_CHANNELS],
        }
    }

    /// **The decoded sound is placed by its first timestamp and counted on
    /// from there**: a millisecond's rounding in a later block's timestamp
    /// moves nothing, a real gap does, and the window is silence where
    /// nothing was decoded.
    #[test]
    fn decoded_sound_is_placed_by_count_and_by_a_gap() {
        // 1000 ms = 48000 samples; blocks of 1536 (an AC3 frame, 32 ms).
        let blocks = vec![
            pcm(1000, 1536, 1.0),
            // 33 ms stamped (rounded), 1536 samples on: placed at 32 ms.
            pcm(1033, 1536, 2.0),
            pcm(libav::NOPTS, 1536, 3.0),
            // A gap: 1500 ms is 21312 samples past where the count is.
            pcm(1500, 100, 4.0),
        ];
        let (window, end) = place(&blocks, MS, 0, 47_000, 50_000);
        let at = |sample: i64| window[(sample - 47_000) as usize * SOUND_CHANNELS];
        assert_eq!(at(47_999), 0.0, "silence before the first");
        assert_eq!(at(48_000), 1.0);
        assert_eq!(at(48_000 + 1535), 1.0);
        assert_eq!(at(48_000 + 1536), 2.0, "counted, not its rounded stamp");
        assert_eq!(at(48_000 + 3072), 3.0, "no stamp: counted on");
        assert_eq!(at(48_000 + 4608), 0.0, "nothing decoded");
        assert_eq!(at(72_000), 4.0, "the gap's block at its stamp");
        assert_eq!(end, Some(72_100));
        // The container's start is the film's zero.
        let (window, _) = place(&[pcm(-21, 48, 1.0)], MS, -21_000, 0, 96);
        assert_eq!(window[0], 1.0);
        assert_eq!(window[47 * 2], 1.0);
        assert_eq!(window[48 * 2], 0.0);
    }

    #[test]
    fn floats_become_rounded_clamped_16_bit_samples() {
        assert_eq!(
            to_s16le(&[0.0, 1.0, -1.0, 2.0, -2.0, 0.5]),
            [0i16, 32767, -32767, 32767, -32768, 16384]
                .iter()
                .flat_map(|s| s.to_le_bytes())
                .collect::<Vec<u8>>()
        );
    }

    // --- The converter, against a fake decoder and encoder --------------------

    /// A decoder that turns each packet (whose first byte is its value) into
    /// a block of 1536 samples of that value, stamped with the packet's
    /// time, recording what each call was fed.
    #[derive(Clone, Default)]
    struct FakeDecoder {
        calls: Arc<Mutex<Vec<Vec<i64>>>>,
    }

    impl PcmDecoder for FakeDecoder {
        fn decode(&mut self, packets: &[libav::Packet]) -> Result<Vec<Pcm>, String> {
            self.calls
                .lock()
                .unwrap()
                .push(packets.iter().map(|packet| packet.pts).collect());
            Ok(packets
                .iter()
                .map(|packet| pcm(packet.pts, 1536, f32::from(packet.data[0])))
                .collect())
        }
    }

    /// An encoder whose output frame `j` is a digest of the input frame
    /// `j - delay / 1024` (silence for the priming), so a frame's bytes say
    /// which sound it holds, and whose calls are counted.
    #[derive(Clone)]
    struct FakeEncoder {
        delay: i64,
        calls: Arc<Mutex<usize>>,
    }

    impl AacEncoder for FakeEncoder {
        fn delay(&self) -> i64 {
            self.delay
        }
        fn encode(&mut self, pcm: &[f32]) -> Result<Vec<Bytes>, String> {
            *self.calls.lock().unwrap() += 1;
            assert_eq!(pcm.len() % (FRAME as usize * SOUND_CHANNELS), 0);
            let samples = (pcm.len() / SOUND_CHANNELS) as i64;
            let frames = (samples + self.delay + FRAME - 1) / FRAME;
            Ok((0..frames)
                .map(|j| {
                    let from = j * FRAME - self.delay;
                    let take = |at: i64| {
                        if (0..samples).contains(&at) {
                            pcm[at as usize * SOUND_CHANNELS]
                        } else {
                            0.0
                        }
                    };
                    let digest = [take(from), take(from + FRAME / 2), take(from + FRAME - 1)];
                    Bytes::from(digest.iter().map(|v| *v as u8).collect::<Vec<u8>>())
                })
                .collect())
        }
    }

    fn packet(ms: i64, value: u8) -> libav::Packet {
        libav::Packet {
            stream: 1,
            pts: ms,
            dts: ms,
            duration: 32,
            key: true,
            data: Bytes::from(vec![value]),
        }
    }

    /// A track of AC3-like packets every 32 ms from `from_ms` to `to_ms`,
    /// each holding its index's low byte (never zero), so where a frame's
    /// sound came from shows in its bytes.
    fn track(from_ms: i64, to_ms: i64) -> Vec<libav::Packet> {
        (from_ms / 32..to_ms / 32)
            .map(|n| packet(n * 32, (n % 250 + 1) as u8))
            .collect()
    }

    fn make_converter(delay: i64, from_us: i64) -> (SoundConverter, FakeDecoder, FakeEncoder) {
        let decoder = FakeDecoder::default();
        let encoder = FakeEncoder {
            delay,
            calls: Arc::default(),
        };
        let converter = SoundConverter::new(
            Box::new(decoder.clone()),
            Box::new(encoder.clone()),
            MS,
            0,
            from_us,
        );
        (converter, decoder, encoder)
    }

    /// Everything a run from `from_ms` hands the sink, as (time, bytes).
    fn convert(delay: i64, from_ms: i64, packets: &[libav::Packet]) -> Vec<(i64, Vec<u8>)> {
        let (mut converter, ..) = make_converter(delay, from_ms * 1000);
        let mut out = Vec::new();
        for packet in packets {
            out.extend(converter.push(packet.pts * 1000, packet.clone()).unwrap());
        }
        out.extend(converter.finish().unwrap());
        out.into_iter()
            .map(|sample| {
                assert_eq!(sample.track, TrackKind::Audio);
                assert!(sample.key);
                (sample.pts_us, sample.data.to_vec())
            })
            .collect()
    }

    /// **The same frames whichever run makes them**: runs started at the
    /// film's start and at three later points (each reading from two
    /// seconds before, as the server's `SEEK_BACK` has it, and from a
    /// packet boundary that is not a chunk's) hand over the same bytes at
    /// the same times for every frame both made, and the later runs make
    /// every frame from 64 ms before their first cut on.
    #[test]
    fn a_frames_bytes_do_not_depend_on_where_its_run_began() {
        for delay in [1024, 1600] {
            let film = track(0, 30_000);
            let whole = convert(delay, 0, &film);
            assert!(!whole.is_empty());
            // Every frame once, on the grid, in order.
            for (n, (pts, _)) in whole.iter().enumerate() {
                assert_eq!(*pts, frame_us(n as i64), "delay {delay}");
            }
            for cut_ms in [6_000, 12_416, 20_032] {
                let from_ms = cut_ms - 2000;
                let read_from = film
                    .iter()
                    .position(|packet| packet.pts >= from_ms - 300)
                    .unwrap();
                let later = convert(delay, from_ms, &film[read_from..]);
                let first_needed = sample_at((cut_ms - 64) * 1000) / FRAME;
                assert!(
                    sample_at(later[0].0) / FRAME <= first_needed,
                    "delay {delay}, cut {cut_ms}: first frame {} after {first_needed}",
                    sample_at(later[0].0) / FRAME
                );
                for (pts, bytes) in &later {
                    let index = sample_at(*pts) / FRAME;
                    assert_eq!(
                        &whole[index as usize],
                        &(*pts, bytes.clone()),
                        "delay {delay}, cut {cut_ms}: frame {index}"
                    );
                }
                assert_eq!(later.last(), whole.last());
            }
        }
    }

    /// **The priming and the pre-roll never reach the sink**: frame `i`
    /// holds the sound at `i x 1024` -- the fake encoder's digest names it
    /// -- for either encoder's delay.
    #[test]
    fn the_kept_frames_hold_the_sound_at_their_time() {
        for delay in [1024, 1600] {
            let film = track(0, 5_000);
            let frames = convert(delay, 0, &film);
            for (pts, bytes) in &frames {
                let sample = sample_at(*pts);
                // The packet whose 1536 samples cover the frame's first.
                let expected = ((sample / 1536) % 250 + 1) as u8;
                assert_eq!(bytes[0], expected, "delay {delay}, frame at {pts}");
            }
        }
    }

    /// **A chunk is fed from a fresh decoder, from the first packet of its
    /// pre-roll to its bound**, the same set whichever run feeds it -- and a
    /// run that did not read from before a chunk's pre-roll does not make
    /// it.
    #[test]
    fn each_chunk_decodes_the_same_packets_and_only_when_it_can() {
        let film = track(0, 8_000);
        let (mut converter, decoder, encoder) = make_converter(1024, 4_000_000);
        // Read from 3.5 s on: chunk 3 (3.072 s) needs 2.6 s, so it is not
        // made; chunk 4 (4.096 s) needs from 3.6 s, so it is.
        for packet in film.iter().filter(|packet| packet.pts >= 3_500) {
            converter.push(packet.pts * 1000, packet.clone()).unwrap();
        }
        converter.finish().unwrap();
        let calls = decoder.calls.lock().unwrap().clone();
        let plan4 = ChunkPlan::of(4, 1024);
        // Fed up to its bound and not past it, though the run read on.
        let last = calls[0].last().copied().unwrap();
        assert!(!at_or_after(last * 1000, plan4.decode_until));
        assert!(at_or_after((last + 32) * 1000, plan4.decode_until));
        let first = calls[0].first().copied().unwrap();
        assert!(at_or_after(first * 1000, plan4.decode_from));
        assert!(!at_or_after((first - 32) * 1000, plan4.decode_from));
        assert_eq!(
            *encoder.calls.lock().unwrap(),
            calls.len(),
            "one encoder per decoded chunk"
        );
        // The same chunk from a run that read everything: the same packets.
        let (mut whole, whole_decoder, _) = make_converter(1024, 0);
        for packet in &film {
            whole.push(packet.pts * 1000, packet.clone()).unwrap();
        }
        whole.finish().unwrap();
        assert_eq!(whole_decoder.calls.lock().unwrap()[4], calls[0]);
    }

    /// Chunks wholly before the run's start are not made at all: nothing
    /// in them is asked of the run, however far back its seek landed.
    #[test]
    fn chunks_before_the_runs_start_are_not_made() {
        let film = track(0, 12_000);
        let (mut converter, decoder, _) = make_converter(1024, 9_000_000);
        for packet in &film {
            converter.push(packet.pts * 1000, packet.clone()).unwrap();
        }
        converter.finish().unwrap();
        // Chunk 8 (8.192-9.216 s) holds 9 s; chunks 0-7 are not decoded.
        let calls = decoder.calls.lock().unwrap();
        let plan8 = ChunkPlan::of(8, 1024);
        assert!(at_or_after(calls[0][0] * 1000, plan8.decode_from));
    }

    /// At the film's end the last chunk is made from what is left, and no
    /// frame starts past the last sound decoded.
    #[test]
    fn the_last_chunk_stops_with_the_sound() {
        let film = track(0, 2_400);
        let frames = convert(1024, 0, &film);
        let sound_end = sample_at(film.last().unwrap().pts * 1000) + 1536;
        let last = sample_at(frames.last().unwrap().0);
        assert!(
            last < sound_end && last + FRAME >= sound_end,
            "{last} {sound_end}"
        );
    }

    /// An encoder that makes fewer frames than a chunk keeps fails the run.
    #[test]
    fn an_encoder_short_of_frames_fails() {
        struct Short;
        impl AacEncoder for Short {
            fn delay(&self) -> i64 {
                1024
            }
            fn encode(&mut self, _: &[f32]) -> Result<Vec<Bytes>, String> {
                Ok(vec![Bytes::new(); 10])
            }
        }
        let mut converter =
            SoundConverter::new(Box::new(FakeDecoder::default()), Box::new(Short), MS, 0, 0);
        let failed = track(0, 3_000)
            .into_iter()
            .map(|packet| converter.push(packet.pts * 1000, packet))
            .find_map(Result::err);
        assert_eq!(
            failed.as_deref(),
            Some("the AAC encoder made 10 frames of 51")
        );
    }
}
