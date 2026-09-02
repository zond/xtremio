//! Panic containment for FFI entry points.
//!
//! FRB's executor already catches panics and surfaces them to Dart as
//! `PanicException`, but that loses context and bypasses our error type.
//! Wrapping every exported function body in [`guarded`] turns a panic into a
//! regular `anyhow::Error` (a Dart `AnyhowException`) with the panic message,
//! and guarantees nothing unwinds across the language boundary.

use std::panic::{catch_unwind, AssertUnwindSafe, UnwindSafe};

/// Runs `f`, converting a panic into an `Err`.
pub fn guarded<T>(f: impl FnOnce() -> anyhow::Result<T>) -> anyhow::Result<T> {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(result) => result,
        // `&*payload`: a plain `&payload` would unsize the Box itself into
        // `dyn Any` and every downcast would miss.
        Err(payload) => Err(anyhow::anyhow!(
            "panic in xtremio_core: {}",
            panic_message(&*payload)
        )),
    }
}

/// Runs an infallible `f`, converting a panic into an `Err`.
pub fn guarded_ok<T>(f: impl FnOnce() -> T + UnwindSafe) -> anyhow::Result<T> {
    catch_unwind(f)
        .map_err(|payload| anyhow::anyhow!("panic in xtremio_core: {}", panic_message(&*payload)))
}

/// Best-effort extraction of the human-readable message from a panic payload.
pub fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(message) = payload.downcast_ref::<&str>() {
        (*message).to_owned()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "<non-string panic payload>".to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passes_results_through() {
        assert_eq!(guarded(|| Ok(3)).unwrap(), 3);
        assert!(guarded::<()>(|| Err(anyhow::anyhow!("boom"))).is_err());
    }

    #[test]
    fn converts_panics_into_errors() {
        let error = guarded::<()>(|| panic!("kaboom {}", 42)).unwrap_err();
        assert!(error.to_string().contains("kaboom 42"), "{error}");
        let error = guarded_ok(|| -> u8 { panic!("static") }).unwrap_err();
        assert!(error.to_string().contains("static"), "{error}");
    }
}
