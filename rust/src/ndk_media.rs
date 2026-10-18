//! **The NDK's media library, opened once**: the `AMediaCodec` and
//! `AMediaFormat` functions the AAC encoder ([`crate::mediacodec`]) and the
//! picture converter ([`crate::picture`]) call, and the one window function
//! from `libandroid.so`.
//!
//! The libraries are opened at run time ([`ndk`]), never linked, so the
//! crate builds and runs on a desktop, where opening them fails. They are
//! opened at most once per process, and every caller shares the table.
//!
//! **API levels.** The app's minSdk is 24. Every function in the table
//! exists from API 21 except the ones held as `Option`, which are `None` on
//! a device too old for them:
//!
//! | Function | API |
//! |---|---|
//! | `AMediaCodec_createInputSurface`, `AMediaCodec_signalEndOfInputStream` | 26 |
//! | `AMediaCodec_getInputFormat`, `AMediaCodec_getName`, `AMediaCodec_releaseName` | 28 |
//! | `AMediaFormat_getRect` | 28 |
//! | `ANativeWindow_release` (`libandroid.so`) | 9 |
//!
//! A missing one makes the path that needs it unavailable
//! ([`crate::picture::support`]). It is never a crash.

use std::ffi::{c_char, c_int, c_long, c_void, CStr};
use std::sync::OnceLock;

/// `AMediaCodecBufferInfo`.
#[repr(C)]
#[derive(Default)]
pub struct BufferInfo {
    pub offset: i32,
    pub size: i32,
    pub presentation_time_us: i64,
    pub flags: u32,
}

/// `AMediaCodec_dequeue*Buffer`'s answers that are not an index.
pub const INFO_TRY_AGAIN_LATER: isize = -1;
pub const INFO_OUTPUT_FORMAT_CHANGED: isize = -2;
pub const INFO_OUTPUT_BUFFERS_CHANGED: isize = -3;
/// `AMEDIACODEC_BUFFER_FLAG_*`.
pub const BUFFER_FLAG_KEY_FRAME: u32 = 1;
pub const BUFFER_FLAG_CODEC_CONFIG: u32 = 2;
pub const BUFFER_FLAG_END_OF_STREAM: u32 = 4;
/// `AMEDIACODEC_CONFIGURE_FLAG_ENCODE`.
pub const CONFIGURE_FLAG_ENCODE: u32 = 1;

/// The `libmediandk.so` and `libandroid.so` functions this crate calls,
/// each read as its `NdkMediaCodec.h`, `NdkMediaFormat.h` or
/// `native_window.h` signature.
pub struct Ndk {
    pub create_codec_by_name: unsafe extern "C" fn(*const c_char) -> *mut c_void,
    pub create_decoder_by_type: unsafe extern "C" fn(*const c_char) -> *mut c_void,
    pub create_encoder_by_type: unsafe extern "C" fn(*const c_char) -> *mut c_void,
    pub delete: unsafe extern "C" fn(*mut c_void) -> i32,
    /// `(codec, format, ANativeWindow*, AMediaCrypto*, flags)`.
    pub configure:
        unsafe extern "C" fn(*mut c_void, *const c_void, *mut c_void, *mut c_void, u32) -> i32,
    pub start: unsafe extern "C" fn(*mut c_void) -> i32,
    pub stop: unsafe extern "C" fn(*mut c_void) -> i32,
    pub dequeue_input_buffer: unsafe extern "C" fn(*mut c_void, i64) -> isize,
    pub get_input_buffer: unsafe extern "C" fn(*mut c_void, usize, *mut usize) -> *mut u8,
    /// `offset` is `off_t`: a `long` on Android, 32 bits on armv7.
    pub queue_input_buffer:
        unsafe extern "C" fn(*mut c_void, usize, c_long, usize, u64, u32) -> i32,
    pub dequeue_output_buffer: unsafe extern "C" fn(*mut c_void, *mut BufferInfo, i64) -> isize,
    pub get_output_buffer: unsafe extern "C" fn(*mut c_void, usize, *mut usize) -> *mut u8,
    /// A new `AMediaFormat` the caller deletes.
    pub get_output_format: unsafe extern "C" fn(*mut c_void) -> *mut c_void,
    pub release_output_buffer: unsafe extern "C" fn(*mut c_void, usize, bool) -> i32,
    /// `(codec, index, timestamp in nanoseconds)`: rendered to the surface
    /// with that time.
    pub release_output_buffer_at_time: unsafe extern "C" fn(*mut c_void, usize, i64) -> i32,
    pub set_output_surface: unsafe extern "C" fn(*mut c_void, *mut c_void) -> i32,
    /// API 26: `(codec, ANativeWindow** out)`, between configure and start.
    pub create_input_surface: Option<unsafe extern "C" fn(*mut c_void, *mut *mut c_void) -> i32>,
    /// API 26.
    pub signal_end_of_input_stream: Option<unsafe extern "C" fn(*mut c_void) -> i32>,
    /// API 28: a new `AMediaFormat` the caller deletes.
    pub get_input_format: Option<unsafe extern "C" fn(*mut c_void) -> *mut c_void>,
    /// API 28: `(codec, char** out)`, released with `release_name`.
    pub get_name: Option<unsafe extern "C" fn(*mut c_void, *mut *mut c_char) -> i32>,
    /// API 28.
    pub release_name: Option<unsafe extern "C" fn(*mut c_void, *mut c_char)>,
    pub format_new: unsafe extern "C" fn() -> *mut c_void,
    pub format_delete: unsafe extern "C" fn(*mut c_void) -> i32,
    pub format_set_string: unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char),
    pub format_set_int32: unsafe extern "C" fn(*mut c_void, *const c_char, i32),
    pub format_set_float: unsafe extern "C" fn(*mut c_void, *const c_char, f32),
    pub format_set_buffer: unsafe extern "C" fn(*mut c_void, *const c_char, *const c_void, usize),
    pub format_get_int32: unsafe extern "C" fn(*mut c_void, *const c_char, *mut i32) -> bool,
    pub format_get_buffer:
        unsafe extern "C" fn(*mut c_void, *const c_char, *mut *mut c_void, *mut usize) -> bool,
    /// API 28: `(format, name, left, top, right, bottom)`, right and bottom
    /// inclusive.
    pub format_get_rect: Option<
        unsafe extern "C" fn(
            *mut c_void,
            *const c_char,
            *mut i32,
            *mut i32,
            *mut i32,
            *mut i32,
        ) -> bool,
    >,
    pub format_to_string: unsafe extern "C" fn(*mut c_void) -> *const c_char,
    /// `libandroid.so`, API 9. `None` when that library did not open.
    pub window_release: Option<unsafe extern "C" fn(*mut c_void)>,
    /// The device's API level, 0 when it could not be read.
    pub api_level: u32,
    _media: libloading::Library,
    _android: Option<libloading::Library>,
}

static NDK: OnceLock<Result<Ndk, String>> = OnceLock::new();

/// The table, opened on the first call. An error where this is no Android,
/// or the media library lacks a function every device since API 21 has.
pub fn ndk() -> Result<&'static Ndk, String> {
    NDK.get_or_init(Ndk::load).as_ref().map_err(Clone::clone)
}

impl Ndk {
    fn load() -> Result<Self, String> {
        // SAFETY: the platform's media and window libraries. Their
        // initialisers have no preconditions, and each symbol is read as its
        // header's signature (the field types above).
        unsafe {
            let media = libloading::Library::new("libmediandk.so")
                .map_err(|error| format!("no libmediandk.so: {error}"))?;
            let android = libloading::Library::new("libandroid.so").ok();
            macro_rules! symbol {
                ($name:literal) => {
                    *media
                        .get(concat!($name, "\0").as_bytes())
                        .map_err(|error| format!("{}: {error}", $name))?
                };
            }
            macro_rules! optional {
                ($library:expr, $name:literal) => {
                    $library
                        .get(concat!($name, "\0").as_bytes())
                        .ok()
                        .map(|symbol: libloading::Symbol<_>| *symbol)
                };
            }
            let window_release = android
                .as_ref()
                .and_then(|library| optional!(library, "ANativeWindow_release"));
            Ok(Self {
                create_codec_by_name: symbol!("AMediaCodec_createCodecByName"),
                create_decoder_by_type: symbol!("AMediaCodec_createDecoderByType"),
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
                get_output_format: symbol!("AMediaCodec_getOutputFormat"),
                release_output_buffer: symbol!("AMediaCodec_releaseOutputBuffer"),
                release_output_buffer_at_time: symbol!("AMediaCodec_releaseOutputBufferAtTime"),
                set_output_surface: symbol!("AMediaCodec_setOutputSurface"),
                create_input_surface: optional!(media, "AMediaCodec_createInputSurface"),
                signal_end_of_input_stream: optional!(media, "AMediaCodec_signalEndOfInputStream"),
                get_input_format: optional!(media, "AMediaCodec_getInputFormat"),
                get_name: optional!(media, "AMediaCodec_getName"),
                release_name: optional!(media, "AMediaCodec_releaseName"),
                format_new: symbol!("AMediaFormat_new"),
                format_delete: symbol!("AMediaFormat_delete"),
                format_set_string: symbol!("AMediaFormat_setString"),
                format_set_int32: symbol!("AMediaFormat_setInt32"),
                format_set_float: symbol!("AMediaFormat_setFloat"),
                format_set_buffer: symbol!("AMediaFormat_setBuffer"),
                format_get_int32: symbol!("AMediaFormat_getInt32"),
                format_get_buffer: symbol!("AMediaFormat_getBuffer"),
                format_get_rect: optional!(media, "AMediaFormat_getRect"),
                format_to_string: symbol!("AMediaFormat_toString"),
                window_release,
                api_level: api_level(),
                _media: media,
                _android: android,
            })
        }
    }

    /// The codec's component name (`c2.mtk.hevc.encoder`), where the device
    /// can say (API 28).
    ///
    /// # Safety
    /// `codec` is a live `AMediaCodec`.
    pub unsafe fn codec_name(&self, codec: *mut c_void) -> Option<String> {
        let (get, release) = (self.get_name?, self.release_name?);
        let mut name: *mut c_char = std::ptr::null_mut();
        if get(codec, &mut name) != 0 || name.is_null() {
            return None;
        }
        let owned = CStr::from_ptr(name).to_string_lossy().into_owned();
        release(codec, name);
        Some(owned)
    }
}

/// The device's API level: `android_get_device_api_level` (libc, API 29),
/// else the `ro.build.version.sdk` property. 0 when neither answers.
fn api_level() -> u32 {
    // SAFETY: bionic's own functions, read as their `<android/api-level.h>`
    // and `<sys/system_properties.h>` signatures. The property buffer is
    // PROP_VALUE_MAX (92) bytes, as the function requires.
    unsafe {
        let Ok(libc) = libloading::Library::new("libc.so") else {
            return 0;
        };
        if let Ok(level) =
            libc.get::<unsafe extern "C" fn() -> c_int>(b"android_get_device_api_level\0")
        {
            let level = level();
            if level > 0 {
                return level as u32;
            }
        }
        let Ok(get) = libc.get::<unsafe extern "C" fn(*const c_char, *mut c_char) -> c_int>(
            b"__system_property_get\0",
        ) else {
            return 0;
        };
        let mut value = [0 as c_char; 92];
        if get(c"ro.build.version.sdk".as_ptr(), value.as_mut_ptr()) <= 0 {
            return 0;
        }
        CStr::from_ptr(value.as_ptr())
            .to_str()
            .ok()
            .and_then(|text| text.trim().parse().ok())
            .unwrap_or(0)
    }
}

/// **An `ANativeWindow` this crate holds a reference to**: an encoder's
/// input surface. Dropping it releases that reference.
pub struct AndroidWindow {
    window: *mut c_void,
    release: unsafe extern "C" fn(*mut c_void),
}

// SAFETY: an `ANativeWindow` reference may be released from any thread,
// and this one is used by one run's thread alone.
unsafe impl Send for AndroidWindow {}

impl AndroidWindow {
    /// Takes over the reference `window` holds.
    ///
    /// # Safety
    /// `window` is a live `ANativeWindow` whose reference the caller owns.
    pub unsafe fn from_raw(
        window: *mut c_void,
        release: unsafe extern "C" fn(*mut c_void),
    ) -> Self {
        Self { window, release }
    }

    pub fn as_ptr(&self) -> *mut c_void {
        self.window
    }
}

impl Drop for AndroidWindow {
    fn drop(&mut self) {
        // SAFETY: the reference this value owns, released once.
        unsafe { (self.release)(self.window) }
    }
}

/// **An `AMediaFormat` this crate owns**, deleted on drop.
pub struct MediaFormat {
    ndk: &'static Ndk,
    format: *mut c_void,
}

impl MediaFormat {
    pub fn new(ndk: &'static Ndk) -> Result<Self, String> {
        // SAFETY: no preconditions.
        let format = unsafe { (ndk.format_new)() };
        if format.is_null() {
            return Err("no media format".to_owned());
        }
        Ok(Self { ndk, format })
    }

    /// Takes over a format the NDK handed out (`getOutputFormat`), or
    /// `None` for a null one.
    ///
    /// # Safety
    /// `format` is null or a live `AMediaFormat` the caller owns.
    pub unsafe fn from_raw(ndk: &'static Ndk, format: *mut c_void) -> Option<Self> {
        (!format.is_null()).then_some(Self { ndk, format })
    }

    pub fn as_ptr(&self) -> *mut c_void {
        self.format
    }

    pub fn set_string(&self, key: &CStr, value: &CStr) {
        // SAFETY: a live format; the format copies both strings.
        unsafe { (self.ndk.format_set_string)(self.format, key.as_ptr(), value.as_ptr()) }
    }

    pub fn set_i32(&self, key: &CStr, value: i32) {
        // SAFETY: a live format; the format copies the key.
        unsafe { (self.ndk.format_set_int32)(self.format, key.as_ptr(), value) }
    }

    pub fn set_f32(&self, key: &CStr, value: f32) {
        // SAFETY: as `set_i32`.
        unsafe { (self.ndk.format_set_float)(self.format, key.as_ptr(), value) }
    }

    pub fn set_buffer(&self, key: &CStr, value: &[u8]) {
        // SAFETY: a live format; the format copies the bytes.
        unsafe {
            (self.ndk.format_set_buffer)(
                self.format,
                key.as_ptr(),
                value.as_ptr().cast(),
                value.len(),
            )
        }
    }

    pub fn i32(&self, key: &CStr) -> Option<i32> {
        let mut value = 0;
        // SAFETY: a live format and a live out-value.
        unsafe { (self.ndk.format_get_int32)(self.format, key.as_ptr(), &mut value) }
            .then_some(value)
    }

    /// The bytes under `key`, copied out of the format.
    pub fn buffer(&self, key: &CStr) -> Option<Vec<u8>> {
        let mut data: *mut c_void = std::ptr::null_mut();
        let mut size = 0usize;
        // SAFETY: a live format. The data stays the format's, valid while
        // it lives, and is copied before this returns.
        unsafe {
            if !(self.ndk.format_get_buffer)(self.format, key.as_ptr(), &mut data, &mut size)
                || data.is_null()
            {
                return None;
            }
            Some(std::slice::from_raw_parts(data.cast::<u8>(), size).to_vec())
        }
    }

    /// The rectangle under `key` as (left, top, right, bottom), right and
    /// bottom inclusive. `None` before API 28.
    pub fn rect(&self, key: &CStr) -> Option<(i32, i32, i32, i32)> {
        let get = self.ndk.format_get_rect?;
        let (mut left, mut top, mut right, mut bottom) = (0, 0, 0, 0);
        // SAFETY: a live format and live out-values.
        unsafe {
            get(
                self.format,
                key.as_ptr(),
                &mut left,
                &mut top,
                &mut right,
                &mut bottom,
            )
        }
        .then_some((left, top, right, bottom))
    }

    /// The format as the NDK prints it, for a log line.
    pub fn describe(&self) -> String {
        // SAFETY: a live format. The string is the format's, copied here.
        unsafe {
            let text = (self.ndk.format_to_string)(self.format);
            if text.is_null() {
                return String::new();
            }
            CStr::from_ptr(text).to_string_lossy().into_owned()
        }
    }
}

impl Drop for MediaFormat {
    fn drop(&mut self) {
        // SAFETY: this value's own format, deleted once.
        unsafe { (self.ndk.format_delete)(self.format) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// On a desktop there is no `libmediandk.so`. Opening says so, every
    /// time, rather than crashing.
    #[cfg(not(target_os = "android"))]
    #[test]
    fn a_desktop_has_no_ndk() {
        assert!(ndk().err().unwrap().contains("libmediandk.so"));
        assert!(ndk().is_err());
    }
}
