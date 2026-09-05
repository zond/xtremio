//! FRB surface for "Match to another subtitle": two subtitle files in,
//! the ratio and the offset that map one onto the other out.
//!
//! Here rather than in Dart because it is two HTTP fetches and a sweep
//! over two arrays of a few hundred numbers, and neither belongs on the UI
//! thread of a device as modest as a Chromecast with Google TV.
//!
//! Neither URL is ever logged or put in an error. An addon's URL can carry
//! a debrid API key, which `AGENTS.md` puts in the same class as the auth
//! material that is never written down; `crate::env::fetch_text` strips
//! the URL out of every failure it reports, and this module adds only
//! which of the two files a failure was about.

use crate::guard::guarded;

/// What a match found, and the evidence for it.
///
/// The transform is exactly what mpv is told: `sub-speed` is [`ratio`] and
/// `sub-delay` is [`offset`], so a cue at `t` in the playing file lands at
/// `ratio * t + offset`, where the reference file has the same moment.
///
/// [`ratio`]: Self::ratio
/// [`offset`]: Self::offset
pub struct SubtitleMatch {
    /// What the playing file's timestamps are multiplied by.
    pub ratio: f64,
    /// What is added afterwards, in seconds.
    pub offset: f64,
    /// How far above chance the two files have text on screen at the same
    /// moments under this transform: 1 for two files lit over exactly the
    /// same moments, 0 for two doing no better than their own talkativeness
    /// predicts. **This is the number the viewer is shown**, because a
    /// count of cues is not comparable between a file that merges lines and
    /// one that does not -- a translation that merges two lines into one
    /// has half the cues and the same subtitle.
    ///
    /// None when there was nothing to measure: one of the two files has too
    /// few cues to be evidence either way, which is a different answer from
    /// a bad score and is said differently.
    pub score: Option<f64>,
    /// How many cues the playing file has. Not evidence of a match -- it is
    /// here so a file that could not be read as a subtitle at all can be
    /// told from two files that merely disagree, which is what a missing
    /// `score` is reported with.
    pub cues: u32,
    /// How many the reference has, for the same reason.
    pub reference_cues: u32,
    /// Whether the two agree well enough for the transform to be worth
    /// applying. **False is an answer, not an error**: two files for
    /// different episodes, half a film against the whole, or a reference
    /// that is itself adrift all measure, none of them should be applied,
    /// and saying so with the score and the transform is honest where
    /// applying it anyway would ruin a subtitle that was merely a little
    /// out.
    pub convincing: bool,
}

/// How much of a subtitle file is fetched before it is refused.
///
/// A subtitle for a three-hour film with every line of song lyrics in it
/// is around a megabyte; four is room for anything real and small enough
/// that a URL answering with something else cannot spend a television's
/// memory on it.
const MOST_BYTES: usize = 4 * 1024 * 1024;

/// Matches the subtitle at `playing_url` to the one at `reference_url`,
/// which the viewer has said is in sync with the video.
///
/// Fetches both, reads when each of them has text on screen and solves for
/// the line between them (`crate::subtitles`). Errors only when a file
/// cannot be fetched -- a pair that does not match is a [`SubtitleMatch`]
/// with `convincing: false` and the score and transform that say so.
///
/// Blocks the FRB worker for the length of two HTTP fetches and a sweep;
/// never call it from the UI thread. The fetches run together, because
/// the second file has nothing to wait for.
pub fn subtitles_match(
    playing_url: String,
    reference_url: String,
) -> anyhow::Result<SubtitleMatch> {
    guarded(|| {
        let playing_url = url::Url::parse(&playing_url).map_err(|_| {
            anyhow::anyhow!("the subtitle being played is not at a URL this can fetch")
        })?;
        let reference_url = url::Url::parse(&reference_url)
            .map_err(|_| anyhow::anyhow!("the chosen subtitle is not at a URL this can fetch"))?;
        // On the concurrent runtime, which is where network effects
        // belong: the sequential one exists to keep storage writes in
        // order, and two fetches have no order to keep.
        let (playing, reference) = crate::env::CONCURRENT.block_on(async {
            futures::future::join(
                crate::env::fetch_text(&playing_url, MOST_BYTES),
                crate::env::fetch_text(&reference_url, MOST_BYTES),
            )
            .await
        });
        let playing = crate::subtitles::cue_spans(
            &playing.map_err(|error| anyhow::anyhow!("the subtitle being played: {error}"))?,
        );
        let reference = crate::subtitles::cue_spans(
            &reference.map_err(|error| anyhow::anyhow!("the chosen subtitle: {error}"))?,
        );
        // Too little to measure still answers with the counts rather than
        // raising: "eleven cue timings in the file you picked" is the same
        // kind of answer as a bad score, and the panel says it the same
        // way.
        Ok(match crate::subtitles::align(&playing, &reference) {
            Some(alignment) => SubtitleMatch {
                ratio: alignment.ratio,
                offset: alignment.offset,
                score: Some(alignment.score),
                cues: playing.len() as u32,
                reference_cues: reference.len() as u32,
                convincing: alignment.is_convincing(),
            },
            None => SubtitleMatch {
                ratio: 1.0,
                offset: 0.0,
                score: None,
                cues: playing.len() as u32,
                reference_cues: reference.len() as u32,
                convincing: false,
            },
        })
    })
}
