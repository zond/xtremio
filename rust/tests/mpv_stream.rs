//! **mpv plays a torrent through `xtremio://<id>`**, end to end on this
//! machine: the embedded server started offline, a torrent built here with
//! its pieces placed where the server keeps them, the id registered and
//! resolved, and a real libmpv (`vo=null`, `ao=null`) reading it through
//! `crate::mpv_stream`'s callbacks and the server's `MediaReader` --
//! position advances, and a seek lands.
//!
//! It needs a libmpv to load and an `ffmpeg` to make the film with, and
//! says so and passes without them (CI's runners have neither). No peer,
//! tracker or network at any point.

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::path::Path;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use xtremio_core::server::StartConfig;

/// Pieces of the torrent built here.
const PIECE: usize = 256 * 1024;

/// How long the film is, and where the seek goes.
const FILM_SECONDS: u32 = 40;
const SEEK_TO: f64 = 30.0;

fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| tokio::runtime::Runtime::new().expect("test runtime"))
}

/// The slice of libmpv's client API this test drives.
struct Mpv {
    create: unsafe extern "C" fn() -> *mut c_void,
    initialize: unsafe extern "C" fn(*mut c_void) -> c_int,
    set_option_string: unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char) -> c_int,
    command: unsafe extern "C" fn(*mut c_void, *const *const c_char) -> c_int,
    get_property_string: unsafe extern "C" fn(*mut c_void, *const c_char) -> *mut c_char,
    free: unsafe extern "C" fn(*mut c_void),
    terminate_destroy: unsafe extern "C" fn(*mut c_void),
    _library: libloading::Library,
}

/// The name libmpv is loaded by: `XTREMIO_LIBMPV`, else the soname.
fn libmpv_name() -> String {
    std::env::var("XTREMIO_LIBMPV").unwrap_or_else(|_| "libmpv.so.2".to_owned())
}

fn load_mpv(name: &str) -> Option<Mpv> {
    // SAFETY: loading libmpv runs its initialisers, which have no
    // preconditions; every symbol below is cast to its `client.h` type.
    unsafe {
        let library = libloading::Library::new(name).ok()?;
        Some(Mpv {
            create: *library.get(b"mpv_create\0").ok()?,
            initialize: *library.get(b"mpv_initialize\0").ok()?,
            set_option_string: *library.get(b"mpv_set_option_string\0").ok()?,
            command: *library.get(b"mpv_command\0").ok()?,
            get_property_string: *library.get(b"mpv_get_property_string\0").ok()?,
            free: *library.get(b"mpv_free\0").ok()?,
            terminate_destroy: *library.get(b"mpv_terminate_destroy\0").ok()?,
            _library: library,
        })
    }
}

impl Mpv {
    fn option(&self, ctx: *mut c_void, name: &str, value: &str) {
        let (name, value) = (CString::new(name).unwrap(), CString::new(value).unwrap());
        // SAFETY: a live handle and NUL-terminated strings.
        let code = unsafe { (self.set_option_string)(ctx, name.as_ptr(), value.as_ptr()) };
        assert_eq!(code, 0, "mpv refused option {name:?}={value:?}");
    }

    fn command(&self, ctx: *mut c_void, args: &[&str]) {
        let owned: Vec<CString> = args.iter().map(|arg| CString::new(*arg).unwrap()).collect();
        let mut argv: Vec<*const c_char> = owned.iter().map(|arg| arg.as_ptr()).collect();
        argv.push(std::ptr::null());
        // SAFETY: a live handle and a NULL-terminated argv of C strings.
        let code = unsafe { (self.command)(ctx, argv.as_ptr()) };
        assert_eq!(code, 0, "mpv refused {args:?}");
    }

    fn property(&self, ctx: *mut c_void, name: &str) -> Option<String> {
        let name = CString::new(name).unwrap();
        // SAFETY: a live handle; mpv answers a string it allocated, or null.
        unsafe {
            let value = (self.get_property_string)(ctx, name.as_ptr());
            if value.is_null() {
                return None;
            }
            let text = CStr::from_ptr(value).to_string_lossy().into_owned();
            (self.free)(value.cast());
            Some(text)
        }
    }

    /// A player as the test wants one: no picture, no sound, and a small
    /// demuxer cache, so a seek is a read of the stream at a new offset and
    /// not a jump inside what was already read.
    fn player(&self) -> *mut c_void {
        // SAFETY: libmpv's documented order: create, options, initialize.
        let ctx = unsafe { (self.create)() };
        assert!(!ctx.is_null());
        self.option(ctx, "vo", "null");
        self.option(ctx, "ao", "null");
        self.option(ctx, "demuxer-max-bytes", "262144");
        self.option(ctx, "demuxer-max-back-bytes", "0");
        self.option(ctx, "force-seekable", "yes");
        // SAFETY: the handle just created.
        assert_eq!(unsafe { (self.initialize)(ctx) }, 0);
        ctx
    }

    fn position(&self, ctx: *mut c_void) -> Option<f64> {
        self.property(ctx, "time-pos")?.parse().ok()
    }
}

/// A film mpv can decode and seek in, made by `ffmpeg`: a Matroska file,
/// whose index is at the end, which is what makes a torrent's seek worth
/// testing. `None` without an `ffmpeg`.
fn make_film(path: &Path) -> Option<()> {
    let tone = if path.ends_with("holed.mkv") {
        660
    } else {
        440
    };
    let status = std::process::Command::new("ffmpeg")
        .args(["-v", "error", "-y", "-f", "lavfi", "-i"])
        .arg(format!(
            "testsrc=size=320x240:rate=25:duration={FILM_SECONDS}"
        ))
        .args(["-f", "lavfi", "-i"])
        .arg(format!("sine=frequency={tone}:duration={FILM_SECONDS}"))
        .args(["-c:v", "mpeg4", "-q:v", "5", "-g", "25", "-c:a", "mp2"])
        .arg(path)
        .status()
        .ok()?;
    status.success().then_some(())
}

/// A single-file torrent over `film`, with its info hash.
fn real_torrent(film: &Path) -> (Vec<u8>, String) {
    runtime().block_on(async {
        let torrent = librqbit::create_torrent(
            film,
            librqbit::CreateTorrentOptions {
                name: None,
                trackers: Vec::new(),
                piece_length: Some(PIECE as u32),
            },
            &librqbit::spawn_utils::BlockingSpawner::new(1),
        )
        .await
        .expect("create torrent");
        (
            torrent.as_bytes().expect("serialize").to_vec(),
            torrent.info_hash().as_string(),
        )
    })
}

/// The pieces of `film` that `keep` says to, where the server keeps
/// torrent data: `<root>/rqbit-downloads/.pieces/<info hash>/<piece /
/// 1000>/<piece>`, the last one as long as what is left.
fn place_pieces(root: &Path, info_hash: &str, film: &Path, keep: impl Fn(usize, usize) -> bool) {
    let bytes = std::fs::read(film).expect("read the film");
    let dir = root
        .join("rqbit-downloads")
        .join(".pieces")
        .join(info_hash.to_ascii_lowercase());
    let pieces = bytes.len().div_ceil(PIECE);
    for (piece, data) in bytes.chunks(PIECE).enumerate() {
        if !keep(piece, pieces) {
            continue;
        }
        let bucket = dir.join((piece / 1000).to_string());
        std::fs::create_dir_all(&bucket).expect("piece bucket");
        std::fs::write(bucket.join(piece.to_string()), data).expect("write piece");
    }
}

/// `POST /create` with the server's bearer token, as `tests/downloads.rs`
/// does: how a torrent whose metadata is known gets into the session.
fn create_torrent_on_server(base_url: &url::Url, torrent: &[u8]) -> serde_json::Value {
    let token = xtremio_core::server::token_for(base_url).expect("server token");
    let hex: String = torrent.iter().map(|byte| format!("{byte:02x}")).collect();
    runtime().block_on(async {
        let client = xtremio_core::env::http_client_builder()
            .no_proxy()
            .timeout(Duration::from_secs(10))
            .build()
            .expect("HTTP client");
        client
            .post(base_url.join("create").expect("create URL"))
            .bearer_auth(token)
            .json(&serde_json::json!({ "torrent": hex }))
            .send()
            .await
            .expect("POST /create")
            .error_for_status()
            .expect("create succeeded")
            .json()
            .await
            .expect("create JSON")
    })
}

/// Polls `done` until it holds, or fails naming `what`.
fn wait_for(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(30);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn mpv_plays_a_torrent_through_its_media_id_and_seeks_in_it() -> anyhow::Result<()> {
    let name = libmpv_name();
    let Some(mpv) = load_mpv(&name) else {
        eprintln!("SKIPPED: no libmpv to load as {name} (set XTREMIO_LIBMPV)");
        return Ok(());
    };
    let tmp = tempfile::tempdir()?;
    let film = tmp.path().join("film.mkv");
    if make_film(&film).is_none() {
        eprintln!("SKIPPED: no ffmpeg to make the film with");
        return Ok(());
    }
    let (torrent, info_hash) = real_torrent(&film);

    let cache_root = tmp.path().join("cache");
    let base_url = xtremio_core::server::start(StartConfig {
        config_dir: tmp.path().join("server"),
        cache_dir: cache_root.clone(),
        offline: true,
    })?;
    // After the start: its sweep deletes pieces of torrents it does not know.
    place_pieces(&cache_root, &info_hash, &film, |_, _| true);
    let created = create_torrent_on_server(&base_url, &torrent);
    assert_eq!(created["infoHash"], info_hash, "{created}");

    // What the app does for a torrent: register the core's URL, record the
    // play, resolve before handing mpv the id.
    let app = xtremio_core::state::state();
    let url = base_url.join(&format!("{info_hash}/0"))?;
    let id = xtremio_core::media::register_in(&app, url.as_str())?;
    xtremio_core::media::set_play_in(&app, &id, "test.1".into(), "normal")?;
    let resolved: serde_json::Value =
        serde_json::from_str(&xtremio_core::media::resolve_in(&app, &id)?)?;
    assert_eq!(resolved["inProcess"], true, "{resolved}");
    assert_eq!(
        resolved["len"],
        std::fs::metadata(&film)?.len(),
        "{resolved}"
    );

    let ctx = mpv.player();

    use xtremio_core::mpv_stream::{register, Registration};
    assert_eq!(register(ctx as i64, &name)?, Registration::Registered);
    assert_eq!(
        register(ctx as i64, &name)?,
        Registration::Already,
        "a second registration on the handle is a no-op"
    );

    mpv.command(ctx, &["loadfile", &format!("xtremio://{id}")]);
    wait_for("the film to play past a second", || {
        mpv.position(ctx).is_some_and(|at| at > 1.0)
    });
    assert_eq!(
        mpv.property(ctx, "path").as_deref(),
        Some(format!("xtremio://{id}").as_str())
    );
    let duration: f64 = mpv
        .property(ctx, "duration")
        .and_then(|d| d.parse().ok())
        .expect("a duration");
    assert!(
        (duration - f64::from(FILM_SECONDS)).abs() < 1.0,
        "{duration}"
    );

    mpv.command(ctx, &["seek", &SEEK_TO.to_string(), "absolute+exact"]);
    wait_for("the seek to land", || {
        mpv.position(ctx).is_some_and(|at| at >= SEEK_TO)
    });
    let landed = mpv.position(ctx).expect("a position");
    wait_for("playback to go on after the seek", || {
        mpv.position(ctx).is_some_and(|at| at > landed + 0.5)
    });

    // SAFETY: the handle, destroyed once; its stream closes with it.
    unsafe { (mpv.terminate_destroy)(ctx) };

    // **A read nobody can answer does not hold up the player's end.** A
    // `stream_cb` read has no `network-timeout`: it waits for the bytes or
    // a cancel. Here a torrent with a hole in it and no peer, and a seek
    // into the hole -- the read parks for good -- and then the player is
    // destroyed, which mpv does by cancelling the stream (`cancel_fn`).
    let holed = tmp.path().join("holed.mkv");
    make_film(&holed).expect("ffmpeg made the first film");
    // Different bytes, so a different torrent: the tone's frequency.
    let (torrent, holed_hash) = real_torrent(&holed);
    assert_ne!(holed_hash, info_hash);
    // The start and the end (the Matroska index), and nothing between.
    place_pieces(&cache_root, &holed_hash, &holed, |piece, pieces| {
        piece < 3 || piece + 2 >= pieces
    });
    create_torrent_on_server(&base_url, &torrent);
    let id = xtremio_core::media::register_in(
        &app,
        base_url.join(&format!("{holed_hash}/0"))?.as_str(),
    )?;
    xtremio_core::media::set_play_in(&app, &id, "test.2".into(), "normal")?;
    xtremio_core::media::resolve_in(&app, &id)?;
    let ctx = mpv.player();
    register(ctx as i64, &name)?;
    mpv.command(ctx, &["loadfile", &format!("xtremio://{id}")]);
    wait_for("the holed film to start", || {
        mpv.position(ctx).is_some_and(|at| at > 0.5)
    });
    mpv.command(ctx, &["seek", "25", "absolute+exact"]);
    wait_for("the read to park in the hole", || {
        mpv.property(ctx, "paused-for-cache").as_deref() == Some("yes")
            || mpv.property(ctx, "seeking").as_deref() == Some("yes")
    });
    let ctx = ctx as usize;
    let (done, destroyed) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        // SAFETY: the handle, destroyed once, on this thread alone.
        unsafe { (mpv.terminate_destroy)(ctx as *mut c_void) };
        let _ = done.send(());
    });
    destroyed
        .recv_timeout(Duration::from_secs(10))
        .expect("destroying the player waited on a read that will never be answered");

    xtremio_core::server::stop()?;
    Ok(())
}
