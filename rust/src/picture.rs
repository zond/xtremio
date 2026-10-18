//! **A rendition's picture converted by Android's MediaCodec**: the
//! embedder's half of stream-server's converted-picture contract
//! (`stream_server::PictureConverter`; stream-server
//! `docs/design/renditions.md` §5 F4).
//!
//! The server decides which segment each decoded picture belongs to and
//! checks what comes back (`stream_server::ConvertedPicture`). This module
//! does the codec work: one decoder for the run, and one encoder per
//! segment, so every segment opens with a sync picture and its bytes do not
//! depend on where the run began.
//!
//! **Three paths.**
//! - **The surface path** (H.264 High and HEVC Main). The decoder renders
//!   into the open encoder's input surface. At a cut the old encoder is
//!   ended and deleted, a fresh one is made, and the decoder is moved onto
//!   its surface (`setOutputSurface`). That is the order the Kotlin probe
//!   measured (`HwProbe.kt`, `cut`). It needs API 26.
//! - **The buffer path** (HEVC Main 10). The decoder writes P010 into
//!   buffers, asked for the Android 13 way: color-format 54 on its
//!   configure format. Each picture is copied into an encoder input buffer
//!   ([`copy_p010`]). The encoders take their colour keys and
//!   `hdr-static-info` from the decoder's first output format where the
//!   container says nothing. It needs API 33.
//! - **The software path** (H.264 High and HEVC Main from a codec the
//!   phone has no hardware decoder for: MPEG-4 Part 2, DivX 3, MPEG-2).
//!   libavcodec decodes on the run's thread ([`SoftDecoder`]) into NV12,
//!   and each picture is copied into an encoder input buffer
//!   ([`copy_nv12`]) as on the buffer path, with `color-format` 21.
//!
//! **Decode times.** An AVI's packets carry when each picture is decoded,
//! not when it is shown ([`PictureSource::decode_times`]). Pictures leave a
//! decoder in the order they are shown, so their times are worked out
//! again on the way out. The software decoder takes libavcodec's best
//! effort time: the decode time of the packet that freed the picture,
//! which comes out the same for a run from any sync picture. A hardware
//! decoder echoes each picture's own input time, so the converter gives
//! each picture the earliest input time not yet given out. That holds
//! while the decoder drops nothing: an open GOP's leading pictures after a
//! seek would shift the times by their count.
//!
//! **One thread.** The run's thread feeds and drains both codecs, waiting
//! at most [`DEQUEUE_WAIT_US`] at a time. No Java looper, no callbacks. A
//! codec that stops answering fails the run after a bounded number of empty
//! waits ([`STALL_WAITS`]). The bound counts waits, not wall time, so the
//! fakes need no clock.
//!
//! The codecs sit behind [`VideoCodecs`] and [`VideoCodec`]: the NDK's
//! `AMediaCodec` in the app ([`NdkCodecs`]), fakes in the tests.

use std::cmp::Reverse;
use std::collections::{BinaryHeap, HashMap, VecDeque};
use std::ffi::{c_void, CStr};
use std::sync::OnceLock;

use bytes::Bytes;
use stream_server::{
    PictureConverter, PictureEvent, PictureTarget, Route, Segments, SourcePicture,
};

use crate::libav::{CodecParameters, ColourTags, Nv12Layout, PictureDecoder};
use crate::mediacodec::DEQUEUE_WAIT_US;
use crate::ndk_media::{
    ndk, AndroidWindow, BufferInfo, MediaFormat, Ndk, BUFFER_FLAG_CODEC_CONFIG,
    BUFFER_FLAG_END_OF_STREAM, BUFFER_FLAG_KEY_FRAME, CONFIGURE_FLAG_ENCODE,
    INFO_OUTPUT_BUFFERS_CHANGED, INFO_OUTPUT_FORMAT_CHANGED, INFO_TRY_AGAIN_LATER,
};

/// Empty waits in a row before a codec counts as stuck: about 5 s.
pub const STALL_WAITS: u32 = 500;
/// Empty waits a surface encoder gets to catch up with what was rendered
/// into it, before its end is signalled anyway: about 2 s.
pub const CATCH_UP_WAITS: u32 = 200;
/// Empty waits an ended encoder gets to hand back its last pictures: about
/// 3 s.
pub const END_WAITS: u32 = 300;
/// `COLOR_FormatSurface`.
pub const COLOR_FORMAT_SURFACE: i32 = 0x7F00_0789;
/// `COLOR_FormatYUVP010`.
pub const COLOR_FORMAT_P010: i32 = 54;
/// `COLOR_FormatYUV420SemiPlanar`: NV12, what the software path hands the
/// encoder.
pub const COLOR_FORMAT_NV12: i32 = 21;
/// Decoded pictures a [`SoftDecoder`] holds before it takes no more input.
pub const SOFT_READY_PICTURES: usize = 4;
/// The encoder's sync picture interval, in seconds. Every segment's first
/// picture is a sync picture anyway, since each segment has its own
/// encoder.
pub const SYNC_INTERVAL_S: i32 = 10;
/// A decoder's input buffers hold at least this many bytes.
pub const MIN_INPUT_BYTES: u32 = 2 * 1024 * 1024;

// --- The codecs, behind traits ----------------------------------------------------

/// What one output dequeue found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VideoOutput {
    /// Buffer `index`: `size` bytes at `offset`, shown at `pts_us`, with
    /// `flags`.
    Buffer {
        index: usize,
        offset: usize,
        size: usize,
        pts_us: i64,
        flags: u32,
    },
    /// The output format changed: read it with [`VideoCodec::output_format`].
    FormatChanged,
    /// Nothing yet.
    Nothing,
}

/// A picture's colour keys as MediaFormat numbers them.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Colour {
    /// `color-standard`: 1 BT.709, 2 BT.601 PAL, 4 BT.601 NTSC, 6 BT.2020.
    pub standard: Option<i32>,
    /// `color-transfer`: 3 SDR, 6 PQ (ST 2084), 7 HLG.
    pub transfer: Option<i32>,
    /// `color-range`: 1 full, 2 limited.
    pub range: Option<i32>,
}

impl Colour {
    /// The keys for a container's colour tags. A tag the container leaves
    /// unspecified gives no key.
    pub fn of_tags(tags: ColourTags) -> Self {
        let standard = |tag: i32| match tag {
            1 => Some(1),      // BT.709
            5 => Some(2),      // BT.470 BG, BT.601 PAL
            6 | 7 => Some(4),  // SMPTE 170M and 240M, BT.601 NTSC
            9 | 10 => Some(6), // BT.2020
            _ => None,
        };
        let transfer = match tags.transfer {
            ColourTags::PQ => Some(6),
            ColourTags::HLG => Some(7),
            // BT.709, BT.470, SMPTE 170M and 240M, BT.2020 10 and 12 bit.
            1 | 4..=7 | 14 | 15 => Some(3),
            _ => None,
        };
        Self {
            standard: standard(tags.primaries).or_else(|| standard(tags.matrix)),
            transfer,
            range: match tags.range {
                1 => Some(2), // MPEG, limited
                2 => Some(1), // JPEG, full
                _ => None,
            },
        }
    }

    /// These keys, with `other`'s where these have none.
    pub fn or(self, other: Colour) -> Self {
        Self {
            standard: self.standard.or(other.standard),
            transfer: self.transfer.or(other.transfer),
            range: self.range.or(other.range),
        }
    }
}

/// What a codec's format says about its pictures.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct VideoFormat {
    pub color_format: Option<i32>,
    pub width: u32,
    pub height: u32,
    /// Bytes from one row to the next. Some codecs give it in samples
    /// ([`PlaneLayout::of`]).
    pub stride: Option<u32>,
    /// Rows from the luma plane's start to the chroma plane's.
    pub slice_height: Option<u32>,
    /// (left, top, right, bottom), right and bottom inclusive.
    pub crop: Option<(u32, u32, u32, u32)>,
    pub colour: Colour,
    pub hdr_static_info: Option<Bytes>,
    /// `csd-0`, then `csd-1` where there is one.
    pub csd: Vec<Bytes>,
}

/// **One codec**: an `AMediaCodec` ([`NdkCodec`]), or a fake.
pub trait VideoCodec {
    /// An input buffer's index, or `None` if none is free within the wait.
    fn dequeue_input(&mut self, wait_us: i64) -> Result<Option<usize>, String>;
    /// Input buffer `index`, to be filled.
    fn input_buffer(&mut self, index: usize) -> Result<&mut [u8], String>;
    fn queue_input(
        &mut self,
        index: usize,
        len: usize,
        pts_us: i64,
        end: bool,
    ) -> Result<(), String>;
    fn dequeue_output(&mut self, wait_us: i64) -> Result<VideoOutput, String>;
    /// Output buffer `index`'s bytes.
    fn output_buffer(&mut self, index: usize) -> Result<&[u8], String>;
    /// Output buffer `index` dropped (`None`), or rendered to the decoder's
    /// surface stamped `pts_us` (`releaseOutputBufferAtTime`, in ns).
    fn release_output(&mut self, index: usize, render_at_us: Option<i64>) -> Result<(), String>;
    fn output_format(&mut self) -> Result<VideoFormat, String>;
    fn input_format(&mut self) -> Result<VideoFormat, String>;
    /// Ends a surface encoder's input.
    fn signal_end_of_input(&mut self) -> Result<(), String>;
}

/// **What makes the codecs**: [`NdkCodecs`], [`SoftCodecs`], or a fake. A
/// codec's drop stops and deletes it. A surface's drop releases the window.
pub trait VideoCodecs: Send {
    /// An encoder.
    type Codec: VideoCodec + Send;
    type Decoder: VideoCodec + Send;
    type Surface: Send;
    /// A started decoder for `source`: rendering into `surface`, or writing
    /// P010 buffers when `p010`, or writing buffers in its own format.
    fn decoder(
        &mut self,
        source: &PictureSource,
        surface: Option<&Self::Surface>,
        p010: bool,
    ) -> Result<Self::Decoder, String>;
    /// A started encoder for `config`, with its input surface when
    /// `surface`.
    fn encoder(
        &mut self,
        config: &EncoderConfig,
        surface: bool,
    ) -> Result<(Self::Codec, Option<Self::Surface>), String>;
    /// Moves `decoder`'s output onto `surface`.
    fn set_output_surface(
        &mut self,
        decoder: &mut Self::Decoder,
        surface: &Self::Surface,
    ) -> Result<(), String>;
    /// Whether the decoder is software, writing NV12 buffers: the software
    /// path.
    fn decodes_in_software(&self) -> bool {
        false
    }
}

/// The source's picture as the decoder is told it.
#[derive(Clone, Debug, PartialEq)]
pub struct PictureSource {
    /// `video/avc`, `video/hevc`, `video/av01` or `video/x-vnd.on2.vp9`.
    pub mime: &'static str,
    pub width: u32,
    pub height: u32,
    pub frame_rate: f32,
    /// `csd-0` and `csd-1`: the H.264 SPS and PPS, HEVC's parameter sets
    /// (both Annex-B), AV1's `av1C`; none for VP9.
    pub csd: Vec<Bytes>,
    /// From the container's tags.
    pub colour: Colour,
    /// The pictures' times are when each is decoded, not shown: an AVI's,
    /// whose packets carry no presentation time.
    pub decode_times: bool,
}

/// What every encoder of a run is configured with. The keys are the same
/// for each one, which is what keeps their codec configurations
/// identical.
#[derive(Clone, Debug, PartialEq)]
pub struct EncoderConfig {
    pub target: PictureTarget,
    /// The container's picture size.
    pub width: u32,
    pub height: u32,
    pub bitrate: u32,
    pub frame_rate: f32,
    pub colour: Colour,
    pub hdr_static_info: Option<Bytes>,
}

impl EncoderConfig {
    /// MediaFormat's MIME type for the target.
    pub fn mime(&self) -> &'static str {
        if self.target.hevc() {
            "video/hevc"
        } else {
            "video/avc"
        }
    }

    /// MediaFormat's `profile`: AVC High 8, HEVC Main 1, HEVC Main 10 2.
    pub fn profile(&self) -> i32 {
        match self.target {
            PictureTarget::H264High => 8,
            PictureTarget::HevcMain => 1,
            PictureTarget::HevcMain10 => 2,
        }
    }
}

// --- The converter ----------------------------------------------------------------

/// One segment's encoder. The codec is declared before its surface, so a
/// drop deletes the codec before it releases the window, as the probe did.
struct OpenEncoder<C, S> {
    codec: C,
    surface: Option<S>,
    segment: u64,
    /// The input layout the buffer path copies into.
    input: Option<VideoFormat>,
    csd: Option<Bytes>,
    configured: bool,
    pictures_in: u32,
    pictures_out: u32,
    ended: bool,
}

/// The run's decoder, and what it has said.
struct Decoding<C> {
    codec: C,
    /// Its output format.
    layout: Option<VideoFormat>,
    /// It handed back its end.
    ended: bool,
}

/// **The converter**: a [`PictureConverter`] over `K`'s codecs, built for
/// one run. Fields drop in order: the open encoder (codec, then window),
/// then the decoder. Nothing is drained on a drop.
pub struct Converter<K: VideoCodecs> {
    open: Option<OpenEncoder<K::Codec, K::Surface>>,
    decoder: Option<Decoding<K::Decoder>>,
    codecs: K,
    source: PictureSource,
    config: EncoderConfig,
    /// The buffer path's encoder keys took the decoder's where the
    /// container said nothing.
    settled: bool,
    /// The input times no picture has been given yet, when a hardware
    /// decoder's pictures are timed again ([`Self::restamps`]).
    times: BinaryHeap<Reverse<i64>>,
}

impl<K: VideoCodecs> Converter<K> {
    /// A converter that has made no codec yet. The first push makes them.
    pub fn new(codecs: K, source: PictureSource, config: EncoderConfig) -> Self {
        Self {
            open: None,
            decoder: None,
            codecs,
            source,
            config,
            settled: false,
            times: BinaryHeap::new(),
        }
    }

    /// What the encoders are configured with, as it stands.
    pub fn config(&self) -> &EncoderConfig {
        &self.config
    }

    /// The software path: a software decoder writing NV12.
    fn software(&self) -> bool {
        self.codecs.decodes_in_software()
    }

    /// Pictures reach the encoder through byte buffers: the buffer path and
    /// the software path.
    fn buffers(&self) -> bool {
        self.config.target.ten_bit() || self.software()
    }

    /// Bytes per sample in the buffers: P010's two, NV12's one.
    fn sample_bytes(&self) -> usize {
        if self.config.target.ten_bit() {
            2
        } else {
            1
        }
    }

    /// The pictures of a hardware decoder fed decode times are timed again
    /// on the way out. The software decoder times its own.
    fn restamps(&self) -> bool {
        self.source.decode_times && !self.software()
    }

    /// The decoder, and on the surface path the encoder for the run's
    /// first segment, whose surface the decoder renders into.
    fn start(&mut self, segments: &Segments) -> Result<(), String> {
        if self.software() && self.config.target.ten_bit() {
            return Err("the software decoder makes 8-bit pictures only".to_owned());
        }
        if self.buffers() {
            let p010 = self.config.target.ten_bit();
            let codec = self.codecs.decoder(&self.source, None, p010)?;
            self.decoder = Some(Decoding {
                codec,
                layout: None,
                ended: false,
            });
            return Ok(());
        }
        self.open_encoder(segments.first())?;
        let surface = self.open.as_ref().and_then(|open| open.surface.as_ref());
        let surface = surface.ok_or("the encoder gave no input surface")?;
        let codec = self.codecs.decoder(&self.source, Some(surface), false)?;
        self.decoder = Some(Decoding {
            codec,
            layout: None,
            ended: false,
        });
        Ok(())
    }

    fn decoder(&mut self) -> Result<&mut K::Decoder, String> {
        Ok(&mut self.decoder.as_mut().ok_or("no decoder")?.codec)
    }

    fn decoder_ended(&self) -> bool {
        self.decoder.as_ref().is_some_and(|decoder| decoder.ended)
    }

    fn open_encoder(&mut self, segment: u64) -> Result<(), String> {
        let buffers = self.buffers();
        let (mut codec, surface) = self.codecs.encoder(&self.config, !buffers)?;
        if !buffers && surface.is_none() {
            return Err("the encoder gave no input surface".to_owned());
        }
        let input = if buffers {
            match codec.input_format() {
                Ok(format) => Some(format),
                Err(error) => {
                    tracing::debug!(%error, "no encoder input format; assuming a packed picture");
                    None
                }
            }
        } else {
            None
        };
        self.open = Some(OpenEncoder {
            codec,
            surface,
            segment,
            input,
            csd: None,
            configured: false,
            pictures_in: 0,
            pictures_out: 0,
            ended: false,
        });
        Ok(())
    }

    fn push_into(
        &mut self,
        picture: SourcePicture,
        segments: &Segments,
        events: &mut Vec<PictureEvent>,
    ) -> Result<(), String> {
        if self.decoder.is_none() {
            self.start(segments)?;
        }
        let mut empty = 0;
        loop {
            let mut queued = false;
            let decoder = self.decoder()?;
            if let Some(index) = decoder.dequeue_input(0)? {
                let buffer = decoder.input_buffer(index)?;
                let len = picture.data.len();
                let capacity = buffer.len();
                let room = buffer.get_mut(..len).ok_or_else(|| {
                    format!(
                        "a picture of {len} bytes does not fit the decoder's {capacity}-byte input"
                    )
                })?;
                room.copy_from_slice(&picture.data);
                decoder.queue_input(index, len, picture.pts_us, false)?;
                if self.restamps() {
                    self.times.push(Reverse(picture.pts_us));
                }
                queued = true;
            }
            let wait = if queued { 0 } else { DEQUEUE_WAIT_US };
            let decoded = self.drain_decoder(wait, segments, events)?;
            let encoded = self.drain_encoder(0, events)?;
            if queued {
                return Ok(());
            }
            if decoded || encoded {
                empty = 0;
            } else {
                empty += 1;
                if empty >= STALL_WAITS {
                    return Err(format!(
                        "the decoder took no picture in {STALL_WAITS} waits"
                    ));
                }
            }
        }
    }

    fn finish_into(
        &mut self,
        segments: &Segments,
        events: &mut Vec<PictureEvent>,
    ) -> Result<(), String> {
        if self.decoder.is_none() {
            return Ok(());
        }
        let mut empty = 0;
        loop {
            let decoder = self.decoder()?;
            if let Some(index) = decoder.dequeue_input(0)? {
                decoder.queue_input(index, 0, 0, true)?;
                break;
            }
            let decoded = self.drain_decoder(DEQUEUE_WAIT_US, segments, events)?;
            let encoded = self.drain_encoder(0, events)?;
            stall(&mut empty, decoded || encoded, "the decoder took no end")?;
        }
        let mut empty = 0;
        while !self.decoder_ended() {
            let decoded = self.drain_decoder(DEQUEUE_WAIT_US, segments, events)?;
            let encoded = self.drain_encoder(0, events)?;
            stall(
                &mut empty,
                decoded || encoded,
                "the decoder never reached its end",
            )?;
        }
        self.finish_encoder(events)
    }

    /// Takes what the decoder has, waiting `wait_us` for the first. True
    /// when anything came out.
    fn drain_decoder(
        &mut self,
        wait_us: i64,
        segments: &Segments,
        events: &mut Vec<PictureEvent>,
    ) -> Result<bool, String> {
        let mut progressed = false;
        let mut wait = wait_us;
        while !self.decoder_ended() {
            let output = self.decoder()?.dequeue_output(wait)?;
            wait = 0;
            match output {
                VideoOutput::Nothing => break,
                VideoOutput::FormatChanged => {
                    progressed = true;
                    self.read_layout()?;
                }
                VideoOutput::Buffer {
                    index,
                    offset,
                    size,
                    pts_us,
                    flags,
                } => {
                    progressed = true;
                    self.decoded(index, offset, size, pts_us, segments, events)?;
                    if flags & BUFFER_FLAG_END_OF_STREAM != 0 {
                        if let Some(decoder) = self.decoder.as_mut() {
                            decoder.ended = true;
                        }
                    }
                }
            }
        }
        Ok(progressed)
    }

    /// The decoder's output format. On the buffer path it must be P010,
    /// and the first one fills in the encoders' colour keys. On the
    /// software path it must be NV12.
    fn read_layout(&mut self) -> Result<(), String> {
        let format = self.decoder()?.output_format()?;
        if self.software() {
            if format.color_format != Some(COLOR_FORMAT_NV12) {
                return Err(format!(
                    "the software decoder gives no NV12 pictures (color-format {:?})",
                    format.color_format
                ));
            }
        } else if self.buffers() {
            if format.color_format != Some(COLOR_FORMAT_P010) {
                return Err(format!(
                    "the decoder gives no 10-bit pictures (color-format {:?})",
                    format.color_format
                ));
            }
            if !self.settled {
                self.settled = true;
                self.config.colour = self.config.colour.or(format.colour);
                if self.config.hdr_static_info.is_none() {
                    self.config.hdr_static_info = format.hdr_static_info.clone();
                }
            }
        }
        if let Some(decoder) = self.decoder.as_mut() {
            decoder.layout = Some(format);
        }
        Ok(())
    }

    /// One decoded picture, routed.
    fn decoded(
        &mut self,
        index: usize,
        offset: usize,
        size: usize,
        pts_us: i64,
        segments: &Segments,
        events: &mut Vec<PictureEvent>,
    ) -> Result<(), String> {
        if size == 0 {
            return self.decoder()?.release_output(index, None);
        }
        let pts_us = if self.restamps() {
            self.times
                .pop()
                .map_or(pts_us, |Reverse(earliest)| earliest)
        } else {
            pts_us
        };
        let segment = match segments.route(pts_us) {
            Route::Drop => {
                return self.decoder()?.release_output(index, None);
            }
            Route::Encode { segment } => segment,
        };
        let open_segment = self.open.as_ref().map(|open| open.segment);
        if let Some(open) = open_segment.filter(|open| *open > segment) {
            return Err(format!(
                "a picture at {pts_us} us is segment {segment}'s, below the open encoder's \
                 segment {open}"
            ));
        }
        if open_segment != Some(segment) {
            self.finish_encoder(events)?;
            self.open_encoder(segment)?;
            if !self.buffers() {
                let (Some(decoder), Some(surface)) = (
                    self.decoder.as_mut(),
                    self.open.as_ref().and_then(|open| open.surface.as_ref()),
                ) else {
                    return Err("no decoder or no encoder surface".to_owned());
                };
                self.codecs
                    .set_output_surface(&mut decoder.codec, surface)?;
            }
        }
        if self.buffers() {
            return self.encode_buffer(index, offset, size, pts_us, events);
        }
        self.decoder()?.release_output(index, Some(pts_us))?;
        if let Some(open) = self.open.as_mut() {
            open.pictures_in += 1;
        }
        Ok(())
    }

    /// The buffer and software paths: decoder buffer `index` copied into an
    /// encoder input buffer and queued at `pts_us`.
    fn encode_buffer(
        &mut self,
        index: usize,
        offset: usize,
        size: usize,
        pts_us: i64,
        events: &mut Vec<PictureEvent>,
    ) -> Result<(), String> {
        if self
            .decoder
            .as_ref()
            .is_some_and(|decoder| decoder.layout.is_none())
        {
            self.read_layout()?;
        }
        let mut empty = 0;
        let input = loop {
            let open = self.open.as_mut().ok_or("no encoder")?;
            if let Some(input) = open.codec.dequeue_input(DEQUEUE_WAIT_US)? {
                break input;
            }
            let encoded = self.drain_encoder(0, events)?;
            stall(&mut empty, encoded, "the encoder took no picture")?;
        };
        let (width, height) = (self.config.width, self.config.height);
        let sample = self.sample_bytes();
        let (Some(decoder), Some(open)) = (self.decoder.as_mut(), self.open.as_mut()) else {
            return Err("no decoder or no encoder".to_owned());
        };
        let layout = decoder.layout.as_ref().ok_or("no decoder format")?;
        let from = PlaneLayout::of(layout, width, height, sample);
        let to = match &open.input {
            Some(format) => PlaneLayout::of(format, width, height, sample),
            None => PlaneLayout::packed(width, height, sample),
        };
        let source = decoder.codec.output_buffer(index)?;
        let source = source
            .get(offset..offset + size)
            .ok_or("the decoder's output runs past its buffer")?;
        // The decoder's buffer is borrowed until it is released, and the
        // encoder's until it is queued: copy between the two at once.
        let target = open.codec.input_buffer(input)?;
        let len = copy_picture(source, from, target, to, width, height, sample)?;
        open.codec.queue_input(input, len, pts_us, false)?;
        decoder.codec.release_output(index, None)?;
        open.pictures_in += 1;
        Ok(())
    }

    /// Takes what the open encoder has, waiting `wait_us` for the first.
    /// True when anything came out.
    fn drain_encoder(
        &mut self,
        wait_us: i64,
        events: &mut Vec<PictureEvent>,
    ) -> Result<bool, String> {
        let Some(open) = self.open.as_mut() else {
            return Ok(false);
        };
        let mut progressed = false;
        let mut wait = wait_us;
        while !open.ended {
            let output = open.codec.dequeue_output(wait)?;
            wait = 0;
            match output {
                VideoOutput::Nothing => break,
                VideoOutput::FormatChanged => {
                    progressed = true;
                    if open.csd.is_none() {
                        let format = open.codec.output_format()?;
                        if !format.csd.is_empty() {
                            open.csd = Some(format.csd.concat().into());
                        }
                    }
                }
                VideoOutput::Buffer {
                    index,
                    offset,
                    size,
                    pts_us,
                    flags,
                } => {
                    progressed = true;
                    let data = open
                        .codec
                        .output_buffer(index)?
                        .get(offset..offset + size)
                        .map(Bytes::copy_from_slice)
                        .ok_or("the encoder's output runs past its buffer")?;
                    open.codec.release_output(index, None)?;
                    if flags & BUFFER_FLAG_CODEC_CONFIG != 0 {
                        if open.csd.is_none() && !data.is_empty() {
                            open.csd = Some(data);
                        }
                    } else if !data.is_empty() {
                        if !open.configured {
                            let csd = open
                                .csd
                                .clone()
                                .ok_or("the encoder gave a picture before its configuration")?;
                            events.push(PictureEvent::Config {
                                segment: open.segment,
                                width: self.config.width,
                                height: self.config.height,
                                csd: with_hdr10_sei(csd, &self.config),
                            });
                            open.configured = true;
                        }
                        events.push(PictureEvent::Picture {
                            segment: open.segment,
                            pts_us,
                            key: flags & BUFFER_FLAG_KEY_FRAME != 0,
                            data,
                        });
                        open.pictures_out += 1;
                    }
                    if flags & BUFFER_FLAG_END_OF_STREAM != 0 {
                        open.ended = true;
                    }
                }
            }
        }
        Ok(progressed)
    }

    /// Ends the open encoder, hands back everything it made, and deletes
    /// it. An encoder that was given nothing is deleted without an end.
    fn finish_encoder(&mut self, events: &mut Vec<PictureEvent>) -> Result<(), String> {
        let Some(open) = self.open.as_ref() else {
            return Ok(());
        };
        let segment = open.segment;
        if open.pictures_in == 0 {
            self.open = None;
            events.push(PictureEvent::SegmentDone {
                segment,
                pictures_in: 0,
                pictures_out: 0,
            });
            return Ok(());
        }
        if self.buffers() {
            let mut empty = 0;
            let input = loop {
                let open = self.open.as_mut().ok_or("no encoder")?;
                if let Some(input) = open.codec.dequeue_input(DEQUEUE_WAIT_US)? {
                    break input;
                }
                let encoded = self.drain_encoder(0, events)?;
                stall(&mut empty, encoded, "the encoder took no end")?;
            };
            let open = self.open.as_mut().ok_or("no encoder")?;
            open.codec.queue_input(input, 0, 0, true)?;
        } else {
            // What was rendered into the surface may still be on its way.
            let mut empty = 0;
            while self
                .open
                .as_ref()
                .is_some_and(|open| open.pictures_out < open.pictures_in && !open.ended)
                && empty < CATCH_UP_WAITS
            {
                if !self.drain_encoder(DEQUEUE_WAIT_US, events)? {
                    empty += 1;
                }
            }
            let open = self.open.as_mut().ok_or("no encoder")?;
            if !open.ended {
                open.codec.signal_end_of_input()?;
            }
        }
        let mut empty = 0;
        while self.open.as_ref().is_some_and(|open| !open.ended) {
            if self.drain_encoder(DEQUEUE_WAIT_US, events)? {
                empty = 0;
            } else {
                empty += 1;
                if empty >= END_WAITS {
                    return Err(format!(
                        "segment {segment}'s encoder did not end in {END_WAITS} waits"
                    ));
                }
            }
        }
        let open = self.open.take().ok_or("no encoder")?;
        events.push(PictureEvent::SegmentDone {
            segment,
            pictures_in: open.pictures_in,
            pictures_out: open.pictures_out,
        });
        Ok(())
    }
}

/// Counts an empty wait, and fails with `what` once there were
/// [`STALL_WAITS`] in a row.
fn stall(empty: &mut u32, progressed: bool, what: &str) -> Result<(), String> {
    if progressed {
        *empty = 0;
        return Ok(());
    }
    *empty += 1;
    if *empty >= STALL_WAITS {
        return Err(format!("{what} in {STALL_WAITS} waits"));
    }
    Ok(())
}

impl<K: VideoCodecs> PictureConverter for Converter<K> {
    fn push(
        &mut self,
        picture: SourcePicture,
        segments: &Segments,
    ) -> Result<Vec<PictureEvent>, String> {
        let mut events = Vec::new();
        self.push_into(picture, segments, &mut events)?;
        Ok(events)
    }

    fn finish(&mut self, segments: &Segments) -> Result<Vec<PictureEvent>, String> {
        let mut events = Vec::new();
        self.finish_into(segments, &mut events)?;
        Ok(events)
    }
}

// --- Pictures in buffers ----------------------------------------------------------

/// Where a semi-planar 4:2:0 picture's samples are in a buffer (P010's
/// 16-bit ones, NV12's 8-bit ones): luma rows, then below the slice height
/// the interleaved chroma rows, at half the height.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PlaneLayout {
    /// Bytes from one row to the next.
    pub row_bytes: usize,
    /// Rows from the luma plane's start to the chroma plane's.
    pub slice_height: usize,
    /// The picture's top-left corner, in samples.
    pub left: usize,
    pub top: usize,
}

impl PlaneLayout {
    /// The layout `format` describes, for a picture `width`×`height` of
    /// `sample`-byte samples. A stride smaller than a row of samples is in
    /// samples, as some codecs give it (the probe's `p010RowBytes`). A
    /// slice height shorter than the picture is not one.
    pub fn of(format: &VideoFormat, width: u32, height: u32, sample: usize) -> Self {
        let width = width as usize;
        let height = height as usize;
        let row_bytes = match format.stride.map(|stride| stride as usize) {
            None | Some(0) => width * sample,
            Some(stride) if stride < width * sample => stride * sample,
            Some(stride) => stride,
        };
        let slice_height = format
            .slice_height
            .map(|slice| slice as usize)
            .filter(|slice| *slice >= height)
            .unwrap_or((format.height as usize).max(height));
        let (left, top) = format
            .crop
            .map_or((0, 0), |(left, top, _, _)| (left as usize, top as usize));
        Self {
            row_bytes,
            slice_height,
            left,
            top,
        }
    }

    /// A picture of `sample`-byte samples with nothing between its rows.
    pub fn packed(width: u32, height: u32, sample: usize) -> Self {
        Self {
            row_bytes: width as usize * sample,
            slice_height: height as usize,
            left: 0,
            top: 0,
        }
    }

    /// The bytes a whole picture of `height` rows takes in this layout,
    /// from the buffer's start.
    pub fn picture_bytes(&self, height: u32) -> usize {
        let chroma_rows = (height as usize).div_ceil(2);
        self.row_bytes * (self.slice_height + chroma_rows)
    }
}

/// **A P010 picture copied between layouts**: [`copy_picture`] of 16-bit
/// samples.
pub fn copy_p010(
    source: &[u8],
    from: PlaneLayout,
    target: &mut [u8],
    to: PlaneLayout,
    width: u32,
    height: u32,
) -> Result<usize, String> {
    copy_picture(source, from, target, to, width, height, 2)
}

/// **An NV12 picture copied between layouts**: [`copy_picture`] of 8-bit
/// samples.
pub fn copy_nv12(
    source: &[u8],
    from: PlaneLayout,
    target: &mut [u8],
    to: PlaneLayout,
    width: u32,
    height: u32,
) -> Result<usize, String> {
    copy_picture(source, from, target, to, width, height, 1)
}

/// **A semi-planar picture copied between layouts**: the `width`×`height`
/// picture of `sample`-byte samples at `from` in `source` into `to` in
/// `target`. Layouts that match, both at the buffer's corner, go as one
/// copy; otherwise row by row, the luma rows and then the chroma rows.
/// Answers how many bytes of `target` make the picture, which is what the
/// encoder is handed.
pub fn copy_picture(
    source: &[u8],
    from: PlaneLayout,
    target: &mut [u8],
    to: PlaneLayout,
    width: u32,
    height: u32,
    sample: usize,
) -> Result<usize, String> {
    let queued = to.picture_bytes(height).min(target.len());
    let luma_bytes = width as usize * sample;
    let chroma_bytes = (width as usize).div_ceil(2) * 2 * sample;
    let chroma_rows = (height as usize).div_ceil(2);
    // The last chroma row ends here, in either layout.
    let end = |layout: PlaneLayout| {
        layout.row_bytes * (layout.slice_height + layout.top / 2 + chroma_rows - 1)
            + layout.left * sample
            + chroma_bytes
    };
    if source.len() < end(from) {
        return Err(format!(
            "the decoder's picture is {} bytes, short of the {} its layout needs",
            source.len(),
            end(from)
        ));
    }
    if target.len() < end(to) {
        return Err(format!(
            "the encoder's input is {} bytes, short of the {} its layout needs",
            target.len(),
            end(to)
        ));
    }
    if from == to && from.left == 0 && from.top == 0 {
        let whole = queued.min(source.len());
        target[..whole].copy_from_slice(&source[..whole]);
        return Ok(queued);
    }
    let mut copy_rows =
        |plane_from: usize, plane_to: usize, rows: usize, bytes: usize, sub: usize| {
            for row in 0..rows {
                let at_from =
                    plane_from + (from.top / sub + row) * from.row_bytes + from.left * sample;
                let at_to = plane_to + (to.top / sub + row) * to.row_bytes + to.left * sample;
                target[at_to..at_to + bytes].copy_from_slice(&source[at_from..at_from + bytes]);
            }
        };
    copy_rows(0, 0, height as usize, luma_bytes, 1);
    copy_rows(
        from.row_bytes * from.slice_height,
        to.row_bytes * to.slice_height,
        chroma_rows,
        chroma_bytes,
        2,
    );
    Ok(queued)
}

// --- HDR10 metadata ---------------------------------------------------------------

/// HEVC's prefix SEI NAL unit type.
const HEVC_PREFIX_SEI: u8 = 39;
/// SEI payload types: mastering display colour volume, content light level.
const SEI_MASTERING_DISPLAY: u8 = 137;
const SEI_CONTENT_LIGHT_LEVEL: u8 = 144;

/// **HDR10's SEI messages from MediaFormat's `hdr-static-info`**, as two
/// Annex-B prefix SEI NAL units: the content light levels (144), then the
/// mastering display (137), the order x265 writes them in. The light levels
/// are left out when both are zero.
///
/// `hdr-static-info` is 25 bytes: descriptor 0, then u16 little-endian
/// values. R, G, B and the white point as x,y in units of 0.00002, the
/// maximum luminance in cd/m², the minimum in units of 0.0001 cd/m², then
/// MaxCLL and MaxFALL. The SEI wants the primaries in G, B, R order and
/// both luminances in units of 0.0001 cd/m², as u32. `None` for anything
/// that is not that.
pub fn hdr10_sei(static_info: &[u8]) -> Option<Bytes> {
    if static_info.len() < 25 || static_info[0] != 0 {
        return None;
    }
    let at =
        |field: usize| u16::from_le_bytes([static_info[1 + field * 2], static_info[2 + field * 2]]);
    let (r, g, b, white) = (
        (at(0), at(1)),
        (at(2), at(3)),
        (at(4), at(5)),
        (at(6), at(7)),
    );
    let (max_luminance, min_luminance) = (u32::from(at(8)) * 10_000, u32::from(at(9)));
    let (max_cll, max_fall) = (at(10), at(11));
    let mut out = Vec::new();
    if max_cll != 0 || max_fall != 0 {
        let mut payload = Vec::new();
        payload.extend_from_slice(&max_cll.to_be_bytes());
        payload.extend_from_slice(&max_fall.to_be_bytes());
        push_sei(&mut out, SEI_CONTENT_LIGHT_LEVEL, &payload);
    }
    let mut payload = Vec::new();
    for (x, y) in [g, b, r, white] {
        payload.extend_from_slice(&x.to_be_bytes());
        payload.extend_from_slice(&y.to_be_bytes());
    }
    payload.extend_from_slice(&max_luminance.to_be_bytes());
    payload.extend_from_slice(&min_luminance.to_be_bytes());
    push_sei(&mut out, SEI_MASTERING_DISPLAY, &payload);
    Some(Bytes::from(out))
}

/// One prefix SEI NAL unit holding one message, behind a four-byte start
/// code, with emulation prevention.
fn push_sei(out: &mut Vec<u8>, payload_type: u8, payload: &[u8]) {
    let mut rbsp = vec![payload_type, payload.len() as u8];
    rbsp.extend_from_slice(payload);
    rbsp.push(0x80); // rbsp_trailing_bits
    out.extend_from_slice(&[0, 0, 0, 1, HEVC_PREFIX_SEI << 1, 0x01]);
    let mut zeros = 0;
    for byte in rbsp {
        if zeros >= 2 && byte <= 3 {
            out.push(3);
            zeros = 0;
        }
        out.push(byte);
        zeros = if byte == 0 { zeros + 1 } else { 0 };
    }
}

/// Whether an Annex-B buffer holds a prefix SEI NAL unit whose first
/// message is of `payload_type`.
pub fn has_sei(annex_b: &[u8], payload_type: u8) -> bool {
    crate::rendition::annex_b_units(annex_b).iter().any(|unit| {
        unit.len() > 2 && (unit[0] >> 1) & 0x3f == HEVC_PREFIX_SEI && unit[2] == payload_type
    })
}

/// The codec configuration a converted HEVC Main 10 picture goes out with:
/// the encoder's, plus HDR10's SEI messages when the run has
/// `hdr-static-info` and the encoder did not put a mastering display in.
fn with_hdr10_sei(csd: Bytes, config: &EncoderConfig) -> Bytes {
    if !config.target.ten_bit() || has_sei(&csd, SEI_MASTERING_DISPLAY) {
        return csd;
    }
    match config.hdr_static_info.as_deref().and_then(hdr10_sei) {
        Some(sei) => [csd.as_ref(), sei.as_ref()].concat().into(),
        None => csd,
    }
}

// --- The NDK ----------------------------------------------------------------------

/// **Android's codecs** as [`VideoCodecs`]: `AMediaCodec`s made by type,
/// so each is the device's first choice for its MIME type.
#[derive(Clone, Debug, Default)]
pub struct NdkCodecs {
    /// MediaFormat's `operating-rate` for every codec, for the bench.
    pub operating_rate: Option<f32>,
    /// MediaFormat's `priority` for every codec (0 is real time), for the
    /// bench.
    pub priority: Option<i32>,
}

impl NdkCodecs {
    /// The device's codecs, or an error where this is no Android.
    pub fn new() -> Result<Self, String> {
        ndk()?;
        Ok(Self::default())
    }

    fn knobs(&self, format: &MediaFormat) {
        if let Some(rate) = self.operating_rate {
            format.set_f32(c"operating-rate", rate);
        }
        if let Some(priority) = self.priority {
            format.set_i32(c"priority", priority);
        }
    }
}

/// **One `AMediaCodec`**, stopped and deleted on drop.
pub struct NdkCodec {
    ndk: &'static Ndk,
    codec: *mut c_void,
    /// "decoder" or "encoder", for an error's detail.
    role: &'static str,
}

// SAFETY: an `AMediaCodec` may be driven from any one thread at a time,
// and this one is used by one run's thread alone, as `NdkAac` is.
unsafe impl Send for NdkCodec {}

impl NdkCodec {
    fn create(ndk: &'static Ndk, mime: &str, role: &'static str) -> Result<Self, String> {
        let name = std::ffi::CString::new(mime).map_err(|error| error.to_string())?;
        // SAFETY: a NUL-terminated MIME type; a null answer is checked.
        let codec = unsafe {
            if role == "encoder" {
                (ndk.create_encoder_by_type)(name.as_ptr())
            } else {
                (ndk.create_decoder_by_type)(name.as_ptr())
            }
        };
        if codec.is_null() {
            return Err(format!("this device has no {mime} {role}"));
        }
        Ok(Self { ndk, codec, role })
    }

    fn check(&self, status: i32, what: &str) -> Result<(), String> {
        if status != 0 {
            return Err(format!("the {} {what} ({status})", self.role));
        }
        Ok(())
    }

    /// The component's name, where the device can say (API 28).
    pub fn name(&self) -> Option<String> {
        // SAFETY: a live codec.
        unsafe { self.ndk.codec_name(self.codec) }
    }

    fn configure(
        &self,
        format: &MediaFormat,
        surface: *mut c_void,
        flags: u32,
    ) -> Result<(), String> {
        // SAFETY: a live codec and format; `surface` is null or a live
        // window; no crypto.
        let status = unsafe {
            (self.ndk.configure)(
                self.codec,
                format.as_ptr(),
                surface,
                std::ptr::null_mut(),
                flags,
            )
        };
        self.check(status, "refused its format")
    }

    fn start(&self) -> Result<(), String> {
        // SAFETY: a configured codec.
        let status = unsafe { (self.ndk.start)(self.codec) };
        self.check(status, "did not start")
    }

    fn format(&self, format: Option<MediaFormat>) -> Result<VideoFormat, String> {
        let format = format.ok_or_else(|| format!("the {} has no format", self.role))?;
        Ok(video_format(&format))
    }
}

/// What a MediaFormat says about a picture.
fn video_format(format: &MediaFormat) -> VideoFormat {
    let positive = |key: &CStr| format.i32(key).and_then(|value| u32::try_from(value).ok());
    let crop = format
        .rect(c"crop")
        .or_else(|| {
            Some((
                format.i32(c"crop-left")?,
                format.i32(c"crop-top")?,
                format.i32(c"crop-right")?,
                format.i32(c"crop-bottom")?,
            ))
        })
        .and_then(|(left, top, right, bottom)| {
            Some((
                u32::try_from(left).ok()?,
                u32::try_from(top).ok()?,
                u32::try_from(right).ok()?,
                u32::try_from(bottom).ok()?,
            ))
        });
    VideoFormat {
        color_format: format.i32(c"color-format"),
        width: positive(c"width").unwrap_or(0),
        height: positive(c"height").unwrap_or(0),
        stride: positive(c"stride"),
        slice_height: positive(c"slice-height"),
        crop,
        colour: Colour {
            standard: format.i32(c"color-standard"),
            transfer: format.i32(c"color-transfer"),
            range: format.i32(c"color-range"),
        },
        hdr_static_info: format.buffer(c"hdr-static-info").map(Bytes::from),
        csd: [c"csd-0", c"csd-1"]
            .into_iter()
            .filter_map(|key| format.buffer(key).map(Bytes::from))
            .collect(),
    }
}

impl VideoCodec for NdkCodec {
    fn dequeue_input(&mut self, wait_us: i64) -> Result<Option<usize>, String> {
        // SAFETY: a started codec.
        let index = unsafe { (self.ndk.dequeue_input_buffer)(self.codec, wait_us) };
        match index {
            INFO_TRY_AGAIN_LATER => Ok(None),
            index if index >= 0 => Ok(Some(index as usize)),
            error => Err(format!("the {} gave no input buffer ({error})", self.role)),
        }
    }

    fn input_buffer(&mut self, index: usize) -> Result<&mut [u8], String> {
        let mut size = 0usize;
        // SAFETY: an index the codec handed out; the buffer is `size` bytes
        // and ours until queued.
        unsafe {
            let data = (self.ndk.get_input_buffer)(self.codec, index, &mut size);
            if data.is_null() {
                return Err(format!("the {}'s input buffer is missing", self.role));
            }
            Ok(std::slice::from_raw_parts_mut(data, size))
        }
    }

    fn queue_input(
        &mut self,
        index: usize,
        len: usize,
        pts_us: i64,
        end: bool,
    ) -> Result<(), String> {
        let flags = if end { BUFFER_FLAG_END_OF_STREAM } else { 0 };
        // SAFETY: an index the codec handed out, filled with `len` bytes.
        // The time crosses as the u64 the header declares, bit for bit.
        let status = unsafe {
            (self.ndk.queue_input_buffer)(self.codec, index, 0, len, pts_us as u64, flags)
        };
        self.check(status, "refused its input")
    }

    fn dequeue_output(&mut self, wait_us: i64) -> Result<VideoOutput, String> {
        let mut info = BufferInfo::default();
        // SAFETY: a started codec and a live info struct.
        let index = unsafe { (self.ndk.dequeue_output_buffer)(self.codec, &mut info, wait_us) };
        match index {
            INFO_TRY_AGAIN_LATER | INFO_OUTPUT_BUFFERS_CHANGED => Ok(VideoOutput::Nothing),
            INFO_OUTPUT_FORMAT_CHANGED => Ok(VideoOutput::FormatChanged),
            index if index >= 0 => Ok(VideoOutput::Buffer {
                index: index as usize,
                offset: usize::try_from(info.offset).unwrap_or(0),
                size: usize::try_from(info.size).unwrap_or(0),
                pts_us: info.presentation_time_us,
                flags: info.flags,
            }),
            error => Err(format!("the {} failed ({error})", self.role)),
        }
    }

    fn output_buffer(&mut self, index: usize) -> Result<&[u8], String> {
        let mut size = 0usize;
        // SAFETY: an index the codec handed out; the buffer is `size` bytes
        // until released.
        unsafe {
            let data = (self.ndk.get_output_buffer)(self.codec, index, &mut size);
            if data.is_null() {
                return Err(format!("the {}'s output buffer is missing", self.role));
            }
            Ok(std::slice::from_raw_parts(data, size))
        }
    }

    fn release_output(&mut self, index: usize, render_at_us: Option<i64>) -> Result<(), String> {
        // SAFETY: an index the codec handed out, released once.
        let status = unsafe {
            match render_at_us {
                None => (self.ndk.release_output_buffer)(self.codec, index, false),
                Some(at_us) => (self.ndk.release_output_buffer_at_time)(
                    self.codec,
                    index,
                    at_us.saturating_mul(1000),
                ),
            }
        };
        self.check(status, "did not release its output")
    }

    fn output_format(&mut self) -> Result<VideoFormat, String> {
        // SAFETY: a started codec; the format is ours to delete.
        let format =
            unsafe { MediaFormat::from_raw(self.ndk, (self.ndk.get_output_format)(self.codec)) };
        self.format(format)
    }

    fn input_format(&mut self) -> Result<VideoFormat, String> {
        let get = self
            .ndk
            .get_input_format
            .ok_or("this device cannot say a codec's input format")?;
        // SAFETY: a configured codec; the format is ours to delete.
        let format = unsafe { MediaFormat::from_raw(self.ndk, get(self.codec)) };
        self.format(format)
    }

    fn signal_end_of_input(&mut self) -> Result<(), String> {
        let signal = self
            .ndk
            .signal_end_of_input_stream
            .ok_or("this device cannot end a surface's input")?;
        // SAFETY: a started surface encoder.
        let status = unsafe { signal(self.codec) };
        self.check(status, "did not take the end of its input")
    }
}

impl Drop for NdkCodec {
    fn drop(&mut self) {
        // SAFETY: this value's own codec, stopped and deleted once.
        unsafe {
            (self.ndk.stop)(self.codec);
            (self.ndk.delete)(self.codec);
        }
    }
}

impl VideoCodecs for NdkCodecs {
    type Codec = NdkCodec;
    type Decoder = NdkCodec;
    type Surface = AndroidWindow;

    fn decoder(
        &mut self,
        source: &PictureSource,
        surface: Option<&AndroidWindow>,
        p010: bool,
    ) -> Result<NdkCodec, String> {
        let ndk = ndk()?;
        let codec = NdkCodec::create(ndk, source.mime, "decoder")?;
        let format = MediaFormat::new(ndk)?;
        let mime = std::ffi::CString::new(source.mime).map_err(|error| error.to_string())?;
        format.set_string(c"mime", &mime);
        format.set_i32(c"width", source.width as i32);
        format.set_i32(c"height", source.height as i32);
        format.set_i32(
            c"max-input-size",
            MIN_INPUT_BYTES.max(source.width.saturating_mul(source.height)) as i32,
        );
        for (key, csd) in [c"csd-0", c"csd-1"].into_iter().zip(&source.csd) {
            format.set_buffer(key, csd);
        }
        if p010 {
            format.set_i32(c"color-format", COLOR_FORMAT_P010);
        }
        self.knobs(&format);
        let window = surface.map_or(std::ptr::null_mut(), AndroidWindow::as_ptr);
        codec.configure(&format, window, 0)?;
        codec.start()?;
        Ok(codec)
    }

    fn encoder(
        &mut self,
        config: &EncoderConfig,
        surface: bool,
    ) -> Result<(NdkCodec, Option<AndroidWindow>), String> {
        let ndk = ndk()?;
        let codec = NdkCodec::create(ndk, config.mime(), "encoder")?;
        let format = encoder_format(ndk, config, surface)?;
        self.knobs(&format);
        codec.configure(&format, std::ptr::null_mut(), CONFIGURE_FLAG_ENCODE)?;
        let window = if surface {
            let (create, release) = ndk
                .create_input_surface
                .zip(ndk.window_release)
                .ok_or("this device cannot make an encoder's input surface")?;
            let mut window: *mut c_void = std::ptr::null_mut();
            // SAFETY: a configured, not yet started encoder; the window is
            // ours to release, which `AndroidWindow` does.
            let status = unsafe { create(codec.codec, &mut window) };
            codec.check(status, "gave no input surface")?;
            if window.is_null() {
                return Err("the encoder gave no input surface".to_owned());
            }
            // SAFETY: the reference `createInputSurface` handed over.
            Some(unsafe { AndroidWindow::from_raw(window, release) })
        } else {
            None
        };
        codec.start()?;
        Ok((codec, window))
    }

    fn set_output_surface(
        &mut self,
        decoder: &mut NdkCodec,
        surface: &AndroidWindow,
    ) -> Result<(), String> {
        // SAFETY: a started surface decoder and a live window.
        let status = unsafe { (decoder.ndk.set_output_surface)(decoder.codec, surface.as_ptr()) };
        decoder.check(status, "could not move to the new encoder's surface")
    }
}

/// How an encoder for `target` takes its pictures: by surface, or in
/// buffers of P010 for Main 10 and of NV12 otherwise (the software path).
pub fn input_color_format(target: PictureTarget, surface: bool) -> i32 {
    if surface {
        COLOR_FORMAT_SURFACE
    } else if target.ten_bit() {
        COLOR_FORMAT_P010
    } else {
        COLOR_FORMAT_NV12
    }
}

/// An encoder's configure format for `config`: CBR at the bitrate, no
/// B-frames (so pictures come out in the order they went in), the
/// container's colour keys. Its pictures come by surface, or in buffers:
/// P010 for Main 10, NV12 otherwise (the software path).
fn encoder_format(
    ndk: &'static Ndk,
    config: &EncoderConfig,
    surface: bool,
) -> Result<MediaFormat, String> {
    let format = MediaFormat::new(ndk)?;
    let mime = std::ffi::CString::new(config.mime()).map_err(|error| error.to_string())?;
    format.set_string(c"mime", &mime);
    format.set_i32(c"width", config.width as i32);
    format.set_i32(c"height", config.height as i32);
    format.set_i32(c"color-format", input_color_format(config.target, surface));
    format.set_i32(
        c"bitrate",
        i32::try_from(config.bitrate).unwrap_or(i32::MAX),
    );
    format.set_i32(c"bitrate-mode", 2); // CBR
    format.set_f32(c"frame-rate", config.frame_rate);
    format.set_i32(c"i-frame-interval", SYNC_INTERVAL_S);
    format.set_i32(c"profile", config.profile());
    format.set_i32(c"max-bframes", 0);
    let Colour {
        standard,
        transfer,
        range,
    } = config.colour;
    for (key, value) in [
        (c"color-standard", standard),
        (c"color-transfer", transfer),
        (c"color-range", range),
    ] {
        if let Some(value) = value {
            format.set_i32(key, value);
        }
    }
    if let Some(info) = &config.hdr_static_info {
        format.set_buffer(c"hdr-static-info", info);
    }
    Ok(format)
}

// --- The software decoder --------------------------------------------------------

/// **The software path's codecs**: a [`SoftDecoder`] over the stream's own
/// codec parameters, and `E`'s encoders ([`NdkCodecs`] in the app).
pub struct SoftCodecs<E: VideoCodecs> {
    encoders: E,
    par: CodecParameters,
    /// The size the decoder's pictures are scaled to: the encoders'.
    width: u32,
    height: u32,
}

impl<E: VideoCodecs> SoftCodecs<E> {
    /// Decodes what `par` describes in software, its pictures scaled to
    /// `width` by `height` (square pixels, `rendition::square_size`), and
    /// encodes with `encoders`.
    pub fn new(encoders: E, par: CodecParameters, width: u32, height: u32) -> Self {
        Self {
            encoders,
            par,
            width,
            height,
        }
    }
}

impl<E: VideoCodecs> VideoCodecs for SoftCodecs<E> {
    type Codec = E::Codec;
    type Decoder = SoftDecoder;
    type Surface = E::Surface;

    fn decoder(
        &mut self,
        source: &PictureSource,
        surface: Option<&Self::Surface>,
        p010: bool,
    ) -> Result<SoftDecoder, String> {
        if surface.is_some() || p010 {
            return Err("the software decoder writes 8-bit buffers only".to_owned());
        }
        SoftDecoder::new(&self.par, source, self.width, self.height)
    }

    fn encoder(
        &mut self,
        config: &EncoderConfig,
        surface: bool,
    ) -> Result<(Self::Codec, Option<Self::Surface>), String> {
        self.encoders.encoder(config, surface)
    }

    fn set_output_surface(&mut self, _: &mut SoftDecoder, _: &Self::Surface) -> Result<(), String> {
        Err("the software decoder renders into no surface".to_owned())
    }

    fn decodes_in_software(&self) -> bool {
        true
    }
}

/// **libavcodec as a [`VideoCodec`]**: one input buffer, decoded as soon as
/// it is queued, and every picture it frees held as an NV12 output buffer
/// ([`PictureDecoder`]) until the converter takes it. Its output format is
/// [`COLOR_FORMAT_NV12`] at the size it was made for: the container's, or
/// wider or narrower to make stretched pixels square.
///
/// **Times.** A source with presentation times hands them to libavcodec as
/// such, and each picture keeps its own. A source with decode times alone
/// ([`PictureSource::decode_times`]) hands them over as decode times, and a
/// picture takes the decode time of the packet that freed it
/// (`best_effort_timestamp`). Either way a picture with no time, or with
/// one no later than the last picture's, takes the last one's plus a frame
/// ([`next_time`]): the end's flush frees pictures that no packet did.
pub struct SoftDecoder {
    decoder: PictureDecoder,
    decode_times: bool,
    frame_us: i64,
    last: Option<i64>,
    input: Vec<u8>,
    ready: VecDeque<(i64, Vec<u8>)>,
    out: HashMap<usize, Vec<u8>>,
    next_out: usize,
    told_format: bool,
    ending: bool,
    ended: bool,
}

impl SoftDecoder {
    /// A started decoder for `par`'s codec, its pictures scaled to `width`
    /// by `height`.
    pub fn new(
        par: &CodecParameters,
        source: &PictureSource,
        width: u32,
        height: u32,
    ) -> Result<Self, String> {
        let decoder = PictureDecoder::open(par, width, height)?
            .ok_or("this FFmpeg has no decoder for the picture")?;
        let frame_us = if source.frame_rate.is_finite() && source.frame_rate > 0.0 {
            (1_000_000.0 / f64::from(source.frame_rate)).round() as i64
        } else {
            33_333
        };
        let input = MIN_INPUT_BYTES.max(source.width.saturating_mul(source.height)) as usize;
        Ok(Self {
            decoder,
            decode_times: source.decode_times,
            frame_us,
            last: None,
            input: vec![0; input],
            ready: VecDeque::new(),
            out: HashMap::new(),
            next_out: 0,
            told_format: false,
            ending: false,
            ended: false,
        })
    }

    fn layout(&self) -> Nv12Layout {
        self.decoder.layout()
    }
}

/// When a picture the decoder timed `time` is shown, after one shown at
/// `last`, at `frame_us` a picture: its own time when it is later than the
/// last, and otherwise the last plus a frame. The first picture with no
/// time is shown at `first`.
pub fn next_time(time: Option<i64>, last: Option<i64>, frame_us: i64, first: i64) -> i64 {
    match (time, last) {
        (Some(time), Some(last)) if time > last => time,
        (_, Some(last)) => last + frame_us,
        (Some(time), None) => time,
        (None, None) => first,
    }
}

impl VideoCodec for SoftDecoder {
    fn dequeue_input(&mut self, _: i64) -> Result<Option<usize>, String> {
        Ok((!self.ending && self.ready.len() < SOFT_READY_PICTURES).then_some(0))
    }

    fn input_buffer(&mut self, _: usize) -> Result<&mut [u8], String> {
        Ok(&mut self.input)
    }

    fn queue_input(&mut self, _: usize, len: usize, pts_us: i64, end: bool) -> Result<(), String> {
        let pictures = if end {
            self.ending = true;
            self.decoder.decode(None)?
        } else {
            let data = self.input.get(..len).ok_or("more input than its buffer")?;
            let (pts, dts) = if self.decode_times {
                (crate::libav::NOPTS, pts_us)
            } else {
                (pts_us, crate::libav::NOPTS)
            };
            self.decoder.decode(Some((data, pts, dts)))?
        };
        for picture in pictures {
            let time = next_time(picture.time, self.last, self.frame_us, pts_us);
            self.last = Some(time);
            self.ready.push_back((time, picture.nv12));
        }
        Ok(())
    }

    fn dequeue_output(&mut self, _: i64) -> Result<VideoOutput, String> {
        if self.ended {
            return Ok(VideoOutput::Nothing);
        }
        if !self.told_format && !self.ready.is_empty() {
            self.told_format = true;
            return Ok(VideoOutput::FormatChanged);
        }
        let index = self.next_out;
        if let Some((pts_us, picture)) = self.ready.pop_front() {
            self.next_out += 1;
            let size = picture.len();
            self.out.insert(index, picture);
            return Ok(VideoOutput::Buffer {
                index,
                offset: 0,
                size,
                pts_us,
                flags: 0,
            });
        }
        if self.ending {
            self.ended = true;
            self.next_out += 1;
            self.out.insert(index, Vec::new());
            return Ok(VideoOutput::Buffer {
                index,
                offset: 0,
                size: 0,
                pts_us: 0,
                flags: BUFFER_FLAG_END_OF_STREAM,
            });
        }
        Ok(VideoOutput::Nothing)
    }

    fn output_buffer(&mut self, index: usize) -> Result<&[u8], String> {
        self.out
            .get(&index)
            .map(Vec::as_slice)
            .ok_or_else(|| "no such picture".to_owned())
    }

    fn release_output(&mut self, index: usize, render_at_us: Option<i64>) -> Result<(), String> {
        if render_at_us.is_some() {
            return Err("the software decoder renders into no surface".to_owned());
        }
        self.out.remove(&index).ok_or("released twice")?;
        Ok(())
    }

    fn output_format(&mut self) -> Result<VideoFormat, String> {
        let layout = self.layout();
        Ok(VideoFormat {
            color_format: Some(COLOR_FORMAT_NV12),
            width: layout.width,
            height: layout.height,
            stride: u32::try_from(layout.stride).ok(),
            slice_height: Some(layout.height),
            ..VideoFormat::default()
        })
    }

    fn input_format(&mut self) -> Result<VideoFormat, String> {
        Err("the software decoder has no input format".to_owned())
    }

    fn signal_end_of_input(&mut self) -> Result<(), String> {
        Err("the software decoder has no input surface".to_owned())
    }
}

// --- What this device can do --------------------------------------------------------

/// What this device's hardware can convert, by the names the cast decision
/// uses ("H.264", "HEVC", "AV1", "VP9").
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DeviceSupport {
    /// The surface path is there (API 26, and every function it needs).
    pub surface: bool,
    /// The buffer path is there, and the HEVC encoder takes Main 10 in P010
    /// (API 33).
    pub ten_bit: bool,
    /// The codecs with a hardware decoder.
    pub decodes: Vec<&'static str>,
    /// The codecs with a hardware encoder: H.264 and HEVC at most.
    pub encodes: Vec<&'static str>,
    /// The codecs the software path decodes ([`SOFTWARE_CODECS`]): those
    /// the player's FFmpeg has a decoder for.
    pub software_decodes: Vec<&'static str>,
}

impl DeviceSupport {
    /// What the cast decision is offered: all of it with the surface path,
    /// and nothing without, since a decoder alone converts nothing.
    pub fn offered(self) -> Self {
        if self.surface {
            self
        } else {
            Self::default()
        }
    }
}

/// The names and FFmpeg codec ids of the codecs the software path decodes.
/// No phone has a hardware decoder worth the name for them: AOSP's own
/// MPEG-4 decoder takes the Simple profile alone, and Xvid is Advanced
/// Simple.
pub const SOFTWARE_CODECS: [(&str, std::ffi::c_int); 3] = [
    ("MPEG-4 Part 2", crate::libav::AV_CODEC_ID_MPEG4),
    ("DivX 3", crate::libav::AV_CODEC_ID_MSMPEG4V3),
    ("MPEG-2", crate::libav::AV_CODEC_ID_MPEG2VIDEO),
];

/// The names and MIME types of the codecs a source's picture can be.
pub const SOURCE_CODECS: [(&str, &str); 4] = [
    ("H.264", "video/avc"),
    ("HEVC", "video/hevc"),
    ("AV1", "video/av01"),
    ("VP9", "video/x-vnd.on2.vp9"),
];

static SUPPORT: OnceLock<DeviceSupport> = OnceLock::new();

/// What this device can convert. Its hardware is asked once a process (it
/// makes and deletes a few codecs). The software decoders are asked of the
/// player's FFmpeg each time, since there is none until a player has
/// loaded libmpv. Nothing on a desktop.
pub fn support() -> DeviceSupport {
    let mut support = SUPPORT.get_or_init(probe_support).clone();
    if let Ok(libav) = crate::libav::Libav::registered() {
        support.software_decodes = software_decodes(libav);
    }
    support
}

/// The [`SOFTWARE_CODECS`] `libav` decodes into what the software path
/// takes.
pub fn software_decodes(libav: &crate::libav::Libav) -> Vec<&'static str> {
    SOFTWARE_CODECS
        .iter()
        .filter(|(_, codec)| crate::libav::decodes_picture(libav, *codec))
        .map(|(name, _)| *name)
        .collect()
}

/// Whether a codec is the hardware's: not one of AOSP's software codecs.
pub fn hardware(name: &str) -> bool {
    !name.starts_with("c2.android.") && !name.starts_with("OMX.google.")
}

fn probe_support() -> DeviceSupport {
    let Ok(ndk) = ndk() else {
        return DeviceSupport::default();
    };
    let surface = ndk.api_level >= 26
        && ndk.create_input_surface.is_some()
        && ndk.signal_end_of_input_stream.is_some()
        && ndk.window_release.is_some();
    let hardware_codec = |mime: &str, role: &'static str| {
        NdkCodec::create(ndk, mime, role)
            .ok()
            .and_then(|codec| codec.name())
            .is_some_and(|name| hardware(&name))
    };
    let decodes: Vec<&'static str> = SOURCE_CODECS
        .iter()
        .filter(|(_, mime)| hardware_codec(mime, "decoder"))
        .map(|(name, _)| *name)
        .collect();
    let encodes: Vec<&'static str> = SOURCE_CODECS[..2]
        .iter()
        .filter(|(_, mime)| hardware_codec(mime, "encoder"))
        .map(|(name, _)| *name)
        .collect();
    let ten_bit = ndk.api_level >= 33
        && ndk.get_input_format.is_some()
        && encodes.contains(&"HEVC")
        && takes_main10(ndk);
    let support = DeviceSupport {
        surface,
        ten_bit,
        decodes,
        encodes,
        software_decodes: Vec::new(),
    };
    tracing::info!(?support, api = ndk.api_level, "picture conversion");
    support
}

/// Whether the HEVC encoder configures for Main 10 from P010 buffers.
fn takes_main10(ndk: &'static Ndk) -> bool {
    let config = EncoderConfig {
        target: PictureTarget::HevcMain10,
        width: 1280,
        height: 720,
        bitrate: 4_000_000,
        frame_rate: 30.0,
        colour: Colour::default(),
        hdr_static_info: None,
    };
    let Ok(codec) = NdkCodec::create(ndk, config.mime(), "encoder") else {
        return false;
    };
    encoder_format(ndk, &config, false)
        .and_then(|format| codec.configure(&format, std::ptr::null_mut(), CONFIGURE_FLAG_ENCODE))
        .is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::{HashMap, VecDeque};
    use std::sync::{Arc, Mutex};
    use stream_server::{Converted, ConvertedPicture};

    // --- The fakes ----------------------------------------------------------------

    /// What every fake codec shares: the order log, the frames on their
    /// way through a surface, the knobs, and what was asked of them.
    #[derive(Default)]
    struct World {
        log: Vec<String>,
        live_codecs: usize,
        live_windows: usize,
        next_codec: usize,
        next_window: usize,
        /// Frames rendered into a window: (pts, polls before the encoder
        /// sees it).
        in_flight: HashMap<usize, VecDeque<(i64, u32)>>,
        configs: Vec<EncoderConfig>,
        sources: Vec<(PictureSource, bool)>,
        /// The decoder shows pictures in order once more than this many
        /// are held: B-frames' reordering.
        reorder: usize,
        /// The decoder gives no input buffer, ever.
        starved: bool,
        /// Pictures an encoder holds before the first comes out.
        latency: usize,
        /// Polls a rendered frame takes to reach its encoder.
        surface_delay: u32,
        /// Rendered frames lost on the way: the encoder never sees them.
        lost: Vec<i64>,
        /// An encoder never hands back its end.
        never_ends: bool,
        /// Each encoder's codec configuration, by the order they were made;
        /// the last for any after.
        csds: Vec<Bytes>,
        /// The configuration comes in the output format, not a buffer.
        csd_in_format: bool,
        /// The decoder's output format on the buffer path.
        decoded: VideoFormat,
        /// The encoder's input format on the buffer path.
        encoder_input: VideoFormat,
        /// Each picture an encoder was handed on the buffer path: its time,
        /// whether every visible sample was the decoder's, and the length.
        copies: Vec<(i64, bool, usize)>,
        /// The decoder is software, writing NV12: the software path.
        software: bool,
        /// A picture's data names when it is shown (`shown`), and the
        /// decoder echoes the time it went in with, as a hardware decoder
        /// fed an AVI's decode times does.
        echoes: bool,
        /// The times pictures were rendered into a window stamped with.
        rendered: Vec<i64>,
    }

    impl World {
        /// Bytes per sample in a buffer: NV12's one, P010's two.
        fn bytes(&self) -> usize {
            if self.software {
                1
            } else {
                2
            }
        }
    }

    type Shared = Arc<Mutex<World>>;

    fn world() -> Shared {
        Arc::new(Mutex::new(World {
            reorder: 2,
            latency: 2,
            surface_delay: 3,
            csds: vec![Bytes::from_static(b"\0\0\0\x01csd")],
            ..World::default()
        }))
    }

    /// A visible sample of the picture at `pts`: plane 0 luma, 1 chroma.
    fn sample(pts: i64, plane: usize, x: usize, y: usize) -> [u8; 2] {
        let value = (pts / 40_000) as usize * 7 + plane * 101 + x * 3 + y * 5;
        (value as u16 & 0x3ff).wrapping_shl(6).to_le_bytes()
    }

    /// [`sample`] in `size` bytes: P010's two, or NV12's one (its high
    /// byte).
    fn sample_in(size: usize, pts: i64, plane: usize, x: usize, y: usize) -> Vec<u8> {
        sample(pts, plane, x, y)[2 - size..].to_vec()
    }

    /// The picture at `pts`, `width`×`height`, in `layout`, of `size`-byte
    /// samples; padding is 0xee.
    fn picture_in(
        layout: PlaneLayout,
        width: usize,
        height: usize,
        pts: i64,
        size: usize,
    ) -> Vec<u8> {
        let rows = layout.slice_height * 2 + layout.top + 2;
        let mut out = vec![0xee; layout.row_bytes * rows];
        for y in 0..height {
            for x in 0..width {
                let at = (layout.top + y) * layout.row_bytes + (layout.left + x) * size;
                out[at..at + size].copy_from_slice(&sample_in(size, pts, 0, x, y));
            }
        }
        let chroma = layout.row_bytes * layout.slice_height;
        for y in 0..height.div_ceil(2) {
            for x in 0..width.div_ceil(2) * 2 {
                let at = chroma
                    + (layout.top / 2 + y) * layout.row_bytes
                    + layout.left * size
                    + x * size;
                out[at..at + size].copy_from_slice(&sample_in(size, pts, 1, x, y));
            }
        }
        out
    }

    /// Whether `buffer` holds the picture at `pts` of `size`-byte samples
    /// where `layout` says.
    fn holds_picture(
        buffer: &[u8],
        layout: PlaneLayout,
        width: usize,
        height: usize,
        pts: i64,
        size: usize,
    ) -> bool {
        let expected = picture_in(layout, width, height, pts, size);
        let luma = (0..height).all(|y| {
            let at = (layout.top + y) * layout.row_bytes + layout.left * size;
            buffer[at..at + width * size] == expected[at..at + width * size]
        });
        let chroma_at = layout.row_bytes * layout.slice_height;
        let chroma = (0..height.div_ceil(2)).all(|y| {
            let at = chroma_at + (layout.top / 2 + y) * layout.row_bytes + layout.left * size;
            let bytes = width.div_ceil(2) * 2 * size;
            buffer[at..at + bytes] == expected[at..at + bytes]
        });
        luma && chroma
    }

    /// A decoder's whole buffer of `size`-byte samples: the luma plane to
    /// the slice height, then chroma for every row of the buffer.
    fn decoded_bytes(format: &VideoFormat, size: usize) -> usize {
        let layout = PlaneLayout::of(format, WIDTH, HEIGHT, size);
        layout.row_bytes * (layout.slice_height + (format.height as usize).div_ceil(2))
    }

    const WIDTH: u32 = 64;
    const HEIGHT: u32 = 36;

    enum Role {
        Decoder {
            p010: bool,
            window: Option<usize>,
            fed: usize,
            /// The run began at a CRA, whose leading pictures cannot be
            /// decoded; until the next IRAP.
            leading_dropped: bool,
            /// (when it is shown, the time it went in with).
            held: Vec<(i64, i64)>,
            ready: VecDeque<i64>,
            ending: bool,
            told_format: bool,
            ended: bool,
        },
        Encoder {
            window: Option<usize>,
            pending: VecDeque<i64>,
            told_config: bool,
            keyed: bool,
            ending: bool,
            ended: bool,
            index: usize,
        },
    }

    struct FakeCodec {
        id: usize,
        world: Shared,
        role: Role,
        input: Vec<u8>,
        output: Vec<u8>,
        /// The time of each output buffer handed out and not released.
        out: HashMap<usize, i64>,
        next_out: usize,
    }

    struct FakeSurface {
        id: usize,
        world: Shared,
    }

    // A drop while the test holds the world (an assertion failing with
    // its guard alive) counts nothing rather than aborting the test.
    impl Drop for FakeSurface {
        fn drop(&mut self) {
            let Ok(mut world) = self.world.try_lock() else {
                return;
            };
            world.live_windows -= 1;
            world.log.push(format!("release window {}", self.id));
        }
    }

    impl Drop for FakeCodec {
        fn drop(&mut self) {
            let Ok(mut world) = self.world.try_lock() else {
                return;
            };
            world.live_codecs -= 1;
            let role = match self.role {
                Role::Decoder { .. } => "decoder",
                Role::Encoder { .. } => "encoder",
            };
            world.log.push(format!("delete {role} {}", self.id));
        }
    }

    impl FakeCodec {
        fn buffer(&mut self, size: usize, pts: i64, flags: u32) -> VideoOutput {
            let index = self.next_out;
            self.next_out += 1;
            self.out.insert(index, pts);
            VideoOutput::Buffer {
                index,
                offset: 0,
                size,
                pts_us: pts,
                flags,
            }
        }
    }

    impl VideoCodec for FakeCodec {
        fn dequeue_input(&mut self, _: i64) -> Result<Option<usize>, String> {
            let world = self.world.lock().unwrap();
            match &self.role {
                Role::Decoder { held, ready, .. } => {
                    let full = held.len() + ready.len() >= world.reorder + 2;
                    Ok((!world.starved && !full).then_some(0))
                }
                Role::Encoder { pending, .. } => {
                    Ok((pending.len() <= world.latency + 1).then_some(0))
                }
            }
        }

        fn input_buffer(&mut self, _: usize) -> Result<&mut [u8], String> {
            let world = self.world.lock().unwrap();
            let size = match &self.role {
                Role::Decoder { .. } => 64,
                Role::Encoder { .. } => {
                    PlaneLayout::of(&world.encoder_input, WIDTH, HEIGHT, world.bytes())
                        .picture_bytes(HEIGHT)
                }
            };
            drop(world);
            self.input = vec![0x55; size];
            Ok(&mut self.input)
        }

        fn queue_input(&mut self, _: usize, len: usize, pts: i64, end: bool) -> Result<(), String> {
            let mut world = self.world.lock().unwrap();
            let reorder = world.reorder;
            match &mut self.role {
                Role::Decoder {
                    fed,
                    leading_dropped,
                    held,
                    ready,
                    ending,
                    ..
                } => {
                    if end {
                        *ending = true;
                        held.sort_unstable();
                        ready.extend(held.drain(..).map(|(_, pts)| pts));
                        return Ok(());
                    }
                    let kind = self.input[0];
                    if *fed == 0 {
                        *leading_dropped = kind == b'C';
                    } else if kind == b'I' || kind == b'C' {
                        *leading_dropped = false;
                    }
                    *fed += 1;
                    if kind == b'R' && *leading_dropped {
                        return Ok(());
                    }
                    let shown = if world.echoes {
                        i64::from_le_bytes(self.input[4..12].try_into().unwrap())
                    } else {
                        pts
                    };
                    held.push((shown, pts));
                    if held.len() > reorder {
                        held.sort_unstable();
                        ready.push_back(held.remove(0).1);
                    }
                }
                Role::Encoder {
                    pending, ending, ..
                } => {
                    if end {
                        assert_eq!(len, 0, "the end is an empty buffer");
                        *ending = true;
                        world
                            .log
                            .push(format!("end of input by buffer {}", self.id));
                        return Ok(());
                    }
                    let size = world.bytes();
                    let layout = PlaneLayout::of(&world.encoder_input, WIDTH, HEIGHT, size);
                    let ok = holds_picture(
                        &self.input,
                        layout,
                        WIDTH as usize,
                        HEIGHT as usize,
                        pts,
                        size,
                    );
                    world.copies.push((pts, ok, len));
                    pending.push_back(pts);
                }
            }
            Ok(())
        }

        fn dequeue_output(&mut self, _: i64) -> Result<VideoOutput, String> {
            let world = self.world.clone();
            let mut world = world.lock().unwrap();
            match &mut self.role {
                Role::Decoder {
                    p010,
                    ready,
                    ending,
                    told_format,
                    ended,
                    held,
                    ..
                } => {
                    if *ended {
                        return Ok(VideoOutput::Nothing);
                    }
                    if !ready.is_empty() && !*told_format {
                        *told_format = true;
                        return Ok(VideoOutput::FormatChanged);
                    }
                    if let Some(pts) = ready.pop_front() {
                        let size = if *p010 || world.software {
                            decoded_bytes(&world.decoded, world.bytes())
                        } else {
                            1
                        };
                        drop(world);
                        return Ok(self.buffer(size, pts, 0));
                    }
                    if *ending && held.is_empty() {
                        *ended = true;
                        drop(world);
                        return Ok(self.buffer(0, 0, BUFFER_FLAG_END_OF_STREAM));
                    }
                    Ok(VideoOutput::Nothing)
                }
                Role::Encoder {
                    window,
                    pending,
                    told_config,
                    keyed,
                    ending,
                    ended,
                    index,
                } => {
                    if *ended {
                        return Ok(VideoOutput::Nothing);
                    }
                    if let Some(window) = window {
                        let lost = world.lost.clone();
                        let flights = world.in_flight.entry(*window).or_default();
                        for flight in flights.iter_mut() {
                            flight.1 = flight.1.saturating_sub(1);
                        }
                        while flights.front().is_some_and(|flight| flight.1 == 0) {
                            let (pts, _) = flights.pop_front().unwrap();
                            if !lost.contains(&pts) {
                                pending.push_back(pts);
                            }
                        }
                    }
                    let csd = world.csds[(*index).min(world.csds.len() - 1)].clone();
                    if !*told_config {
                        *told_config = true;
                        if world.csd_in_format {
                            return Ok(VideoOutput::FormatChanged);
                        }
                        self.output = csd.to_vec();
                        let size = self.output.len();
                        drop(world);
                        return Ok(self.buffer(size, 0, BUFFER_FLAG_CODEC_CONFIG));
                    }
                    let in_flight = window
                        .and_then(|window| world.in_flight.get(&window))
                        .is_some_and(|flights| !flights.is_empty());
                    if pending.len() > world.latency
                        || (*ending && !in_flight && !pending.is_empty())
                    {
                        let pts = pending.pop_front().unwrap();
                        let flags = if *keyed { 0 } else { BUFFER_FLAG_KEY_FRAME };
                        *keyed = true;
                        self.output = format!("{}:{pts}", self.id).into_bytes();
                        let size = self.output.len();
                        drop(world);
                        return Ok(self.buffer(size, pts, flags));
                    }
                    if *ending && pending.is_empty() && !in_flight && !world.never_ends {
                        *ended = true;
                        drop(world);
                        return Ok(self.buffer(0, 0, BUFFER_FLAG_END_OF_STREAM));
                    }
                    Ok(VideoOutput::Nothing)
                }
            }
        }

        fn output_buffer(&mut self, index: usize) -> Result<&[u8], String> {
            let pts = *self.out.get(&index).ok_or("no such output buffer")?;
            if let Role::Decoder { p010, .. } = self.role {
                let world = self.world.lock().unwrap();
                assert!(
                    p010 || world.software,
                    "a surface decoder's buffers are not read"
                );
                let size = world.bytes();
                let layout = PlaneLayout::of(&world.decoded, WIDTH, HEIGHT, size);
                self.output = picture_in(layout, WIDTH as usize, HEIGHT as usize, pts, size);
                self.output.truncate(decoded_bytes(&world.decoded, size));
            }
            Ok(&self.output)
        }

        fn release_output(
            &mut self,
            index: usize,
            render_at_us: Option<i64>,
        ) -> Result<(), String> {
            let pts = self.out.remove(&index).ok_or("released twice")?;
            if let (Role::Decoder { window, .. }, Some(at)) = (&self.role, render_at_us) {
                let window = window.expect("a surface decoder");
                let mut world = self.world.lock().unwrap();
                if !world.echoes {
                    assert_eq!(at, pts, "rendered stamped with its own time");
                }
                world.rendered.push(at);
                let delay = world.surface_delay;
                world
                    .in_flight
                    .entry(window)
                    .or_default()
                    .push_back((at, delay));
                world.log.push(format!("render {at} into window {window}"));
            }
            Ok(())
        }

        fn output_format(&mut self) -> Result<VideoFormat, String> {
            let world = self.world.lock().unwrap();
            Ok(match &self.role {
                Role::Decoder { .. } => world.decoded.clone(),
                Role::Encoder { index, .. } => VideoFormat {
                    csd: vec![world.csds[(*index).min(world.csds.len() - 1)].clone()],
                    ..VideoFormat::default()
                },
            })
        }

        fn input_format(&mut self) -> Result<VideoFormat, String> {
            Ok(self.world.lock().unwrap().encoder_input.clone())
        }

        fn signal_end_of_input(&mut self) -> Result<(), String> {
            if let Role::Encoder { ending, .. } = &mut self.role {
                *ending = true;
            }
            self.world
                .lock()
                .unwrap()
                .log
                .push(format!("end of input by signal {}", self.id));
            Ok(())
        }
    }

    struct FakeCodecs(Shared);

    impl FakeCodecs {
        fn codec(&self, role: Role) -> FakeCodec {
            let mut world = self.0.lock().unwrap();
            world.live_codecs += 1;
            world.next_codec += 1;
            FakeCodec {
                id: world.next_codec,
                world: self.0.clone(),
                role,
                input: Vec::new(),
                output: Vec::new(),
                out: HashMap::new(),
                next_out: 0,
            }
        }
    }

    impl VideoCodecs for FakeCodecs {
        type Codec = FakeCodec;
        type Decoder = FakeCodec;
        type Surface = FakeSurface;

        fn decoder(
            &mut self,
            source: &PictureSource,
            surface: Option<&FakeSurface>,
            p010: bool,
        ) -> Result<FakeCodec, String> {
            let codec = self.codec(Role::Decoder {
                p010,
                window: surface.map(|surface| surface.id),
                fed: 0,
                leading_dropped: false,
                held: Vec::new(),
                ready: VecDeque::new(),
                ending: false,
                told_format: false,
                ended: false,
            });
            let mut world = self.0.lock().unwrap();
            world.sources.push((source.clone(), p010));
            let into = surface.map_or("buffers".to_owned(), |surface| {
                format!("window {}", surface.id)
            });
            world
                .log
                .push(format!("create decoder {} into {into}", codec.id));
            Ok(codec)
        }

        fn encoder(
            &mut self,
            config: &EncoderConfig,
            surface: bool,
        ) -> Result<(FakeCodec, Option<FakeSurface>), String> {
            let window = surface.then(|| {
                let mut world = self.0.lock().unwrap();
                world.next_window += 1;
                world.live_windows += 1;
                world.next_window
            });
            let index = self.0.lock().unwrap().configs.len();
            let codec = self.codec(Role::Encoder {
                window,
                pending: VecDeque::new(),
                told_config: false,
                keyed: false,
                ending: false,
                ended: false,
                index,
            });
            let mut world = self.0.lock().unwrap();
            world.configs.push(config.clone());
            let with = window.map_or("buffers".to_owned(), |window| format!("window {window}"));
            world
                .log
                .push(format!("create encoder {} with {with}", codec.id));
            let surface = window.map(|id| FakeSurface {
                id,
                world: self.0.clone(),
            });
            Ok((codec, surface))
        }

        fn set_output_surface(
            &mut self,
            decoder: &mut FakeCodec,
            surface: &FakeSurface,
        ) -> Result<(), String> {
            if let Role::Decoder { window, .. } = &mut decoder.role {
                *window = Some(surface.id);
            }
            self.0
                .lock()
                .unwrap()
                .log
                .push(format!("decoder {} onto window {}", decoder.id, surface.id));
            Ok(())
        }

        fn decodes_in_software(&self) -> bool {
            self.0.lock().unwrap().software
        }
    }

    // --- A film -------------------------------------------------------------------

    const FRAME_US: i64 = 40_000;

    /// One source picture: its kind (`I` IDR, `C` CRA, `R` a CRA's leading
    /// picture, `P`) and the time it is shown at.
    fn picture(kind: u8, pts_us: i64) -> SourcePicture {
        SourcePicture {
            pts_us,
            key: kind == b'I' || kind == b'C',
            data: Bytes::from(vec![kind, 0, 0, 1]),
        }
    }

    /// `seconds` of film at 25 pictures a second, a closed GOP each
    /// second, in decode order with B-frames: every key, then pairs of a
    /// later P and the earlier picture between.
    fn closed_film(seconds: i64) -> Vec<SourcePicture> {
        let mut out = Vec::new();
        for second in 0..seconds {
            let base = second * 25;
            out.push(picture(b'I', base * FRAME_US));
            let mut n = 1;
            while n < 25 {
                if n + 1 < 25 {
                    out.push(picture(b'P', (base + n + 1) * FRAME_US));
                    out.push(picture(b'P', (base + n) * FRAME_US));
                    n += 2;
                } else {
                    out.push(picture(b'P', (base + n) * FRAME_US));
                    n += 1;
                }
            }
        }
        out
    }

    /// Cuts every second.
    fn segments(count: i64, first: u64) -> Segments {
        let mut cuts = vec![i64::MIN];
        cuts.extend((1..count).map(|second| second * 1_000_000));
        Segments::new(cuts.into(), first)
    }

    fn source() -> PictureSource {
        PictureSource {
            mime: "video/hevc",
            width: WIDTH,
            height: HEIGHT,
            frame_rate: 25.0,
            csd: vec![Bytes::from_static(b"\0\0\0\x01vps")],
            colour: Colour::default(),
            decode_times: false,
        }
    }

    fn config(target: PictureTarget) -> EncoderConfig {
        EncoderConfig {
            target,
            width: WIDTH,
            height: HEIGHT,
            bitrate: 4_000_000,
            frame_rate: 25.0,
            colour: Colour::default(),
            hdr_static_info: None,
        }
    }

    fn converter(world: &Shared, target: PictureTarget) -> Converter<FakeCodecs> {
        Converter::new(FakeCodecs(world.clone()), source(), config(target))
    }

    /// Every picture pushed, then the end: every event, in order.
    fn convert(
        converter: &mut Converter<FakeCodecs>,
        pictures: &[SourcePicture],
        segments: &Segments,
    ) -> Result<Vec<PictureEvent>, String> {
        let mut events = Vec::new();
        for picture in pictures {
            events.extend(converter.push(picture.clone(), segments)?);
        }
        events.extend(converter.finish(segments)?);
        Ok(events)
    }

    /// The pictures of each segment, as (segment, pts, key).
    fn pictures_of(events: &[PictureEvent]) -> Vec<(u64, i64, bool)> {
        events
            .iter()
            .filter_map(|event| match event {
                PictureEvent::Picture {
                    segment,
                    pts_us,
                    key,
                    ..
                } => Some((*segment, *pts_us, *key)),
                _ => None,
            })
            .collect()
    }

    /// **The surface path, segment by segment**: each segment's events are
    /// its encoder's configuration, a sync picture first, every picture
    /// shown in its interval at the time it went in with, and an end whose
    /// counts agree. The server's own driver takes them without complaint.
    #[test]
    fn the_surface_path_makes_each_segment_with_its_own_encoder() {
        let world = world();
        let film = closed_film(3);
        let segments = segments(3, 0);
        let events = convert(
            &mut converter(&world, PictureTarget::HevcMain),
            &film,
            &segments,
        )
        .unwrap();
        let mut shown: Vec<i64> = film.iter().map(|picture| picture.pts_us).collect();
        shown.sort_unstable();
        for segment in 0..3u64 {
            let mine: Vec<&PictureEvent> = events
                .iter()
                .filter(|event| match event {
                    PictureEvent::Config { segment: s, .. }
                    | PictureEvent::Picture { segment: s, .. }
                    | PictureEvent::SegmentDone { segment: s, .. } => *s == segment,
                })
                .collect();
            assert!(
                matches!(
                    mine[0],
                    PictureEvent::Config {
                        width: WIDTH,
                        height: HEIGHT,
                        ..
                    }
                ),
                "{mine:?}"
            );
            let pictures = pictures_of(&events)
                .into_iter()
                .filter(|(s, ..)| *s == segment)
                .collect::<Vec<_>>();
            assert!(pictures[0].2, "segment {segment} opens with a sync picture");
            assert!(pictures[1..].iter().all(|(.., key)| !key));
            let expected: Vec<i64> = shown
                .iter()
                .copied()
                .filter(|pts| segments.of(*pts) == segment)
                .collect();
            assert_eq!(
                pictures.iter().map(|(_, pts, _)| *pts).collect::<Vec<_>>(),
                expected
            );
            assert_eq!(
                mine.last(),
                Some(&&PictureEvent::SegmentDone {
                    segment,
                    pictures_in: 25,
                    pictures_out: 25
                })
            );
        }
        // All of a segment's events before the next's.
        let order: Vec<u64> = events
            .iter()
            .map(|event| match event {
                PictureEvent::Config { segment, .. }
                | PictureEvent::Picture { segment, .. }
                | PictureEvent::SegmentDone { segment, .. } => *segment,
            })
            .collect();
        assert!(order.windows(2).all(|pair| pair[0] <= pair[1]));

        // The server's driver over the same converter.
        let world = self::world();
        let mut driver = ConvertedPicture::new(
            converter(&world, PictureTarget::HevcMain),
            segments,
            PictureTarget::HevcMain,
        );
        let mut converted = Vec::new();
        for picture in film {
            converted.extend(driver.push(picture).unwrap());
        }
        converted.extend(driver.finish().unwrap());
        assert!(matches!(converted[0], Converted::Format(_)));
        assert_eq!(converted.len(), 1 + 75);
    }

    /// **The measured order at a cut**: the old encoder is ended and
    /// deleted and its window released, then the new encoder is made, and
    /// the decoder is moved onto its window before the first picture is
    /// rendered into it.
    #[test]
    fn a_cut_deletes_the_old_encoder_before_the_new_one_takes_the_decoder() {
        let world = world();
        convert(
            &mut converter(&world, PictureTarget::H264High),
            &closed_film(2),
            &segments(2, 0),
        )
        .unwrap();
        let log = world.lock().unwrap().log.clone();
        let at = |line: &str| {
            log.iter()
                .position(|entry| entry == line)
                .unwrap_or_else(|| panic!("no {line:?} in {log:?}"))
        };
        // Encoder 1 and its window 1 are made first; the decoder (2) into it.
        assert_eq!(log[0], "create encoder 1 with window 1");
        assert_eq!(log[1], "create decoder 2 into window 1");
        let order = [
            at("end of input by signal 1"),
            at("delete encoder 1"),
            at("release window 1"),
            at("create encoder 3 with window 2"),
            at("decoder 2 onto window 2"),
            at("render 1000000 into window 2"),
        ];
        assert!(order.windows(2).all(|pair| pair[0] < pair[1]), "{log:?}");
        // Never two encoders at once.
        let mut live = 0;
        for entry in &log {
            if entry.starts_with("create encoder") {
                live += 1;
                assert_eq!(live, 1, "{log:?}");
            } else if entry.starts_with("delete encoder") {
                live -= 1;
            }
        }
    }

    /// **A run from segment 2**: the decoder starts at the sync picture
    /// before the cut, and what is shown before the cut is decoded and
    /// released, never rendered. No encoder is made for an earlier
    /// segment.
    #[test]
    fn a_run_from_a_later_segment_drops_what_comes_before_its_cut() {
        let world = world();
        // From the key at 1 s; the run's first segment is 2 (cut at 2 s).
        let film: Vec<SourcePicture> = closed_film(4)
            .into_iter()
            .filter(|picture| picture.pts_us >= 1_000_000)
            .collect();
        let segments = segments(4, 2);
        let events = convert(
            &mut converter(&world, PictureTarget::HevcMain),
            &film,
            &segments,
        )
        .unwrap();
        let world = world.lock().unwrap();
        assert!(world
            .log
            .iter()
            .filter(|entry| entry.starts_with("render"))
            .all(|entry| {
                let pts: i64 = entry.split(' ').nth(1).unwrap().parse().unwrap();
                pts >= 2_000_000
            }));
        assert_eq!(world.configs.len(), 2, "segments 2 and 3 only");
        assert!(pictures_of(&events)
            .iter()
            .all(|(segment, ..)| *segment >= 2));
        assert_eq!(pictures_of(&events).len(), 50);
    }

    /// **An open GOP across a cut**: the leading pictures of the CRA at a
    /// cut are shown before it, so a run passing through gives them to the
    /// segment before. A run starting at that CRA cannot decode them and
    /// never sees them. The segment from the cut is the same pictures
    /// either way.
    #[test]
    fn an_open_gops_leading_pictures_belong_to_the_segment_before() {
        // 0..1 s closed; at 1 s a CRA, then its two leading pictures (shown
        // at 0.92 and 0.96 s, so the first second has no picture there),
        // then the rest of its second.
        let mut film: Vec<SourcePicture> = (0..23)
            .map(|n| picture(if n == 0 { b'I' } else { b'P' }, n * FRAME_US))
            .collect();
        let gop = vec![
            picture(b'C', 1_000_000),
            picture(b'R', 920_000),
            picture(b'R', 960_000),
        ];
        let rest: Vec<SourcePicture> = (1..25)
            .map(|n| picture(b'P', 1_000_000 + n * FRAME_US))
            .collect();
        film.extend(gop.iter().cloned());
        film.extend(rest.iter().cloned());
        let through = convert(
            &mut converter(&world(), PictureTarget::HevcMain),
            &film,
            &segments(2, 0),
        )
        .unwrap();
        let leading: Vec<(u64, i64, bool)> = pictures_of(&through)
            .into_iter()
            .filter(|(_, pts, _)| [920_000, 960_000].contains(pts))
            .collect();
        assert_eq!(leading, vec![(0, 920_000, false), (0, 960_000, false)]);

        let from_cra: Vec<SourcePicture> = gop.into_iter().chain(rest).collect();
        let started = convert(
            &mut converter(&world(), PictureTarget::HevcMain),
            &from_cra,
            &segments(2, 1),
        )
        .unwrap();
        let segment_1 = |events: &[PictureEvent]| -> Vec<(i64, bool)> {
            pictures_of(events)
                .into_iter()
                .filter(|(segment, ..)| *segment == 1)
                .map(|(_, pts, key)| (pts, key))
                .collect()
        };
        assert_eq!(segment_1(&started), segment_1(&through));
        assert_eq!(segment_1(&started).len(), 25);
    }

    // --- The buffer path ----------------------------------------------------------

    /// The decoder's P010 layout in `t9` shape but padded: a stride wider
    /// than a row, a crop that does not start at the corner, and a slice
    /// height past the picture.
    fn padded() -> VideoFormat {
        VideoFormat {
            color_format: Some(COLOR_FORMAT_P010),
            width: WIDTH + 16,
            height: HEIGHT + 8,
            stride: Some((WIDTH + 32) * 2),
            slice_height: Some(HEIGHT + 12),
            crop: Some((4, 2, 4 + WIDTH - 1, 2 + HEIGHT - 1)),
            colour: Colour {
                standard: Some(1),
                transfer: Some(6),
                range: Some(2),
            },
            hdr_static_info: Some(Bytes::from(T9_STATIC_INFO.to_vec())),
            csd: Vec::new(),
        }
    }

    /// The decoder's `hdr-static-info` in `t9-p010.json`.
    const T9_STATIC_INFO: [u8; 25] = [
        0x00, 0xd0, 0x84, 0x80, 0x3e, 0xc2, 0x33, 0xc4, 0x86, 0x4c, 0x1d, 0xb8, 0x0b, 0x13, 0x3d,
        0x42, 0x40, 0xe8, 0x03, 0x01, 0x00, 0xe8, 0x03, 0x90, 0x01,
    ];

    fn buffer_world() -> Shared {
        let world = world();
        {
            let mut world = world.lock().unwrap();
            world.decoded = padded();
            world.encoder_input = VideoFormat {
                stride: Some(WIDTH * 2),
                slice_height: Some(HEIGHT),
                ..VideoFormat::default()
            };
        }
        world
    }

    /// **The buffer path**: every decoded picture reaches its encoder
    /// whole, from the decoder's padded and cropped layout into the
    /// encoder's packed one, queued at the encoder's picture length. Each
    /// encoder ends with an empty buffer marked as the end. The encoders
    /// take the container's colour keys, and the decoder's where the
    /// container says nothing, with the decoder's `hdr-static-info`.
    #[test]
    fn the_buffer_path_copies_every_picture_and_ends_by_an_empty_buffer() {
        let world = buffer_world();
        let mut source = source();
        source.colour = Colour {
            standard: Some(6),
            transfer: None,
            range: None,
        };
        let mut container = config(PictureTarget::HevcMain10);
        container.colour = source.colour;
        let mut converter = Converter::new(FakeCodecs(world.clone()), source, container);
        let events = convert(&mut converter, &closed_film(2), &segments(2, 0)).unwrap();
        let world = world.lock().unwrap();
        assert_eq!(world.copies.len(), 50);
        let packed = PlaneLayout::packed(WIDTH, HEIGHT, 2).picture_bytes(HEIGHT);
        assert!(
            world
                .copies
                .iter()
                .all(|(_, ok, len)| *ok && *len == packed),
            "{:?}",
            world.copies
        );
        assert_eq!(
            world
                .log
                .iter()
                .filter(|entry| entry.starts_with("end of input by buffer"))
                .count(),
            2
        );
        assert!(!world
            .log
            .iter()
            .any(|entry| entry.starts_with("end of input by signal")));
        assert!(world.sources[0].1, "the decoder asked for P010");
        for config in &world.configs {
            assert_eq!(
                config.colour,
                Colour {
                    standard: Some(6),
                    transfer: Some(6),
                    range: Some(2)
                }
            );
            assert_eq!(config.hdr_static_info.as_deref(), Some(&T9_STATIC_INFO[..]));
        }
        assert_eq!(pictures_of(&events).len(), 50);
    }

    // --- The software path --------------------------------------------------------

    /// The software decoder's NV12 layout, padded: a stride wider than a
    /// row, a crop off the corner, a slice height past the picture.
    fn padded_nv12() -> VideoFormat {
        VideoFormat {
            color_format: Some(COLOR_FORMAT_NV12),
            width: WIDTH + 16,
            height: HEIGHT + 8,
            stride: Some(WIDTH + 40),
            slice_height: Some(HEIGHT + 12),
            crop: Some((6, 2, 6 + WIDTH - 1, 2 + HEIGHT - 1)),
            ..VideoFormat::default()
        }
    }

    fn software_world() -> Shared {
        let world = world();
        {
            let mut world = world.lock().unwrap();
            world.software = true;
            world.decoded = padded_nv12();
            // The encoder's input is padded another way.
            world.encoder_input = VideoFormat {
                stride: Some(WIDTH + 16),
                slice_height: Some(HEIGHT + 4),
                ..VideoFormat::default()
            };
        }
        world
    }

    /// **The software path**: the decoder's pictures leave in the order
    /// they are shown, though B-frames came in decode order, and each one
    /// reaches its encoder whole as NV12: from the decoder's padded,
    /// cropped layout into the encoder's padded one, byte for byte, queued
    /// at the encoder's picture length. Every encoder takes buffers, ends
    /// with an empty buffer marked as the end, and makes 8-bit pictures.
    #[test]
    fn the_software_path_copies_nv12_in_presentation_order_and_ends_by_an_empty_buffer() {
        let world = software_world();
        let film = closed_film(2);
        let segments = segments(2, 0);
        let events = convert(
            &mut converter(&world, PictureTarget::HevcMain),
            &film,
            &segments,
        )
        .unwrap();
        let world = world.lock().unwrap();
        let mut shown: Vec<i64> = film.iter().map(|picture| picture.pts_us).collect();
        shown.sort_unstable();
        let decoded: Vec<i64> = world.copies.iter().map(|(pts, ..)| *pts).collect();
        assert_eq!(decoded, shown, "in the order they are shown");
        let padded = PlaneLayout::of(&world.encoder_input, WIDTH, HEIGHT, 1);
        assert_eq!(padded.row_bytes, WIDTH as usize + 16);
        let length = padded.picture_bytes(HEIGHT);
        assert!(
            world
                .copies
                .iter()
                .all(|(_, whole, len)| *whole && *len == length),
            "{:?}",
            world.copies
        );
        assert_eq!(world.sources, vec![(source(), false)], "no P010 asked");
        assert!(
            world.log[0].starts_with("create decoder"),
            "{:?}",
            world.log
        );
        assert_eq!(
            world
                .log
                .iter()
                .filter(|entry| entry.ends_with("with buffers"))
                .count(),
            2
        );
        assert_eq!(
            world
                .log
                .iter()
                .filter(|entry| entry.starts_with("end of input by buffer"))
                .count(),
            2
        );
        assert!(!world.log.iter().any(|entry| entry.contains("window")));
        assert!(world
            .configs
            .iter()
            .all(|config| config.target == PictureTarget::HevcMain));
        let pictures: Vec<i64> = pictures_of(&events)
            .iter()
            .map(|(_, pts, _)| *pts)
            .collect();
        assert_eq!(pictures, shown);
        assert_eq!(
            input_color_format(PictureTarget::HevcMain, false),
            COLOR_FORMAT_NV12
        );
        assert_eq!(
            input_color_format(PictureTarget::H264High, false),
            COLOR_FORMAT_NV12
        );
        assert_eq!(
            input_color_format(PictureTarget::HevcMain10, false),
            COLOR_FORMAT_P010
        );
        assert_eq!(
            input_color_format(PictureTarget::HevcMain, true),
            COLOR_FORMAT_SURFACE
        );
    }

    /// The software path refuses a decoder that does not write NV12, and a
    /// 10-bit target.
    #[test]
    fn the_software_path_wants_nv12_and_eight_bits() {
        let world = software_world();
        world.lock().unwrap().decoded.color_format = Some(COLOR_FORMAT_P010);
        let error = convert(
            &mut converter(&world, PictureTarget::HevcMain),
            &closed_film(1),
            &segments(1, 0),
        )
        .unwrap_err();
        assert!(
            error.starts_with("the software decoder gives no NV12 pictures"),
            "{error}"
        );
        let error = convert(
            &mut converter(&software_world(), PictureTarget::HevcMain10),
            &closed_film(1),
            &segments(1, 0),
        )
        .unwrap_err();
        assert_eq!(error, "the software decoder makes 8-bit pictures only");
    }

    /// **A hardware decoder fed an AVI's decode times**: it hands each
    /// picture back with the time it went in with, in the order pictures
    /// are shown, so B-frames come out with times out of order. The
    /// converter gives each the earliest input time not yet given out:
    /// the pictures go to the encoder and out of it with times that only
    /// increase, and the server's driver takes them.
    #[test]
    fn a_hardware_decoders_pictures_fed_decode_times_are_timed_again() {
        let world = world();
        world.lock().unwrap().echoes = true;
        // The closed film in decode order, each picture timed by when it
        // is decoded, its data naming when it is shown.
        let film: Vec<SourcePicture> = closed_film(2)
            .into_iter()
            .enumerate()
            .map(|(n, picture)| {
                let mut data = picture.data.to_vec();
                data.extend_from_slice(&picture.pts_us.to_le_bytes());
                SourcePicture {
                    pts_us: n as i64 * FRAME_US,
                    key: picture.key,
                    data: data.into(),
                }
            })
            .collect();
        let mut source = source();
        source.decode_times = true;
        let make = || {
            Converter::new(
                FakeCodecs(world.clone()),
                source.clone(),
                config(PictureTarget::HevcMain),
            )
        };
        let segments = segments(2, 0);
        let mut driver = ConvertedPicture::new(make(), segments.clone(), PictureTarget::HevcMain);
        let mut converted = Vec::new();
        for picture in film.clone() {
            converted.extend(driver.push(picture).unwrap());
        }
        converted.extend(driver.finish().unwrap());
        let times: Vec<i64> = converted
            .iter()
            .filter_map(|item| match item {
                Converted::Sample(sample) => Some(sample.pts_us),
                Converted::Format(_) => None,
            })
            .collect();
        let expected: Vec<i64> = (0..50).map(|n| n * FRAME_US).collect();
        assert_eq!(times, expected);
        assert_eq!(world.lock().unwrap().rendered, expected);
    }

    /// **HDR10's SEI goes into the configuration only when the encoder
    /// left it out**: appended to a csd of parameter sets alone, and not
    /// to one that already has a mastering display.
    #[test]
    fn the_hdr10_sei_is_appended_only_when_absent() {
        let bare = Bytes::from_static(b"\0\0\0\x01\x40\x01vps");
        let world = buffer_world();
        world.lock().unwrap().csds = vec![bare.clone()];
        let events = convert(
            &mut converter(&world, PictureTarget::HevcMain10),
            &closed_film(1),
            &segments(1, 0),
        )
        .unwrap();
        let sei = hdr10_sei(&T9_STATIC_INFO).unwrap();
        assert_eq!(
            events[0],
            PictureEvent::Config {
                segment: 0,
                width: WIDTH,
                height: HEIGHT,
                csd: [bare.as_ref(), sei.as_ref()].concat().into(),
            }
        );

        let with = Bytes::from([bare.as_ref(), &hdr10_sei(&T9_STATIC_INFO).unwrap()[..]].concat());
        let world = buffer_world();
        world.lock().unwrap().csds = vec![with.clone()];
        let events = convert(
            &mut converter(&world, PictureTarget::HevcMain10),
            &closed_film(1),
            &segments(1, 0),
        )
        .unwrap();
        assert!(matches!(&events[0], PictureEvent::Config { csd, .. } if *csd == with));

        // An 8-bit target never carries it, whatever the decoder said.
        let world = self::world();
        world.lock().unwrap().csds = vec![bare.clone()];
        let mut config = config(PictureTarget::HevcMain);
        config.hdr_static_info = Some(Bytes::from(T9_STATIC_INFO.to_vec()));
        let mut eight = Converter::new(FakeCodecs(world), source(), config);
        let events = convert(&mut eight, &closed_film(1), &segments(1, 0)).unwrap();
        assert!(matches!(&events[0], PictureEvent::Config { csd, .. } if *csd == bare));
    }

    /// The configuration comes from the output format when the encoder
    /// hands no configuration buffer.
    #[test]
    fn the_configuration_may_come_in_the_output_format() {
        let world = world();
        world.lock().unwrap().csd_in_format = true;
        let events = convert(
            &mut converter(&world, PictureTarget::HevcMain),
            &closed_film(1),
            &segments(1, 0),
        )
        .unwrap();
        assert!(
            matches!(&events[0], PictureEvent::Config { csd, .. } if csd.as_ref() == b"\0\0\0\x01csd")
        );
    }

    /// A decoder that does not give P010 fails the buffer path at its first
    /// picture.
    #[test]
    fn a_decoder_without_p010_fails_the_buffer_path() {
        let world = buffer_world();
        world.lock().unwrap().decoded.color_format = Some(0x7f42_0888);
        let error = convert(
            &mut converter(&world, PictureTarget::HevcMain10),
            &closed_film(1),
            &segments(1, 0),
        )
        .unwrap_err();
        assert!(
            error.starts_with("the decoder gives no 10-bit pictures"),
            "{error}"
        );
    }

    // --- P010 and HDR10, by hand ---------------------------------------------------

    /// **The copy is exact between any two layouts**: padded stride, a
    /// crop off the corner and a tall slice on one side, a packed picture
    /// on the other, and back. Layouts that match go whole, padding and
    /// all.
    #[test]
    fn copy_p010_moves_exactly_the_picture() {
        let (width, height) = (10usize, 6usize);
        let padded = PlaneLayout {
            row_bytes: 32,
            slice_height: 9,
            left: 2,
            top: 2,
        };
        let packed = PlaneLayout::packed(width as u32, height as u32, 2);
        let source = picture_in(padded, width, height, 80_000, 2);
        let mut target = vec![0u8; packed.picture_bytes(height as u32)];
        let len = copy_p010(
            &source,
            padded,
            &mut target,
            packed,
            width as u32,
            height as u32,
        )
        .unwrap();
        assert_eq!(len, 20 * (6 + 3));
        // Built independently: each luma row, then each chroma row.
        let mut expected = Vec::new();
        for y in 0..height {
            for x in 0..width {
                expected.extend_from_slice(&sample(80_000, 0, x, y));
            }
        }
        for y in 0..height / 2 {
            for x in 0..width {
                expected.extend_from_slice(&sample(80_000, 1, x, y));
            }
        }
        assert_eq!(target, expected);

        let mut back = vec![0xeeu8; padded.picture_bytes(height as u32) + padded.row_bytes];
        copy_p010(
            &target,
            packed,
            &mut back,
            padded,
            width as u32,
            height as u32,
        )
        .unwrap();
        assert!(holds_picture(&back, padded, width, height, 80_000, 2));

        let corner = PlaneLayout {
            left: 0,
            top: 0,
            ..padded
        };
        let source = picture_in(corner, width, height, 40_000, 2);
        let mut same = vec![0u8; source.len()];
        let len = copy_p010(
            &source,
            corner,
            &mut same,
            corner,
            width as u32,
            height as u32,
        )
        .unwrap();
        assert_eq!(len, corner.picture_bytes(height as u32));
        assert_eq!(same[..len], source[..len]);

        assert!(copy_p010(&source[..100], corner, &mut same, corner, 10, 6).is_err());
    }

    /// **An NV12 copy is exact between any two layouts**: a padded stride,
    /// a crop off the corner and a tall slice on one side, packed on the
    /// other.
    #[test]
    fn copy_nv12_moves_exactly_the_picture() {
        let (width, height) = (10usize, 6usize);
        let padded = PlaneLayout {
            row_bytes: 16,
            slice_height: 9,
            left: 2,
            top: 2,
        };
        let packed = PlaneLayout::packed(width as u32, height as u32, 1);
        let source = picture_in(padded, width, height, 80_000, 1);
        let mut target = vec![0u8; packed.picture_bytes(height as u32)];
        let len = copy_nv12(
            &source,
            padded,
            &mut target,
            packed,
            width as u32,
            height as u32,
        )
        .unwrap();
        assert_eq!(len, 10 * (6 + 3));
        // Built independently: each luma row, then each chroma row of
        // interleaved U and V.
        let mut expected = Vec::new();
        for y in 0..height {
            for x in 0..width {
                expected.push(sample(80_000, 0, x, y)[1]);
            }
        }
        for y in 0..height / 2 {
            for x in 0..width {
                expected.push(sample(80_000, 1, x, y)[1]);
            }
        }
        assert_eq!(target, expected);
        let mut back = vec![0xeeu8; padded.picture_bytes(height as u32) + padded.row_bytes];
        copy_nv12(
            &target,
            packed,
            &mut back,
            padded,
            width as u32,
            height as u32,
        )
        .unwrap();
        assert!(holds_picture(&back, padded, width, height, 80_000, 1));
        assert!(copy_nv12(&source[..50], padded, &mut back, packed, 10, 6).is_err());
    }

    /// **A software decoder's picture times**: its own when later than the
    /// last, else the last plus a frame (no time at all, or one no later),
    /// and the input's time for a first picture with none.
    #[test]
    fn a_software_pictures_time_is_its_own_or_a_frame_after_the_last() {
        assert_eq!(next_time(Some(80), Some(40), 40, 0), 80);
        assert_eq!(next_time(None, Some(80), 40, 0), 120);
        assert_eq!(next_time(Some(80), Some(80), 40, 0), 120);
        assert_eq!(next_time(Some(40), Some(80), 40, 0), 120);
        assert_eq!(next_time(Some(40), None, 40, 7), 40);
        assert_eq!(next_time(None, None, 40, 7), 7);
    }

    /// The probe's stride rule: a stride smaller than a row of 16-bit
    /// samples is in samples. A slice height shorter than the picture is
    /// not one.
    #[test]
    fn a_layout_reads_stride_in_samples_or_bytes() {
        let t9 = VideoFormat {
            width: 3840,
            height: 2160,
            stride: Some(7680),
            slice_height: Some(2160),
            crop: Some((0, 0, 3839, 2159)),
            ..VideoFormat::default()
        };
        let layout = PlaneLayout::of(&t9, 3840, 2160, 2);
        assert_eq!(layout, PlaneLayout::packed(3840, 2160, 2));
        assert_eq!(layout.picture_bytes(2160), 24_883_200, "t9's buffer size");
        let samples = VideoFormat {
            stride: Some(4096),
            slice_height: Some(16),
            ..t9
        };
        let layout = PlaneLayout::of(&samples, 3840, 2160, 2);
        assert_eq!((layout.row_bytes, layout.slice_height), (8192, 2160));
    }

    /// **The HDR10 SEI, byte for byte as x265 wrote it** for the same
    /// metadata: the decoder's `hdr-static-info` in `t9`, against the two
    /// SEI NAL units in that film's own `csd-0` (the mastering display's
    /// with its emulation-prevention byte).
    #[test]
    fn hdr10_sei_matches_x265() {
        let hex = |text: &str| -> Vec<u8> {
            (0..text.len())
                .step_by(2)
                .map(|at| u8::from_str_radix(&text[at..at + 2], 16).unwrap())
                .collect()
        };
        let info = hex("00d084803ec233c4864c1db80b133d4240e8030100e8039001");
        assert_eq!(info, T9_STATIC_INFO);
        let expected = [
            hex("000000014e01900403e8019080"),
            hex("000000014e01891833c286c41d4c0bb884d03e803d13404200989680000003000180"),
        ]
        .concat();
        assert_eq!(hdr10_sei(&info).unwrap().as_ref(), expected.as_slice());
        assert!(has_sei(&expected, SEI_MASTERING_DISPLAY));
        assert!(has_sei(&expected, SEI_CONTENT_LIGHT_LEVEL));
        assert!(!has_sei(&expected[..13], SEI_MASTERING_DISPLAY));

        // No light levels: the mastering display alone.
        let mut dark = info.clone();
        dark[21..25].fill(0);
        assert_eq!(hdr10_sei(&dark).unwrap().as_ref(), &expected[13..]);
        assert_eq!(hdr10_sei(&info[..24]), None);
        assert_eq!(hdr10_sei(&[1; 25]), None, "another descriptor");
    }

    // --- Stalls and drops ---------------------------------------------------------

    /// **A decoder that never takes a picture fails the push** after
    /// [`STALL_WAITS`] empty waits, not forever.
    #[test]
    fn a_starved_decoder_fails_the_push() {
        let world = world();
        world.lock().unwrap().starved = true;
        let error = converter(&world, PictureTarget::HevcMain)
            .push(picture(b'I', 0), &segments(1, 0))
            .unwrap_err();
        assert_eq!(error, "the decoder took no picture in 500 waits");
    }

    /// **A surface encoder that never catches up** is waited for a bounded
    /// time and then ended anyway. Its end says one picture went missing,
    /// which the server's driver refuses. One that never ends at all fails.
    #[test]
    fn an_encoder_that_never_catches_up_is_waited_for_a_bounded_time() {
        let world = world();
        world.lock().unwrap().lost = vec![480_000];
        let events = convert(
            &mut converter(&world, PictureTarget::HevcMain),
            &closed_film(1),
            &segments(1, 0),
        )
        .unwrap();
        assert_eq!(
            events.last(),
            Some(&PictureEvent::SegmentDone {
                segment: 0,
                pictures_in: 25,
                pictures_out: 24
            })
        );

        let world = self::world();
        world.lock().unwrap().never_ends = true;
        let error = convert(
            &mut converter(&world, PictureTarget::HevcMain),
            &closed_film(1),
            &segments(1, 0),
        )
        .unwrap_err();
        assert_eq!(error, "segment 0's encoder did not end in 300 waits");
    }

    /// **Dropping the converter releases every codec**, mid-run, without
    /// draining: the encoder, then its window, then the decoder.
    #[test]
    fn a_drop_releases_every_codec() {
        let world = world();
        let mut converter = converter(&world, PictureTarget::HevcMain);
        for picture in closed_film(2).into_iter().take(30) {
            converter.push(picture, &segments(2, 0)).unwrap();
        }
        assert_eq!(world.lock().unwrap().live_codecs, 2);
        let before = world.lock().unwrap().log.len();
        drop(converter);
        let world = world.lock().unwrap();
        assert_eq!((world.live_codecs, world.live_windows), (0, 0));
        assert_eq!(
            world.log[before..],
            ["delete encoder 3", "release window 2", "delete decoder 2"]
        );
    }

    /// A picture routed below the open encoder's segment is an error, not a
    /// picture in the wrong segment.
    #[test]
    fn a_picture_below_the_open_segment_is_an_error() {
        let world = world();
        world.lock().unwrap().reorder = 0;
        let mut converter = converter(&world, PictureTarget::HevcMain);
        let segments = segments(2, 0);
        converter.push(picture(b'I', 1_000_000), &segments).unwrap();
        converter.push(picture(b'P', 1_040_000), &segments).unwrap();
        let error = converter
            .push(picture(b'P', 960_000), &segments)
            .and_then(|_| converter.finish(&segments))
            .unwrap_err();
        assert!(
            error.contains("below the open encoder's segment 1"),
            "{error}"
        );
    }

    /// The container's colour tags as MediaFormat keys.
    #[test]
    fn colour_tags_become_mediaformat_keys() {
        let hdr10 = ColourTags {
            primaries: 9,
            transfer: ColourTags::PQ,
            matrix: 9,
            range: 1,
        };
        assert_eq!(
            Colour::of_tags(hdr10),
            Colour {
                standard: Some(6),
                transfer: Some(6),
                range: Some(2)
            }
        );
        let hlg_full = ColourTags {
            primaries: 2,
            transfer: ColourTags::HLG,
            matrix: 9,
            range: 2,
        };
        assert_eq!(
            Colour::of_tags(hlg_full),
            Colour {
                standard: Some(6),
                transfer: Some(7),
                range: Some(1)
            }
        );
        let sdr = ColourTags {
            primaries: 1,
            transfer: 1,
            matrix: 1,
            range: 0,
        };
        assert_eq!(
            Colour::of_tags(sdr),
            Colour {
                standard: Some(1),
                transfer: Some(3),
                range: None
            }
        );
        assert_eq!(Colour::of_tags(ColourTags::default()), Colour::default());
    }

    /// **The cast decision is offered what the hardware converts, or
    /// nothing at all** where the surface path is missing.
    #[test]
    fn without_the_surface_path_nothing_is_offered() {
        let phone = DeviceSupport {
            surface: true,
            ten_bit: true,
            decodes: vec!["H.264", "AV1"],
            encodes: vec!["HEVC"],
            software_decodes: vec!["MPEG-4 Part 2"],
        };
        assert_eq!(phone.clone().offered(), phone);
        let old = DeviceSupport {
            surface: false,
            ..phone
        };
        assert_eq!(old.offered(), DeviceSupport::default());
    }

    /// On a desktop nothing converts.
    #[cfg(not(target_os = "android"))]
    #[test]
    fn a_desktop_converts_nothing() {
        assert_eq!(support(), DeviceSupport::default());
        assert!(NdkCodecs::new().is_err());
    }
}
