//! **libavformat, from the libmpv the app already ships**: the demuxer a
//! rendition is read with (stream-server `docs/design/renditions.md` §5,
//! F1½: `MediaExtractor` drops every Dolby and DTS track and opens no AVI,
//! so the demuxer is FFmpeg's).
//!
//! # Where the functions come from
//!
//! Nothing here links FFmpeg. The vendored `media_kit_libs_android_video`
//! libmpv (`full` flavour, libmpv-android v1.1.11) carries FFmpeg **n6.0**
//! inside it (`Lavf60.3.100`, `Lavc60.3.100`) and exports its whole API
//! from its dynamic symbol table -- 801 `av*`/`swr_*` symbols on every
//! ABI, arm64, armv7, x86 and x86_64 alike. [`crate::mpv_stream`] already
//! `dlopen`s that library to reach `mpv_stream_cb_add_ro`; this opens it
//! again by the same path ([`Libav::registered`]), which the loader answers
//! with the instance already mapped. On Linux the system libmpv links the
//! system's `libavformat.so.N`, and a lookup on libmpv's handle finds the
//! symbols in its dependencies, so the same code reaches them there.
//!
//! # Bound to one FFmpeg ABI, and checked
//!
//! Functions are looked up by name; **structs are read by layout**, and a
//! layout is only stable within a major version (`docs/design/renditions.md`
//! §6½). Every struct below is the *prefix* of FFmpeg 6.0's, up to the last
//! field this module reads, transcribed from `libavformat/avformat.h`,
//! `avio.h`, `libavcodec/codec_par.h`, `packet.h` and
//! `libavutil/channel_layout.h` at tag `n6.0`. Two checks hold them:
//!
//! - **At compile time**, every field this module reads is asserted at the
//!   offset a C compiler puts it, for 64-bit and 32-bit targets
//!   ([`layout`]). The numbers come from `tool/libav_offsets.sh`, which
//!   compiles `offsetof` over the n6.0 headers for x86_64, aarch64 and armv7
//!   (and over the host's 6.1 headers, which agree: fields are only ever
//!   appended within a major). A bump of the vendored jar to another FFmpeg
//!   major re-runs it and re-transcribes the prefixes.
//! - **At load time**, [`Libav::load`] refuses a library whose
//!   `avformat_version`, `avcodec_version` or `avutil_version` is not the
//!   major these layouts are for ([`AVFORMAT_MAJOR`], [`AVCODEC_MAJOR`],
//!   [`AVUTIL_MAJOR`]): a desktop whose system FFmpeg is 7.x answers
//!   "unavailable", never a misread struct.
//!
//! # What it is used for
//!
//! [`Demuxer`]: a custom `AVIOContext` over any [`Source`] -- the server's
//! [`MediaReader`] in the app, bytes in memory in the tests -- whose read
//! and seek callbacks are blocking Rust, then `av_read_frame` packet by
//! packet. Nothing is decoded but what `avformat_find_stream_info` decodes
//! to learn where the film starts, as mpv's own open does.

use std::ffi::{c_char, c_int, c_uint, c_void};
use std::io;
use std::sync::OnceLock;

use bytes::Bytes;
use stream_server::MediaReader;

/// The `LIBAVFORMAT_VERSION_MAJOR` the struct layouts are for.
pub const AVFORMAT_MAJOR: u32 = 60;
/// The `LIBAVCODEC_VERSION_MAJOR` (`AVPacket`, `AVCodecParameters`).
pub const AVCODEC_MAJOR: u32 = 60;
/// The `LIBAVUTIL_VERSION_MAJOR` (`AVChannelLayout`, `AVRational`).
pub const AVUTIL_MAJOR: u32 = 58;

/// `AV_NOPTS_VALUE`.
pub const NOPTS: i64 = i64::MIN;
/// `AV_TIME_BASE`: the microseconds `AVFormatContext` times are in.
const TIME_BASE: i64 = 1_000_000;
/// `AVERROR_EOF`: `-MKTAG('E','O','F',' ')`.
const AVERROR_EOF: c_int = -0x2046_4F45;
/// `AVERROR(EIO)`.
const AVERROR_EIO: c_int = -5;
/// `AVERROR(EINVAL)`.
const AVERROR_EINVAL: c_int = -22;
/// `AVSEEK_SIZE`: a seek callback asked for the length.
const AVSEEK_SIZE: c_int = 0x1_0000;
/// `AVSEEK_FORCE`, OR'd into `whence`; nothing to do with it here.
const AVSEEK_FORCE: c_int = 0x2_0000;
/// `AVSEEK_FLAG_BACKWARD`: seek to the sync point at or before.
const AVSEEK_FLAG_BACKWARD: c_int = 1;
/// `AV_PKT_FLAG_KEY`.
const AV_PKT_FLAG_KEY: c_int = 1;
/// `AV_DISPOSITION_ATTACHED_PIC`: a cover picture, not the film.
const AV_DISPOSITION_ATTACHED_PIC: c_int = 0x0400;
/// `AVMEDIA_TYPE_VIDEO`, `AVMEDIA_TYPE_AUDIO`.
const AVMEDIA_TYPE_VIDEO: c_int = 0;
const AVMEDIA_TYPE_AUDIO: c_int = 1;
/// `AV_CODEC_ID_H264`, `AV_CODEC_ID_HEVC`, `AV_CODEC_ID_AAC` (n6.0).
pub const AV_CODEC_ID_H264: c_int = 27;
pub const AV_CODEC_ID_HEVC: c_int = 173;
pub const AV_CODEC_ID_AAC: c_int = 0x15002;
/// How much the custom I/O context asks of a [`Source`] at a time.
const IO_BUFFER: usize = 256 * 1024;

/// `AVRational`.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rational {
    pub num: c_int,
    pub den: c_int,
}

/// `AVFormatContext`, n6.0, up to `duration`.
#[repr(C)]
struct AVFormatContext {
    av_class: *const c_void,
    iformat: *const c_void,
    oformat: *const c_void,
    priv_data: *mut c_void,
    pb: *mut AVIOContext,
    ctx_flags: c_int,
    nb_streams: c_uint,
    streams: *mut *mut AVStream,
    url: *mut c_char,
    start_time: i64,
    duration: i64,
}

/// `AVStream`, n6.0, up to `disposition`.
#[repr(C)]
struct AVStream {
    av_class: *const c_void,
    index: c_int,
    id: c_int,
    codecpar: *mut AVCodecParameters,
    priv_data: *mut c_void,
    time_base: Rational,
    start_time: i64,
    duration: i64,
    nb_frames: i64,
    disposition: c_int,
}

/// `AVChannelLayout`, n6.0, up to its union, whose `uint64_t` is what
/// aligns the struct -- and so where `ch_layout` sits -- to eight bytes.
#[repr(C)]
struct AVChannelLayout {
    order: c_int,
    nb_channels: c_int,
    mask: u64,
}

/// `AVCodecParameters`, n6.0 (with `FF_API_OLD_CHANNEL_LAYOUT`, which 6.x
/// keeps), up to the start of `ch_layout`.
#[repr(C)]
struct AVCodecParameters {
    codec_type: c_int,
    codec_id: c_int,
    codec_tag: u32,
    extradata: *mut u8,
    extradata_size: c_int,
    format: c_int,
    bit_rate: i64,
    bits_per_coded_sample: c_int,
    bits_per_raw_sample: c_int,
    profile: c_int,
    level: c_int,
    width: c_int,
    height: c_int,
    sample_aspect_ratio: Rational,
    field_order: c_int,
    color_range: c_int,
    color_primaries: c_int,
    color_trc: c_int,
    color_space: c_int,
    chroma_location: c_int,
    video_delay: c_int,
    channel_layout: u64,
    channels: c_int,
    sample_rate: c_int,
    block_align: c_int,
    frame_size: c_int,
    initial_padding: c_int,
    trailing_padding: c_int,
    seek_preroll: c_int,
    ch_layout: AVChannelLayout,
}

/// `AVPacket`, n6.0, up to `duration`.
#[repr(C)]
struct AVPacket {
    buf: *mut c_void,
    pts: i64,
    dts: i64,
    data: *mut u8,
    size: c_int,
    stream_index: c_int,
    flags: c_int,
    side_data: *mut c_void,
    side_data_elems: c_int,
    duration: i64,
}

/// `AVIOContext`, up to `buffer`, which the context may have reallocated
/// and is ours to free.
#[repr(C)]
struct AVIOContext {
    av_class: *const c_void,
    buffer: *mut u8,
}

/// The offsets `tool/libav_offsets.sh` measured, asserted where the
/// compiler can refuse the build: a prefix transcribed wrong does not
/// compile, on the host or on either Android ABI.
mod layout {
    use super::*;
    use std::mem::offset_of;

    macro_rules! at {
        ($kind:ident . $field:ident, $wide:expr, $narrow:expr) => {
            const _: () = assert!(
                offset_of!($kind, $field)
                    == if cfg!(target_pointer_width = "64") {
                        $wide
                    } else {
                        $narrow
                    }
            );
        };
    }

    at!(AVFormatContext.pb, 32, 16);
    at!(AVFormatContext.nb_streams, 44, 24);
    at!(AVFormatContext.streams, 48, 28);
    at!(AVFormatContext.start_time, 64, 40);
    at!(AVFormatContext.duration, 72, 48);
    at!(AVStream.index, 8, 4);
    at!(AVStream.codecpar, 16, 12);
    at!(AVStream.time_base, 32, 20);
    at!(AVStream.disposition, 64, 56);
    at!(AVCodecParameters.codec_type, 0, 0);
    at!(AVCodecParameters.codec_id, 4, 4);
    at!(AVCodecParameters.extradata, 16, 12);
    at!(AVCodecParameters.extradata_size, 24, 16);
    at!(AVCodecParameters.width, 56, 48);
    at!(AVCodecParameters.height, 60, 52);
    at!(AVCodecParameters.sample_rate, 116, 108);
    at!(AVCodecParameters.ch_layout, 144, 136);
    at!(AVChannelLayout.nb_channels, 4, 4);
    at!(AVPacket.pts, 8, 8);
    at!(AVPacket.dts, 16, 16);
    at!(AVPacket.data, 24, 24);
    at!(AVPacket.size, 32, 28);
    at!(AVPacket.stream_index, 36, 32);
    at!(AVPacket.flags, 40, 36);
    at!(AVPacket.duration, 64, 48);
    at!(AVIOContext.buffer, 8, 4);
}

type ReadFn = unsafe extern "C" fn(*mut c_void, *mut u8, c_int) -> c_int;
type WriteFn = unsafe extern "C" fn(*mut c_void, *mut u8, c_int) -> c_int;
type SeekFn = unsafe extern "C" fn(*mut c_void, i64, c_int) -> i64;

/// The FFmpeg functions this crate calls, resolved from one library.
pub struct Libav {
    avformat_alloc_context: unsafe extern "C" fn() -> *mut AVFormatContext,
    avformat_open_input: unsafe extern "C" fn(
        *mut *mut AVFormatContext,
        *const c_char,
        *const c_void,
        *mut *mut c_void,
    ) -> c_int,
    avformat_close_input: unsafe extern "C" fn(*mut *mut AVFormatContext),
    avformat_find_stream_info:
        unsafe extern "C" fn(*mut AVFormatContext, *mut *mut c_void) -> c_int,
    av_read_frame: unsafe extern "C" fn(*mut AVFormatContext, *mut AVPacket) -> c_int,
    av_seek_frame: unsafe extern "C" fn(*mut AVFormatContext, c_int, i64, c_int) -> c_int,
    avio_alloc_context: unsafe extern "C" fn(
        *mut u8,
        c_int,
        c_int,
        *mut c_void,
        Option<ReadFn>,
        Option<WriteFn>,
        Option<SeekFn>,
    ) -> *mut AVIOContext,
    avio_context_free: unsafe extern "C" fn(*mut *mut AVIOContext),
    av_packet_alloc: unsafe extern "C" fn() -> *mut AVPacket,
    av_packet_free: unsafe extern "C" fn(*mut *mut AVPacket),
    av_packet_unref: unsafe extern "C" fn(*mut AVPacket),
    av_malloc: unsafe extern "C" fn(usize) -> *mut c_void,
    av_free: unsafe extern "C" fn(*mut c_void),
    _library: libloading::Library,
}

impl Libav {
    /// The functions from the library at `path` -- libmpv on Android, or
    /// any library whose dependencies are libavformat, libavcodec and
    /// libavutil -- refused unless all three are the majors the layouts
    /// here were measured for.
    pub fn load(path: &str) -> Result<Self, String> {
        // SAFETY: the app's libmpv is already loaded (media_kit loaded it),
        // so this takes one more reference and runs no initialiser; a test
        // loads a system libmpv, whose initialisers have no preconditions.
        let library = unsafe { libloading::Library::new(path) }
            .map_err(|error| format!("could not open {path}: {error}"))?;
        // SAFETY: each symbol is the FFmpeg function of that name, and the
        // type it is read as is that function's n6.0 C signature.
        unsafe {
            let version = |name: &[u8]| -> Result<u32, String> {
                let get = library
                    .get::<unsafe extern "C" fn() -> c_uint>(name)
                    .map_err(|error| error.to_string())?;
                Ok(get() >> 16)
            };
            let found = (
                version(b"avformat_version\0")?,
                version(b"avcodec_version\0")?,
                version(b"avutil_version\0")?,
            );
            if found != (AVFORMAT_MAJOR, AVCODEC_MAJOR, AVUTIL_MAJOR) {
                return Err(format!(
                    "the library's FFmpeg is libavformat {}, libavcodec {}, libavutil {}; \
                     this build reads {AVFORMAT_MAJOR}, {AVCODEC_MAJOR}, {AVUTIL_MAJOR}",
                    found.0, found.1, found.2
                ));
            }
            macro_rules! symbol {
                ($name:literal) => {
                    *library
                        .get(concat!($name, "\0").as_bytes())
                        .map_err(|error| format!("{}: {error}", $name))?
                };
            }
            Ok(Self {
                avformat_alloc_context: symbol!("avformat_alloc_context"),
                avformat_open_input: symbol!("avformat_open_input"),
                avformat_close_input: symbol!("avformat_close_input"),
                avformat_find_stream_info: symbol!("avformat_find_stream_info"),
                av_read_frame: symbol!("av_read_frame"),
                av_seek_frame: symbol!("av_seek_frame"),
                avio_alloc_context: symbol!("avio_alloc_context"),
                avio_context_free: symbol!("avio_context_free"),
                av_packet_alloc: symbol!("av_packet_alloc"),
                av_packet_free: symbol!("av_packet_free"),
                av_packet_unref: symbol!("av_packet_unref"),
                av_malloc: symbol!("av_malloc"),
                av_free: symbol!("av_free"),
                _library: library,
            })
        }
    }

    /// The functions from the libmpv the player registered its protocol
    /// with ([`crate::mpv_stream::registered_libmpv`]), loaded once per
    /// process. An error until a player has registered: the library's path
    /// is Dart's to tell, and only a player knows it.
    pub fn registered() -> Result<&'static Self, String> {
        static LOADED: OnceLock<(String, Result<Libav, String>)> = OnceLock::new();
        let path = crate::mpv_stream::registered_libmpv()
            .ok_or("no player has loaded libmpv in this process yet")?;
        let (loaded_from, loaded) = LOADED.get_or_init(|| (path.to_owned(), Self::load(path)));
        if loaded_from != path {
            return Err("libmpv was loaded from another path in this process".to_owned());
        }
        loaded.as_ref().map_err(Clone::clone)
    }
}

// --- Sources ---------------------------------------------------------------------

/// What a [`Demuxer`] reads: blocking, positioned, of known length. The
/// server's [`MediaReader`] in the app.
pub trait Source: Send {
    /// Up to `buf.len()` bytes from the position, at least one unless at
    /// the end (`Ok(0)`).
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize>;
    /// Move to `offset`; answers where the source is.
    fn seek(&mut self, offset: u64) -> io::Result<u64>;
    /// The length in bytes.
    fn length(&self) -> u64;
}

impl Source for MediaReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        MediaReader::read(self, buf)
    }

    fn seek(&mut self, offset: u64) -> io::Result<u64> {
        MediaReader::seek(self, offset)
    }

    fn length(&self) -> u64 {
        MediaReader::len(self)
    }
}

impl Source for io::Cursor<Bytes> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        io::Read::read(self, buf)
    }

    fn seek(&mut self, offset: u64) -> io::Result<u64> {
        io::Seek::seek(self, io::SeekFrom::Start(offset))
    }

    fn length(&self) -> u64 {
        self.get_ref().len() as u64
    }
}

/// What the I/O callbacks reach through their `opaque`: the source, where
/// it is, and whether it failed, for the log line that says why a read
/// stopped.
struct Io<S: Source> {
    source: S,
    pos: u64,
    len: u64,
    failed: Option<io::ErrorKind>,
}

/// `read_packet`: bytes read, `AVERROR_EOF` at the end, `AVERROR(EIO)` when
/// the source fails -- a cancel's included.
unsafe extern "C" fn read_cb<S: Source>(opaque: *mut c_void, buf: *mut u8, size: c_int) -> c_int {
    // SAFETY: `opaque` is the `Io<S>` the demuxer owns, alive for as long
    // as the context that calls this; libavformat makes one call at a time.
    let io = unsafe { &mut *opaque.cast::<Io<S>>() };
    let Ok(size) = usize::try_from(size) else {
        return AVERROR_EINVAL;
    };
    if size == 0 {
        return 0;
    }
    // SAFETY: libavformat's buffer holds at least `size` bytes.
    let out = unsafe { std::slice::from_raw_parts_mut(buf, size) };
    let read = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| io.source.read(out)));
    match read {
        Ok(Ok(0)) => AVERROR_EOF,
        Ok(Ok(n)) => {
            io.pos += n as u64;
            c_int::try_from(n).unwrap_or(AVERROR_EIO)
        }
        Ok(Err(error)) => {
            io.failed = Some(error.kind());
            AVERROR_EIO
        }
        Err(_) => {
            io.failed = Some(io::ErrorKind::Other);
            AVERROR_EIO
        }
    }
}

/// `seek`: the offset the source is at, the length for `AVSEEK_SIZE`, an
/// error for an offset outside the file. A seek to where the source is
/// does not touch it (a reopen, for a torrent).
unsafe extern "C" fn seek_cb<S: Source>(opaque: *mut c_void, offset: i64, whence: c_int) -> i64 {
    // SAFETY: as in `read_cb`.
    let io = unsafe { &mut *opaque.cast::<Io<S>>() };
    let whence = whence & !AVSEEK_FORCE;
    if whence == AVSEEK_SIZE {
        return i64::try_from(io.len).unwrap_or(i64::from(AVERROR_EINVAL));
    }
    let base = match whence {
        0 => 0,
        1 => io.pos as i64,
        2 => io.len as i64,
        _ => return i64::from(AVERROR_EINVAL),
    };
    let Some(target) = base
        .checked_add(offset)
        .and_then(|target| u64::try_from(target).ok())
        .filter(|target| *target <= io.len)
    else {
        return i64::from(AVERROR_EINVAL);
    };
    if target == io.pos {
        return target as i64;
    }
    let seek = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| io.source.seek(target)));
    match seek {
        Ok(Ok(at)) => {
            io.pos = at;
            at as i64
        }
        Ok(Err(error)) => {
            io.failed = Some(error.kind());
            i64::from(AVERROR_EIO)
        }
        Err(_) => {
            io.failed = Some(io::ErrorKind::Other);
            i64::from(AVERROR_EIO)
        }
    }
}

// --- The demuxer -----------------------------------------------------------------

/// What kind of stream.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Video,
    Audio,
    Other,
}

/// One stream of the file, as its header describes it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StreamInfo {
    pub index: usize,
    pub kind: Kind,
    /// `AVCodecID`.
    pub codec: c_int,
    /// A cover picture: a video stream that is not the film.
    pub attached_picture: bool,
    /// The codec configuration as the container carries it: an `avcC`
    /// for Matroska's H.264, the AudioSpecificConfig for its AAC.
    pub extradata: Bytes,
    pub width: u32,
    pub height: u32,
    pub sample_rate: u32,
    pub channels: u32,
    pub time_base: Rational,
}

/// One packet, as `av_read_frame` handed it out.
#[derive(Clone, Debug)]
pub struct Packet {
    pub stream: usize,
    /// In the stream's time base; [`NOPTS`] when unknown.
    pub pts: i64,
    pub dts: i64,
    pub duration: i64,
    pub key: bool,
    pub data: Bytes,
}

/// What the next read found.
#[derive(Debug)]
pub enum Next {
    Packet(Packet),
    /// The film ended.
    End,
    /// The source failed or the file cannot be read on; for the log.
    Failed(String),
}

/// A file being demuxed, over a [`Source`] read through a custom
/// `AVIOContext`. Single-threaded: made, read and dropped on one thread.
pub struct Demuxer<S: Source> {
    libav: &'static Libav,
    ctx: *mut AVFormatContext,
    io: *mut AVIOContext,
    packet: *mut AVPacket,
    /// Boxed so its address -- the callbacks' `opaque` -- never moves.
    state: Box<Io<S>>,
    streams: Vec<StreamInfo>,
}

impl<S: Source> Demuxer<S> {
    /// Opens `source` and reads its header. The error is for the log.
    pub fn open(libav: &'static Libav, source: S) -> Result<Self, String> {
        let len = source.length();
        let mut demuxer = Self {
            libav,
            ctx: std::ptr::null_mut(),
            io: std::ptr::null_mut(),
            packet: std::ptr::null_mut(),
            state: Box::new(Io {
                source,
                pos: 0,
                len,
                failed: None,
            }),
            streams: Vec::new(),
        };
        // SAFETY: FFmpeg's documented custom-I/O sequence: a buffer from
        // av_malloc handed to avio_alloc_context, the context set as `pb`
        // before avformat_open_input; everything is freed in `Drop`, which
        // runs whatever fails below.
        unsafe {
            let buffer = (libav.av_malloc)(IO_BUFFER).cast::<u8>();
            if buffer.is_null() {
                return Err("no memory for the I/O buffer".to_owned());
            }
            let opaque = std::ptr::from_mut(demuxer.state.as_mut()).cast::<c_void>();
            demuxer.io = (libav.avio_alloc_context)(
                buffer,
                IO_BUFFER as c_int,
                0,
                opaque,
                Some(read_cb::<S>),
                None,
                Some(seek_cb::<S>),
            );
            if demuxer.io.is_null() {
                (libav.av_free)(buffer.cast());
                return Err("no memory for the I/O context".to_owned());
            }
            demuxer.packet = (libav.av_packet_alloc)();
            if demuxer.packet.is_null() {
                return Err("no memory for a packet".to_owned());
            }
            let mut ctx = (libav.avformat_alloc_context)();
            if ctx.is_null() {
                return Err("no memory for the format context".to_owned());
            }
            (*ctx).pb = demuxer.io;
            // On failure this frees the context and nulls `ctx`; the I/O
            // context stays ours.
            let opened = (libav.avformat_open_input)(
                &mut ctx,
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null_mut(),
            );
            if opened < 0 {
                return Err(demuxer.failure("the file's header could not be read", opened));
            }
            demuxer.ctx = ctx;
            // What mpv does after its open (`demux_lavf.c`), and for the
            // same reason here: it is what sets the container's
            // `start_time` -- the first timestamp of any stream, which is
            // the zero mpv's clock and the playlist count from. Matroska's
            // header does not carry it; the first packets do (an AAC
            // encoder's priming starts audio before zero). The packets it
            // reads are kept and handed out by the reads that follow.
            let found = (libav.avformat_find_stream_info)(ctx, std::ptr::null_mut());
            if found < 0 {
                return Err(demuxer.failure("the file's streams could not be read", found));
            }
            demuxer.streams = demuxer.read_streams();
        }
        Ok(demuxer)
    }

    /// Every stream the header names, in the file's order.
    pub fn streams(&self) -> &[StreamInfo] {
        &self.streams
    }

    /// Where the film starts, in microseconds: the container's first
    /// timestamp, which a player calls zero (mpv rebases to it). Zero when
    /// the container does not say.
    pub fn start_us(&self) -> i64 {
        // SAFETY: `ctx` is the open context.
        let start = unsafe { (*self.ctx).start_time };
        if start == NOPTS {
            0
        } else {
            start
        }
    }

    /// The film's length in microseconds, when the container says.
    pub fn duration_us(&self) -> Option<i64> {
        // SAFETY: `ctx` is the open context.
        let duration = unsafe { (*self.ctx).duration };
        (duration != NOPTS && duration > 0).then_some(duration)
    }

    /// Moves to the sync point at or before `at_us` on the film's clock
    /// (microseconds from [`Self::start_us`]).
    pub fn seek_us(&mut self, at_us: i64) -> Result<(), String> {
        let target = at_us.saturating_add(self.start_us());
        // SAFETY: `ctx` is the open context; stream -1 takes AV_TIME_BASE.
        let sought =
            unsafe { (self.libav.av_seek_frame)(self.ctx, -1, target, AVSEEK_FLAG_BACKWARD) };
        if sought < 0 {
            return Err(self.failure("the film could not be sought in", sought));
        }
        Ok(())
    }

    /// The next packet of any stream, the end, or why there is none.
    pub fn read_packet(&mut self) -> Next {
        // SAFETY: `ctx` and `packet` are live; the packet is unreferenced
        // before this returns, its bytes copied out first.
        unsafe {
            let read = (self.libav.av_read_frame)(self.ctx, self.packet);
            if read < 0 {
                // A source that failed answered `AVERROR(EIO)`, which comes
                // back out here as itself: only the file's end is the end.
                if read == AVERROR_EOF {
                    return Next::End;
                }
                return Next::Failed(self.failure("the film could not be read on", read));
            }
            let packet = &*self.packet;
            let data = if packet.data.is_null() || packet.size <= 0 {
                Bytes::new()
            } else {
                Bytes::copy_from_slice(std::slice::from_raw_parts(
                    packet.data,
                    packet.size as usize,
                ))
            };
            let out = Packet {
                stream: usize::try_from(packet.stream_index).unwrap_or(usize::MAX),
                pts: packet.pts,
                dts: packet.dts,
                duration: packet.duration,
                key: packet.flags & AV_PKT_FLAG_KEY != 0,
                data,
            };
            (self.libav.av_packet_unref)(self.packet);
            Next::Packet(out)
        }
    }

    fn failure(&self, what: &str, code: c_int) -> String {
        match self.state.failed {
            Some(kind) => format!("{what}: the source failed ({kind:?})"),
            None => format!("{what} (libavformat error {code})"),
        }
    }

    /// # Safety
    ///
    /// `ctx` is the open context.
    unsafe fn read_streams(&self) -> Vec<StreamInfo> {
        // SAFETY: the caller's contract; `streams` holds `nb_streams` live
        // pointers, each with its `codecpar`, for the context's life.
        unsafe {
            let ctx = &*self.ctx;
            let count = ctx.nb_streams as usize;
            if ctx.streams.is_null() {
                return Vec::new();
            }
            (0..count)
                .filter_map(|at| {
                    let stream = (*ctx.streams.add(at)).as_ref()?;
                    let par = stream.codecpar.as_ref()?;
                    let extradata = if par.extradata.is_null() || par.extradata_size <= 0 {
                        Bytes::new()
                    } else {
                        Bytes::copy_from_slice(std::slice::from_raw_parts(
                            par.extradata,
                            par.extradata_size as usize,
                        ))
                    };
                    let kind = match par.codec_type {
                        AVMEDIA_TYPE_VIDEO => Kind::Video,
                        AVMEDIA_TYPE_AUDIO => Kind::Audio,
                        _ => Kind::Other,
                    };
                    let positive = |value: c_int| u32::try_from(value).unwrap_or(0);
                    Some(StreamInfo {
                        index: usize::try_from(stream.index).unwrap_or(at),
                        kind,
                        codec: par.codec_id,
                        attached_picture: stream.disposition & AV_DISPOSITION_ATTACHED_PIC != 0,
                        extradata,
                        width: positive(par.width),
                        height: positive(par.height),
                        sample_rate: positive(par.sample_rate),
                        channels: positive(par.ch_layout.nb_channels),
                        time_base: stream.time_base,
                    })
                })
                .collect()
        }
    }
}

impl<S: Source> Drop for Demuxer<S> {
    fn drop(&mut self) {
        // SAFETY: each pointer is null or one this demuxer allocated and
        // still owns. The format context goes first (it does not free a
        // custom `pb`), then the I/O buffer -- read from the context, which
        // may have replaced it -- and the I/O context. `state` outlives all
        // of them, being a field dropped after this body.
        unsafe {
            if !self.ctx.is_null() {
                (self.libav.avformat_close_input)(&mut self.ctx);
            }
            if !self.io.is_null() {
                (self.libav.av_free)((*self.io).buffer.cast());
                (self.libav.avio_context_free)(&mut self.io);
            }
            if !self.packet.is_null() {
                (self.libav.av_packet_free)(&mut self.packet);
            }
        }
    }
}

/// A timestamp in `time_base` units as microseconds; `None` for
/// [`NOPTS`] or a time base that is not one.
pub fn to_us(ts: i64, time_base: Rational) -> Option<i64> {
    if ts == NOPTS || time_base.den <= 0 || time_base.num <= 0 {
        return None;
    }
    let scaled = i128::from(ts) * i128::from(time_base.num) * i128::from(TIME_BASE)
        / i128::from(time_base.den);
    i64::try_from(scaled).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_timestamp_is_rescaled_to_microseconds() {
        let ms = Rational { num: 1, den: 1000 };
        assert_eq!(to_us(40, ms), Some(40_000));
        assert_eq!(to_us(-23, ms), Some(-23_000));
        assert_eq!(to_us(NOPTS, ms), None);
        assert_eq!(
            to_us(
                3003,
                Rational {
                    num: 1,
                    den: 90_000
                }
            ),
            Some(33_366)
        );
        assert_eq!(to_us(1, Rational { num: 1, den: 0 }), None);
    }

    /// The callbacks a demuxer hands libavformat, driven by hand: a read
    /// counts the position on, the end is `AVERROR_EOF`, a seek answers the
    /// length for `AVSEEK_SIZE` and refuses outside the file, and a source
    /// that fails is remembered -- which is how the end of a film is told
    /// from a source that broke.
    #[test]
    fn the_io_callbacks_track_the_position_and_remember_a_failure() {
        /// The bytes, a switch that makes every read fail, and the seeks
        /// that reached it.
        struct Broken(io::Cursor<Bytes>, bool, Vec<u64>);
        impl Source for Broken {
            fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
                if self.1 {
                    return Err(io::Error::from(io::ErrorKind::Interrupted));
                }
                Source::read(&mut self.0, buf)
            }
            fn seek(&mut self, offset: u64) -> io::Result<u64> {
                self.2.push(offset);
                Source::seek(&mut self.0, offset)
            }
            fn length(&self) -> u64 {
                Source::length(&self.0)
            }
        }
        let mut io = Io {
            source: Broken(
                io::Cursor::new(Bytes::from_static(b"0123456789")),
                false,
                Vec::new(),
            ),
            pos: 0,
            len: 10,
            failed: None,
        };
        let opaque = std::ptr::from_mut(&mut io).cast::<c_void>();
        let mut buf = [0u8; 4];
        // SAFETY: a live `Io` and a four-byte buffer.
        unsafe {
            assert_eq!(read_cb::<Broken>(opaque, buf.as_mut_ptr(), 4), 4);
            assert_eq!(&buf, b"0123");
            assert_eq!(seek_cb::<Broken>(opaque, 0, AVSEEK_SIZE | AVSEEK_FORCE), 10);
            assert_eq!(seek_cb::<Broken>(opaque, 2, 1), 6, "from the position");
            assert_eq!(seek_cb::<Broken>(opaque, -1, 2), 9, "from the end");
            assert_eq!(read_cb::<Broken>(opaque, buf.as_mut_ptr(), 4), 1);
            assert_eq!(read_cb::<Broken>(opaque, buf.as_mut_ptr(), 4), AVERROR_EOF);
            assert_eq!(seek_cb::<Broken>(opaque, 11, 0), i64::from(AVERROR_EINVAL));
            assert_eq!(seek_cb::<Broken>(opaque, 3, 0), 3);
            assert_eq!(seek_cb::<Broken>(opaque, 0, 1), 3, "where it is already");
        }
        assert_eq!(io.failed, None, "an end is not a failure");
        assert_eq!(
            io.source.2,
            vec![6, 9, 3],
            "a seek to where the source is does not reach it (a reopen, for a torrent)"
        );
        io.source.1 = true;
        let opaque = std::ptr::from_mut(&mut io).cast::<c_void>();
        // SAFETY: as above.
        unsafe {
            assert_eq!(read_cb::<Broken>(opaque, buf.as_mut_ptr(), 4), AVERROR_EIO);
        }
        assert_eq!(io.failed, Some(io::ErrorKind::Interrupted));
    }
}
