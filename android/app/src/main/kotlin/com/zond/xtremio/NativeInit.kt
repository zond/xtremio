package com.zond.xtremio

import android.content.Context

/**
 * One-time native initialisation that has to happen before Dart starts.
 *
 * Loading `libxtremio_core.so` here also means flutter_rust_bridge's later
 * `DynamicLibrary.open("libxtremio_core.so")` reuses the same mapping.
 */
object NativeInit {
    init {
        System.loadLibrary("xtremio_core")
    }

    /**
     * Hands the application [Context] to rustls-platform-verifier (Rust side:
     * `rust/src/android.rs`). Without it every HTTPS request made from Rust
     * fails. Idempotent; throws a RuntimeException if the JNI setup fails.
     */
    external fun initTlsVerifier(context: Context)
}
