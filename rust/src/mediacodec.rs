//! **Android's AAC encoder, through the NDK's `AMediaCodec`**: what a
//! rendition's converted sound is encoded with on a phone, whose libmpv has
//! FFmpeg's decoders but no encoder (`--disable-encoders`; stream-server
//! `docs/design/renditions.md` §2.6).
//!
//! `libmediandk.so` is opened at run time ([`Ndk::load`]), never linked, so
//! the crate builds and runs on a desktop, where loading it fails and the
//! sound is encoded by FFmpeg's own AAC encoder instead
//! ([`crate::libav::LibavAac`]). No Kotlin, no JNI: the NDK's C API is the
//! whole of it.
//!
//! **The codec**: `c2.android.aac.encoder` by name -- AOSP's software
//! encoder, Fraunhofer's FDK, on every device since Android 10 -- and
//! `audio/mp4a-latm` by type only where that name is missing, since a
//! vendor's encoder is not known to make the same bytes from the same sound,
//! nor to have FDK's priming. AAC-LC, 48 kHz, two channels, 16-bit PCM in
//! (FDK takes nothing else).
//!
//! **The priming** is FDK's `nDelay` for AAC-LC with 1024-sample frames:
//! the transform's 1024 plus the block switching's look-ahead,
//! `4 x 128 + 128 / 2` -- 1600 samples (`libAACenc/src/aacenc_lib.cpp`,
//! `DELAY_AAC`). The Codec2 wrapper (`C2SoftAacEnc`) does not compensate
//! for it (its output times are its input times), so the converter
//! discards it by count ([`crate::sound`]).
//!
//! **A fresh state for every chunk**: each call is fed, ended with
//! end-of-stream, drained, and the codec stopped and configured again
//! before the next, which is what the API documents as a codec back at
//! its start. (`C2SoftAacEnc`'s flush also re-initialises FDK,
//! `AACENC_INIT_ALL`; the stop is the documented way.) Synchronous: the
//! run's own thread feeds and drains, waiting at most
//! [`DEQUEUE_WAIT_US`] at a time for the codec, with no limit on how many
//! waits -- a codec that errors fails the run, one that is merely slow is
//! waited for.

use std::ffi::{c_char, c_long, c_void, CStr};

use bytes::Bytes;

use crate::sound::{to_s16le, AacEncoder, AUDIO_SPECIFIC_CONFIG};

/// FDK's priming for AAC-LC with 1024-sample frames, in samples.
pub const FDK_DELAY: i64 = 1600;
/// The codec asked for by name: AOSP's FDK encoder.
pub const FDK_NAME: &CStr = c"c2.android.aac.encoder";
/// How long one dequeue waits for the codec, in microseconds.
pub const DEQUEUE_WAIT_US: i64 = 10_000;

const BUFFER_FLAG_CODEC_CONFIG: u32 = 2;
const BUFFER_FLAG_END_OF_STREAM: u32 = 4;
const INFO_TRY_AGAIN_LATER: isize = -1;
const INFO_OUTPUT_FORMAT_CHANGED: isize = -2;
const INFO_OUTPUT_BUFFERS_CHANGED: isize = -3;
const CONFIGURE_FLAG_ENCODE: u32 = 1;
/// `AACObjectLC`.
const AAC_PROFILE_LC: i32 = 2;

/// What one output dequeue found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Output {
    /// Buffer `index`, `size` bytes at `offset`, with `flags`.
    Buffer {
        index: usize,
        offset: usize,
        size: usize,
        flags: u32,
    },
    /// Nothing yet, or a format or buffer change that needs nothing done.
    Nothing,
}

/// The few calls the encoding loop makes of a codec: the NDK's
/// `AMediaCodec` in the app ([`NdkAac`]), a fake in the tests.
pub trait Codec {
    /// An input buffer's index, or `None` if none is free within the wait.
    fn dequeue_input(&mut self, wait_us: i64) -> Result<Option<usize>, String>;
    /// Input buffer `index`, to be filled.
    fn input_buffer(&mut self, index: usize) -> Result<&mut [u8], String>;
    fn queue_input(
        &mut self,
        index: usize,
        len: usize,
        pts_us: u64,
        end: bool,
    ) -> Result<(), String>;
    fn dequeue_output(&mut self, wait_us: i64) -> Result<Output, String>;
    /// Output buffer `index`'s bytes.
    fn output_buffer(&mut self, index: usize) -> Result<&[u8], String>;
    fn release_output(&mut self, index: usize) -> Result<(), String>;
    /// Back to a fresh start, ready for input.
    fn restart(&mut self) -> Result<(), String>;
}

/// What one encoding made: the codec configuration the encoder reported,
/// and every frame after it, in order.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Encoded {
    pub config: Option<Bytes>,
    pub frames: Vec<Bytes>,
}

/// **The buffer loop**: `pcm` (16-bit stereo at 48 kHz, little-endian) fed
/// to `codec` buffer by buffer, the last flagged end-of-stream (an empty one
/// when there is nothing), every output collected until the codec says the
/// stream ended. Input is offered whenever a buffer is free; the loop waits
/// on the codec only when it has nothing to feed it.
pub fn encode_with<C: Codec>(codec: &mut C, pcm: &[u8]) -> Result<Encoded, String> {
    const FRAME_BYTES: usize = 4; // a stereo 16-bit sample
    let mut fed = 0usize;
    let mut ended = false;
    let mut out = Encoded::default();
    loop {
        let mut fed_now = false;
        if !ended {
            if let Some(index) = codec.dequeue_input(0)? {
                let buffer = codec.input_buffer(index)?;
                let room = buffer.len() / FRAME_BYTES * FRAME_BYTES;
                let len = room.min(pcm.len() - fed);
                if len == 0 && fed < pcm.len() {
                    return Err("the AAC encoder's input buffer holds no sample".to_owned());
                }
                buffer[..len].copy_from_slice(&pcm[fed..fed + len]);
                let pts_us = (fed / FRAME_BYTES) as u64 * 1_000_000 / 48_000;
                fed += len;
                ended = fed == pcm.len();
                codec.queue_input(index, len, pts_us, ended)?;
                fed_now = true;
            }
        }
        let wait = if fed_now { 0 } else { DEQUEUE_WAIT_US };
        match codec.dequeue_output(wait)? {
            Output::Nothing => {}
            Output::Buffer {
                index,
                offset,
                size,
                flags,
            } => {
                let bytes = codec.output_buffer(index)?;
                let data = bytes
                    .get(offset..offset + size)
                    .map(Bytes::copy_from_slice)
                    .ok_or("the AAC encoder's output runs past its buffer")?;
                codec.release_output(index)?;
                if flags & BUFFER_FLAG_CODEC_CONFIG != 0 {
                    out.config = Some(data);
                } else if !data.is_empty() {
                    out.frames.push(data);
                }
                if flags & BUFFER_FLAG_END_OF_STREAM != 0 {
                    return Ok(out);
                }
            }
        }
    }
}

/// **An [`AacEncoder`] over a [`Codec`]**: every call from a fresh start
/// (the codec restarted after the call before), the configuration it
/// reports checked against the one the server was told
/// ([`AUDIO_SPECIFIC_CONFIG`]).
pub struct CodecAac<C: Codec> {
    codec: C,
    delay: i64,
    used: bool,
}

impl<C: Codec> CodecAac<C> {
    /// `codec`, configured and started, whose priming is `delay` samples.
    pub fn new(codec: C, delay: i64) -> Self {
        Self {
            codec,
            delay,
            used: false,
        }
    }
}

impl<C: Codec + Send> AacEncoder for CodecAac<C> {
    fn delay(&self) -> i64 {
        self.delay
    }

    fn encode(&mut self, pcm: &[f32]) -> Result<Vec<Bytes>, String> {
        if self.used {
            self.codec.restart()?;
        }
        self.used = true;
        let encoded = encode_with(&mut self.codec, &to_s16le(pcm))?;
        if let Some(config) = &encoded.config {
            if config.as_ref() != AUDIO_SPECIFIC_CONFIG {
                return Err(format!(
                    "the AAC encoder made a configuration of {:02x?}, not AAC-LC 48 kHz stereo",
                    config.as_ref()
                ));
            }
        }
        Ok(encoded.frames)
    }
}

// --- The NDK -----------------------------------------------------------------------

/// `AMediaCodecBufferInfo`.
#[repr(C)]
#[derive(Default)]
struct BufferInfo {
    offset: i32,
    size: i32,
    presentation_time_us: i64,
    flags: u32,
}

/// The `libmediandk.so` functions the encoder calls (API 21).
struct Ndk {
    create_codec_by_name: unsafe extern "C" fn(*const c_char) -> *mut c_void,
    create_encoder_by_type: unsafe extern "C" fn(*const c_char) -> *mut c_void,
    delete: unsafe extern "C" fn(*mut c_void) -> i32,
    configure:
        unsafe extern "C" fn(*mut c_void, *const c_void, *mut c_void, *mut c_void, u32) -> i32,
    start: unsafe extern "C" fn(*mut c_void) -> i32,
    stop: unsafe extern "C" fn(*mut c_void) -> i32,
    dequeue_input_buffer: unsafe extern "C" fn(*mut c_void, i64) -> isize,
    get_input_buffer: unsafe extern "C" fn(*mut c_void, usize, *mut usize) -> *mut u8,
    /// `offset` is `off_t`: a `long` on Android, 32 bits on armv7.
    queue_input_buffer: unsafe extern "C" fn(*mut c_void, usize, c_long, usize, u64, u32) -> i32,
    dequeue_output_buffer: unsafe extern "C" fn(*mut c_void, *mut BufferInfo, i64) -> isize,
    get_output_buffer: unsafe extern "C" fn(*mut c_void, usize, *mut usize) -> *mut u8,
    release_output_buffer: unsafe extern "C" fn(*mut c_void, usize, bool) -> i32,
    format_new: unsafe extern "C" fn() -> *mut c_void,
    format_delete: unsafe extern "C" fn(*mut c_void) -> i32,
    format_set_string: unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char),
    format_set_int32: unsafe extern "C" fn(*mut c_void, *const c_char, i32),
    _library: libloading::Library,
}

impl Ndk {
    fn load() -> Result<Self, String> {
        // SAFETY: the platform's media library; its initialisers have no
        // preconditions, and each symbol is read as its `NdkMediaCodec.h` /
        // `NdkMediaFormat.h` signature.
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
            Ok(Self {
                create_codec_by_name: symbol!("AMediaCodec_createCodecByName"),
                create_encoder_by_type: symbol!("AMediaCodec_createEncoderByType"),
                delete: symbol!("AMediaCodec_delete"),
                configure: symbol!("AMediaCodec_configure"),
                start: symbol!("AMediaCodec_start"),
                stop: symbol!("AMediaCodec_stop"),
                dequeue_input_buffer: symbol!("AMediaCodec_dequeueInputBuffer"),
                get_input_buffer: symbol!("AMediaCodec_getInputBuffer"),
                queue_input_buffer: symbol!("AMediaCodec_queueInputBuffer"),
                dequeue_output_buffer: symbol!("AMediaCodec_dequeueOutputBuffer"),
                get_output_buffer: symbol!("AMediaCodec_getOutputBuffer"),
                release_output_buffer: symbol!("AMediaCodec_releaseOutputBuffer"),
                format_new: symbol!("AMediaFormat_new"),
                format_delete: symbol!("AMediaFormat_delete"),
                format_set_string: symbol!("AMediaFormat_setString"),
                format_set_int32: symbol!("AMediaFormat_setInt32"),
                _library: library,
            })
        }
    }
}

/// **Android's AAC encoder** as a [`Codec`]: one `AMediaCodec`, configured
/// for AAC-LC 48 kHz stereo at a bitrate, and its format kept for every
/// restart.
pub struct NdkAac {
    ndk: Ndk,
    codec: *mut c_void,
    format: *mut c_void,
}

// SAFETY: an `AMediaCodec` may be driven from any one thread at a time;
// this value is used by the run's thread alone.
unsafe impl Send for NdkAac {}

impl NdkAac {
    /// The encoder at `bitrate` bits a second, configured and started, and
    /// its priming; an error where this is no Android or no AAC encoder.
    pub fn open(bitrate: u32) -> Result<(Self, i64), String> {
        let ndk = Ndk::load()?;
        // SAFETY: the NDK's documented sequence; the codec and format are
        // this value's, deleted in its `Drop` whatever fails below.
        unsafe {
            let mut delay = FDK_DELAY;
            let mut codec = (ndk.create_codec_by_name)(FDK_NAME.as_ptr());
            if codec.is_null() {
                tracing::warn!("no c2.android.aac.encoder; taking the device's AAC encoder");
                codec = (ndk.create_encoder_by_type)(c"audio/mp4a-latm".as_ptr());
                // A vendor's priming is not known; FDK's is the guess.
                delay = FDK_DELAY;
            }
            let format = (ndk.format_new)();
            let encoder = Self { ndk, codec, format };
            if encoder.codec.is_null() || encoder.format.is_null() {
                return Err("this device has no AAC encoder".to_owned());
            }
            let set_int = |key: &CStr, value: i32| {
                (encoder.ndk.format_set_int32)(encoder.format, key.as_ptr(), value)
            };
            (encoder.ndk.format_set_string)(
                encoder.format,
                c"mime".as_ptr(),
                c"audio/mp4a-latm".as_ptr(),
            );
            set_int(c"sample-rate", 48_000);
            set_int(c"channel-count", 2);
            set_int(c"bitrate", i32::try_from(bitrate).unwrap_or(192_000));
            set_int(c"aac-profile", AAC_PROFILE_LC);
            set_int(c"pcm-encoding", 2); // ENCODING_PCM_16BIT
            set_int(c"max-input-size", 64 * 1024);
            encoder.configure_and_start()?;
            Ok((encoder, delay))
        }
    }

    fn configure_and_start(&self) -> Result<(), String> {
        // SAFETY: the codec and format are live; no surface, no crypto.
        unsafe {
            let configured = (self.ndk.configure)(
                self.codec,
                self.format,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                CONFIGURE_FLAG_ENCODE,
            );
            if configured != 0 {
                return Err(format!("the AAC encoder refused its format ({configured})"));
            }
            let started = (self.ndk.start)(self.codec);
            if started != 0 {
                return Err(format!("the AAC encoder did not start ({started})"));
            }
        }
        Ok(())
    }
}

impl Codec for NdkAac {
    fn dequeue_input(&mut self, wait_us: i64) -> Result<Option<usize>, String> {
        // SAFETY: a started codec.
        let index = unsafe { (self.ndk.dequeue_input_buffer)(self.codec, wait_us) };
        match index {
            INFO_TRY_AGAIN_LATER => Ok(None),
            index if index >= 0 => Ok(Some(index as usize)),
            error => Err(format!("the AAC encoder gave no input buffer ({error})")),
        }
    }

    fn input_buffer(&mut self, index: usize) -> Result<&mut [u8], String> {
        let mut size = 0usize;
        // SAFETY: an index the codec handed out; the buffer is `size` bytes
        // and ours until queued.
        unsafe {
            let data = (self.ndk.get_input_buffer)(self.codec, index, &mut size);
            if data.is_null() {
                return Err("the AAC encoder's input buffer is missing".to_owned());
            }
            Ok(std::slice::from_raw_parts_mut(data, size))
        }
    }

    fn queue_input(
        &mut self,
        index: usize,
        len: usize,
        pts_us: u64,
        end: bool,
    ) -> Result<(), String> {
        let flags = if end { BUFFER_FLAG_END_OF_STREAM } else { 0 };
        // SAFETY: an index the codec handed out, filled with `len` bytes.
        let queued =
            unsafe { (self.ndk.queue_input_buffer)(self.codec, index, 0, len, pts_us, flags) };
        if queued != 0 {
            return Err(format!("the AAC encoder refused its input ({queued})"));
        }
        Ok(())
    }

    fn dequeue_output(&mut self, wait_us: i64) -> Result<Output, String> {
        let mut info = BufferInfo::default();
        // SAFETY: a started codec and a live info struct.
        let index = unsafe { (self.ndk.dequeue_output_buffer)(self.codec, &mut info, wait_us) };
        match index {
            INFO_TRY_AGAIN_LATER | INFO_OUTPUT_FORMAT_CHANGED | INFO_OUTPUT_BUFFERS_CHANGED => {
                Ok(Output::Nothing)
            }
            index if index >= 0 => Ok(Output::Buffer {
                index: index as usize,
                offset: usize::try_from(info.offset).unwrap_or(0),
                size: usize::try_from(info.size).unwrap_or(0),
                flags: info.flags,
            }),
            error => Err(format!("the AAC encoder failed ({error})")),
        }
    }

    fn output_buffer(&mut self, index: usize) -> Result<&[u8], String> {
        let mut size = 0usize;
        // SAFETY: an index the codec handed out; the buffer is `size` bytes
        // until released.
        unsafe {
            let data = (self.ndk.get_output_buffer)(self.codec, index, &mut size);
            if data.is_null() {
                return Err("the AAC encoder's output buffer is missing".to_owned());
            }
            Ok(std::slice::from_raw_parts(data, size))
        }
    }

    fn release_output(&mut self, index: usize) -> Result<(), String> {
        // SAFETY: an index the codec handed out, released once.
        let released = unsafe { (self.ndk.release_output_buffer)(self.codec, index, false) };
        if released != 0 {
            return Err(format!(
                "the AAC encoder's output was not released ({released})"
            ));
        }
        Ok(())
    }

    fn restart(&mut self) -> Result<(), String> {
        // SAFETY: a configured codec; stopped, it is configured again.
        let stopped = unsafe { (self.ndk.stop)(self.codec) };
        if stopped != 0 {
            return Err(format!("the AAC encoder did not stop ({stopped})"));
        }
        self.configure_and_start()
    }
}

impl Drop for NdkAac {
    fn drop(&mut self) {
        // SAFETY: each pointer is null or this value's own, deleted once.
        unsafe {
            if !self.codec.is_null() {
                (self.ndk.stop)(self.codec);
                (self.ndk.delete)(self.codec);
            }
            if !self.format.is_null() {
                (self.ndk.format_delete)(self.format);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;

    /// A codec like FDK in shape: input buffers of `room` bytes, output one
    /// "frame" per 4096 bytes of input (a 1024-sample stereo frame), whose
    /// bytes are the frame's number, a configuration first and an
    /// end-of-stream flag on the last; `free_inputs` buffers free at a time,
    /// output held back until `lag` frames are pending, so the loop has to
    /// drain to be given input again.
    struct FakeCodec {
        free_inputs: usize,
        lag: usize,
        inputs: Vec<Vec<u8>>,
        queued: VecDeque<usize>,
        pending: usize,
        fed: usize,
        ended: bool,
        outputs: VecDeque<(Vec<u8>, u32)>,
        made: usize,
        sent_config: bool,
        held: Option<Vec<u8>>,
        restarts: usize,
        waits: Vec<i64>,
    }

    impl FakeCodec {
        fn new(room: usize, free_inputs: usize, lag: usize) -> Self {
            Self {
                free_inputs,
                lag,
                inputs: vec![vec![0; room]; 4],
                queued: VecDeque::new(),
                pending: 0,
                fed: 0,
                ended: false,
                outputs: VecDeque::new(),
                made: 0,
                sent_config: false,
                held: None,
                restarts: 0,
                waits: Vec::new(),
            }
        }

        fn produce(&mut self) {
            if !self.sent_config {
                self.sent_config = true;
                self.outputs
                    .push_back((AUDIO_SPECIFIC_CONFIG.to_vec(), BUFFER_FLAG_CODEC_CONFIG));
            }
            while self.fed / 4096 > self.made && (self.pending >= self.lag || self.ended) {
                self.outputs.push_back((vec![self.made as u8], 0));
                self.made += 1;
                self.pending = self.pending.saturating_sub(1);
            }
            if self.ended && self.fed / 4096 <= self.made {
                // The flush: the rest, padded, and the end.
                if !self.fed.is_multiple_of(4096) && self.fed / 4096 == self.made {
                    self.outputs.push_back((vec![self.made as u8], 0));
                    self.made += 1;
                }
                self.outputs
                    .push_back((Vec::new(), BUFFER_FLAG_END_OF_STREAM));
                self.ended = false;
            }
        }
    }

    impl Codec for FakeCodec {
        fn dequeue_input(&mut self, _: i64) -> Result<Option<usize>, String> {
            if self.queued.len() >= self.free_inputs {
                return Ok(None);
            }
            let index = (0..4).find(|i| !self.queued.contains(i)).unwrap();
            self.queued.push_back(index);
            Ok(Some(index))
        }
        fn input_buffer(&mut self, index: usize) -> Result<&mut [u8], String> {
            Ok(&mut self.inputs[index])
        }
        fn queue_input(
            &mut self,
            index: usize,
            len: usize,
            pts_us: u64,
            end: bool,
        ) -> Result<(), String> {
            assert_eq!(pts_us, (self.fed / 4) as u64 * 1_000_000 / 48_000);
            assert_eq!(len % 4, 0, "whole stereo samples");
            let before = self.fed / 4096;
            self.fed += len;
            self.pending += self.fed / 4096 - before;
            self.ended = end;
            self.produce();
            // Taken once the codec has had it, which frees the buffer only
            // when output was drained (the lag).
            if self.outputs.is_empty() || end {
                self.queued.retain(|i| *i != index);
            } else {
                self.held = Some(vec![index as u8]);
            }
            Ok(())
        }
        fn dequeue_output(&mut self, wait_us: i64) -> Result<Output, String> {
            self.waits.push(wait_us);
            match self.outputs.front() {
                None => Ok(Output::Nothing),
                Some((data, flags)) => Ok(Output::Buffer {
                    index: 0,
                    offset: 0,
                    size: data.len(),
                    flags: *flags,
                }),
            }
        }
        fn output_buffer(&mut self, _: usize) -> Result<&[u8], String> {
            Ok(&self.outputs.front().unwrap().0)
        }
        fn release_output(&mut self, _: usize) -> Result<(), String> {
            self.outputs.pop_front();
            if let Some(held) = self.held.take() {
                self.queued.retain(|i| *i != usize::from(held[0]));
            }
            Ok(())
        }
        fn restart(&mut self) -> Result<(), String> {
            self.restarts += 1;
            self.queued.clear();
            self.pending = 0;
            self.fed = 0;
            self.made = 0;
            self.ended = false;
            self.outputs.clear();
            self.sent_config = false;
            Ok(())
        }
    }

    /// **The loop feeds every byte, drains every frame and stops at the
    /// end-of-stream**: the configuration is told apart from the frames,
    /// the input crosses buffers smaller than a frame, and a codec that
    /// frees an input buffer only once its output is drained does not stall
    /// it.
    #[test]
    fn the_buffer_loop_feeds_everything_and_drains_to_the_end() {
        for (room, free_inputs, lag) in [(8192, 4, 0), (1000, 1, 2), (65536, 2, 1)] {
            let mut codec = FakeCodec::new(room, free_inputs, lag);
            let pcm = vec![0u8; 4096 * 10 + 400];
            let encoded = encode_with(&mut codec, &pcm).unwrap();
            assert_eq!(
                encoded.config.as_deref(),
                Some(&AUDIO_SPECIFIC_CONFIG[..]),
                "room {room}"
            );
            assert_eq!(
                encoded.frames,
                (0..11u8).map(|n| Bytes::from(vec![n])).collect::<Vec<_>>(),
                "room {room}"
            );
            assert_eq!(codec.fed, pcm.len());
        }
    }

    /// Nothing to encode still ends the stream: one empty buffer with the
    /// flag.
    #[test]
    fn an_empty_input_still_ends_the_stream() {
        let mut codec = FakeCodec::new(8192, 4, 0);
        let encoded = encode_with(&mut codec, &[]).unwrap();
        assert!(encoded.frames.is_empty());
        assert_eq!(codec.fed, 0);
    }

    /// The loop waits on the codec only when it had nothing to feed it.
    #[test]
    fn the_loop_waits_only_when_it_fed_nothing() {
        let mut codec = FakeCodec::new(1000, 1, 2);
        encode_with(&mut codec, &vec![0u8; 4096 * 4]).unwrap();
        assert!(codec.waits.contains(&0));
        assert!(codec.waits.contains(&DEQUEUE_WAIT_US));
    }

    /// **Every chunk from a fresh start**: the codec is restarted before
    /// each call but the first, and a configuration that is not AAC-LC
    /// 48 kHz stereo -- what the server was told -- fails.
    #[test]
    fn each_call_restarts_the_codec_and_checks_its_configuration() {
        let mut aac = CodecAac::new(FakeCodec::new(8192, 4, 0), FDK_DELAY);
        let pcm = vec![0f32; 1024 * 2 * 3];
        assert_eq!(aac.encode(&pcm).unwrap().len(), 3);
        assert_eq!(aac.codec.restarts, 0);
        assert_eq!(aac.encode(&pcm).unwrap().len(), 3);
        assert_eq!(aac.codec.restarts, 1);
        assert_eq!(aac.delay(), 1600);

        struct WrongConfig(FakeCodec);
        impl Codec for WrongConfig {
            fn dequeue_input(&mut self, wait: i64) -> Result<Option<usize>, String> {
                self.0.dequeue_input(wait)
            }
            fn input_buffer(&mut self, index: usize) -> Result<&mut [u8], String> {
                self.0.input_buffer(index)
            }
            fn queue_input(&mut self, i: usize, l: usize, p: u64, e: bool) -> Result<(), String> {
                self.0.queue_input(i, l, p, e)?;
                if let Some(first) = self.0.outputs.front_mut() {
                    if first.1 == BUFFER_FLAG_CODEC_CONFIG {
                        first.0 = vec![0x13, 0x10];
                    }
                }
                Ok(())
            }
            fn dequeue_output(&mut self, wait: i64) -> Result<Output, String> {
                self.0.dequeue_output(wait)
            }
            fn output_buffer(&mut self, index: usize) -> Result<&[u8], String> {
                self.0.output_buffer(index)
            }
            fn release_output(&mut self, index: usize) -> Result<(), String> {
                self.0.release_output(index)
            }
            fn restart(&mut self) -> Result<(), String> {
                self.0.restart()
            }
        }
        let mut wrong = CodecAac::new(WrongConfig(FakeCodec::new(8192, 4, 0)), FDK_DELAY);
        assert_eq!(
            wrong.encode(&pcm).unwrap_err(),
            "the AAC encoder made a configuration of [13, 10], not AAC-LC 48 kHz stereo"
        );
    }

    /// On a desktop there is no `libmediandk.so`, and opening says so
    /// rather than crashing.
    #[cfg(not(target_os = "android"))]
    #[test]
    fn a_desktop_has_no_ndk_encoder() {
        assert!(NdkAac::open(192_000).is_err());
    }
}
