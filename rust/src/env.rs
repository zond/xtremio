//! `XtremioEnv`: the `stremio_core::runtime::Env` this app runs the engine
//! on. Modeled on stremio-core-kotlin's `AndroidEnv` and stremiox's `TvosEnv`.
//!
//! - **fetch**: reqwest + rustls; JSON bodies in, JSON out (errors name the
//!   failing JSON path). A request to the embedded server carries its
//!   bearer token (`crate::server::token_for`); no other host gets it.
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
fn write_atomically(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
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

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use stremio_core::constants::{SCHEMA_VERSION, SCHEMA_VERSION_STORAGE_KEY};

    use super::*;

    /// STORAGE_DIR is process-global; serialize the tests that touch it.
    static STORAGE_LOCK: Mutex<()> = Mutex::new(());

    fn with_storage_dir<T>(f: impl FnOnce(&Path) -> T) -> T {
        let _guard = STORAGE_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let tmp = tempfile::tempdir().expect("tempdir");
        set_storage_dir(tmp.path()).expect("set storage dir");
        let result = f(tmp.path());
        set_storage_dir_raw(None);
        result
    }

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
        let _guard = STORAGE_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        set_storage_dir_raw(None);
        let error = block_on(XtremioEnv::get_storage::<Item>("item")).unwrap_err();
        assert_eq!(error, EnvError::StorageUnavailable);
        let error = block_on(XtremioEnv::set_storage("item", Some(&1u32))).unwrap_err();
        assert_eq!(error, EnvError::StorageUnavailable);
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

    #[derive(Debug, Deserialize)]
    struct Heartbeat {
        success: bool,
    }

    #[test]
    fn fetch_decodes_json_from_the_embedded_server() {
        // The embedded server is a process-global singleton; serialize
        // against `server`'s own start/stop test.
        let _guard = crate::server::LIFECYCLE_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
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
