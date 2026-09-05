//! What a subtitle file says about *time*, and nothing else.
//!
//! Two subtitle files for one video are two clocks. When they disagree the
//! disagreement is a line -- `reference = ratio * playing + offset` -- and
//! this module is how that line is measured: turn each file into a bitmap
//! of **when it has text on screen** and find the ratio and shift that make
//! the two bitmaps overlap most.
//!
//! **Both timestamps of every cue are read, and the text is thrown away.**
//! The measurement this replaced compared cue *starts*, and it refused a
//! pairing that was perfectly good: the owner's Swedish Gilmore Girls file
//! has 690 cues where the English one for the same episode has 1024,
//! because the translator merges lines and starts each merged line on its
//! own beat. At the best ratio and offset only 54 % of its starts land
//! within a third of a second of an English start -- but 97 % land within
//! a second and a half, and the two files have text on screen at the same
//! time almost all of the time. Merging and splitting stop mattering to a
//! bitmap: a merged line *overlaps* both the lines it covers, and a line
//! one file does not have costs its own bins rather than a whole match.
//!
//! **The overlap is scored against chance, never absolutely.** Subtitles
//! are on screen roughly two thirds of an episode, so two files that have
//! nothing to do with each other already overlap a great deal. What is
//! reported and thresholded is therefore how far the overlap beats what
//! two files of these two densities would reach by accident -- see
//! [`above_chance`].

/// One cue's span: when a line goes up and when it comes down, in seconds.
///
/// Both ends, because the whole point of this module is the interval
/// rather than the instant. Ends drift with reading speed and with each
/// translator's habits, which is why the old measurement threw them away;
/// what that missed is that a *set* of intervals describes the episode's
/// speech even when no single interval agrees with its counterpart.
pub type Cue = (f64, f64);

/// Every cue in `text`, as `(start, end)` seconds, sorted by start.
///
/// SRT and WebVTT both write a cue as `<start> --> <end>` on a line of its
/// own, so the parse is that line and nothing around it: no cue numbering,
/// no `WEBVTT` header, no `NOTE` block, no styling and no text. Anything
/// this does not recognise is skipped rather than refused -- a subtitle
/// file with one damaged cue in it is still a usable description of when
/// somebody is speaking, and the caller judges the result by how much of
/// it overlaps the other file.
///
/// The two formats differ in the fraction separator (`,` against `.`) and
/// in whether the hours are written at all, and files in the wild mix both
/// conventions, so both are accepted in either format rather than the file
/// being sniffed for which one it claims to be. WebVTT also writes cue
/// settings (`line:90% align:middle`) after the end time, so only the
/// first token on the right of the arrow is read.
///
/// Cues are *not* deduplicated and *not* merged: two boxes on screen
/// together are one lit interval once the bitmap is built, and a cue whose
/// end precedes its start is dropped because it describes no interval at
/// all. Sorted because the extent of the file is read off the ends.
pub fn cue_spans(text: &str) -> Vec<Cue> {
    let mut cues: Vec<Cue> = text
        .lines()
        .filter_map(|line| {
            let (start, end) = line.split_once("-->")?;
            let start = timestamp_seconds(start)?;
            let end = timestamp_seconds(end.split_whitespace().next()?)?;
            (end >= start).then_some((start, end))
        })
        .collect();
    cues.sort_by(|left, right| left.0.total_cmp(&right.0));
    cues
}

/// `HH:MM:SS,mmm` (SRT), `MM:SS.mmm` (WebVTT's short form) and every
/// mixture of the two, in seconds. None for anything else, which includes
/// every line of a subtitle file that is not a timing line.
///
/// The hours are optional because WebVTT makes them optional; the fraction
/// is optional because a hand-edited file that drops it means the whole
/// second, and refusing the cue would lose the observation over a
/// formality.
fn timestamp_seconds(stamp: &str) -> Option<f64> {
    let stamp = stamp.trim();
    if stamp.is_empty() {
        return None;
    }
    let (whole, fraction) = match stamp.split_once([',', '.']) {
        Some((whole, fraction)) => (whole, Some(fraction)),
        None => (stamp, None),
    };
    let mut fields = whole.split(':').rev();
    let seconds: u32 = fields.next()?.parse().ok()?;
    let minutes: u32 = fields.next()?.parse().ok()?;
    let hours: u32 = match fields.next() {
        Some(hours) => hours.parse().ok()?,
        None => 0,
    };
    if fields.next().is_some() || seconds >= 60 || minutes >= 60 {
        return None;
    }
    // A fraction is read as a decimal, so both `.5` (half a second, which
    // a hand-edited file means) and `,500` come out at 0.5 -- where
    // treating the digits as milliseconds would call the first one half a
    // millisecond and put the cue where it never was.
    let fraction = match fraction {
        Some("") => 0.0,
        Some(digits) => {
            if !digits.bytes().all(|byte| byte.is_ascii_digit()) {
                return None;
            }
            format!("0.{digits}").parse().ok()?
        }
        None => 0.0,
    };
    Some(f64::from(hours * 3600 + minutes * 60 + seconds) + fraction)
}

/// The line that maps the playing subtitle's clock onto the reference's,
/// and how far above chance the two files then agree.
///
/// `reference = ratio * playing + offset`, which is exactly the transform
/// mpv applies: `sub-speed` multiplies the file's timestamps and
/// `sub-delay` is added to the product. So a trusted alignment is written
/// straight onto those two properties -- the reference file is standing in
/// for the video's own clock, on the viewer's word that it is in sync.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Alignment {
    /// What the playing file's timestamps are multiplied by.
    pub ratio: f64,
    /// What is added afterwards, in seconds.
    pub offset: f64,
    /// How much of the overlap this line achieves is more than two files
    /// of these densities would have reached by accident: 1 for two files
    /// lit over exactly the same moments, 0 for two that do no better than
    /// chance, negative for two that do worse. See [`above_chance`].
    pub score: f64,
}

/// The width of a bin in the bitmap the two files are compared as, at each
/// pass of the search.
///
/// The first pass is over the whole rate window and every offset, so its
/// bin is a second: an episode is then some tens of machine words, which
/// is what makes a quarter of a million (ratio, offset) pairs affordable
/// on a Chromecast. The passes after it look only near the winner, so
/// they can afford the hundred milliseconds the spans are really worth --
/// about the shortest interval two subtitlers agree on -- and then a fifth
/// of that, which takes the residual drift over an episode below what a
/// viewer can see.
const COARSE_BIN: f64 = 1.0;
const FINE_BIN: f64 = 0.1;
const FINEST_BIN: f64 = 0.02;

/// The window the ratio is looked for in, either side of the file's own
/// timing.
///
/// PAL against film -- 25 fps timings on a 23.976 fps cut -- is 4.27 %,
/// and is the largest mismatch that really occurs; everything else is
/// telecine, which preserves seconds and needs no ratio at all. **Finding
/// that unaided is the point**, so the window has to be wide enough that
/// nothing in it is a hint: a tenth either way is room for PAL plus
/// anything a hand-retimed file has picked up, and still narrow enough to
/// stop the search "explaining" two unrelated files by stretching one into
/// the shape of the other.
pub const LOWEST_RATIO: f64 = 0.90;
pub const HIGHEST_RATIO: f64 = 1.10;

/// How far apart the two files' clocks may be before an offset stops being
/// considered.
///
/// Ten minutes covers a subtitle written for a disc with its own pre-roll,
/// a broadcast recording that keeps the recap, and a distributor's logo
/// reel. Past that the two files are not two timings of one recording but
/// two different things -- the second half of a film against the whole, an
/// episode against its neighbour -- which is a pairing to refuse rather
/// than one to search harder for.
const WIDEST_OFFSET: f64 = 600.0;

/// How far above chance two files have to overlap before the transform is
/// worth applying.
///
/// **Provisional.** Prototyped on the owner's own files, where the three
/// genuine pairings score 1.00, 0.66 and 0.66 and the two wrong episodes
/// score 0.25 and 0.20, this sits in the gap with room on both sides. Five
/// pairings are enough to show the metric separates them at all and not
/// enough to set a number: what that needs is a spread of shows,
/// languages, merge-and-split styles and deliberate mismatches, and the
/// worst genuine pair and the best wrong pair named out of it. Until that
/// is measured this constant is a placeholder, and the case for it is the
/// gap rather than the value.
pub const CONVINCING: f64 = 0.45;

/// How few cues make a file useless as evidence either way.
///
/// A forced-subtitle track of a dozen signs is lit so rarely that the
/// chance it is scored against is near zero -- which is exactly the regime
/// where a handful of accidental coincidences reads as a strong result.
/// Refusing to measure is better than measuring badly, and the floor
/// guards both sides because either file can be the sparse one.
///
/// Fifty is inherited from the measurement this replaced, where it was the
/// count at which an unrelated file stopped being alignable by accident.
/// Scoring against chance moved that count a long way down --
/// [`tests::a_handful_of_cues_can_be_laid_onto_anything`] measures it at
/// about eight cues a side, and at fifty the best an unrelated pair reaches
/// is well under [`CONVINCING`] -- so the floor is now generous rather than
/// tight. It stays where it is because it costs nothing real (a file with
/// fewer than fifty cues is a signs track, not a translation) and because
/// re-tuning it is calibration, which is the next piece of work and not
/// this one.
const FEWEST_CUES: usize = 50;

/// The bounds the first pass's ratio step is kept between; what it
/// actually takes is [`coarse_step`], which is a property of the file's
/// length.
///
/// The coarser bound is for a file too short for the derivation to ask for
/// anything, and the finer one is a stop against a ten-hour timeline
/// spending a television's afternoon on a search. Neither is reached by a
/// film or an episode.
const COARSEST_STEP: f64 = 0.005;
const FINEST_STEP: f64 = 0.00002;

/// The step the ratio is swept at for a playing file spanning `span`
/// seconds, when the bitmap's bins are `bin` wide.
///
/// **The step cannot be a constant, because what a wrong ratio costs
/// depends on how long the file is.** A ratio out by `d` puts a cue `t`
/// seconds into the file `d * t` from where it belongs; the offset the
/// search chooses centres that error on the file, so the worst cue is out
/// by `d * span / 2`, and a step of `h` leaves `d` as large as `h / 2`.
/// For the right ratio to be found at all, the nearest step to it has to
/// keep the whole file inside a bin: `h * span / 4 <= bin`, which is this
/// with a factor of two in hand.
fn coarse_step(span: f64, bin: f64) -> f64 {
    if span > 0.0 {
        (2.0 * bin / span).clamp(FINEST_STEP, COARSEST_STEP)
    } else {
        COARSEST_STEP
    }
}

impl Alignment {
    /// Whether these two files agree well enough ([`CONVINCING`]) for the
    /// line to be worth applying.
    pub fn is_convincing(&self) -> bool {
        self.score >= CONVINCING
    }
}

/// Solves for the line that maps `playing` onto `reference`, both being
/// cue spans as [`cue_spans`] answers them.
///
/// None when either file has too few cues to be evidence ([`FEWEST_CUES`]);
/// otherwise an [`Alignment`] and its score, *including* when the score is
/// hopeless -- refusing is [`Alignment::is_convincing`]'s call to make, and
/// what was found is what the viewer is owed either way.
///
/// The measurement is a search rather than anything cleverer because the
/// two unknowns are not independent: an offset can only be read once a
/// ratio is assumed, since the same pair of files at the wrong ratio has no
/// single offset at all. Cross-correlating by FFT would answer every offset
/// at once, which is what ffsubsync does; going coarse to fine costs no new
/// dependency and, at a second per bin, gets the whole rate window and
/// every offset into a few hundred thousand machine words.
pub fn align(playing: &[Cue], reference: &[Cue]) -> Option<Alignment> {
    if playing.len() < FEWEST_CUES || reference.len() < FEWEST_CUES {
        return None;
    }
    Some(solve(playing, reference))
}

/// The measurement itself, with the floor already checked.
///
/// Split out so a test can put two files through the search that [`align`]
/// refuses to measure at all, which is how the floor is shown to be worth
/// having rather than merely asserted.
fn solve(playing: &[Cue], reference: &[Cue]) -> Alignment {
    let span = extent(playing);

    // First pass: the whole rate window and every offset, at a second per
    // bin. Everything after it is a local search, so this is the pass that
    // has to actually contain the answer.
    let coarse = coarse_step(span, COARSE_BIN);
    let coarse_shift = (WIDEST_OFFSET / COARSE_BIN) as i64;
    let mut best = sweep(
        playing,
        reference,
        COARSE_BIN,
        &ratios(LOWEST_RATIO, HIGHEST_RATIO, coarse),
        -coarse_shift..=coarse_shift,
    );

    // Then twice near the winner, each pass narrowing the ratio window to
    // the step the pass before it could resolve and the offset window to
    // its bin. Two passes rather than one because the ratio and the offset
    // trade off against each other: a ratio a step out is partly hidden by
    // an offset half a bin out, and the second pass is where that comes
    // apart.
    for (bin, coarser_bin, coarser_step) in [
        (FINE_BIN, COARSE_BIN, coarse),
        (FINEST_BIN, FINE_BIN, coarse_step(span, FINE_BIN)),
    ] {
        let step = coarse_step(span, bin);
        let steps = ratios(best.ratio - coarser_step, best.ratio + coarser_step, step);
        let around = (best.offset / bin).round() as i64;
        let reach = (coarser_bin / bin).ceil() as i64;
        best = sweep(
            playing,
            reference,
            bin,
            &steps,
            (around - reach)..=(around + reach),
        );
    }
    best
}

/// Every ratio from `from` to `to` at `step`, clamped to the window the
/// search is allowed to answer in.
///
/// Inclusive of `to` up to a rounding, because a window that is not a whole
/// number of steps long would otherwise leave its own end unexamined --
/// and the end of the *refined* window is where the answer sits whenever
/// the pass before it was half a step out.
fn ratios(from: f64, to: f64, step: f64) -> Vec<f64> {
    let count = ((to - from) / step).round().max(0.0) as usize;
    let candidates: Vec<f64> = (0..=count)
        .map(|index| from + index as f64 * step)
        .filter(|ratio| (LOWEST_RATIO..=HIGHEST_RATIO).contains(ratio))
        .collect();
    if candidates.is_empty() {
        // A refined window can fall wholly outside the allowed one only by
        // a rounding at its very edge. The edge itself is then the answer
        // to refine around, and a pass with nothing to score would throw
        // away everything the pass before it found.
        return vec![from.clamp(LOWEST_RATIO, HIGHEST_RATIO)];
    }
    candidates
}

/// The best line over `candidates` and `shifts`, with both files binned at
/// `bin`.
///
/// The reference's bitmap is built once for the whole sweep and the
/// playing file's once per ratio, because scaling the playing file is what
/// a ratio *is*: `sub-speed` multiplies its timestamps, so a cue two
/// seconds long at 1.0427 is on screen for two and a tenth.
fn sweep(
    playing: &[Cue],
    reference: &[Cue],
    bin: f64,
    candidates: &[f64],
    shifts: std::ops::RangeInclusive<i64>,
) -> Alignment {
    let reference = Bitmap::of(reference, 1.0, bin);
    let mut best = Alignment {
        ratio: 1.0,
        offset: 0.0,
        score: f64::NEG_INFINITY,
    };
    for &ratio in candidates {
        let playing = Bitmap::of(playing, ratio, bin);
        for shift in shifts.clone() {
            let score = above_chance(&playing, &reference, shift);
            if score > best.score {
                best = Alignment {
                    ratio,
                    offset: shift as f64 * bin,
                    score,
                };
            }
        }
    }
    best
}

/// When a file has text on screen, as one bit per bin from time zero.
struct Bitmap {
    /// Bin `index` is bit `index % 64` of word `index / 64`.
    words: Vec<u64>,
    /// How many bins are lit: the file's `|A|` in the Dice coefficient.
    lit: u32,
    /// How many bins the file reaches over, lit or not.
    bins: usize,
}

impl Bitmap {
    /// `cues` with their timestamps multiplied by `ratio`, binned at `bin`.
    ///
    /// A bin is lit when text covers **at least half** of it, rather than
    /// any part of it. That rule is what makes the coarse pass mean
    /// anything: lighting a bin from any overlap turns a file of two-second
    /// lines with one-second gaps into a bitmap that is ninety per cent lit
    /// at a second per bin, and two files that are both nearly all lit have
    /// no headroom above chance left to tell them apart -- measured, the
    /// right ratio scored 0.14 there and a wrong one 0.34. Rounding to the
    /// nearer answer keeps a file's density roughly what it is at every bin
    /// width, so the coarse pass and the fine passes are measuring the same
    /// thing at different resolutions.
    fn of(cues: &[Cue], ratio: f64, bin: f64) -> Self {
        let bins = ((ratio * extent(cues) / bin).ceil() as usize).max(1);
        let mut covered = vec![0.0f64; bins];
        for &(start, end) in cues {
            let (start, end) = (ratio * start / bin, ratio * end / bin);
            let from = (start.floor().max(0.0) as usize).min(bins);
            let to = ((end.ceil() as usize).max(from + 1)).min(bins);
            for (index, share) in covered.iter_mut().enumerate().take(to).skip(from) {
                let within = end.min((index + 1) as f64) - start.max(index as f64);
                if within > 0.0 {
                    *share += within;
                }
            }
        }
        let mut words = vec![0u64; bins.div_ceil(64)];
        let mut lit = 0;
        for (index, share) in covered.iter().enumerate() {
            if *share >= 0.5 {
                words[index / 64] |= 1 << (index % 64);
                lit += 1;
            }
        }
        Self { words, lit, bins }
    }
}

/// The last moment `cues` has anything on screen.
fn extent(cues: &[Cue]) -> f64 {
    cues.iter().map(|&(_, end)| end).fold(0.0, f64::max)
}

/// How much better than chance `playing` and `reference` overlap when the
/// playing file's bins are moved `shift` bins later.
///
/// The overlap itself is the Dice coefficient, `2|A∩B| / (|A|+|B|)`, which
/// is the natural score for two sets of lit bins: it asks what share of
/// the two files' on-screen time is on screen in both.
///
/// **Dice alone would accept anything.** A subtitle is up for something
/// like two thirds of an episode, so two files that have nothing to do
/// with each other -- a different episode, a different show -- already
/// score around two thirds, and the pairs that must be accepted score in
/// the high eighties: a threshold between them is a threshold between two
/// numbers that are mostly measuring how talkative the programme is. So
/// what is reported is how far the overlap beat the overlap two files of
/// these densities would reach if they were lit independently:
/// `chance = 2·da·db / (da+db)` from the two densities over the timeline
/// the pair covers, and the answer is `(dice − chance) / (1 − chance)`.
/// One is two files lit over exactly the same moments, zero is two files
/// doing no better than their densities predict, and the wrong-episode
/// pairs the old metric could not separate come out at a fifth to a
/// quarter.
///
/// The timeline is the union of the two files' reach *under this shift*,
/// so pushing one file off the end of the other lowers the densities
/// rather than quietly shrinking the denominator the chance is computed
/// over.
fn above_chance(playing: &Bitmap, reference: &Bitmap, shift: i64) -> f64 {
    let lit_playing = f64::from(playing.lit);
    let lit_reference = f64::from(reference.lit);
    if lit_playing <= 0.0 || lit_reference <= 0.0 {
        return 0.0;
    }
    let first = shift.min(0);
    let last = (shift + playing.bins as i64).max(reference.bins as i64);
    let bins = (last - first) as f64;
    let (density_playing, density_reference) = (lit_playing / bins, lit_reference / bins);
    let chance = 2.0 * density_playing * density_reference / (density_playing + density_reference);
    if chance >= 1.0 {
        // Both files lit in every bin of the timeline: they agree
        // perfectly and the agreement says nothing at all.
        return 0.0;
    }
    let dice = 2.0 * f64::from(overlap(playing, reference, shift)) / (lit_playing + lit_reference);
    (dice - chance) / (1.0 - chance)
}

/// How many bins are lit in both files when the playing file's bin `index`
/// is read against the reference's bin `index + shift`.
///
/// Word at a time rather than bin at a time: an episode is a few tens of
/// words at the coarse bin, and the first pass asks this question a
/// quarter of a million times.
fn overlap(playing: &Bitmap, reference: &Bitmap, shift: i64) -> u32 {
    let (whole, part) = (shift.div_euclid(64), shift.rem_euclid(64) as u32);
    let word = |index: i64| -> u64 {
        usize::try_from(index)
            .ok()
            .and_then(|index| reference.words.get(index))
            .copied()
            .unwrap_or(0)
    };
    playing
        .words
        .iter()
        .enumerate()
        .map(|(index, &lit)| {
            if lit == 0 {
                return 0;
            }
            let index = index as i64 + whole;
            let against = if part == 0 {
                word(index)
            } else {
                (word(index) >> part) | (word(index + 1) << (64 - part))
            };
            (lit & against).count_ones()
        })
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Cue spans that look like a real file's: `count` of them, with
    /// irregular gaps and irregular lengths averaging about two seconds on
    /// screen in every three.
    ///
    /// Irregular deliberately. Cues spaced exactly alike are a comb, and a
    /// comb aligns onto itself at every shift of one tooth, so a matcher
    /// with a real bug in it would still score perfectly against evenly
    /// spaced test data. What makes a subtitle file identifiable is that
    /// the *pattern* of its intervals occurs once.
    fn synthetic_cues(count: usize) -> Vec<Cue> {
        synthetic_cues_from(0x2545_f491_4f6c_dd1d, count)
    }

    /// The same, from a chosen seed, so that two files can be *unrelated*
    /// rather than one being the other retimed.
    fn synthetic_cues_from(seed: u64, count: usize) -> Vec<Cue> {
        let mut state = seed;
        let mut random = move || {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            f64::from((state >> 40) as u32) / 16_777_216.0
        };
        let mut at = 12.0;
        (0..count)
            .map(|_| {
                let length = 0.8 + 2.4 * random();
                let gap = 0.2 + 1.8 * random();
                let start = at;
                at += length + gap;
                (round_ms(start), round_ms(start + length))
            })
            .collect()
    }

    /// A subtitle file's timestamps are written to the millisecond.
    fn round_ms(at: f64) -> f64 {
        (at * 1000.0).round() / 1000.0
    }

    /// `cues` as another file would carry them: the same moments through
    /// `ratio` and `offset`.
    fn retimed(cues: &[Cue], ratio: f64, offset: f64) -> Vec<Cue> {
        cues.iter()
            .map(|&(start, end)| (ratio * start + offset, ratio * end + offset))
            .collect()
    }

    /// `cues` with neighbours that are already close written as one cue,
    /// the way a translator merges two short exchanges into one subtitle
    /// and gives the merged line its own beat.
    ///
    /// Only the close ones, because that is what merging really is: a
    /// translator does not join two lines a scene apart, and a merge that
    /// swallowed a long pause would put text on screen where the programme
    /// is silent -- a difference the bitmap is *supposed* to notice.
    fn merged(cues: &[Cue]) -> Vec<Cue> {
        let mut merged: Vec<Cue> = Vec::new();
        for &(start, end) in cues {
            match merged.last_mut() {
                Some(last) if start - last.1 < 0.8 => last.1 = end,
                _ => merged.push((start, end)),
            }
        }
        merged
    }

    /// `cues` with every cue written as two, the way a translator splits a
    /// line that will not fit on screen at once. The halves are parted by
    /// a frame's worth of nothing, as a subtitler's tooling does.
    fn split(cues: &[Cue]) -> Vec<Cue> {
        cues.iter()
            .flat_map(|&(start, end)| {
                let middle = (start + end) / 2.0;
                [(start, middle - 0.04), (middle, end)]
            })
            .collect()
    }

    #[test]
    fn recovers_a_known_ratio_and_offset() {
        let playing = synthetic_cues(400);
        let reference = retimed(&playing, 1.0427, 2.5);
        let alignment = align(&playing, &reference).expect("align");
        // To the precision the finest bin can resolve: a fiftieth of a
        // second of offset, and a ratio whose error over the whole file is
        // less than that.
        assert!((alignment.ratio - 1.0427).abs() < 1e-4, "{alignment:?}");
        assert!((alignment.offset - 2.5).abs() < FINEST_BIN, "{alignment:?}");
        assert!(alignment.score > 0.97, "{alignment:?}");
    }

    #[test]
    fn merging_and_splitting_cost_almost_nothing() {
        // The reason this measurement exists. A translation with 690 cues
        // against an original with 1024 is not a worse pairing, it is the
        // same pairing written differently, and a bitmap of when text is
        // on screen barely notices: a merged line covers both the lines it
        // replaced, and a split one covers the same interval twice.
        let playing = synthetic_cues(400);
        let reference = retimed(&playing, 1.0427, 2.5);
        let whole = align(&playing, &reference).expect("align");
        for (what, retold) in [("merged", merged(&playing)), ("split", split(&playing))] {
            let alignment = align(&retold, &reference).expect("align");
            assert!(
                (alignment.ratio - 1.0427).abs() < 1e-4,
                "{what}: {alignment:?}"
            );
            assert!(
                alignment.score > whole.score - 0.15 && alignment.score > 0.8,
                "{what}: {alignment:?} against {whole:?}"
            );
            assert!(alignment.is_convincing(), "{what}: {alignment:?}");
        }
        // And the retellings really are retellings: the old measurement
        // compared cue starts, and these are the files whose starts stopped
        // lining up.
        assert!(merged(&playing).len() * 4 < playing.len() * 3, "merged");
        assert_eq!(split(&playing).len(), playing.len() * 2);
    }

    #[test]
    fn cues_missing_from_the_reference_cost_only_themselves() {
        // Every translation drops and adds lines. What that may not do is
        // move the line the rest of them agree on.
        let playing = synthetic_cues(400);
        let reference: Vec<Cue> = retimed(&playing, 1.0427, 2.5)
            .into_iter()
            .enumerate()
            .filter(|(index, _)| index % 5 != 0)
            .map(|(_, cue)| cue)
            .collect();
        let alignment = align(&playing, &reference).expect("align");
        assert!((alignment.ratio - 1.0427).abs() < 1e-4, "{alignment:?}");
        assert!(alignment.is_convincing(), "{alignment:?}");
    }

    #[test]
    fn an_unrelated_pair_is_measured_and_refused() {
        // The answer is still an alignment with a score in it: the viewer
        // is told what was found, which is the evidence for the refusal,
        // rather than being shown an error with no number in it.
        //
        // Both of these overlap the playing file heavily in absolute
        // terms -- text is on screen two thirds of the time in all of them
        // -- which is exactly what the normalisation is for.
        let playing = synthetic_cues(400);
        for (what, unrelated) in [
            (
                "another episode",
                synthetic_cues_from(0x9e37_79b9_7f4a_7c15, 400),
            ),
            (
                "another episode retimed",
                retimed(&synthetic_cues(400), 1.11, 173.0),
            ),
        ] {
            let alignment = align(&playing, &unrelated).expect("align");
            assert!(!alignment.is_convincing(), "{what}: {alignment:?}");
            assert!(alignment.score < 0.35, "{what}: {alignment:?}");
        }
    }

    #[test]
    fn a_reference_covering_half_the_episode_is_not_convincing() {
        // The half it covers really does line up, and the ratio it implies
        // is right -- but half a file of evidence is exactly the CD1
        // against a whole film that must be refused rather than applied.
        let playing = synthetic_cues(400);
        let reference = retimed(&playing[..200], 1.0427, 2.5);
        let alignment = align(&playing, &reference).expect("align");
        assert!(!alignment.is_convincing(), "{alignment:?}");
    }

    #[test]
    fn chance_is_measured_from_both_densities() {
        // What the normalisation does when one file is lit far less than
        // the other -- a full translation against one that carries only a
        // quarter of the lines, which is what a forced or partial track
        // really looks like.
        //
        // The chance term is computed from *both* densities, so the sparse
        // file's own thinness is the yardstick: an unrelated sparse file
        // overlaps a dense one a great deal in absolute terms and lands at
        // nothing at all here, while the sparse file that really belongs to
        // this episode recovers the ratio and the offset exactly and scores
        // clear of it.
        let dense = synthetic_cues(400);
        let sparse: Vec<Cue> = dense
            .iter()
            .step_by(4)
            .map(|&(start, end)| (start, end))
            .collect();
        let honest = align(&dense, &retimed(&sparse, 1.0427, 2.5)).expect("align");
        let unrelated: Vec<Cue> = synthetic_cues_from(0x9e37_79b9_7f4a_7c15, 400)
            .into_iter()
            .step_by(4)
            .collect();
        let wrong = align(&dense, &unrelated).expect("align");
        assert!((honest.ratio - 1.0427).abs() < 1e-4, "{honest:?}");
        assert!((honest.offset - 2.5).abs() < FINE_BIN, "{honest:?}");
        assert!(wrong.score < 0.05, "{wrong:?}");
        assert!(honest.score > wrong.score + 0.1, "{honest:?} / {wrong:?}");

        // **And it is still refused**, which is a property of the Dice
        // coefficient rather than of the threshold: when the reference is
        // lit a quarter as much as the playing file, `2|A∩B| / (|A|+|B|)`
        // cannot exceed 0.4 however perfectly the two line up, and the
        // chance term for those densities is 0.26 of that. A partial
        // subtitle is therefore not evidence this metric can accept, and
        // whoever calibrates `CONVINCING` has to decide whether that is
        // the right answer or the reason to score a different way.
        assert!(!honest.is_convincing(), "{honest:?}");
    }

    #[test]
    fn too_few_cues_are_not_evidence() {
        // A forced-subtitle track of a dozen signs can be laid onto
        // anything by accident, so there is no answer to give.
        let playing = synthetic_cues(400);
        let reference = retimed(&playing, 1.0427, 2.5);
        assert!(align(&playing[..FEWEST_CUES - 1], &reference).is_none());
        assert!(align(&playing, &reference[..FEWEST_CUES - 1]).is_none());
        assert!(align(&[], &[]).is_none());
    }

    #[test]
    fn a_handful_of_cues_can_be_laid_onto_anything() {
        // Why the floor is worth having. Two files of a handful of cues
        // each are two files lit in a couple of dozen bins out of
        // thousands, so chance is near nothing and there is nothing the
        // search has to beat: with so little to satisfy, and a ratio and an
        // offset of its own choosing to satisfy it with, it lays a
        // forced-subtitle track onto an unrelated episode and calls it a
        // match. Both sides are thinned because that is the shape it takes
        // -- a dense file against a sparse one is held down by the sparse
        // one's own density (`chance_is_measured_from_both_densities`), and
        // it is two sparse files that leave no yardstick at all.
        //
        // Fifty is inherited from the measurement this replaced, and it now
        // has far more room than it needs: three cues a side is convincing
        // almost every time, eight is once in eleven, and by twelve it has
        // stopped happening. What that room buys is the same thing the
        // number was for, so it is left where it is rather than re-tuned by
        // a test that is not calibrating anything.
        let thin = |cues: &[Cue], count: usize| -> Vec<Cue> {
            let step = cues.len() / count;
            (0..count).map(|index| cues[index * step]).collect()
        };
        let whole = synthetic_cues(400);
        let counts = [3usize, 8, FEWEST_CUES];
        let mut coincidences = [0usize; 3];
        let mut best = 0.0f64;
        for seed in 1u64..12 {
            let unrelated = synthetic_cues_from(seed.wrapping_mul(0x9e37_79b9_7f4a_7c15), 400);
            for (coincidences, &count) in coincidences.iter_mut().zip(&counts) {
                let alignment = solve(&thin(&whole, count), &thin(&unrelated, count));
                if count == FEWEST_CUES {
                    best = best.max(alignment.score);
                }
                if alignment.is_convincing() {
                    *coincidences += 1;
                }
            }
        }
        assert!(coincidences[0] >= 5, "{coincidences:?}");
        assert_eq!(coincidences[2], 0, "{coincidences:?}");
        assert!(best < CONVINCING - 0.1, "{best} at the floor");

        // So nothing under the floor is measured at all, however much of
        // it the search would have agreed with. The floor guards both
        // sides, because either file can be the thin one.
        let unrelated = synthetic_cues_from(0x9e37_79b9_7f4a_7c15, 400);
        for count in [3usize, 12, FEWEST_CUES - 1] {
            assert!(
                align(&thin(&whole, count), &unrelated).is_none(),
                "{count} playing cues"
            );
            assert!(
                align(&whole, &thin(&unrelated, count)).is_none(),
                "{count} reference cues"
            );
        }
    }

    #[test]
    fn the_first_pass_keeps_a_whole_file_inside_a_bin() {
        // What the ratio step has to be worth. The passes after the first
        // one only look near its winner, so a step that lets the ends of
        // the file drift out of their bins does not lose precision, it
        // loses the answer.
        for span in [300.0, 1_200.0, 2_600.0, 5_400.0, 10_800.0] {
            let worst_ratio_error = coarse_step(span, COARSE_BIN) / 2.0;
            // The offset the search picks centres the error on the file,
            // so the worst cue is half a span out from the middle.
            let worst_cue_error = worst_ratio_error * span / 2.0;
            assert!(
                worst_cue_error <= COARSE_BIN,
                "{span} s: {worst_cue_error} s"
            );
        }
        // A file too short for that to ask anything is still swept at the
        // coarser bound, rather than in one enormous step.
        assert_eq!(coarse_step(0.0, COARSE_BIN), COARSEST_STEP);
        assert_eq!(coarse_step(60.0, COARSE_BIN), COARSEST_STEP);
    }

    #[test]
    fn reads_both_ends_of_an_srt() {
        let srt = "1\r\n00:00:01,000 --> 00:00:03,500\r\nFirst line\r\n\r\n\
                   2\r\n00:01:02,250 --> 00:01:04,000\r\nSecond line\r\n";
        assert_eq!(cue_spans(srt), vec![(1.0, 3.5), (62.25, 64.0)]);
    }

    #[test]
    fn reads_both_ends_of_a_webvtt() {
        // Hours omitted, dots for the fraction, cue settings after the end
        // time, a header and a NOTE block -- all of which a WebVTT file
        // from an addon that does not normalise to SRT really carries.
        // The settings are why only the first token after the arrow is
        // read.
        let vtt = "WEBVTT\n\nNOTE this file came from a broadcast\n\n\
                   00:01.000 --> 00:03.500 line:90% align:middle\nFirst line\n\n\
                   intro\n01:02.250 --> 01:04.000\nSecond line\n";
        assert_eq!(cue_spans(vtt), vec![(1.0, 3.5), (62.25, 64.0)]);
    }

    #[test]
    fn skips_what_it_cannot_read_rather_than_refusing_the_file() {
        // A damaged cue costs its own interval and no other: the file is
        // still worth measuring against. A cue that ends before it starts
        // is damaged in the same way -- it describes no interval at all.
        let srt = "1\n00:00:01,000 --> 00:00:03,500\nGood\n\n\
                   2\n00:00:9x,000 --> 00:00:12,000\nBroken start\n\n\
                   3\n00:00:14,000 --> 00:00:1x,000\nBroken end\n\n\
                   4\n00:00:22,000 --> 00:00:20,000\nBackwards\n\n\
                   5\n00:00:20,000 --> 00:00:22,000\nGood\n";
        assert_eq!(cue_spans(srt), vec![(1.0, 3.5), (20.0, 22.0)]);
        assert!(cue_spans("nothing here at all\n").is_empty());
    }

    #[test]
    fn sorts_by_when_the_line_goes_up() {
        // A file out of order is still a set of intervals, and two boxes
        // on screen together are two intervals that light the same bins
        // rather than one observation counted twice.
        let srt = "00:00:10,000 --> 00:00:12,000\nOne\n\n\
                   00:00:10,000 --> 00:00:11,000\n- Two\n\n\
                   00:00:05,000 --> 00:00:06,000\nEarlier\n";
        assert_eq!(cue_spans(srt), vec![(5.0, 6.0), (10.0, 12.0), (10.0, 11.0)]);
    }

    #[test]
    fn a_coarser_bin_keeps_the_file_s_density() {
        // The property the coarse pass rests on. Lighting a bin from any
        // overlap would make a file of two-second lines and one-second gaps
        // nearly all lit at a second per bin, and a chance term computed
        // from two densities of 0.9 leaves nothing above it to measure --
        // measured that way, the right ratio scored 0.14 where a wrong one
        // scored 0.34. Rounding a bin to the nearer answer keeps every pass
        // looking at the same file.
        let cues = synthetic_cues(400);
        let density = |bin: f64| {
            let map = Bitmap::of(&cues, 1.0, bin);
            f64::from(map.lit) / map.bins as f64
        };
        let truth = density(FINEST_BIN);
        assert!((0.5..0.8).contains(&truth), "{truth}");
        for bin in [FINE_BIN, COARSE_BIN] {
            assert!(
                (density(bin) - truth).abs() < 0.05,
                "{bin}: {}",
                density(bin)
            );
        }
    }

    #[test]
    fn a_fraction_is_a_decimal_and_not_a_count_of_milliseconds() {
        assert_eq!(timestamp_seconds("00:00:01,5"), Some(1.5));
        assert_eq!(timestamp_seconds("00:00:01,500"), Some(1.5));
        assert_eq!(timestamp_seconds("00:00:01"), Some(1.0));
        assert_eq!(timestamp_seconds("1:02:03,000"), Some(3723.0));
    }

    #[test]
    fn refuses_a_stamp_that_is_not_one() {
        assert_eq!(timestamp_seconds(""), None);
        assert_eq!(timestamp_seconds("12"), None);
        assert_eq!(timestamp_seconds("00:00:60,000"), None);
        assert_eq!(timestamp_seconds("00:60:00,000"), None);
        assert_eq!(timestamp_seconds("1:00:00:00,000"), None);
        assert_eq!(timestamp_seconds("00:00:01,abc"), None);
    }
}
