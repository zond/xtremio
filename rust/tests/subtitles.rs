//! Aligning one subtitle file to another, against timings taken off real
//! files.
//!
//! Its own test binary because it owns a fixture: `tests/fixtures/
//! subtitle_starts.json` is the cue timings -- and nothing else, no text --
//! of two real subtitle files for one Gilmore Girls episode, one timed for
//! 25 fps and one for 23.976. That pair is the case the feature exists for
//! and the one to beat: a rate error no shift can cancel, between two files
//! nothing in the metadata separates. The synthetic tests next to
//! [`xtremio_core::subtitles::align`] say the arithmetic is right; this one
//! says it survives what people actually upload -- cues one file has and
//! the other does not, a translator's own timings, and two subtitlers'
//! habits about when a line goes up.
//!
//! **The checked-in fixture predates the move to spans and holds only the
//! starts.** The recorder below now writes both ends, and this test uses
//! them whenever the file has them; until the fixture is re-recorded from
//! the files it came from, each cue is given [`NOMINAL_LENGTH`] on screen
//! instead. That makes what is being asserted here narrower than it looks:
//! it is the *search* -- a PAL-sized ratio found unaided across a real,
//! irregular pattern of 694 cues against 683 -- and not the tolerance of
//! merged and split lines, which needs real ends and is covered
//! synthetically in the module's own tests.
//!
//! Re-record it with two SRT or WebVTT files of your own, which is also
//! how it gains those ends:
//!
//! ```text
//! XTREMIO_SUBTITLE_PLAYING=a.srt XTREMIO_SUBTITLE_REFERENCE=b.srt \
//!   cargo test --test subtitles -- --ignored
//! ```

use serde::{Deserialize, Serialize};
use xtremio_core::subtitles::{align, cue_spans, Cue};

/// How long a cue is assumed to be on screen when the fixture records only
/// its start.
///
/// Two seconds is about what a line of dialogue gets, and it is clipped to
/// the next cue's start so a pause in the programme stays a pause. What it
/// must not do is fill the gaps: a file lit in every bin has nothing left
/// to be above chance about.
const NOMINAL_LENGTH: f64 = 2.0;

#[derive(Serialize, Deserialize)]
struct Starts {
    note: String,
    playing: Vec<f64>,
    reference: Vec<f64>,
    /// The same cues with both of their timestamps, once the fixture has
    /// been recorded by a build that reads them. Defaulted rather than
    /// required so the recording that predates spans still loads.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    playing_spans: Vec<Cue>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    reference_spans: Vec<Cue>,
}

impl Starts {
    fn read() -> Self {
        serde_json::from_slice(&std::fs::read(fixture_path()).expect("read the fixture"))
            .expect("parse the fixture")
    }

    fn playing(&self) -> Vec<Cue> {
        spans(&self.playing_spans, &self.playing)
    }

    fn reference(&self) -> Vec<Cue> {
        spans(&self.reference_spans, &self.reference)
    }
}

/// The recorded spans, or the starts stretched to [`NOMINAL_LENGTH`] when
/// the fixture has none.
fn spans(recorded: &[Cue], starts: &[f64]) -> Vec<Cue> {
    if !recorded.is_empty() {
        return recorded.to_vec();
    }
    starts
        .iter()
        .enumerate()
        .map(|(index, &start)| {
            let next = starts.get(index + 1).copied().unwrap_or(f64::INFINITY);
            (start, (start + NOMINAL_LENGTH).min(next))
        })
        .collect()
}

fn fixture_path() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/subtitle_starts.json")
}

#[test]
fn a_pal_timed_file_is_matched_to_a_film_timed_one() {
    let starts = Starts::read();
    let alignment = align(&starts.playing(), &starts.reference()).expect("two real files align");

    // 25 against 23.976 is 1.0427, and what these two files really need is
    // a shade off it -- which is the whole point: the constant is not the
    // answer, the measurement is. Found across a window that reaches a
    // tenth either way, so nothing in the search knew where to look.
    assert!(
        (1.040..=1.045).contains(&alignment.ratio),
        "{alignment:?} should be a PAL-sized stretch"
    );
    assert!(alignment.is_convincing(), "{alignment:?}");
}

#[test]
fn the_same_files_the_other_way_round_are_the_inverse() {
    // Nothing in the arithmetic prefers a direction, and the viewer picks
    // which file is the reference -- so the answer has to be the same line
    // read backwards, whichever way they choose.
    let starts = Starts::read();
    let there = align(&starts.playing(), &starts.reference()).expect("align");
    let back = align(&starts.reference(), &starts.playing()).expect("align");
    assert!(
        (back.ratio - 1.0 / there.ratio).abs() < 1e-3,
        "{there:?} against {back:?}"
    );
    assert!(back.is_convincing(), "{back:?}");
}

/// Rewrites the fixture from two subtitle files on this machine. Ignored:
/// it needs files that are not in the repository, and it is how the
/// fixture is refreshed rather than something CI has an opinion about.
#[test]
#[ignore]
fn record_the_starts_of_two_files() -> anyhow::Result<()> {
    let read = |name: &str| -> anyhow::Result<Vec<Cue>> {
        let path = std::env::var(name)?;
        let bytes = std::fs::read(&path)?;
        // Lossy on purpose: a subtitle file that is not UTF-8 (and plenty
        // are Latin-1) still has readable ASCII digits and colons in its
        // timing lines, which is the whole of what is being read.
        Ok(cue_spans(&String::from_utf8_lossy(&bytes)))
    };
    let playing = read("XTREMIO_SUBTITLE_PLAYING")?;
    let reference = read("XTREMIO_SUBTITLE_REFERENCE")?;
    let starts = Starts {
        note: "Cue timings only, in seconds, from two real subtitle files for one episode: \
               the playing one timed for 25 fps, the reference for 23.976. No text is kept. \
               `playing`/`reference` are the starts alone, which is all the first recording \
               of this fixture had; the spans are what the matcher reads."
            .to_owned(),
        playing: playing.iter().map(|&(start, _)| start).collect(),
        reference: reference.iter().map(|&(start, _)| start).collect(),
        playing_spans: playing,
        reference_spans: reference,
    };
    std::fs::write(fixture_path(), serde_json::to_vec_pretty(&starts)?)?;
    Ok(())
}
