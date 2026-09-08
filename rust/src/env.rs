//! `XtremioEnv`: the `stremio_core::runtime::Env` this app runs the engine
//! on. Modeled on stremio-core-kotlin's `AndroidEnv` and stremiox's `TvosEnv`.
//!
//! - **fetch**: reqwest + rustls with Mozilla's roots compiled in
//!   ([`http_client_builder`], which says why not the device store); JSON
//!   bodies in, JSON out (errors name the failing JSON path). A request to
//!   the embedded server carries its bearer token
//!   (`crate::server::token_for`); no other host gets it.
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

/// A reqwest builder whose TLS trust is the compiled-in Mozilla root set
/// (`webpki-root-certs`), verified by rustls itself -- not the device's
/// certificate store through `rustls-platform-verifier`.
///
/// reqwest 0.13's `rustls` feature constructs `rustls_platform_verifier::
/// Verifier` for any client that brings no roots (reqwest 0.13.4
/// `src/async_impl/client.rs`, the `!config.tls_certs_only` arm of the
/// verifier `match`); `tls_certs_only` is the one builder state that takes
/// the plain `with_root_certificates` arm instead, which never names the
/// platform verifier. On Android that verifier runs every handshake through
/// Java's `CertPathValidator` with revocation set to SOFT_FAIL and no
/// NO_FALLBACK, so for a leaf without an OCSP URL Android downloads the
/// issuer's CRL and parses it in Java. Measured on a Chromecast: ~180k Java
/// objects per addon or catalog handshake, and 15 million objects / 400 MB
/// for one tracker whose CRL has 116k entries -- 91% of the app's Java
/// allocation, the GC storm that pushed a 2 GB box into swap and an ANR.
///
/// Trust policy, stated plainly: the app's own HTTPS (addon manifests,
/// catalogs, the Stremio API, subtitles) trusts Mozilla's root program as
/// built into this binary, not the device store. A CA the user installed on
/// the device -- a corporate TLS-inspecting proxy, a debugging proxy -- is
/// no longer trusted for that traffic, and a root Mozilla admits after this
/// build ships is not trusted until the crate is updated. That is the right
/// trade for this app: it talks to public addon servers and Stremio's API,
/// never to an intranet, so a user-installed CA on this path is far more
/// likely an interception than a need; the URLs it sends carry debrid API
/// keys, so a public root set is the conservative choice for them; and the
/// alternative was the Java heap above. Every client this crate builds for
/// its own traffic goes through here so the policy has one home.
///
/// Verified how: reading the reqwest source named above, and on the device
/// by the disappearance of the `Thread-N` tokio workers attaching to the JVM
/// (`jni::vm::java_vm: Attached thread xtremio-core` in logcat) and of the
/// GC bursts that followed each of the app's own handshakes. reqwest
/// exposes nothing to inspect a built client's verifier, so
/// [`tests::our_client_builds_where_the_platform_verifier_cannot`] proves it
/// behaviourally where the desktop allows.
pub fn http_client_builder() -> reqwest::ClientBuilder {
    Client::builder().tls_certs_only(mozilla_roots())
}

/// The compiled-in Mozilla roots as reqwest certificates. Each is a
/// constant DER blob, and `from_der` only stores the bytes (rustls parses
/// them when the client is built), so this cannot fail.
fn mozilla_roots() -> impl Iterator<Item = reqwest::Certificate> {
    webpki_root_certs::TLS_SERVER_ROOT_CERTS
        .iter()
        .map(|der| reqwest::Certificate::from_der(der).expect("compiled-in root is DER"))
}

/// Shared HTTP client. Connects lazily, so building it outside a runtime is
/// fine.
static CLIENT: LazyLock<Client> = LazyLock::new(|| {
    http_client_builder()
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

/// `<storage_dir>/<key>.json`, or `None` before the directory is set.
pub(crate) fn storage_path(key: &str) -> Option<PathBuf> {
    storage_dir().map(|dir| dir.join(format!("{key}.json")))
}

/// Renames `path` to `<file name>.corrupt-<unix seconds>` beside itself and
/// answers where it went.
///
/// For a file the app can read but not parse. Reading it as empty is the
/// right answer for the session -- a bad byte must not stop the app -- but
/// the next write then lands on the only copy of what was there, and for a
/// stremio-core bucket that is a logged-in profile or a library nothing
/// else holds. Moved aside, the bytes stay for a later build or a human,
/// and the fresh file starts beside them. Shared by the buckets
/// (`crate::core`), the downloads registry and the preferences file, so the
/// three spell the name one way and a recovery can look for one pattern.
pub(crate) fn move_aside(path: &Path) -> std::io::Result<PathBuf> {
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let aside = path.with_file_name(format!("{name}.corrupt-{}", Utc::now().timestamp()));
    std::fs::rename(path, &aside)?;
    Ok(aside)
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
/// The cap is a real bound rather than a check afterwards ([`read_capped`],
/// which [`Env::fetch`] reads through as well) because a URL that answers
/// with something enormous must not be able to spend the device's memory
/// on it.
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
    let response = request
        .send()
        .await
        .map_err(|error| anyhow::anyhow!("fetch failed: {}", error.without_url()))?;
    let status = response.status();
    if !status.is_success() {
        anyhow::bail!("HTTP {}", status.as_u16());
    }
    let body = read_capped(response, most_bytes)
        .await
        .map_err(|error| match error {
            ReadError::TooBig(most_bytes) => anyhow::anyhow!("larger than {most_bytes} bytes"),
            ReadError::Transport(error) => anyhow::anyhow!("fetch failed: {}", error.without_url()),
        })?;
    Ok(String::from_utf8_lossy(&body).into_owned())
}

/// The most a JSON answer may be -- an addon's manifest, catalog page,
/// meta, streams or subtitles list, or the Stremio API's answer to a login
/// or a library sync: 32 MiB.
///
/// Measured rather than guessed. The largest legitimate answer found is
/// Cinemeta's meta for General Hospital, some fifteen thousand episodes, at
/// 3.1 MB; Days of Our Lives is 1.2 MB and One Piece 1.4 MB, a catalog page
/// 128 KB to 628 KB, a manifest a few KB. A library synced down whole is a
/// few hundred bytes per item, so tens of thousands of items fit too. Ten
/// times the largest of those rules nothing real out, and rules out what an
/// unbounded read let an installed addon do: reqwest inflates gzip
/// transparently, so a 100 KB body on the wire became 100 MB in memory and
/// 1.7 GB with the value tree on top -- on a 2 GB television box, and on
/// every launch, since the board asks every addon's catalogs.
pub(crate) const MOST_JSON_BYTES: usize = 32 * 1024 * 1024;

/// Why [`read_capped`] stopped short of a whole body.
enum ReadError {
    /// The body passed the cap it was given, which is carried for the
    /// message.
    TooBig(usize),
    Transport(reqwest::Error),
}

/// Reads `response`'s body, at most `most_bytes` of it.
///
/// The cap is a real bound rather than a check afterwards: the body is
/// accumulated chunk by chunk and abandoned the moment it is exceeded. It
/// has to be, because a `Content-Length` says nothing here -- reqwest drops
/// it when it inflates a compressed body, and the inflated size is the one
/// that costs memory -- so only a bound on what arrives after decoding
/// bounds what the device spends. Both HTTP paths of the crate read through
/// this, so neither can grow a body of any size again.
async fn read_capped(
    mut response: reqwest::Response,
    most_bytes: usize,
) -> Result<Vec<u8>, ReadError> {
    let mut body: Vec<u8> = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(ReadError::Transport)? {
        if body.len() + chunk.len() > most_bytes {
            return Err(ReadError::TooBig(most_bytes));
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
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
        // **The URL never reaches an error out of here**, as with
        // [`fetch_text`]: a stream request to a Torrentio-style addon
        // carries the debrid API key in its path, `reqwest` puts the URL it
        // was given into its own `Display`, and `EnvError::Fetch`'s text is
        // what the failed-addons line on screen shows verbatim -- so every
        // `reqwest::Error` here goes through `without_url` first. The host
        // alone is logged, at debug: the readable half the addon health
        // record keeps too, enough to say which addon failed and nothing
        // about how it is configured.
        let mut request = match reqwest::Request::try_from(Request::from_parts(parts, body)) {
            Ok(request) => request,
            Err(error) => {
                return future::err(EnvError::Fetch(error.without_url().to_string())).boxed_env()
            }
        };
        let host = request.url().host_str().map(str::to_owned);
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
            let response = CLIENT.execute(request).await.map_err(|error| {
                let error = error.without_url();
                tracing::debug!(host = host.as_deref().unwrap_or("-"), %error, "fetch failed");
                EnvError::Fetch(error.to_string())
            })?;
            let status = response.status();
            if !status.is_success() {
                return Err(EnvError::Fetch(format!("HTTP {}", status.as_u16())));
            }
            let bytes =
                read_capped(response, MOST_JSON_BYTES)
                    .await
                    .map_err(|error| match error {
                        ReadError::TooBig(most_bytes) => {
                            EnvError::Fetch(format!("response larger than {most_bytes} bytes"))
                        }
                        ReadError::Transport(error) => {
                            EnvError::Fetch(error.without_url().to_string())
                        }
                    })?;
            let mut deserializer = serde_json::Deserializer::from_slice(&bytes);
            serde_path_to_error::deserialize::<_, OUT>(&mut deserializer).map_err(|error| {
                EnvError::Serde(crate::serde_fault::at_path(error.path(), error.inner()))
            })
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
        one_shot_with(status, &[], body)
    }

    /// [`one_shot`] with extra response headers, each `"Name: value"`.
    fn one_shot_with(status: &'static str, headers: &[&'static str], body: Vec<u8>) -> url::Url {
        use std::io::{BufRead, BufReader, Write};

        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let url = url::Url::parse(&format!(
            "http://{}/subtitle.srt",
            listener.local_addr().expect("addr")
        ))
        .expect("url");
        let headers: Vec<&'static str> = headers.to_vec();
        std::thread::spawn(move || {
            let (stream, _) = listener.accept().expect("accept");
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            while reader.read_line(&mut line).is_ok_and(|read| read > 2) {
                line.clear();
            }
            let mut stream = reader.into_inner();
            let extra: String = headers
                .iter()
                .map(|header| format!("{header}\r\n"))
                .collect();
            let _ = write!(
                stream,
                "HTTP/1.1 {status}\r\nContent-Length: {}\r\n{extra}Connection: close\r\n\r\n",
                body.len()
            );
            let _ = stream.write_all(&body);
        });
        url
    }

    /// `Env::fetch` is bounded the way `fetch_text` is, and the bound is on
    /// what arrives *after* decoding: a compressed body a fraction of the
    /// cap on the wire is refused once it inflates past it, before serde
    /// sees a byte. This is the shape a poisoned addon takes -- a 100 KB
    /// answer that costs the device a gigabyte -- and the shape a
    /// `Content-Length` check would wave through.
    #[test]
    fn fetch_refuses_a_body_that_inflates_past_the_cap() {
        use std::io::Write;

        let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        encoder
            .write_all(&vec![b'0'; MOST_JSON_BYTES + 1])
            .expect("compress");
        let wire = encoder.finish().expect("finish");
        assert!(
            wire.len() < 1024 * 1024,
            "the wire body is small; that is the point: {} bytes",
            wire.len()
        );

        let url = one_shot_with("200 OK", &["Content-Encoding: gzip"], wire);
        let request = Request::get(url.as_str()).body(()).expect("request");
        let error = CONCURRENT
            .block_on(XtremioEnv::fetch::<(), serde_json::Value>(request))
            .expect_err("a body over the cap is refused");
        assert!(
            matches!(&error, EnvError::Fetch(message)
                if message.contains("larger than") && message.contains(&MOST_JSON_BYTES.to_string())),
            "{error:?}"
        );
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

    /// `fetch`'s errors keep the URL out the way `fetch_text`'s do. A stream
    /// request to a Torrentio-style addon has the debrid API key in its
    /// path, and `EnvError::Fetch`'s text is what the failed-addons line on
    /// screen shows verbatim -- on a television in a shared room.
    #[test]
    fn fetch_keeps_the_url_out_of_its_errors() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("addr");
        drop(listener);
        let url = format!(
            "http://{address}/realdebrid=SECRETKEY123/stream/movie/tt1.json?apikey=hunter2"
        );
        let request = Request::get(&url).body(()).expect("request");
        let error = CONCURRENT
            .block_on(XtremioEnv::fetch::<(), serde_json::Value>(request))
            .expect_err("nothing is listening there");
        let EnvError::Fetch(message) = &error else {
            panic!("a transport failure is a Fetch error: {error:?}");
        };
        assert!(!message.contains("SECRETKEY123"), "{message}");
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

    /// reqwest exposes nothing about a built client's verifier, so this
    /// proves it by difference. On Linux the platform verifier loads the
    /// system store through `rustls-native-certs`, which takes the store
    /// from `SSL_CERT_FILE` and `SSL_CERT_DIR` when either is set (both are,
    /// in this process: something in the graph runs `openssl-probe` at
    /// start-up and points them at `/usr/lib/ssl`). Pointed at an empty
    /// file and an empty directory it loads nothing, and
    /// `rustls_platform_verifier::Verifier::new` refuses an empty store
    /// ("No CA certificates were loaded from the system"), so a builder that
    /// constructs it cannot `build()`. Ours builds regardless, which is only
    /// possible if it never asked the platform for roots. (Racy in theory
    /// with anything else reading those variables at the same moment;
    /// nothing else in this crate's tests builds a platform-verified client.
    /// Linux only: macOS asks the Security framework and Android the JVM.)
    #[test]
    #[cfg(target_os = "linux")]
    fn our_client_builds_where_the_platform_verifier_cannot() {
        let empty_file = tempfile::NamedTempFile::new().expect("temp file");
        let empty_dir = tempfile::tempdir().expect("temp dir");
        let saved = ["SSL_CERT_FILE", "SSL_CERT_DIR"].map(|name| (name, std::env::var_os(name)));
        std::env::set_var("SSL_CERT_FILE", empty_file.path());
        std::env::set_var("SSL_CERT_DIR", empty_dir.path());
        let platform = Client::builder().build();
        let ours = http_client_builder().build();
        for (name, value) in saved {
            match value {
                Some(value) => std::env::set_var(name, value),
                None => std::env::remove_var(name),
            }
        }
        let error = platform.expect_err("the platform verifier found roots in an empty store");
        assert!(error.is_builder(), "{error:?}");
        ours.expect("our client does not depend on the platform store");
    }

    /// The compiled-in set is a real root program, not a stub: Mozilla's
    /// has held between 130 and 160 roots for years.
    #[test]
    fn mozilla_roots_are_a_full_root_program() {
        let count = mozilla_roots().count();
        assert!((100..300).contains(&count), "{count} roots");
    }
}
