//! Aligning one subtitle file to another, against cue starts taken off
//! real files.
//!
//! Its own test binary because it owns a fixture: `tests/fixtures/
//! subtitle_starts.json` is the cue start times -- and nothing else, no
//! text -- of two real subtitle files for one Gilmore Girls episode, one
//! timed for 25 fps and one for 23.976. That pair is the case the feature
//! exists for and the one to beat: a rate error no shift can cancel,
//! between two files nothing in the metadata separates. The synthetic
//! tests next to [`xtremio_core::subtitles::align`] say the arithmetic is
//! right; this one says it survives what people actually upload -- cues
//! one file has and the other does not, a translator's own timings, and
//! two subtitlers' habits about when a line goes up.
//!
//! Re-record it with two SRT or WebVTT files of your own:
//!
//! ```text
//! XTREMIO_SUBTITLE_PLAYING=a.srt XTREMIO_SUBTITLE_REFERENCE=b.srt \
//!   cargo test --test subtitles -- --ignored
//! ```

use serde::{Deserialize, Serialize};
use xtremio_core::subtitles::{align, cue_starts};

#[derive(Serialize, Deserialize)]
struct Starts {
    note: String,
    playing: Vec<f64>,
    reference: Vec<f64>,
}

fn fixture_path() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/subtitle_starts.json")
}

#[test]
fn a_pal_timed_file_is_matched_to_a_film_timed_one() {
    let starts: Starts =
        serde_json::from_slice(&std::fs::read(fixture_path()).expect("read the fixture"))
            .expect("parse the fixture");
    let alignment = align(&starts.playing, &starts.reference).expect("two real files align");

    // 25 against 23.976 is 1.0427, and what these two files really need is
    // a shade off it -- which is the whole point: the constant is not the
    // answer, the measurement is.
    assert!(
        (1.040..=1.045).contains(&alignment.ratio),
        "{alignment:?} should be a PAL-sized stretch"
    );
    // Measured at 613 of 694 when this was written. The floor is set below
    // that rather than at it: what is being asserted is that two real
    // files agree overwhelmingly, not that a tolerance and a bin size
    // never change again.
    assert!(
        alignment.matched >= 590 && alignment.cues == starts.playing.len(),
        "{alignment:?} should match nearly every cue"
    );
    assert!(alignment.is_convincing(), "{alignment:?}");
}

#[test]
fn the_same_files_the_other_way_round_are_the_inverse() {
    // Nothing in the arithmetic prefers a direction, and the viewer picks
    // which file is the reference -- so the answer has to be the same line
    // read backwards, whichever way they choose.
    let starts: Starts =
        serde_json::from_slice(&std::fs::read(fixture_path()).expect("read the fixture"))
            .expect("parse the fixture");
    let there = align(&starts.playing, &starts.reference).expect("align");
    let back = align(&starts.reference, &starts.playing).expect("align");
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
    let read = |name: &str| -> anyhow::Result<Vec<f64>> {
        let path = std::env::var(name)?;
        let bytes = std::fs::read(&path)?;
        // Lossy on purpose: a subtitle file that is not UTF-8 (and plenty
        // are Latin-1) still has readable ASCII digits and colons in its
        // timing lines, which is the whole of what is being read.
        Ok(cue_starts(&String::from_utf8_lossy(&bytes)))
    };
    let starts = Starts {
        note: "Cue start times only, in seconds, from two real subtitle files for one \
               episode: the playing one timed for 25 fps, the reference for 23.976. \
               No text is kept."
            .to_owned(),
        playing: read("XTREMIO_SUBTITLE_PLAYING")?,
        reference: read("XTREMIO_SUBTITLE_REFERENCE")?,
    };
    std::fs::write(fixture_path(), serde_json::to_vec_pretty(&starts)?)?;
    Ok(())
}
