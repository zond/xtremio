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

/// What a sentence calls the codec `id` (an n6.0 `AVCodecID`), for the
/// ones a film is likely to carry; `None` for the rest.
pub fn codec_name(id: c_int) -> Option<&'static str> {
    Some(match id {
        AV_CODEC_ID_H264 => "H.264",
        AV_CODEC_ID_HEVC => "HEVC",
        226 => "AV1",
        167 => "VP9",
        139 => "VP8",
        12 => "MPEG-4 Part 2",
        2 => "MPEG-2",
        70 => "VC-1",
        AV_CODEC_ID_AAC => "AAC",
        86019 => "Dolby Digital (AC3)",
        86056 => "Dolby Digital Plus (E-AC3)",
        86060 => "Dolby TrueHD",
        86020 => "DTS",
        86028 => "FLAC",
        86076 => "Opus",
        86017 => "MP3",
        86016 => "MP2",
        86021 => "Vorbis",
        _ => return None,
    })
}
/// How much the custom I/O context asks of a [`Source`] at a time.
const IO_BUFFER: usize = 256 * 1024;

/// `AVRational`.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rational {
    pub num: c_int,
    pub den: c_int,
}

/// `AVInputFormat`, n6.0, up to `name`.
#[repr(C)]
struct AVInputFormat {
    name: *const c_char,
}

/// `AVIndexEntry`, n6.0, whole: `int flags:2; int size:30;` is one `int`
/// whose two low bits -- on every little-endian ABI this is built for --
/// are the flags.
#[repr(C)]
struct AVIndexEntry {
    pos: i64,
    timestamp: i64,
    flags_and_size: c_int,
    min_distance: c_int,
}

/// `AVINDEX_KEYFRAME`.
const AVINDEX_KEYFRAME: c_int = 1;

/// `AVFormatContext`, n6.0, up to `duration`.
#[repr(C)]
struct AVFormatContext {
    av_class: *const c_void,
    iformat: *const AVInputFormat,
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

/// `AVStream`, n6.0, up to `nb_side_data` (deprecated in 6.1, which still
/// fills it from the codec parameters' side data, and gone in 7.0 -- where
/// the major check refuses the library anyway).
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
    discard: c_int,
    sample_aspect_ratio: Rational,
    metadata: *mut c_void,
    avg_frame_rate: Rational,
    attached_pic: AVPacket,
    side_data: *const AVPacketSideData,
    nb_side_data: c_int,
}

/// `AVPacketSideData`, n6.0, whole.
#[repr(C)]
struct AVPacketSideData {
    data: *const u8,
    size: usize,
    kind: c_int,
}

/// `AV_PKT_DATA_DOVI_CONF`: an `AVDOVIDecoderConfigurationRecord`, the
/// Dolby Vision configuration a container carries (Matroska's `dvcC`/`dvvC`
/// block addition mapping, an MP4's `dvcC`/`dvvC` box, a transport
/// stream's descriptor).
const AV_PKT_DATA_DOVI_CONF: c_int = 29;

/// `AVChannelLayout`, n6.0, whole: its union's `uint64_t` (the mask, for
/// the native order) is what aligns the struct -- and so where `ch_layout`
/// sits -- to eight bytes. Whole, because the sound's conversion hands one
/// to FFmpeg by pointer ([`STEREO`]).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct AVChannelLayout {
    order: c_int,
    nb_channels: c_int,
    mask: u64,
    opaque: *mut c_void,
}

/// `AV_CHANNEL_ORDER_NATIVE`: positions as a mask.
const AV_CHANNEL_ORDER_NATIVE: c_int = 1;
/// `AV_CH_LAYOUT_STEREO`'s layout: front left and right.
const STEREO: AVChannelLayout = AVChannelLayout {
    order: AV_CHANNEL_ORDER_NATIVE,
    nb_channels: 2,
    mask: 0x3,
    opaque: std::ptr::null_mut(),
};

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

/// `AVPacket`, n6.0, whole: [`AVStream`] holds one by value.
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
    pos: i64,
    opaque: *mut c_void,
    opaque_ref: *mut c_void,
    time_base: Rational,
}

/// `AVFrame`, n6.0, up to `ch_layout`: the sound the decoder hands out and
/// the encoder takes. Every field through the deprecated ones 6.x keeps
/// (`coded_picture_number`, `reordered_opaque`, `channel_layout`,
/// `pkt_duration`, `channels`), since they come before `ch_layout`.
#[repr(C)]
struct AVFrame {
    data: [*mut u8; 8],
    linesize: [c_int; 8],
    extended_data: *mut *mut u8,
    width: c_int,
    height: c_int,
    nb_samples: c_int,
    format: c_int,
    key_frame: c_int,
    pict_type: c_int,
    sample_aspect_ratio: Rational,
    pts: i64,
    pkt_dts: i64,
    time_base: Rational,
    coded_picture_number: c_int,
    display_picture_number: c_int,
    quality: c_int,
    opaque: *mut c_void,
    repeat_pict: c_int,
    interlaced_frame: c_int,
    top_field_first: c_int,
    palette_has_changed: c_int,
    reordered_opaque: i64,
    sample_rate: c_int,
    channel_layout: u64,
    buf: [*mut c_void; 8],
    extended_buf: *mut *mut c_void,
    nb_extended_buf: c_int,
    side_data: *mut *mut c_void,
    nb_side_data: c_int,
    flags: c_int,
    color_range: c_int,
    color_primaries: c_int,
    color_trc: c_int,
    colorspace: c_int,
    chroma_location: c_int,
    best_effort_timestamp: i64,
    pkt_pos: i64,
    pkt_duration: i64,
    metadata: *mut c_void,
    decode_error_flags: c_int,
    channels: c_int,
    pkt_size: c_int,
    hw_frames_ctx: *mut c_void,
    opaque_ref: *mut c_void,
    crop_top: usize,
    crop_bottom: usize,
    crop_left: usize,
    crop_right: usize,
    private_ref: *mut c_void,
    ch_layout: AVChannelLayout,
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

    at!(AVFormatContext.iformat, 8, 4);
    at!(AVFormatContext.pb, 32, 16);
    at!(AVFormatContext.nb_streams, 44, 24);
    at!(AVFormatContext.streams, 48, 28);
    at!(AVFormatContext.start_time, 64, 40);
    at!(AVFormatContext.duration, 72, 48);
    at!(AVStream.index, 8, 4);
    at!(AVStream.codecpar, 16, 12);
    at!(AVStream.time_base, 32, 20);
    at!(AVStream.disposition, 64, 56);
    at!(AVStream.attached_pic, 96, 88);
    at!(AVStream.side_data, 200, 168);
    at!(AVStream.nb_side_data, 208, 172);
    at!(AVPacketSideData.size, 8, 4);
    at!(AVPacketSideData.kind, 16, 8);
    const _: () = assert!(
        std::mem::size_of::<AVPacketSideData>()
            == if cfg!(target_pointer_width = "64") {
                24
            } else {
                12
            }
    );
    at!(AVCodecParameters.codec_type, 0, 0);
    at!(AVCodecParameters.codec_id, 4, 4);
    at!(AVCodecParameters.extradata, 16, 12);
    at!(AVCodecParameters.extradata_size, 24, 16);
    at!(AVCodecParameters.width, 56, 48);
    at!(AVCodecParameters.height, 60, 52);
    at!(AVCodecParameters.sample_rate, 116, 108);
    at!(AVCodecParameters.ch_layout, 144, 136);
    at!(AVCodecParameters.format, 28, 20);
    at!(AVCodecParameters.bit_rate, 32, 24);
    at!(AVChannelLayout.nb_channels, 4, 4);
    at!(AVChannelLayout.mask, 8, 8);
    at!(AVChannelLayout.opaque, 16, 16);
    const _: () = assert!(std::mem::size_of::<AVChannelLayout>() == 24);
    at!(AVFrame.extended_data, 96, 64);
    at!(AVFrame.nb_samples, 112, 76);
    at!(AVFrame.format, 116, 80);
    at!(AVFrame.pts, 136, 104);
    at!(AVFrame.sample_rate, 208, 168);
    at!(AVFrame.ch_layout, 448, 328);
    at!(AVPacket.pts, 8, 8);
    at!(AVPacket.dts, 16, 16);
    at!(AVPacket.data, 24, 24);
    at!(AVPacket.size, 32, 28);
    at!(AVPacket.stream_index, 36, 32);
    at!(AVPacket.flags, 40, 36);
    at!(AVPacket.duration, 64, 48);
    const _: () = assert!(
        std::mem::size_of::<AVPacket>()
            == if cfg!(target_pointer_width = "64") {
                104
            } else {
                80
            }
    );
    at!(AVIOContext.buffer, 8, 4);
    at!(AVIndexEntry.timestamp, 8, 8);
    at!(AVIndexEntry.flags_and_size, 16, 16);
    const _: () = assert!(std::mem::size_of::<AVIndexEntry>() == 24);
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
    avformat_index_get_entries_count: unsafe extern "C" fn(*const AVStream) -> c_int,
    avformat_index_get_entry: unsafe extern "C" fn(*mut AVStream, c_int) -> *const AVIndexEntry,
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
    /// What converting sound needs (libavcodec's codecs, libswresample),
    /// looked up apart: a libmpv without them still repackages.
    codecs: Result<Codecs, String>,
    _library: libloading::Library,
}

/// The functions that decode, resample and encode sound, resolved from the
/// same library as [`Libav`]'s.
struct Codecs {
    avcodec_find_decoder: unsafe extern "C" fn(c_int) -> *const c_void,
    avcodec_find_encoder_by_name: unsafe extern "C" fn(*const c_char) -> *const c_void,
    avcodec_alloc_context3: unsafe extern "C" fn(*const c_void) -> *mut c_void,
    avcodec_free_context: unsafe extern "C" fn(*mut *mut c_void),
    avcodec_parameters_alloc: unsafe extern "C" fn() -> *mut AVCodecParameters,
    avcodec_parameters_free: unsafe extern "C" fn(*mut *mut AVCodecParameters),
    avcodec_parameters_copy:
        unsafe extern "C" fn(*mut AVCodecParameters, *const AVCodecParameters) -> c_int,
    avcodec_parameters_to_context:
        unsafe extern "C" fn(*mut c_void, *const AVCodecParameters) -> c_int,
    avcodec_open2: unsafe extern "C" fn(*mut c_void, *const c_void, *mut *mut c_void) -> c_int,
    avcodec_send_packet: unsafe extern "C" fn(*mut c_void, *const AVPacket) -> c_int,
    avcodec_receive_frame: unsafe extern "C" fn(*mut c_void, *mut AVFrame) -> c_int,
    avcodec_send_frame: unsafe extern "C" fn(*mut c_void, *const AVFrame) -> c_int,
    avcodec_receive_packet: unsafe extern "C" fn(*mut c_void, *mut AVPacket) -> c_int,
    av_frame_alloc: unsafe extern "C" fn() -> *mut AVFrame,
    av_frame_free: unsafe extern "C" fn(*mut *mut AVFrame),
    av_frame_unref: unsafe extern "C" fn(*mut AVFrame),
    av_frame_get_buffer: unsafe extern "C" fn(*mut AVFrame, c_int) -> c_int,
    av_new_packet: unsafe extern "C" fn(*mut AVPacket, c_int) -> c_int,
    #[allow(clippy::type_complexity)]
    swr_alloc_set_opts2: unsafe extern "C" fn(
        *mut *mut c_void,
        *const AVChannelLayout,
        c_int,
        c_int,
        *const AVChannelLayout,
        c_int,
        c_int,
        c_int,
        *mut c_void,
    ) -> c_int,
    swr_init: unsafe extern "C" fn(*mut c_void) -> c_int,
    swr_convert:
        unsafe extern "C" fn(*mut c_void, *mut *mut u8, c_int, *const *const u8, c_int) -> c_int,
    swr_free: unsafe extern "C" fn(*mut *mut c_void),
    av_opt_set_double: unsafe extern "C" fn(*mut c_void, *const c_char, f64, c_int) -> c_int,
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
                avformat_index_get_entries_count: symbol!("avformat_index_get_entries_count"),
                avformat_index_get_entry: symbol!("avformat_index_get_entry"),
                avio_alloc_context: symbol!("avio_alloc_context"),
                avio_context_free: symbol!("avio_context_free"),
                av_packet_alloc: symbol!("av_packet_alloc"),
                av_packet_free: symbol!("av_packet_free"),
                av_packet_unref: symbol!("av_packet_unref"),
                av_malloc: symbol!("av_malloc"),
                av_free: symbol!("av_free"),
                codecs: Codecs::load(&library),
                _library: library,
            })
        }
    }

    /// The sound conversion's functions, or why this library has none.
    fn codecs(&self) -> Result<&Codecs, String> {
        self.codecs.as_ref().map_err(Clone::clone)
    }

    /// Whether this library has FFmpeg's own AAC encoder: a desktop's
    /// system FFmpeg does, the libmpv an Android build ships does not
    /// (`--disable-encoders`), which encodes with `MediaCodec` instead.
    pub fn has_aac_encoder(&self) -> bool {
        self.codecs().is_ok_and(|codecs| {
            // SAFETY: a static string, a lookup that allocates nothing.
            !unsafe { (codecs.avcodec_find_encoder_by_name)(c"aac".as_ptr()) }.is_null()
        })
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

impl Codecs {
    fn load(library: &libloading::Library) -> Result<Self, String> {
        // SAFETY: each symbol is the FFmpeg function of that name, read as
        // its n6.0 C signature.
        unsafe {
            macro_rules! symbol {
                ($name:literal) => {
                    *library
                        .get(concat!($name, "\0").as_bytes())
                        .map_err(|error| format!("{}: {error}", $name))?
                };
            }
            Ok(Self {
                avcodec_find_decoder: symbol!("avcodec_find_decoder"),
                avcodec_find_encoder_by_name: symbol!("avcodec_find_encoder_by_name"),
                avcodec_alloc_context3: symbol!("avcodec_alloc_context3"),
                avcodec_free_context: symbol!("avcodec_free_context"),
                avcodec_parameters_alloc: symbol!("avcodec_parameters_alloc"),
                avcodec_parameters_free: symbol!("avcodec_parameters_free"),
                avcodec_parameters_copy: symbol!("avcodec_parameters_copy"),
                avcodec_parameters_to_context: symbol!("avcodec_parameters_to_context"),
                avcodec_open2: symbol!("avcodec_open2"),
                avcodec_send_packet: symbol!("avcodec_send_packet"),
                avcodec_receive_frame: symbol!("avcodec_receive_frame"),
                avcodec_send_frame: symbol!("avcodec_send_frame"),
                avcodec_receive_packet: symbol!("avcodec_receive_packet"),
                av_frame_alloc: symbol!("av_frame_alloc"),
                av_frame_free: symbol!("av_frame_free"),
                av_frame_unref: symbol!("av_frame_unref"),
                av_frame_get_buffer: symbol!("av_frame_get_buffer"),
                av_new_packet: symbol!("av_new_packet"),
                swr_alloc_set_opts2: symbol!("swr_alloc_set_opts2"),
                swr_init: symbol!("swr_init"),
                swr_convert: symbol!("swr_convert"),
                swr_free: symbol!("swr_free"),
                av_opt_set_double: symbol!("av_opt_set_double"),
            })
        }
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
    /// The Dolby Vision configuration the container declares for this
    /// stream, if it declares one.
    pub dolby_vision: Option<DolbyVision>,
}

/// A Dolby Vision configuration record (`AVDOVIDecoderConfigurationRecord`,
/// the `dvcC`/`dvvC` of the Dolby Vision streams specification): which
/// profile, and what the base layer is to a decoder that knows nothing of
/// Dolby Vision.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DolbyVision {
    pub profile: u8,
    pub level: u8,
    /// `dv_bl_signal_compatibility_id`: 0 for a base layer only a Dolby
    /// Vision decoder shows right (profile 5's IPT-PQ-c2), 1 for HDR10,
    /// 2 for SDR, 4 for HLG, 6 for a Blu-ray's HDR10 (profile 7).
    pub compatibility: u8,
}

impl DolbyVision {
    /// From the record as FFmpeg holds it, a byte per field: version major
    /// and minor, profile, level, three presence flags, then the
    /// compatibility id.
    pub fn of_record(record: &[u8]) -> Option<Self> {
        Some(Self {
            profile: *record.get(2)?,
            level: *record.get(3)?,
            compatibility: *record.get(7)?,
        })
    }
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

/// One entry of a stream's index, as libavformat holds it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct IndexEntry {
    /// Where in the file: the sample, or the container unit that holds it
    /// (a Matroska cluster).
    pub pos: i64,
    /// In the stream's time base.
    pub timestamp: i64,
    pub keyframe: bool,
}

/// What the next read found.
#[derive(Clone, Debug)]
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

    /// The FFmpeg it reads with.
    pub fn libav(&self) -> &'static Libav {
        self.libav
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

    /// The demuxer's name, as libavformat calls it: `matroska,webm`,
    /// `mov,mp4,m4a,3gp,3g2,mj2`, `avi`, `mpegts`, ...
    pub fn format_name(&self) -> String {
        // SAFETY: `ctx` is the open context; `iformat` and its name are
        // static strings of the library's.
        unsafe {
            let format = (*self.ctx).iformat;
            if format.is_null() || (*format).name.is_null() {
                return String::new();
            }
            std::ffi::CStr::from_ptr((*format).name)
                .to_string_lossy()
                .into_owned()
        }
    }

    /// Stream `stream`'s index as libavformat holds it now: an MP4's every
    /// sample (from its sample tables), an AVI's `idx1`, Matroska's cues
    /// once a seek has made it read them, or the few entries a demuxer adds
    /// as it reads a file with none.
    pub fn index_entries(&self, stream: usize) -> Vec<IndexEntry> {
        // SAFETY: `ctx` is the open context and `stream` one of its streams;
        // each entry is read while the index is not changed (nothing reads
        // or seeks meanwhile, on this one thread).
        unsafe {
            let ctx = &*self.ctx;
            if ctx.streams.is_null() || stream >= ctx.nb_streams as usize {
                return Vec::new();
            }
            let st = *ctx.streams.add(stream);
            let count = (self.libav.avformat_index_get_entries_count)(st);
            (0..count)
                .filter_map(|at| {
                    let entry = (self.libav.avformat_index_get_entry)(st, at).as_ref()?;
                    Some(IndexEntry {
                        pos: entry.pos,
                        timestamp: entry.timestamp,
                        keyframe: entry.flags_and_size & AVINDEX_KEYFRAME != 0,
                    })
                })
                .collect()
        }
    }

    /// Up to `len` bytes of the source at `offset`, read past libavformat,
    /// which finds the source where it left it: what it reads next comes
    /// from its own buffer or a seek of its own.
    pub fn read_source_at(&mut self, offset: u64, len: usize) -> io::Result<Vec<u8>> {
        let state = self.state.as_mut();
        let len = len.min(usize::try_from(state.len.saturating_sub(offset)).unwrap_or(len));
        let mut out = vec![0u8; len];
        let read = (|| {
            state.source.seek(offset)?;
            let mut filled = 0;
            while filled < len {
                let n = state.source.read(&mut out[filled..])?;
                if n == 0 {
                    break;
                }
                filled += n;
            }
            Ok::<_, io::Error>(filled)
        })();
        let back = state.source.seek(state.pos);
        let filled = read?;
        back?;
        out.truncate(filled);
        Ok(out)
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
                    let side_data = if stream.side_data.is_null() || stream.nb_side_data <= 0 {
                        &[][..]
                    } else {
                        std::slice::from_raw_parts(stream.side_data, stream.nb_side_data as usize)
                    };
                    let dolby_vision = side_data
                        .iter()
                        .filter(|side| side.kind == AV_PKT_DATA_DOVI_CONF && !side.data.is_null())
                        .find_map(|side| {
                            DolbyVision::of_record(std::slice::from_raw_parts(side.data, side.size))
                        });
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
                        dolby_vision,
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

// --- Sound ----------------------------------------------------------------------

/// `AV_SAMPLE_FMT_FLT`: interleaved 32-bit float, what the decoded sound is
/// converted to.
const AV_SAMPLE_FMT_FLT: c_int = 3;
/// `AV_SAMPLE_FMT_FLTP`: planar float, what FFmpeg's AAC encoder takes.
const AV_SAMPLE_FMT_FLTP: c_int = 8;
/// `AVERROR(EAGAIN)`.
const AVERROR_EAGAIN: c_int = -11;
/// The rate converted sound is made at: what a Cast receiver's AAC is, and
/// what Dolby and DTS tracks are already.
pub const SOUND_RATE: u32 = 48_000;
/// The channels of converted sound, interleaved: left, right.
pub const SOUND_CHANNELS: usize = 2;

/// One stream's codec parameters, copied out of its demuxer, so a decoder
/// can be opened on them again and again while the demuxer reads on.
pub struct CodecParameters {
    libav: &'static Libav,
    par: *mut AVCodecParameters,
}

// SAFETY: the copy is this value's alone, and FFmpeg's codec parameters
// are plain data with no thread affinity.
unsafe impl Send for CodecParameters {}

impl Drop for CodecParameters {
    fn drop(&mut self) {
        if let Ok(codecs) = self.libav.codecs() {
            // SAFETY: allocated by `avcodec_parameters_alloc`, freed once.
            unsafe { (codecs.avcodec_parameters_free)(&mut self.par) };
        }
    }
}

impl<S: Source> Demuxer<S> {
    /// Stream `stream`'s codec parameters, copied.
    pub fn codec_parameters(&self, stream: usize) -> Result<CodecParameters, String> {
        let codecs = self.libav.codecs()?;
        // SAFETY: `ctx` is the open context and `stream` checked against
        // its count; the copy is a fresh allocation this value owns.
        unsafe {
            let ctx = &*self.ctx;
            if ctx.streams.is_null() || stream >= ctx.nb_streams as usize {
                return Err(format!("no stream {stream}"));
            }
            let source = (**ctx.streams.add(stream)).codecpar;
            let par = (codecs.avcodec_parameters_alloc)();
            if par.is_null() {
                return Err("no memory for codec parameters".to_owned());
            }
            let copy = CodecParameters {
                libav: self.libav,
                par,
            };
            if (codecs.avcodec_parameters_copy)(par, source) < 0 {
                return Err("the codec parameters could not be copied".to_owned());
            }
            Ok(copy)
        }
    }
}

/// Decoded sound: 48 kHz stereo, interleaved float, and the presentation
/// time of its first sample in the stream's time base ([`NOPTS`] when the
/// decoder said none, or for what a resampler held back to the end).
#[derive(Clone, Debug, PartialEq)]
pub struct Pcm {
    pub pts: i64,
    pub samples: Vec<f32>,
}

/// **A decoder of one stream's sound to 48 kHz stereo**, opened afresh for
/// every call to [`SoundDecoder::decode`], so what it makes of the same
/// packets is the same whichever call it is: no state crosses from one
/// call to the next, in the decoder or in the resampler.
///
/// The downmix is libswresample's default matrix (centre and surrounds at
/// -3 dB into each side, LFE left out), **normalised** so no sum clips
/// (`rematrix_maxval` 1): the stereo a 16-bit encoder is handed never
/// exceeds full scale, at the cost of a quieter mix than the source's
/// front pair alone.
pub struct SoundDecoder {
    libav: &'static Libav,
    decoder: *const c_void,
    par: CodecParameters,
}

// SAFETY: the decoder is a static description FFmpeg never frees; the
// parameters are owned (see `CodecParameters`).
unsafe impl Send for SoundDecoder {}

impl SoundDecoder {
    /// A decoder for `par`'s codec, or `None` when this FFmpeg has none.
    pub fn new(par: CodecParameters) -> Result<Option<Self>, String> {
        let libav = par.libav;
        let codecs = libav.codecs()?;
        // SAFETY: `par` is live; the lookup allocates nothing.
        let decoder = unsafe { (codecs.avcodec_find_decoder)((*par.par).codec_id) };
        Ok((!decoder.is_null()).then_some(Self {
            libav,
            decoder,
            par,
        }))
    }

    /// `packets` (one stream's, in order) decoded from a fresh decoder, and
    /// the sound converted to 48 kHz stereo by a fresh resampler; a packet
    /// the decoder refuses is skipped.
    pub fn decode(&mut self, packets: &[Packet]) -> Result<Vec<Pcm>, String> {
        let codecs = self.libav.codecs()?;
        let mut run = DecodeRun {
            libav: self.libav,
            codecs,
            ctx: std::ptr::null_mut(),
            frame: std::ptr::null_mut(),
            packet: std::ptr::null_mut(),
            swr: std::ptr::null_mut(),
            swr_for: None,
        };
        // SAFETY: FFmpeg's decoding sequence on objects `run` owns and frees
        // in its `Drop`, whatever returns early.
        unsafe {
            run.ctx = (codecs.avcodec_alloc_context3)(self.decoder);
            run.frame = (codecs.av_frame_alloc)();
            run.packet = (self.libav.av_packet_alloc)();
            if run.ctx.is_null() || run.frame.is_null() || run.packet.is_null() {
                return Err("no memory for a decoder".to_owned());
            }
            if (codecs.avcodec_parameters_to_context)(run.ctx, self.par.par) < 0 {
                return Err("the decoder could not be configured".to_owned());
            }
            let opened = (codecs.avcodec_open2)(run.ctx, self.decoder, std::ptr::null_mut());
            if opened < 0 {
                return Err(format!("the decoder could not be opened ({opened})"));
            }
            let mut out = Vec::new();
            for packet in packets {
                run.send(Some(packet), &mut out)?;
            }
            run.send(None, &mut out)?;
            run.drain(&mut out)?;
            Ok(out)
        }
    }
}

/// One [`SoundDecoder::decode`]'s FFmpeg objects, freed on drop.
struct DecodeRun {
    libav: &'static Libav,
    codecs: &'static Codecs,
    ctx: *mut c_void,
    frame: *mut AVFrame,
    packet: *mut AVPacket,
    swr: *mut c_void,
    /// What the resampler was made for: format, rate, layout.
    swr_for: Option<(c_int, c_int, c_int, c_int, u64)>,
}

impl DecodeRun {
    /// Sends `packet` (`None`: the end) and converts every frame it frees.
    ///
    /// # Safety
    ///
    /// The context is open, the frame and packet allocated.
    unsafe fn send(&mut self, packet: Option<&Packet>, out: &mut Vec<Pcm>) -> Result<(), String> {
        // SAFETY: the caller's contract; a packet's buffer holds `size`
        // bytes once `av_new_packet` succeeds.
        unsafe {
            let sent = match packet {
                Some(packet) => {
                    let size = c_int::try_from(packet.data.len())
                        .map_err(|_| "a packet too large to decode".to_owned())?;
                    if (self.codecs.av_new_packet)(self.packet, size) < 0 {
                        return Err("no memory for a packet".to_owned());
                    }
                    let p = &mut *self.packet;
                    std::ptr::copy_nonoverlapping(packet.data.as_ptr(), p.data, packet.data.len());
                    p.pts = packet.pts;
                    p.dts = packet.dts;
                    p.duration = packet.duration;
                    p.flags = if packet.key { AV_PKT_FLAG_KEY } else { 0 };
                    let sent = (self.codecs.avcodec_send_packet)(self.ctx, self.packet);
                    (self.libav.av_packet_unref)(self.packet);
                    sent
                }
                None => (self.codecs.avcodec_send_packet)(self.ctx, std::ptr::null()),
            };
            // A packet the decoder refuses (a TrueHD frame before its first
            // major sync, a damaged one) frees no sound: skipped.
            if sent < 0 && sent != AVERROR_EOF {
                return Ok(());
            }
            loop {
                let received = (self.codecs.avcodec_receive_frame)(self.ctx, self.frame);
                if received < 0 {
                    // EAGAIN (wants the next packet), the end, or an error
                    // in this packet: nothing more from it.
                    return Ok(());
                }
                let converted = self.convert(out);
                (self.codecs.av_frame_unref)(self.frame);
                converted?;
            }
        }
    }

    /// The decoded frame, resampled into `out`.
    ///
    /// # Safety
    ///
    /// `frame` holds a decoded audio frame.
    unsafe fn convert(&mut self, out: &mut Vec<Pcm>) -> Result<(), String> {
        // SAFETY: the caller's contract; the resampler is made for this
        // frame's format, rate and layout before it reads the frame's
        // `nb_samples` from `extended_data`, and writes at most `capacity`
        // stereo samples into a buffer of that many.
        unsafe {
            let frame = &*self.frame;
            // A layout of only a count (PCM that names no speakers) is
            // libswresample's to read as the usual speakers for it.
            let layout = frame.ch_layout;
            let mask = if layout.order == AV_CHANNEL_ORDER_NATIVE {
                layout.mask
            } else {
                0
            };
            let wanted = (
                frame.format,
                frame.sample_rate,
                layout.order,
                layout.nb_channels,
                mask,
            );
            if self.swr_for != Some(wanted) {
                self.drain(out)?;
                (self.codecs.swr_free)(&mut self.swr);
                let made = (self.codecs.swr_alloc_set_opts2)(
                    &mut self.swr,
                    &STEREO,
                    AV_SAMPLE_FMT_FLT,
                    SOUND_RATE as c_int,
                    &layout,
                    frame.format,
                    frame.sample_rate,
                    0,
                    std::ptr::null_mut(),
                );
                if made < 0 || self.swr.is_null() {
                    return Err(format!("no resampler for this sound ({made})"));
                }
                (self.codecs.av_opt_set_double)(self.swr, c"rematrix_maxval".as_ptr(), 1.0, 0);
                let ready = (self.codecs.swr_init)(self.swr);
                if ready < 0 {
                    return Err(format!("the resampler could not start ({ready})"));
                }
                self.swr_for = Some(wanted);
            }
            let rate = i64::from(frame.sample_rate.max(1));
            let capacity = i64::from(frame.nb_samples) * i64::from(SOUND_RATE) / rate + 256;
            let mut samples = vec![0f32; capacity as usize * SOUND_CHANNELS];
            let mut planes = [samples.as_mut_ptr().cast::<u8>()];
            let made = (self.codecs.swr_convert)(
                self.swr,
                planes.as_mut_ptr(),
                capacity as c_int,
                frame.extended_data as *const *const u8,
                frame.nb_samples,
            );
            if made < 0 {
                return Err(format!("the sound could not be resampled ({made})"));
            }
            samples.truncate(made as usize * SOUND_CHANNELS);
            out.push(Pcm {
                pts: frame.pts,
                samples,
            });
            Ok(())
        }
    }

    /// Whatever the resampler still holds, into `out`.
    ///
    /// # Safety
    ///
    /// `swr` is null or an initialised resampler.
    unsafe fn drain(&mut self, out: &mut Vec<Pcm>) -> Result<(), String> {
        if self.swr.is_null() {
            return Ok(());
        }
        loop {
            const CAPACITY: usize = 4096;
            let mut samples = vec![0f32; CAPACITY * SOUND_CHANNELS];
            let mut planes = [samples.as_mut_ptr().cast::<u8>()];
            // SAFETY: the caller's contract; a buffer of `CAPACITY` stereo
            // samples, and no input (the flush).
            let made = unsafe {
                (self.codecs.swr_convert)(
                    self.swr,
                    planes.as_mut_ptr(),
                    CAPACITY as c_int,
                    std::ptr::null(),
                    0,
                )
            };
            if made < 0 {
                return Err(format!("the sound could not be resampled ({made})"));
            }
            if made == 0 {
                return Ok(());
            }
            samples.truncate(made as usize * SOUND_CHANNELS);
            out.push(Pcm {
                pts: NOPTS,
                samples,
            });
        }
    }
}

impl Drop for DecodeRun {
    fn drop(&mut self) {
        // SAFETY: each pointer is null or this run's own, freed once.
        unsafe {
            (self.codecs.swr_free)(&mut self.swr);
            if !self.frame.is_null() {
                (self.codecs.av_frame_free)(&mut self.frame);
            }
            if !self.packet.is_null() {
                (self.libav.av_packet_free)(&mut self.packet);
            }
            if !self.ctx.is_null() {
                (self.codecs.avcodec_free_context)(&mut self.ctx);
            }
        }
    }
}

/// **FFmpeg's own AAC encoder** (AAC-LC, 48 kHz stereo), where the library
/// has one: a desktop's system FFmpeg. Opened afresh for every call to
/// [`LibavAac::encode`].
pub struct LibavAac {
    libav: &'static Libav,
    encoder: *const c_void,
    bitrate: u32,
}

// SAFETY: the encoder is a static description FFmpeg never frees.
unsafe impl Send for LibavAac {}

impl LibavAac {
    /// FFmpeg's AAC encoder's priming: its `initial_padding`, one frame.
    pub const DELAY: u32 = 1024;

    /// The encoder at `bitrate` bits a second, or `None` when the library
    /// has none.
    pub fn new(libav: &'static Libav, bitrate: u32) -> Option<Self> {
        let codecs = libav.codecs().ok()?;
        // SAFETY: a static string; the lookup allocates nothing.
        let encoder = unsafe { (codecs.avcodec_find_encoder_by_name)(c"aac".as_ptr()) };
        (!encoder.is_null()).then_some(Self {
            libav,
            encoder,
            bitrate,
        })
    }

    /// `pcm` (48 kHz stereo, interleaved, a whole number of 1024-sample
    /// frames) encoded from a fresh encoder and flushed: every frame it
    /// makes, its priming first, raw (no ADTS).
    pub fn encode(&mut self, pcm: &[f32]) -> Result<Vec<Bytes>, String> {
        let codecs = self.libav.codecs()?;
        let mut run = EncodeRun {
            libav: self.libav,
            codecs,
            ctx: std::ptr::null_mut(),
            frame: std::ptr::null_mut(),
            packet: std::ptr::null_mut(),
        };
        // SAFETY: FFmpeg's encoding sequence on objects `run` owns and frees
        // in its `Drop`; each frame's planes hold `nb_samples` floats once
        // `av_frame_get_buffer` succeeds.
        unsafe {
            let mut par = (codecs.avcodec_parameters_alloc)();
            if par.is_null() {
                return Err("no memory for codec parameters".to_owned());
            }
            (*par).codec_type = AVMEDIA_TYPE_AUDIO;
            (*par).codec_id = AV_CODEC_ID_AAC;
            (*par).format = AV_SAMPLE_FMT_FLTP;
            (*par).bit_rate = i64::from(self.bitrate);
            (*par).sample_rate = SOUND_RATE as c_int;
            (*par).ch_layout = STEREO;
            run.ctx = (codecs.avcodec_alloc_context3)(self.encoder);
            let configured =
                !run.ctx.is_null() && (codecs.avcodec_parameters_to_context)(run.ctx, par) >= 0;
            (codecs.avcodec_parameters_free)(&mut par);
            if !configured {
                return Err("the AAC encoder could not be configured".to_owned());
            }
            let opened = (codecs.avcodec_open2)(run.ctx, self.encoder, std::ptr::null_mut());
            if opened < 0 {
                return Err(format!("the AAC encoder could not be opened ({opened})"));
            }
            run.frame = (codecs.av_frame_alloc)();
            run.packet = (self.libav.av_packet_alloc)();
            if run.frame.is_null() || run.packet.is_null() {
                return Err("no memory for the AAC encoder".to_owned());
            }
            let mut out = Vec::new();
            for (at, block) in pcm.chunks(1024 * SOUND_CHANNELS).enumerate() {
                let samples = block.len() / SOUND_CHANNELS;
                let frame = &mut *run.frame;
                frame.nb_samples = samples as c_int;
                frame.format = AV_SAMPLE_FMT_FLTP;
                frame.sample_rate = SOUND_RATE as c_int;
                frame.ch_layout = STEREO;
                frame.pts = (at * 1024) as i64;
                if (codecs.av_frame_get_buffer)(run.frame, 0) < 0 {
                    return Err("no memory for a frame".to_owned());
                }
                let frame = &mut *run.frame;
                let left = std::slice::from_raw_parts_mut(frame.data[0].cast::<f32>(), samples);
                let right = std::slice::from_raw_parts_mut(frame.data[1].cast::<f32>(), samples);
                for (n, pair) in block.as_chunks::<SOUND_CHANNELS>().0.iter().enumerate() {
                    left[n] = pair[0];
                    right[n] = pair[1];
                }
                let sent = (codecs.avcodec_send_frame)(run.ctx, run.frame);
                (codecs.av_frame_unref)(run.frame);
                if sent < 0 {
                    return Err(format!("the AAC encoder refused a frame ({sent})"));
                }
                run.receive(&mut out)?;
            }
            let flushed = (codecs.avcodec_send_frame)(run.ctx, std::ptr::null());
            if flushed < 0 {
                return Err(format!("the AAC encoder could not be flushed ({flushed})"));
            }
            run.receive(&mut out)?;
            Ok(out)
        }
    }
}

/// One [`LibavAac::encode`]'s FFmpeg objects, freed on drop.
struct EncodeRun {
    libav: &'static Libav,
    codecs: &'static Codecs,
    ctx: *mut c_void,
    frame: *mut AVFrame,
    packet: *mut AVPacket,
}

impl EncodeRun {
    /// Every packet the encoder has ready, into `out`.
    ///
    /// # Safety
    ///
    /// The context is an open encoder, the packet allocated.
    unsafe fn receive(&mut self, out: &mut Vec<Bytes>) -> Result<(), String> {
        loop {
            // SAFETY: the caller's contract; a received packet's `data`
            // holds `size` bytes until it is unreferenced.
            unsafe {
                let received = (self.codecs.avcodec_receive_packet)(self.ctx, self.packet);
                if received == AVERROR_EAGAIN || received == AVERROR_EOF {
                    return Ok(());
                }
                if received < 0 {
                    return Err(format!("the AAC encoder failed ({received})"));
                }
                let packet = &*self.packet;
                out.push(if packet.data.is_null() || packet.size <= 0 {
                    Bytes::new()
                } else {
                    Bytes::copy_from_slice(std::slice::from_raw_parts(
                        packet.data,
                        packet.size as usize,
                    ))
                });
                (self.libav.av_packet_unref)(self.packet);
            }
        }
    }
}

impl Drop for EncodeRun {
    fn drop(&mut self) {
        // SAFETY: each pointer is null or this run's own, freed once.
        unsafe {
            if !self.frame.is_null() {
                (self.codecs.av_frame_free)(&mut self.frame);
            }
            if !self.packet.is_null() {
                (self.libav.av_packet_free)(&mut self.packet);
            }
            if !self.ctx.is_null() {
                (self.codecs.avcodec_free_context)(&mut self.ctx);
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
