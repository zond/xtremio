//! How a rejected JSON payload is described, which is never its contents.
//!
//! `serde_json`'s own messages quote the value they refused -- `invalid
//! type: string "hunter2", expected u64` -- and every payload this crate
//! deserializes carries something that must not be written down:
//! `Ctx::Authenticate` holds the user's password, a download request holds a
//! debrid URL with its token in the path, an addon response holds the
//! Stremio auth key, and a preference value holds whatever the app keeps.
//!
//! Those messages do not stay in the caller's `Result`. They reach
//! [`crate::diagnostics`]'s ring and, on Android, logcat -- and the ring is
//! what a bug report copies, which is precisely the moment a password would
//! travel. The error is not even the interesting half: a payload malformed
//! enough to be refused is a bug in our own Dart, and the field it was
//! refused at is what finds it.
//!
//! So a fault is reported as **where** and **what kind**, never **what**.
//! `serde_path_to_error` gives the field path, and `serde_json` gives a
//! category and a position, none of which quote the payload.
//!
//! The path is field names and indices rather than values, so it does not
//! carry the secret; the one place it could is a map whose *keys* come from
//! the payload, and no type deserialized here has one whose keys are worth
//! hiding.

use std::fmt::Display;

/// A [`serde_path_to_error::Error`] as a field path plus a cause, with the
/// refused value left out. See the module doc for why.
pub(crate) fn at_path(path: impl Display, inner: &serde_json::Error) -> String {
    format!("at `{path}`: {}", cause(inner))
}

/// A bare [`serde_json::Error`] as a cause alone, for the callers that have
/// no path to name because they deserialize into an untyped `Value`.
pub(crate) fn cause(error: &serde_json::Error) -> String {
    format!(
        "{:?} error at line {} column {}",
        error.classify(),
        error.line(),
        error.column()
    )
}

#[cfg(test)]
mod tests {
    /// The whole point, and the only test that matters: whatever went in
    /// does not come out. The value here is the shape that leaked --
    /// `serde_json` answers a type mismatch with `invalid type: string
    /// "hunter2", expected u64`, quoting the string it was given.
    #[test]
    fn a_refused_value_is_never_in_the_message() {
        #[derive(Debug, serde::Deserialize)]
        struct Credentials {
            #[allow(dead_code)]
            attempts: u64,
        }

        let json = r#"{"attempts": "hunter2"}"#;
        let mut deserializer = serde_json::Deserializer::from_str(json);
        let error = serde_path_to_error::deserialize::<_, Credentials>(&mut deserializer)
            .expect_err("a string is not a u64");

        // What serde would have said, so the test fails if this stops being
        // the leak it is written against.
        assert!(
            error.inner().to_string().contains("hunter2"),
            "serde still quotes the value: {}",
            error.inner()
        );

        let reported = super::at_path(error.path(), error.inner());
        assert!(
            !reported.contains("hunter2"),
            "the secret reached the message: {reported}"
        );
        assert!(
            reported.contains("attempts"),
            "and the field that was refused is still named: {reported}"
        );
    }

    /// A syntax error has no field to name, and still says nothing about
    /// the bytes.
    #[test]
    fn a_bare_cause_carries_no_payload_either() {
        let error =
            serde_json::from_str::<serde_json::Value>(r#"{"token": "s3cret",}"#).expect_err("bad");
        let reported = super::cause(&error);
        assert!(!reported.contains("s3cret"), "{reported}");
        assert!(reported.contains("line"), "{reported}");
    }
}
