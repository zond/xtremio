//! `XtremioEnv`: the `stremio_core::runtime::Env` this app runs the engine
//! on. Modeled on stremio-core-kotlin's `AndroidEnv` and stremiox's `TvosEnv`.
//!
//! - **fetch**: reqwest + rustls; JSON bodies in, JSON out (errors name the
//!   failing JSON path). A request to the embedded server carries its
//!   bearer token (`crate::server::token_for`); no other host gets it.
//!   [`fetch_text`] is the same path for a body that is not JSON -- a
//!   subtitle file -- and shares the client and the token rule rather than
//!   standing up a second one.
//! - **storage**: one JSON file per key under a directory Dart chooses;
//!   writes are temp-then-fsync-then-rename so a crash can never leave a
//!   half-written bucket.
//! - **executors**: two lib-owned tokio runtimes, `CONCURRENT` for parallel
//!   effects and a single-worker `SEQUENTIAL` one because the engine relies
//!   on storage/library persistence effects running in order.
//! - **time**: `chrono::Utc::now()`; analytics are stubbed (built without the
//!   `analytics` feature).

use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::Context;
use chrono::{DateTime, Utc};
use futures::future;
use http::header::{HeaderValue, AUTHORIZATION};
use http::{Method, Request};
use reqwest::{Body, Client};
use serde::{Deserialize, Serialize};
use stremio_core::models::ctx::Ctx;
use stremio_core::models::streaming_server::StreamingServer;
use stremio_core::runtime::{Env, EnvError, EnvFuture, EnvFutureExt, TryEnvFuture};

// The three statics below stay statics on purpose, and are not part of
// `crate::state::AppState`: an executor and a connection pool are
// process-wide by nature. They are built once, hold no per-session state,
// cost real OS threads and sockets to create, and outliving a shutdown is
// the point -- work spawned before it still has somewhere to run, and the
// next `core_init` reuses the pool instead of standing up new threads.

/// Effects that may run in parallel (catalog fetches, addon calls, ...), the
/// runtime-event pump, and async work started by the FRB layer.
pub static CONCURRENT: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    let workers = std::thread::available_parallelism()
        .map(|n| n.get().min(4))
        .unwrap_or(2);
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(workers)
        .thread_name("xtremio-core")
        .enable_all()
        .build()
        .expect("build concurrent tokio runtime")
});

/// Effects that must not race each other (storage writes, library sync).
pub static SEQUENTIAL: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .thread_name("xtremio-core-seq")
        .enable_all()
        .build()
        .expect("build sequential tokio runtime")
});

/// Shared HTTP client. Connects lazily, so building it outside a runtime is
/// fine.
static CLIENT: LazyLock<Client> = LazyLock::new(|| {
    Client::builder()
        .connect_timeout(Duration::from_secs(30))
        .timeout(Duration::from_secs(60))
        .user_agent(concat!("xtremio/", env!("CARGO_PKG_VERSION")))
        .build()
        .expect("build reqwest client")
});

/// Root for persisted buckets: `<dir>/<key>.json`. Set once from `core_init`.
///
/// This one is a forced global, and the only piece of session state that
/// did not move into `crate::state::AppState`. `Env` declares `fetch`,
/// `get_storage`, `set_storage` and `now` as associated functions with no
/// `self` (stremio-core `src/runtime/env.rs`, `pub trait Env`), so an
/// implementation is a *type* and has no instance to hang a storage
/// directory on: `XtremioEnv::get_storage(key)` has nothing but statics to
/// read from.
///
/// If we ever want two independent cores in one process, the way out is a
/// type-indexed context -- `struct XtremioEnv<C: EnvContext>(PhantomData<C>)`
/// with the directory behind `C`, which type-checks because `Runtime` only
/// asks for `E: Env + Send + 'static` and the trait's defaulted methods
/// only add `Self: Sized + 'static`. A `tokio::task_local!` context was
/// considered and rejected: a future that escapes the scope reads the
/// wrong context silently instead of failing loudly, and storage effects
/// are exactly the futures that get spawned onwards.
static STORAGE_DIR: RwLock<Option<PathBuf>> = RwLock::new(None);

/// Points storage at `dir` (created if missing).
pub fn set_storage_dir(dir: impl Into<PathBuf>) -> anyhow::Result<()> {
    let dir = dir.into();
    std::fs::create_dir_all(&dir).with_context(|| format!("create storage dir {dir:?}"))?;
    set_storage_dir_raw(Some(dir));
    Ok(())
}

fn set_storage_dir_raw(dir: Option<PathBuf>) {
    *STORAGE_DIR
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = dir;
}

/// The configured storage directory, if any.
pub fn storage_dir() -> Option<PathBuf> {
    STORAGE_DIR
        .read()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone()
}

fn storage_path(key: &str) -> Option<PathBuf> {
    storage_dir().map(|dir| dir.join(format!("{key}.json")))
}

/// Drives a future to completion on the sequential runtime. Only call from a
/// thread that is not itself a tokio worker (FRB's pool is fine).
pub fn block_on<F: Future>(future: F) -> F::Output {
    SEQUENTIAL.block_on(future)
}

/// Writes `bytes` to `path` atomically: temp file next to it, fsync, rename.
/// Shared with `crate::downloads`, whose registry wants the same guarantee
/// as a stremio-core bucket: a crash mid-write can never leave half a file.
pub(crate) fn write_atomically(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(format!(".tmp-{}-{nanos}", std::process::id()));
    let tmp = PathBuf::from(tmp);

    let result = (|| {
        let mut file = std::fs::File::create(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

/// Fetches `url` as text, at most `most_bytes` of it.
///
/// [`Env::fetch`] is the crate's one HTTP path and it deserializes JSON,
/// which a subtitle file is not -- so this is the same path with the
/// decoding left off: the same [`CLIENT`] (one connection pool, one user
/// agent, one set of timeouts) and the same rule about the embedded
/// server's bearer token, and not a second client built somewhere else.
///
/// Decoded lossily on purpose. Plenty of subtitle files are Latin-1 or
/// worse, and the caller reads only the ASCII digits and colons of their
/// timing lines; refusing a file over an encoding would lose a set of
/// observations that is perfectly readable.
///
/// The cap is a real bound rather than a check afterwards -- the body is
/// accumulated chunk by chunk and abandoned the moment it is exceeded --
/// because a URL that answers with something enormous must not be able to
/// spend the device's memory on it.
///
/// **The URL never reaches the error.** An addon's URL can carry a debrid
/// API key (`AGENTS.md`, "Deep links open an addon"), and `reqwest` puts
/// the URL it was given into its own `Display`, so every error out of it
/// is stripped with `without_url` before it becomes a message anyone can
/// log.
pub(crate) async fn fetch_text(url: &url::Url, most_bytes: usize) -> anyhow::Result<String> {
    let mut request = CLIENT.get(url.clone());
    if let Some(token) = crate::server::token_for(url) {
        request = request.bearer_auth(token);
    }
    let mut response = request
        .send()
        .await
        .map_err(|error| anyhow::anyhow!("fetch failed: {}", error.without_url()))?;
    let status = response.status();
    if !status.is_success() {
        anyhow::bail!("HTTP {}", status.as_u16());
    }
    let mut body: Vec<u8> = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|error| anyhow::anyhow!("fetch failed: {}", error.without_url()))?
    {
        if body.len() + chunk.len() > most_bytes {
            anyhow::bail!("larger than {most_bytes} bytes");
        }
        body.extend_from_slice(&chunk);
    }
    Ok(String::from_utf8_lossy(&body).into_owned())
}

/// Uninhabited: `Env` is implemented on the type, never on a value.
pub enum XtremioEnv {}

impl Env for XtremioEnv {
    fn fetch<IN: Serialize + Send + 'static, OUT: for<'de> Deserialize<'de> + Send + 'static>(
        request: Request<IN>,
    ) -> TryEnvFuture<OUT> {
        let (parts, body) = request.into_parts();
        let body = match serde_json::to_string(&body) {
            Ok(body) if body != "null" && parts.method != Method::GET => Body::from(body),
            Ok(_) => Body::from(Vec::<u8>::new()),
            Err(error) => return future::err(EnvError::Serde(error.to_string())).boxed_env(),
        };
        let mut request = match reqwest::Request::try_from(Request::from_parts(parts, body)) {
            Ok(request) => request,
            Err(error) => return future::err(EnvError::Fetch(error.to_string())).boxed_env(),
        };
        // The embedded server's control API (settings, stats, create, ...)
        // requires its per-launch bearer token; no other host gets it.
        if let Some(token) = crate::server::token_for(request.url()) {
            match HeaderValue::from_str(&format!("Bearer {token}")) {
                Ok(mut value) => {
                    value.set_sensitive(true);
                    request.headers_mut().insert(AUTHORIZATION, value);
                }
                Err(error) => {
                    return future::err(EnvError::Fetch(format!("server token: {error}")))
                        .boxed_env()
                }
            }
        }
        async move {
            let response = CLIENT
                .execute(request)
                .await
                .map_err(|error| EnvError::Fetch(error.to_string()))?;
            let status = response.status();
            if !status.is_success() {
                return Err(EnvError::Fetch(format!("HTTP {}", status.as_u16())));
            }
            let bytes = response
                .bytes()
                .await
                .map_err(|error| EnvError::Fetch(error.to_string()))?;
            let mut deserializer = serde_json::Deserializer::from_slice(&bytes);
            serde_path_to_error::deserialize::<_, OUT>(&mut deserializer)
                .map_err(|error| EnvError::Serde(error.to_string()))
        }
        .boxed_env()
    }

    fn get_storage<T: for<'de> Deserialize<'de> + Send + 'static>(
        key: &str,
    ) -> TryEnvFuture<Option<T>> {
        let path = storage_path(key);
        future::lazy(move |_| {
            let path = path.ok_or(EnvError::StorageUnavailable)?;
            match std::fs::read(&path) {
                Ok(bytes) => serde_json::from_slice::<T>(&bytes)
                    .map(Some)
                    .map_err(|error| EnvError::Serde(error.to_string())),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(error) => Err(EnvError::StorageReadError(error.to_string())),
            }
        })
        .boxed_env()
    }

    fn set_storage<T: Serialize>(key: &str, value: Option<&T>) -> TryEnvFuture<()> {
        let path = storage_path(key);
        let serialized = match value.map(serde_json::to_vec) {
            Some(Ok(bytes)) => Some(bytes),
            Some(Err(error)) => return future::err(EnvError::Serde(error.to_string())).boxed_env(),
            None => None,
        };
        future::lazy(move |_| {
            let path = path.ok_or(EnvError::StorageUnavailable)?;
            match serialized {
                Some(bytes) => write_atomically(&path, &bytes)
                    .map_err(|error| EnvError::StorageWriteError(error.to_string())),
                None => match std::fs::remove_file(&path) {
                    Ok(()) => Ok(()),
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
                    Err(error) => Err(EnvError::StorageWriteError(error.to_string())),
                },
            }
        })
        .boxed_env()
    }

    fn exec_concurrent<F: Future<Output = ()> + Send + 'static>(future: F) {
        CONCURRENT.spawn(future);
    }

    fn exec_sequential<F: Future<Output = ()> + Send + 'static>(future: F) {
        SEQUENTIAL.spawn(future);
    }

    fn now() -> DateTime<Utc> {
        Utc::now()
    }

    fn flush_analytics() -> EnvFuture<'static, ()> {
        future::ready(()).boxed_env()
    }

    fn analytics_context(
        _ctx: &Ctx,
        _streaming_server: &StreamingServer,
        _path: &str,
    ) -> serde_json::Value {
        serde_json::json!({})
    }

    #[cfg(debug_assertions)]
    fn log(message: String) {
        tracing::debug!(target: "stremio_core", "{message}");
    }
}

/// Points storage at a fresh temporary directory for the length of `f`.
///
/// The last test-only lock in the crate, and it is here for the reason
/// [`STORAGE_DIR`] is a static at all: an `Env` implementation is a type,
/// so the storage directory cannot be a field of an `AppState` that a test
/// could keep to itself. Every test that wants one takes this -- here, and
/// not in a module's own test mod -- and they queue behind each other
/// instead of pulling the directory out from under one another. Whatever
/// can be said about a pure function is said about one instead
/// (`registry_path_in`, `only_downloaded_moved`), and everything else now
/// runs against its own `AppState`.
#[cfg(test)]
static STORAGE_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(test)]
pub(crate) fn with_storage_dir<T>(f: impl FnOnce(&Path) -> T) -> T {
    let _guard = STORAGE_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let tmp = tempfile::tempdir().expect("tempdir");
    set_storage_dir(tmp.path()).expect("set storage dir");
    let result = f(tmp.path());
    set_storage_dir_raw(None);
    result
}

/// The same with storage pointed nowhere, which is what everything sees
/// before `core_init` has run.
#[cfg(test)]
pub(crate) fn without_storage_dir<T>(f: impl FnOnce() -> T) -> T {
    let _guard = STORAGE_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    set_storage_dir_raw(None);
    f()
}

#[cfg(test)]
mod tests {
    use stremio_core::constants::{SCHEMA_VERSION, SCHEMA_VERSION_STORAGE_KEY};

    use super::*;

    #[derive(Debug, PartialEq, Serialize, Deserialize)]
    struct Item {
        name: String,
        count: u32,
    }

    fn leftover_tmp_files(dir: &Path) -> Vec<PathBuf> {
        std::fs::read_dir(dir)
            .expect("read dir")
            .map(|entry| entry.expect("entry").path())
            .filter(|path| path.to_string_lossy().contains(".tmp-"))
            .collect()
    }

    #[test]
    fn storage_roundtrip_delete_and_missing() {
        with_storage_dir(|dir| {
            let item = Item {
                name: "x".into(),
                count: 3,
            };
            block_on(XtremioEnv::set_storage("item", Some(&item))).expect("set");
            assert!(dir.join("item.json").is_file());
            assert!(leftover_tmp_files(dir).is_empty(), "temp file left behind");

            let read: Option<Item> = block_on(XtremioEnv::get_storage("item")).expect("get");
            assert_eq!(read, Some(item));

            let missing: Option<Item> =
                block_on(XtremioEnv::get_storage("nope")).expect("get missing");
            assert_eq!(missing, None);

            block_on(XtremioEnv::set_storage::<Item>("item", None)).expect("delete");
            assert!(!dir.join("item.json").exists());
            // Deleting again is not an error.
            block_on(XtremioEnv::set_storage::<Item>("item", None)).expect("delete twice");
        });
    }

    #[test]
    fn storage_overwrite_replaces_whole_file() {
        with_storage_dir(|dir| {
            let long = Item {
                name: "a".repeat(4096),
                count: 1,
            };
            let short = Item {
                name: "b".into(),
                count: 2,
            };
            block_on(XtremioEnv::set_storage("item", Some(&long))).expect("set long");
            block_on(XtremioEnv::set_storage("item", Some(&short))).expect("set short");
            let bytes = std::fs::read(dir.join("item.json")).expect("read");
            assert_eq!(
                serde_json::from_slice::<Item>(&bytes).expect("parse"),
                short
            );
            assert!(leftover_tmp_files(dir).is_empty());
        });
    }

    #[test]
    fn corrupt_json_is_a_serde_error() {
        with_storage_dir(|dir| {
            std::fs::write(dir.join("bad.json"), b"{not json").expect("write");
            let error = block_on(XtremioEnv::get_storage::<Item>("bad")).unwrap_err();
            assert!(matches!(error, EnvError::Serde(_)), "{error:?}");
        });
    }

    #[test]
    fn storage_unavailable_until_dir_is_set() {
        without_storage_dir(|| {
            let error = block_on(XtremioEnv::get_storage::<Item>("item")).unwrap_err();
            assert_eq!(error, EnvError::StorageUnavailable);
            let error = block_on(XtremioEnv::set_storage("item", Some(&1u32))).unwrap_err();
            assert_eq!(error, EnvError::StorageUnavailable);
        });
    }

    #[test]
    fn migration_on_empty_storage_writes_current_schema_version() {
        with_storage_dir(|dir| {
            block_on(XtremioEnv::migrate_storage_schema()).expect("migrate");
            let version: Option<u32> =
                block_on(XtremioEnv::get_storage(SCHEMA_VERSION_STORAGE_KEY)).expect("get");
            assert_eq!(version, Some(SCHEMA_VERSION));
            assert!(dir.join("schema_version.json").is_file());
            // Running again is a no-op.
            block_on(XtremioEnv::migrate_storage_schema()).expect("migrate twice");
        });
    }

    /// A server that answers one request with `status` and `body`, and the
    /// URL to reach it at.
    ///
    /// Twenty lines of `TcpStream` rather than the embedded server,
    /// because what is being tested is the *reading* of a body -- its
    /// size, its encoding, a status that is not 200 -- and the embedded
    /// server has no route that would answer any of those on demand. It
    /// also leaves the one test below the only one holding the process's
    /// server.
    fn one_shot(status: &'static str, body: Vec<u8>) -> url::Url {
        use std::io::{BufRead, BufReader, Write};

        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let url = url::Url::parse(&format!(
            "http://{}/subtitle.srt",
            listener.local_addr().expect("addr")
        ))
        .expect("url");
        std::thread::spawn(move || {
            let (stream, _) = listener.accept().expect("accept");
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            while reader.read_line(&mut line).is_ok_and(|read| read > 2) {
                line.clear();
            }
            let mut stream = reader.into_inner();
            let _ = write!(
                stream,
                "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = stream.write_all(&body);
        });
        url
    }

    #[test]
    fn fetch_text_reads_a_body_that_is_not_json() {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nHej\n";
        let url = one_shot("200 OK", vtt.as_bytes().to_vec());
        let body = CONCURRENT
            .block_on(fetch_text(&url, 4096))
            .expect("fetch the file");
        assert_eq!(body, vtt);

        // Latin-1, which plenty of subtitle files really are: the byte
        // that is not UTF-8 becomes a replacement character and the timing
        // lines -- the whole of what the caller reads -- survive.
        let mut latin1 = b"00:00:01,000 --> 00:00:03,000\nH".to_vec();
        latin1.push(0xe9);
        latin1.push(b'j');
        let url = one_shot("200 OK", latin1);
        let body = CONCURRENT
            .block_on(fetch_text(&url, 4096))
            .expect("fetch a file that is not UTF-8");
        assert!(body.starts_with("00:00:01,000 -->"), "{body:?}");
    }

    #[test]
    fn fetch_text_refuses_what_is_too_big_or_not_there() {
        let url = one_shot("200 OK", vec![b'x'; 4096]);
        let error = CONCURRENT
            .block_on(fetch_text(&url, 1024))
            .expect_err("a body over the cap is refused");
        assert!(error.to_string().contains("larger than 1024"), "{error}");

        let url = one_shot("404 Not Found", Vec::new());
        let error = CONCURRENT
            .block_on(fetch_text(&url, 4096))
            .expect_err("a 404 is an error");
        assert!(error.to_string().contains("HTTP 404"), "{error}");
    }

    #[test]
    fn fetch_text_keeps_the_url_out_of_its_errors() {
        // An addon's subtitle URL can carry a debrid API key, so a failure
        // that quotes the URL back writes the key into a log. `reqwest`
        // puts the URL in its own Display; this is the test that it is
        // taken out again.
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("addr");
        drop(listener);
        let url =
            url::Url::parse(&format!("http://{address}/subtitle.srt?apikey=hunter2")).expect("url");
        let error = CONCURRENT
            .block_on(fetch_text(&url, 4096))
            .expect_err("nothing is listening there");
        let message = error.to_string();
        assert!(!message.contains("hunter2"), "{message}");
        assert!(!message.contains(&address.to_string()), "{message}");
    }

    #[derive(Debug, Deserialize)]
    struct Heartbeat {
        success: bool,
    }

    /// The one lib test that starts the *process* state's embedded server,
    /// and it has to: `fetch` reaches `crate::server::token_for` with no
    /// argument to route it, because `Env` has no `self` (see
    /// `STORAGE_DIR`). Every other test that wants a server builds an
    /// `AppState` of its own instead; a second one here would have to
    /// serialize with this.
    #[test]
    fn fetch_decodes_json_from_the_embedded_server() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let url = crate::server::start(crate::server::StartConfig {
            config_dir: tmp.path().join("server"),
            cache_dir: tmp.path().join("cache"),
            port: 0,
            fallback_to_ephemeral: true,
        })
        .expect("server start");

        // The control API wants the per-launch bearer token; `fetch` adds it
        // for the embedded server's URL, so a token-protected route answers.
        let request = Request::get(url.join("heartbeat").unwrap().as_str())
            .body(())
            .expect("request");
        let heartbeat: Heartbeat = CONCURRENT
            .block_on(XtremioEnv::fetch(request))
            .expect("fetch heartbeat");
        assert!(heartbeat.success);

        // The text path shares the client and the token rule rather than
        // building a second one, and this route is what proves it: it
        // answers 401 without the bearer.
        let text = CONCURRENT
            .block_on(fetch_text(&url.join("heartbeat").unwrap(), 4096))
            .expect("fetch heartbeat as text");
        assert!(text.contains("success"), "{text}");

        // Wrong shape names the JSON path.
        #[derive(Debug, Deserialize)]
        #[allow(dead_code)]
        struct Wrong {
            success: String,
        }
        let request = Request::get(url.join("heartbeat").unwrap().as_str())
            .body(())
            .expect("request");
        let error = CONCURRENT
            .block_on(XtremioEnv::fetch::<(), Wrong>(request))
            .unwrap_err();
        assert!(
            matches!(&error, EnvError::Serde(message) if message.contains("success")),
            "{error:?}"
        );

        // Only the embedded server's authority gets the token: the same
        // route on another port (a stranger's server, or nothing) is asked
        // without credentials.
        let mut other = url.clone();
        other
            .set_port(Some(if url.port() == Some(1) { 2 } else { 1 }))
            .unwrap();
        assert!(crate::server::token_for(&url).is_some());
        assert_eq!(crate::server::token_for(&other), None);
        assert!(crate::server::is_embedded_url(&url));
        assert!(!crate::server::is_embedded_url(&other));

        // A route the server does not have is a Fetch error.
        let request = Request::get(url.join("definitely-not-a-route").unwrap().as_str())
            .body(())
            .expect("request");
        let error = CONCURRENT
            .block_on(XtremioEnv::fetch::<(), Heartbeat>(request))
            .unwrap_err();
        assert!(matches!(error, EnvError::Fetch(_)), "{error:?}");

        crate::server::stop().expect("server stop");
    }
}
