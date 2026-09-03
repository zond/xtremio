//! Process-wide `tracing` setup, and the in-memory ring the Diagnostics
//! screen copies.
//!
//! stream-server is embedded with `init_logging: false`, so this crate owns
//! the one subscriber -- which is why every line the server writes lands in
//! the same place ours do. [`RingLayer`] sits in that subscriber and keeps
//! the last [`RING_CAPACITY`] formatted lines in memory, so a release build
//! on a phone can show and copy its own log without ADB.
//!
//! Desktop builds also print to stderr. On Android there is now a
//! subscriber where there used to be none, and installing one stops
//! `tracing`'s `log` feature from forwarding events to the `log` crate (it
//! only does that while no subscriber is installed), so [`RingLayer`]
//! re-emits each line through `log` itself -- which is what FRB's
//! `setup_default_user_utils` routes to logcat.

use std::collections::VecDeque;
use std::fmt::{self, Write as _};
use std::sync::{Mutex, MutexGuard, Once, OnceLock};

use chrono::{DateTime, SecondsFormat, Utc};
use tracing::field::{Field, Visit};
use tracing::{Event, Level, Subscriber};
use tracing_subscriber::layer::{Context, Layer};
use tracing_subscriber::prelude::*;
use tracing_subscriber::EnvFilter;

/// Default filter when `RUST_LOG` is unset.
pub const DEFAULT_FILTER: &str = "xtremio_core=info,stream_server=info,enginefs=warn";

/// How many formatted lines the ring keeps; the oldest is dropped to make
/// room. A few hundred is enough to cover a start-up and a failed playback
/// while staying small enough to hold in memory and paste into a report.
pub const RING_CAPACITY: usize = 400;

/// A static, not part of `crate::state::AppState`: `tracing`'s global
/// subscriber is itself process-wide and can only be installed once, so
/// what remembers that has to outlive any one session. Re-running this
/// after a shutdown would be a no-op at best.
static INIT: Once = Once::new();

/// The captured lines. Process-wide for the same reason [`INIT`] is: the
/// subscriber that fills it outlives every session, and a log that was
/// emptied by a shutdown would be a log without the shutdown in it.
static RING: OnceLock<Mutex<Ring>> = OnceLock::new();

/// A bounded queue of formatted lines, oldest first.
#[derive(Debug)]
struct Ring {
    lines: VecDeque<String>,
    capacity: usize,
}

impl Ring {
    fn new(capacity: usize) -> Self {
        Self {
            lines: VecDeque::with_capacity(capacity.min(64)),
            capacity,
        }
    }

    fn push(&mut self, line: String) {
        while self.lines.len() >= self.capacity {
            self.lines.pop_front();
        }
        self.lines.push_back(line);
    }

    fn lines(&self) -> Vec<String> {
        self.lines.iter().cloned().collect()
    }
}

fn ring() -> MutexGuard<'static, Ring> {
    RING.get_or_init(|| Mutex::new(Ring::new(RING_CAPACITY)))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// The captured lines, oldest first. Never the whole truth of a session:
/// only what has happened since the ring last wrapped.
pub fn recent_lines() -> Vec<String> {
    ring().lines()
}

/// Installs the global subscriber once. Safe to call repeatedly; a subscriber
/// installed by someone else (e.g. a test harness) is left in place.
pub fn init() {
    INIT.call_once(|| {
        let filter =
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(DEFAULT_FILTER));
        let registry = tracing_subscriber::registry().with(filter).with(RingLayer);
        #[cfg(not(target_os = "android"))]
        let _ = registry
            .with(
                tracing_subscriber::fmt::layer()
                    .with_writer(std::io::stderr)
                    .with_ansi(false),
            )
            .try_init();
        #[cfg(target_os = "android")]
        let _ = registry.try_init();
    });
}

/// The longest message the Dart side may record. A ring line is meant to
/// be read in a paste; a stack trace or a whole JSON body would push out
/// the lines around it, which are what give it meaning.
pub const MAX_APP_MESSAGE: usize = 400;

/// Records one line the *Dart* side produced -- a player open, an engine
/// error, an unhandled Flutter error -- into the same ring as everything
/// else.
///
/// It goes in as a real `tracing` event rather than straight into the ring,
/// so it gets the one clock, the one format, the one filter and (on
/// Android) the same logcat re-emission with no second path to keep in
/// step. That is also what keeps the two sides in order: the ring is
/// append-only and both sides stamp from `Utc::now()` as they push.
///
/// `target` names the Dart source (`player`, `flutter`); the tracing target
/// stays this crate's, since that is what the filter is written against.
pub fn record_app_event(level: &str, target: &str, message: &str) {
    let message = truncate(message, MAX_APP_MESSAGE);
    let target = truncate(target, 64);
    match level.to_ascii_lowercase().as_str() {
        "error" => tracing::error!(target: "xtremio_core::app", "{target}: {message}"),
        "warn" | "warning" => tracing::warn!(target: "xtremio_core::app", "{target}: {message}"),
        "debug" => tracing::debug!(target: "xtremio_core::app", "{target}: {message}"),
        _ => tracing::info!(target: "xtremio_core::app", "{target}: {message}"),
    }
}

/// `text` at most `max` characters (not bytes: a multi-byte character must
/// not be cut in half), with an ellipsis when something was dropped.
fn truncate(text: &str, max: usize) -> String {
    match text.char_indices().nth(max) {
        None => text.to_string(),
        Some((end, _)) => format!("{}…", &text[..end]),
    }
}

/// Formats every event into [`RING`] -- and, on Android, into logcat.
struct RingLayer;

impl<S: Subscriber> Layer<S> for RingLayer {
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let metadata = event.metadata();
        let mut visitor = LineVisitor::default();
        event.record(&mut visitor);
        let line = format_line(
            Utc::now(),
            metadata.level(),
            metadata.target(),
            &visitor.message,
            &visitor.fields,
        );
        #[cfg(target_os = "android")]
        log::log!(target: "xtremio_core", log_level(metadata.level()), "{line}");
        ring().push(line);
    }
}

/// Splits an event's fields into the `message` and everything else, the way
/// `tracing_subscriber`'s own formatter does (`Debug`, so a recorded string
/// keeps its quotes and a `%`/`?` field prints as it was asked to).
#[derive(Default)]
struct LineVisitor {
    message: String,
    fields: String,
}

impl Visit for LineVisitor {
    fn record_debug(&mut self, field: &Field, value: &dyn fmt::Debug) {
        if field.name() == "message" {
            let _ = write!(self.message, "{value:?}");
            return;
        }
        if !self.fields.is_empty() {
            self.fields.push(' ');
        }
        let _ = write!(self.fields, "{}={value:?}", field.name());
    }
}

/// One line: an RFC 3339 UTC stamp, the level, the target, the message and
/// the remaining fields. Pure, so the shape is a test rather than a guess.
fn format_line(
    at: DateTime<Utc>,
    level: &Level,
    target: &str,
    message: &str,
    fields: &str,
) -> String {
    let mut line = format!(
        "{} {:>5} {target}:",
        at.to_rfc3339_opts(SecondsFormat::Millis, true),
        level.as_str(),
    );
    for part in [message, fields] {
        if !part.is_empty() {
            line.push(' ');
            line.push_str(part);
        }
    }
    line
}

/// `tracing`'s level as the `log` crate's, for the Android re-emission.
#[cfg(target_os = "android")]
fn log_level(level: &Level) -> log::Level {
    match *level {
        Level::ERROR => log::Level::Error,
        Level::WARN => log::Level::Warn,
        Level::INFO => log::Level::Info,
        Level::DEBUG => log::Level::Debug,
        Level::TRACE => log::Level::Trace,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_a_line_with_its_fields() {
        let at = DateTime::parse_from_rfc3339("2026-09-03T12:34:56.789Z")
            .unwrap()
            .with_timezone(&Utc);
        assert_eq!(
            format_line(
                at,
                &Level::INFO,
                "xtremio_core::server",
                "embedded stream-server started",
                "url=http://127.0.0.1:11470/",
            ),
            "2026-09-03T12:34:56.789Z  INFO xtremio_core::server: \
             embedded stream-server started url=http://127.0.0.1:11470/"
        );
        // No fields, and no message: neither leaves a stray separator.
        assert_eq!(
            format_line(at, &Level::WARN, "stream_server", "no peers", ""),
            "2026-09-03T12:34:56.789Z  WARN stream_server: no peers"
        );
        assert_eq!(
            format_line(at, &Level::ERROR, "enginefs", "", "error=timeout"),
            "2026-09-03T12:34:56.789Z ERROR enginefs: error=timeout"
        );
    }

    #[test]
    fn an_app_event_lands_in_the_ring_like_any_other_line() {
        init();
        record_app_event("error", "player", "open failed marker-app-event");
        let lines = recent_lines();
        let line = lines
            .iter()
            .find(|line| line.contains("marker-app-event"))
            .unwrap_or_else(|| panic!("app event not captured: {lines:?}"));
        assert!(line.contains("ERROR xtremio_core::app: player: "), "{line}");
    }

    #[test]
    fn a_long_app_message_is_cut_rather_than_filling_the_ring() {
        let long = "x".repeat(MAX_APP_MESSAGE * 2);
        let cut = truncate(&long, MAX_APP_MESSAGE);
        assert_eq!(cut.chars().count(), MAX_APP_MESSAGE + 1);
        assert!(cut.ends_with('…'), "{cut}");
        // A message that fits is untouched, and a multi-byte character is
        // never cut in half.
        assert_eq!(truncate("héllo", MAX_APP_MESSAGE), "héllo");
        assert_eq!(truncate("héllo", 2), "hé…");
    }

    #[test]
    fn drops_the_oldest_line_when_full() {
        let mut ring = Ring::new(3);
        for i in 0..5 {
            ring.push(format!("line {i}"));
        }
        assert_eq!(ring.lines(), ["line 2", "line 3", "line 4"]);
    }

    #[test]
    fn captures_events_from_the_installed_subscriber() {
        init();
        // A marker, not an exact line: other tests log into the same
        // process-wide ring, and they run in parallel with this one.
        tracing::info!(marker = "ring-layer-test", "captured by the ring");
        let lines = recent_lines();
        let line = lines
            .iter()
            .find(|line| line.contains("ring-layer-test"))
            .unwrap_or_else(|| panic!("event not captured: {lines:?}"));
        assert!(line.contains(" INFO "), "{line}");
        assert!(line.contains("captured by the ring"), "{line}");
        assert!(line.contains("marker=\"ring-layer-test\""), "{line}");
    }
}
