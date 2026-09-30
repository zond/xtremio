//! **mpv reads `xtremio://<id>` through the embedded server's
//! [`MediaReader`]**, over libmpv's `stream_cb` protocol API
//! (`mpv/stream_cb.h`; stream-server's `docs/design/media-pipeline.md`
//! §2.4-2.5).
//!
//! media_kit owns the `mpv_handle`. Dart hands its address and the path of
//! the libmpv it loaded to [`register`] once per player, after the player
//! initialised and before the first open; that `dlopen`s the same library
//! (the loader answers with the instance already mapped), resolves
//! `mpv_stream_cb_add_ro` and registers [`PROTOCOL`] on the handle. mpv then
//! calls [`open_cb`] for every `xtremio://` URL it is asked to load, and the
//! stream's other callbacks after it, **on mpv's own threads**: they are
//! plain blocking Rust, with no Dart and no `ServerHandle` in them.
//!
//! # Who owns what
//!
//! The *cookie* mpv hands back to every callback is a `Box<Cookie>` this
//! module leaked in [`open_cb`] and takes back in [`close_cb`], which mpv
//! calls exactly once. It owns the reader, and with it everything the
//! reader holds; dropping it closes the stream (the server's reader task
//! drops its source on its own runtime). It holds no `ServerHandle`: an
//! open is the only callback that reaches the server
//! ([`crate::media::open_for_player`]), and it lets go of the handle
//! before it returns.
//!
//! **A cancel never waits on the read it interrupts.** mpv calls
//! `cancel_fn` from another thread while a read or seek blocks, and it
//! "should not block". The reader sits behind a mutex that a read holds
//! for its whole length; the cancel goes through the [`Cancel`] handle
//! beside it, which does not take that mutex. It is sticky, as mpv's
//! contract says: every later call answers an error at once.
//!
//! Generic over [`Opener`] and [`StreamReader`] so the unit tests below can
//! drive every callback with a fake reader and no libmpv; the production
//! instantiation is [`ServerOpener`] over [`MediaReader`].

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::io;
use std::sync::{Mutex, MutexGuard, OnceLock, PoisonError};

use stream_server::{Canceller, MediaReader};

/// The URI scheme registered on each handle, and the one the app hands mpv
/// (`xtremio://<id>`). The Dart side names the same string to media_kit
/// (`NativePlayer.streamCallbackSchemes`).
pub const PROTOCOL: &str = "xtremio";

/// `MPV_ERROR_LOADING_FAILED`: what an open answers when there is nothing
/// to read.
const MPV_ERROR_LOADING_FAILED: c_int = -13;
/// `MPV_ERROR_INVALID_PARAMETER`: `mpv_stream_cb_add_ro`'s answer for a
/// protocol already registered on the handle.
const MPV_ERROR_INVALID_PARAMETER: c_int = -4;
/// `MPV_ERROR_GENERIC`, a seek that failed.
const MPV_ERROR_GENERIC: i64 = -20;
/// `MPV_ERROR_UNSUPPORTED`, a size nobody knows.
const MPV_ERROR_UNSUPPORTED: i64 = -18;

/// `mpv_stream_cb_info` from `stream_cb.h` (API 1.106 and later, which
/// added `cancel_fn`). mpv owns the struct and hands it to the open
/// callback to fill in.
#[repr(C)]
pub struct MpvStreamCbInfo {
    cookie: *mut c_void,
    read_fn: Option<unsafe extern "C" fn(*mut c_void, *mut c_char, u64) -> i64>,
    seek_fn: Option<unsafe extern "C" fn(*mut c_void, i64) -> i64>,
    size_fn: Option<unsafe extern "C" fn(*mut c_void) -> i64>,
    close_fn: Option<unsafe extern "C" fn(*mut c_void)>,
    cancel_fn: Option<unsafe extern "C" fn(*mut c_void)>,
}

/// `mpv_stream_cb_open_ro_fn`.
type OpenFn = unsafe extern "C" fn(*mut c_void, *mut c_char, *mut MpvStreamCbInfo) -> c_int;

/// `mpv_stream_cb_add_ro`.
type AddRoFn = unsafe extern "C" fn(*mut c_void, *const c_char, *mut c_void, OpenFn) -> c_int;

/// What cancels a reader from another thread without blocking.
pub trait Cancel: Send + Sync {
    /// Cancel the call in flight and every later one.
    fn cancel(&self);
}

/// A blocking reader mpv's callbacks drive: [`MediaReader`]'s calls, named
/// so a fake can stand in for it.
pub trait StreamReader: Send {
    /// Cancels this reader while one of its calls blocks.
    type Canceller: Cancel;
    /// Up to `buf.len()` bytes, `Ok(0)` at the end of the file.
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize>;
    /// Move to `offset`; answers where the reader is.
    fn seek(&mut self, offset: u64) -> io::Result<u64>;
    /// The file's length: what mpv's `size_fn` answers.
    fn size(&self) -> u64;
    /// A handle that cancels this reader from another thread.
    fn canceller(&self) -> Self::Canceller;
}

/// What an `xtremio://<id>` URL is opened with.
pub trait Opener: 'static {
    /// The reader an open hands mpv.
    type Reader: StreamReader;
    /// A reader over `id`, or why there is none: a sentence for the log,
    /// which must carry no URL (AGENTS.md, "Never log auth material").
    fn open(&self, id: &str) -> Result<Self::Reader, String>;
}

impl Cancel for Canceller {
    fn cancel(&self) {
        Canceller::cancel(self);
    }
}

impl StreamReader for MediaReader {
    type Canceller = Canceller;

    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        MediaReader::read(self, buf)
    }

    fn seek(&mut self, offset: u64) -> io::Result<u64> {
        MediaReader::seek(self, offset)
    }

    fn size(&self) -> u64 {
        MediaReader::len(self)
    }

    fn canceller(&self) -> Canceller {
        MediaReader::canceller(self)
    }
}

/// The production opener: the embedded server, with the play the app
/// registered for the id ([`crate::media::open_for_player`]).
pub struct ServerOpener;

impl Opener for ServerOpener {
    type Reader = MediaReader;

    fn open(&self, id: &str) -> Result<MediaReader, String> {
        crate::media::open_for_player(id)
    }
}

/// The id in `xtremio://<id>`, or `None` for anything else. An id is the
/// server's 32 hex characters, so anything past it -- a path, a query, a
/// fragment -- is not one, rather than something to strip.
pub fn media_id(uri: &str) -> Option<&str> {
    let (scheme, rest) = uri.split_once("://")?;
    if !scheme.eq_ignore_ascii_case(PROTOCOL) {
        return None;
    }
    let id = rest;
    (!id.is_empty() && id.bytes().all(|byte| byte.is_ascii_alphanumeric())).then_some(id)
}

/// One open stream: what mpv's cookie points at.
struct Cookie<R: StreamReader> {
    /// Held by a read or a seek for its whole length; mpv makes one call at
    /// a time on a stream, so it is never contended but by a close, which
    /// mpv does not make while a call is in flight.
    reader: Mutex<R>,
    /// Beside the mutex, so a cancel never waits for the read it cancels.
    canceller: R::Canceller,
    len: u64,
}

impl<R: StreamReader> Cookie<R> {
    fn new(reader: R) -> Self {
        Self {
            canceller: reader.canceller(),
            len: reader.size(),
            reader: Mutex::new(reader),
        }
    }

    fn reader(&self) -> MutexGuard<'_, R> {
        self.reader.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// `open_fn`: parse the URI, open a reader over the id, and hand mpv the
/// cookie and callbacks. `user_data` is the `&'static O` [`register`]
/// passed to `mpv_stream_cb_add_ro`.
///
/// # Safety
///
/// `user_data` points at a live `O`; `uri` is NUL-terminated and `info`
/// writable, for this call (mpv's contract).
unsafe extern "C" fn open_cb<O: Opener>(
    user_data: *mut c_void,
    uri: *mut c_char,
    info: *mut MpvStreamCbInfo,
) -> c_int {
    let opened = std::panic::catch_unwind(|| {
        // SAFETY: mpv passes a NUL-terminated URI valid for this call.
        let uri = unsafe { CStr::from_ptr(uri) }.to_string_lossy();
        let Some(id) = media_id(&uri) else {
            tracing::warn!("mpv asked for an {PROTOCOL}:// URL that names no media id");
            return None;
        };
        // SAFETY: `register` passed a `&'static O` as the user data.
        let opener = unsafe { &*user_data.cast::<O>() };
        match opener.open(id) {
            Ok(reader) => Some(Box::new(Cookie::new(reader))),
            Err(error) => {
                tracing::warn!(%id, %error, "mpv could not open a media id");
                None
            }
        }
    });
    let Ok(Some(cookie)) = opened else {
        return MPV_ERROR_LOADING_FAILED;
    };
    // SAFETY: mpv passes a valid, writable info struct for this call.
    let info = unsafe { &mut *info };
    info.cookie = Box::into_raw(cookie).cast();
    info.read_fn = Some(read_cb::<O::Reader>);
    info.seek_fn = Some(seek_cb::<O::Reader>);
    info.size_fn = Some(size_cb::<O::Reader>);
    info.close_fn = Some(close_cb::<O::Reader>);
    info.cancel_fn = Some(cancel_cb::<O::Reader>);
    0
}

/// The cookie behind mpv's pointer.
///
/// # Safety
///
/// `cookie` is one [`open_cb`] handed mpv and [`close_cb`] has not taken
/// back.
unsafe fn cookie<'a, R: StreamReader>(cookie: *mut c_void) -> &'a Cookie<R> {
    // SAFETY: the caller's contract.
    unsafe { &*cookie.cast::<Cookie<R>>() }
}

/// `read_fn`: bytes read, `0` at the end of the file, `-1` on an error --
/// a cancel's included.
unsafe extern "C" fn read_cb<R: StreamReader>(
    cookie_ptr: *mut c_void,
    buf: *mut c_char,
    nbytes: u64,
) -> i64 {
    // SAFETY: mpv passes the cookie `open_cb` handed it, alive until close.
    let cookie = unsafe { cookie::<R>(cookie_ptr) };
    let len = usize::try_from(nbytes).unwrap_or(usize::MAX);
    // SAFETY: mpv's buffer holds at least `nbytes` bytes.
    let out = unsafe { std::slice::from_raw_parts_mut(buf.cast::<u8>(), len) };
    let read = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| cookie.reader().read(out)));
    match read {
        Ok(Ok(n)) => i64::try_from(n).unwrap_or(-1),
        _ => -1,
    }
}

/// `seek_fn`: the offset the reader is at, or `MPV_ERROR_GENERIC`.
unsafe extern "C" fn seek_cb<R: StreamReader>(cookie_ptr: *mut c_void, offset: i64) -> i64 {
    // SAFETY: as in `read_cb`.
    let cookie = unsafe { cookie::<R>(cookie_ptr) };
    let Ok(offset) = u64::try_from(offset) else {
        return MPV_ERROR_GENERIC;
    };
    let seek = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        cookie.reader().seek(offset)
    }));
    match seek {
        Ok(Ok(at)) => i64::try_from(at).unwrap_or(MPV_ERROR_GENERIC),
        _ => MPV_ERROR_GENERIC,
    }
}

/// `size_fn`: the file's length, known since the open.
unsafe extern "C" fn size_cb<R: StreamReader>(cookie_ptr: *mut c_void) -> i64 {
    // SAFETY: as in `read_cb`.
    let cookie = unsafe { cookie::<R>(cookie_ptr) };
    i64::try_from(cookie.len).unwrap_or(MPV_ERROR_UNSUPPORTED)
}

/// `close_fn`: drop the cookie, which closes the reader. mpv calls it once.
unsafe extern "C" fn close_cb<R: StreamReader>(cookie_ptr: *mut c_void) {
    // SAFETY: the Box `open_cb` leaked; mpv calls close exactly once and
    // nothing after it.
    let cookie = unsafe { Box::from_raw(cookie_ptr.cast::<Cookie<R>>()) };
    // A reader's drop does nothing that unwinds by design; a panic in it
    // must still not cross into C.
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || drop(cookie)));
}

/// `cancel_fn`: trip the reader's cancel. Never takes the reader's lock, so
/// it never waits on the read it interrupts.
unsafe extern "C" fn cancel_cb<R: StreamReader>(cookie_ptr: *mut c_void) {
    // SAFETY: as in `read_cb`; mpv does not call cancel after close.
    let cookie = unsafe { cookie::<R>(cookie_ptr) };
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| cookie.canceller.cancel()));
}

/// What a registration found.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Registration {
    /// mpv took the protocol on this handle.
    Registered,
    /// It was already registered there, by an earlier call.
    Already,
}

/// A handle and the library it came from, seen through a function table so
/// the bookkeeping can be tested without libmpv.
trait AddRo {
    /// `mpv_stream_cb_add_ro(ctx, PROTOCOL, user_data, open_cb::<O>)`.
    fn add_ro(&self, ctx: usize, open: OpenFn, user_data: *mut c_void) -> c_int;
}

/// The libmpv media_kit loaded, opened again (the loader hands back the
/// mapped instance) and kept for the process: a callback mpv holds is a
/// pointer into this crate, not into it, but the handle's library must not
/// be unloaded under the `mpv_stream_cb_add_ro` pointer resolved from it.
struct Libmpv {
    add_ro: AddRoFn,
    _library: libloading::Library,
}

impl AddRo for Libmpv {
    fn add_ro(&self, ctx: usize, open: OpenFn, user_data: *mut c_void) -> c_int {
        let protocol = CString::new(PROTOCOL).expect("the protocol has no NUL");
        // SAFETY: `ctx` is a live mpv_handle (the caller's contract); mpv
        // copies the protocol name; `open` and `user_data` are 'static.
        unsafe { (self.add_ro)(ctx as *mut c_void, protocol.as_ptr(), user_data, open) }
    }
}

/// The libmpv at `path`, loaded once per process. A later call naming
/// another path is refused: one process has one libmpv.
fn libmpv(path: &str) -> anyhow::Result<&'static Libmpv> {
    static LIBMPV: OnceLock<(String, Result<Libmpv, String>)> = OnceLock::new();
    let (loaded_from, loaded) = LIBMPV.get_or_init(|| {
        let loaded = (|| {
            // SAFETY: media_kit has already loaded this library, so this
            // runs no initialiser; it takes one more reference to it.
            let library = unsafe { libloading::Library::new(path) }.map_err(|e| e.to_string())?;
            // SAFETY: the symbol is `mpv_stream_cb_add_ro`, whose C
            // signature `AddRoFn` mirrors (`stream_cb.h`).
            let add_ro = unsafe { library.get::<AddRoFn>(b"mpv_stream_cb_add_ro\0") }
                .map_err(|e| e.to_string())?;
            Ok(Libmpv {
                add_ro: *add_ro,
                _library: library,
            })
        })();
        (path.to_owned(), loaded)
    });
    if loaded_from != path {
        anyhow::bail!("libmpv was loaded from another path in this process");
    }
    loaded
        .as_ref()
        .map_err(|error| anyhow::anyhow!("could not load libmpv's stream_cb API: {error}"))
}

/// Registers [`PROTOCOL`] on the mpv handle at `ctx`, with the embedded
/// server behind it, resolving `mpv_stream_cb_add_ro` from the libmpv at
/// `libmpv_path` -- the one media_kit loaded (`NativeLibrary.path`).
///
/// Once per handle, which the engine keeps (one call per player); a
/// second call is harmless: mpv refuses a protocol a handle already has
/// (`MPV_ERROR_INVALID_PARAMETER`), and that is answered as
/// [`Registration::Already`]. Nothing here remembers handles by address --
/// a destroyed handle's address can be the next player's, and a record of
/// it would then skip a registration mpv never saw. `ctx` must be an
/// initialised handle that stays alive while mpv can open a stream on it
/// (Dart awaits `waitForPlayerInitialization` first); `0` is refused.
pub fn register(ctx: i64, libmpv_path: &str) -> anyhow::Result<Registration> {
    let ctx = handle_address(ctx)?;
    let library = libmpv(libmpv_path)?;
    register_with(library, ctx, &ServerOpener)
}

fn handle_address(ctx: i64) -> anyhow::Result<usize> {
    match usize::try_from(ctx) {
        Ok(0) => anyhow::bail!("no mpv handle: the player has not initialised"),
        Ok(ctx) => Ok(ctx),
        Err(_) => anyhow::bail!("{ctx} is not an mpv handle's address"),
    }
}

/// [`register`] through `library`, with `opener` behind the protocol.
fn register_with<O: Opener>(
    library: &dyn AddRo,
    ctx: usize,
    opener: &'static O,
) -> anyhow::Result<Registration> {
    let user_data = std::ptr::from_ref(opener).cast_mut().cast::<c_void>();
    match library.add_ro(ctx, open_cb::<O>, user_data) {
        0 => Ok(Registration::Registered),
        // The protocol is there already, which is all a caller wants: the
        // name is fixed, so a duplicate is the one way to be refused this.
        MPV_ERROR_INVALID_PARAMETER => Ok(Registration::Already),
        code => anyhow::bail!("mpv refused the {PROTOCOL} protocol (error {code})"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::{Arc, Condvar};
    use std::time::Duration;

    /// What the fake reader's owner can see and do from outside it.
    #[derive(Default)]
    struct Shared {
        closed: AtomicBool,
        cancelled: AtomicBool,
        seeks: Mutex<Vec<u64>>,
        /// Set while a read waits for [`Self::gate`].
        parked: AtomicBool,
        gate: (Mutex<bool>, Condvar),
    }

    struct FakeReader {
        data: Vec<u8>,
        at: usize,
        shared: Arc<Shared>,
        /// Whether a read waits for the gate or a cancel.
        blocks: bool,
    }

    struct FakeCanceller(Arc<Shared>);

    impl Cancel for FakeCanceller {
        fn cancel(&self) {
            self.0.cancelled.store(true, Ordering::SeqCst);
            let (lock, wake) = &self.0.gate;
            *lock.lock().unwrap() = true;
            wake.notify_all();
        }
    }

    impl StreamReader for FakeReader {
        type Canceller = FakeCanceller;

        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            if self.blocks {
                self.shared.parked.store(true, Ordering::SeqCst);
                let (lock, wake) = &self.shared.gate;
                let mut open = lock.lock().unwrap();
                while !*open {
                    open = wake.wait(open).unwrap();
                }
            }
            if self.shared.cancelled.load(Ordering::SeqCst) {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "cancelled"));
            }
            let n = buf.len().min(self.data.len() - self.at);
            buf[..n].copy_from_slice(&self.data[self.at..self.at + n]);
            self.at += n;
            Ok(n)
        }

        fn seek(&mut self, offset: u64) -> io::Result<u64> {
            if self.shared.cancelled.load(Ordering::SeqCst) {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "cancelled"));
            }
            self.shared.seeks.lock().unwrap().push(offset);
            self.at = usize::try_from(offset).unwrap().min(self.data.len());
            Ok(self.at as u64)
        }

        fn size(&self) -> u64 {
            self.data.len() as u64
        }

        fn canceller(&self) -> FakeCanceller {
            FakeCanceller(self.shared.clone())
        }
    }

    impl Drop for FakeReader {
        fn drop(&mut self) {
            self.shared.closed.store(true, Ordering::SeqCst);
        }
    }

    /// Opens the ids it knows, recording every id it was asked for.
    struct FakeOpener {
        known: &'static str,
        blocks: bool,
        shared: Arc<Shared>,
        asked: Mutex<Vec<String>>,
    }

    impl Opener for FakeOpener {
        type Reader = FakeReader;

        fn open(&self, id: &str) -> Result<FakeReader, String> {
            self.asked.lock().unwrap().push(id.to_owned());
            if id != self.known {
                return Err("unknownId".into());
            }
            Ok(FakeReader {
                data: (0..=255u8).cycle().take(1000).collect(),
                at: 0,
                shared: self.shared.clone(),
                blocks: self.blocks,
            })
        }
    }

    const ID: &str = "0123456789abcdef0123456789abcdef";

    fn opener(blocks: bool) -> &'static FakeOpener {
        Box::leak(Box::new(FakeOpener {
            known: ID,
            blocks,
            shared: Arc::default(),
            asked: Mutex::default(),
        }))
    }

    fn empty_info() -> MpvStreamCbInfo {
        MpvStreamCbInfo {
            cookie: std::ptr::null_mut(),
            read_fn: None,
            seek_fn: None,
            size_fn: None,
            close_fn: None,
            cancel_fn: None,
        }
    }

    /// Opens `uri` the way mpv does: through the user data `register`
    /// hands `mpv_stream_cb_add_ro`.
    fn open(opener: &'static FakeOpener, uri: &str) -> (c_int, MpvStreamCbInfo) {
        let uri = CString::new(uri).unwrap();
        let mut info = empty_info();
        let user_data = std::ptr::from_ref(opener).cast_mut().cast::<c_void>();
        // SAFETY: a live opener, a NUL-terminated URI and a writable info.
        let code = unsafe { open_cb::<FakeOpener>(user_data, uri.as_ptr().cast_mut(), &mut info) };
        (code, info)
    }

    #[test]
    fn the_id_is_what_follows_the_scheme_and_nothing_else_is_one() {
        assert_eq!(media_id(&format!("xtremio://{ID}")), Some(ID));
        assert_eq!(media_id(&format!("XTREMIO://{ID}")), Some(ID));
        for not_one in [
            "xtremio://",
            "http://127.0.0.1:1/abc",
            "xtremio:abc",
            "fd://3",
            "xtremio://abc/def",
            "xtremio://abc?x=1",
            "xtremio://../etc/passwd",
            "xtremios://abc",
        ] {
            assert_eq!(media_id(not_one), None, "{not_one}");
        }
    }

    /// **An open that finds no reader tells mpv the load failed, and leaves
    /// nothing behind**: no cookie for a URL that names no id, and the
    /// opener is not even asked about one.
    #[test]
    fn an_open_without_a_reader_fails_the_load() {
        let opener = opener(false);
        let (code, info) = open(opener, "xtremio://feedface");
        assert_eq!(code, MPV_ERROR_LOADING_FAILED);
        assert!(info.cookie.is_null() && info.read_fn.is_none());
        let (code, _) = open(opener, "xtremio://not/an/id");
        assert_eq!(code, MPV_ERROR_LOADING_FAILED);
        assert_eq!(*opener.asked.lock().unwrap(), vec!["feedface".to_owned()]);
    }

    /// **The cookie is the reader, from open to close**: reads, seeks and
    /// the size go to the reader the open made, and the close -- once --
    /// drops it, which is what closes a server reader.
    #[test]
    fn the_cookie_reads_seeks_sizes_and_closes_the_reader_it_opened() {
        let opener = opener(false);
        let (code, info) = open(opener, &format!("xtremio://{ID}"));
        assert_eq!(code, 0);
        assert_eq!(*opener.asked.lock().unwrap(), vec![ID.to_owned()]);
        let (read, seek, size, close) = (
            info.read_fn.unwrap(),
            info.seek_fn.unwrap(),
            info.size_fn.unwrap(),
            info.close_fn.unwrap(),
        );
        assert!(info.cancel_fn.is_some());
        let mut buf = [0u8; 16];
        // SAFETY: the cookie open handed out, a 16-byte buffer.
        unsafe {
            assert_eq!(size(info.cookie), 1000);
            assert_eq!(read(info.cookie, buf.as_mut_ptr().cast(), 16), 16);
            assert_eq!(buf[..4], [0, 1, 2, 3]);
            assert_eq!(seek(info.cookie, 300), 300);
            assert_eq!(read(info.cookie, buf.as_mut_ptr().cast(), 4), 4);
            assert_eq!(buf[..4], [44, 45, 46, 47]); // 300 % 256
            assert_eq!(seek(info.cookie, -1), MPV_ERROR_GENERIC);
            assert_eq!(seek(info.cookie, 996), 996);
            assert_eq!(read(info.cookie, buf.as_mut_ptr().cast(), 16), 4);
            assert_eq!(read(info.cookie, buf.as_mut_ptr().cast(), 16), 0);
        }
        assert_eq!(*opener.shared.seeks.lock().unwrap(), vec![300, 996]);
        assert!(!opener.shared.closed.load(Ordering::SeqCst));
        // SAFETY: the cookie, closed once.
        unsafe { close(info.cookie) };
        assert!(opener.shared.closed.load(Ordering::SeqCst));
    }

    /// **A cancel wakes a read that is blocked, from another thread,
    /// without waiting for it** -- the reader's lock is the read's, and the
    /// cancel does not take it -- and it sticks: the next read and seek are
    /// errors at once.
    #[test]
    fn a_cancel_overtakes_a_blocked_read_and_sticks() {
        let opener = opener(true);
        let (code, info) = open(opener, &format!("xtremio://{ID}"));
        assert_eq!(code, 0);
        let cookie = info.cookie as usize;
        let read = info.read_fn.unwrap();
        let reads = Arc::new(AtomicUsize::new(0));
        let reading = std::thread::spawn({
            let reads = reads.clone();
            move || {
                let mut buf = [0u8; 8];
                // SAFETY: the live cookie and an 8-byte buffer.
                let got = unsafe { read(cookie as *mut c_void, buf.as_mut_ptr().cast(), 8) };
                reads.fetch_add(1, Ordering::SeqCst);
                got
            }
        });
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while !opener.shared.parked.load(Ordering::SeqCst) {
            assert!(
                std::time::Instant::now() < deadline,
                "the read never parked"
            );
            std::thread::yield_now();
        }
        assert_eq!(reads.load(Ordering::SeqCst), 0, "the read did not block");
        // SAFETY: the live cookie; this thread holds no lock of the read's.
        unsafe { info.cancel_fn.unwrap()(info.cookie) };
        assert_eq!(reading.join().unwrap(), -1);
        let mut buf = [0u8; 8];
        // SAFETY: the live cookie and an 8-byte buffer.
        unsafe {
            assert_eq!(read(info.cookie, buf.as_mut_ptr().cast(), 8), -1);
            assert_eq!(info.seek_fn.unwrap()(info.cookie, 0), MPV_ERROR_GENERIC);
            info.close_fn.unwrap()(info.cookie);
        }
        assert!(opener.shared.closed.load(Ordering::SeqCst));
    }

    /// Answers what a test says, and counts the asks.
    struct FakeLibrary {
        answer: c_int,
        asks: AtomicUsize,
    }

    impl AddRo for FakeLibrary {
        fn add_ro(&self, _ctx: usize, _open: OpenFn, _user_data: *mut c_void) -> c_int {
            self.asks.fetch_add(1, Ordering::SeqCst);
            self.answer
        }
    }

    /// **A second registration is a no-op, not an error**: mpv refuses a
    /// protocol a handle already has, and the caller is told it is there.
    /// Any other refusal is an error, and a null handle is refused before
    /// anything is loaded or asked.
    #[test]
    fn a_second_registration_is_already_there() {
        let opener = opener(false);
        let fresh = FakeLibrary {
            answer: 0,
            asks: AtomicUsize::new(0),
        };
        assert_eq!(
            register_with(&fresh, 0x5eed, opener).unwrap(),
            Registration::Registered
        );
        let taken = FakeLibrary {
            answer: MPV_ERROR_INVALID_PARAMETER,
            asks: AtomicUsize::new(0),
        };
        assert_eq!(
            register_with(&taken, 0x5eed, opener).unwrap(),
            Registration::Already
        );
        let refusing = FakeLibrary {
            answer: -1,
            asks: AtomicUsize::new(0),
        };
        assert!(register_with(&refusing, 0x5eed, opener).is_err());
        assert_eq!(
            fresh.asks.load(Ordering::SeqCst) + taken.asks.load(Ordering::SeqCst),
            2
        );
        assert!(register(0, "/nonexistent/libmpv.so").is_err());
        assert!(handle_address(-1).is_err());
    }
}
