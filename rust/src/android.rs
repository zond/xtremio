//! Android-only JNI entry points, called from the Kotlin side before Dart
//! starts (`com.zond.xtremio.NativeInit`).
//!
//! On Android reqwest's rustls uses `rustls-platform-verifier`, which
//! validates certificates through the platform's Java APIs and therefore
//! needs a one-time init with the application `Context`. Without it every
//! HTTPS request from stremio-core *and* the embedded stream-server panics
//! with "Expect rustls-platform-verifier to be initialized" (caught by
//! reqwest and surfaced as a fetch error: empty catalogs, no addon
//! manifests). Both reqwest clients share the crate's single global, so one
//! init covers everything in this library.
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
