//! Android-only JNI entry points, called from the Kotlin side before Dart
//! starts (`com.zond.xtremio.NativeInit`).
//!
//! On Android a reqwest client built with the `rustls` feature and no roots
//! of its own verifies certificates through `rustls-platform-verifier`,
//! which goes through the platform's Java APIs and therefore needs a
//! one-time init with the application `Context`. Without it every HTTPS
//! request such a client makes panics with "Expect rustls-platform-verifier
//! to be initialized" (caught by reqwest and surfaced as a fetch error).
//!
//! Who still needs this init: the embedded stream-server. Its clients --
//! enginefs (addon-hosted torrent files, tracker lists), librqbit's tracker
//! announcer, UPnP and HTTP-API clients -- are built inside that crate with
//! reqwest's defaults, so they construct the platform verifier; until
//! stream-server's half of the fix lands (its own roots, or a cheaper
//! verifier), removing this init would make every HTTPS tracker announce
//! and every torrent-file fetch fail on Android. The app's *own* client
//! (`crate::env::http_client_builder`) does not use the platform verifier
//! any more: it trusts Mozilla's compiled-in roots, verified by rustls, and
//! never touches Java. That is what took the CRL downloads out of the app's
//! addon and catalog traffic; the tracker announces are stream-server's to
//! fix. The verifier is one process-wide global, so this one init covers
//! every client in the library that still wants it.
//!
//! stream-server exports its own `Java_com_stremio_mobile_server_*` symbols
//! (they end up in libxtremio_core.so too); those must never be called, they
//! would start a second server.

use jni::objects::{JClass, JObject};
use jni::EnvUnowned;

/// `NativeInit.initTlsVerifier(context)`.
///
/// Idempotent: the verifier keeps the first context it was given. Errors are
/// rethrown as a Java `RuntimeException`.
///
/// # Safety
///
/// Called by the JVM; `env`, `_class` and `context` must be valid JNI handles
/// belonging to the calling thread for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "system" fn Java_com_zond_xtremio_NativeInit_initTlsVerifier(
    mut env: EnvUnowned,
    _class: JClass,
    context: JObject,
) {
    env.with_env(|env| rustls_platform_verifier::android::init_with_env(env, context))
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}
