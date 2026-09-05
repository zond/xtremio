//! What a subtitle file says about *time*, and nothing else.
//!
//! Two subtitle files for one video are two clocks. When they disagree the
//! disagreement is a line -- `reference = ratio * playing + offset` -- and
//! this module is how that line is measured: read the cue *start* times out
//! of both files and solve for the ratio and the offset that make the most
//! starts coincide.
//!
//! **Only the starts are read, and the text is thrown away.** Different
//! languages split one sentence into two lines and merge two into one, so
//! neither the number of cues nor the words in them survive a translation;
//! what does survive is that a line of dialogue starts when somebody starts
//! speaking. Ends drift with reading speed and with each translator's
//! habits, so an end is a worse observation of the same moment than the
//! start next to it.

/// Every cue start in `text`, in seconds, sorted and without duplicates.
///
/// SRT and WebVTT both write a cue as `<start> --> <end>` on a line of its
/// own, so the parse is that line and nothing around it: no cue numbering,
/// no `WEBVTT` header, no `NOTE` block, no styling and no text. Anything
/// this does not recognise is skipped rather than refused -- a subtitle
/// file with one damaged cue in it is still a usable set of observations,
/// and the caller judges the result by how many cues came out.
///
/// The two formats differ in the fraction separator (`,` against `.`) and
/// in whether the hours are written at all, and files in the wild mix both
/// conventions, so both are accepted in either format rather than the file
/// being sniffed for which one it claims to be.
///
/// Sorted because everything downstream binary-searches this; deduplicated
/// because two cues that start at the same moment (a speaker change split
/// across two boxes) are one observation of one speech onset, and counting
/// it twice would let a file with many of them outvote one without.
pub fn cue_starts(text: &str) -> Vec<f64> {
    let mut starts: Vec<f64> = text
        .lines()
        .filter_map(|line| line.split("-->").next())
        .filter_map(timestamp_seconds)
        .collect();
    starts.sort_by(f64::total_cmp);
    starts.dedup();
    starts
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
/// and how much of the file agrees with it.
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
    /// How many of the playing file's cue starts land within
    /// [`TOLERANCE`] of a cue start in the reference under this line.
    pub matched: usize,
    /// How many cue starts the playing file has: the denominator of the
    /// evidence, and the number the viewer is shown it against.
    pub cues: usize,
}

/// How close two cue starts have to be to be called the same moment.
///
/// A third of a second is about what two translators disagree by on the
/// same speech onset, and is well under the quarter-second a viewer
/// notices as being out. Tighter and an honest match is thrown away by
/// two subtitlers' habits; looser and the accidental coincidences of an
/// unrelated file start counting, which is what the refusal below depends
/// on being rare.
pub const TOLERANCE: f64 = 0.35;

/// The window the ratio is looked for in, either side of the file's own
/// timing.
///
/// PAL against film -- 25 fps timings on a 23.976 fps cut -- is 4.3 %, and
/// is the largest mismatch that really occurs; everything else is
/// telecine, which preserves seconds and needs no ratio at all. A tenth
/// either way is room enough for that plus anything a hand-retimed file
/// has picked up, and stops the sweep from "explaining" two unrelated
/// files by stretching one of them into the shape of the other.
pub const LOWEST_RATIO: f64 = 0.90;
pub const HIGHEST_RATIO: f64 = 1.10;

/// The share of the playing file's cues that has to land on the reference
/// before the answer is worth applying.
///
/// Measured against the owner's own files: ten pairs of real English
/// subtitles for one episode align at 87-100 %, and every pair that
/// should not be aligned at all -- two different episodes, two different
/// cuts of one episode, half a film against the whole -- comes in at
/// 22-53 %. The gap between those two populations is where this sits.
/// Below it the honest answer is that these two files do not describe the
/// same recording, which the viewer is told rather than shown as a
/// transform that ruins a subtitle that was merely a little out.
pub const CONVINCING: f64 = 0.60;

/// How few cues make a file useless as evidence either way.
///
/// A forced-subtitle track of a dozen signs can be aligned onto anything
/// by accident, and a coincidence rate over so small a denominator says
/// nothing. Refusing to measure is better than measuring badly.
const FEWEST_CUES: usize = 20;

/// How many cues of each file the offset histogram is built from.
///
/// The histogram is the one quadratic step (every sampled cue against
/// every sampled cue, once per ratio tried), so this is what keeps a
/// three-hour film costing the same as an episode. A few hundred starts
/// spread across a file describe its timeline as well as all of them do:
/// the line being fitted has two parameters, and the sample keeps the
/// span, which is what a ratio is read off.
const SAMPLE_CAP: usize = 300;

/// The bin the pairwise differences are counted in, and how far apart the
/// two files' clocks may be before a difference stops being considered.
///
/// The bin is under [`TOLERANCE`] so the mode of the differences already
/// names an offset that scores; the exact value is recovered afterwards by
/// [`Alignment::refit`]. An hour of offset covers a subtitle written for a
/// disc with a different pre-roll and even a half-film reference, while
/// keeping the histogram small enough to clear once per ratio.
const OFFSET_BIN: f64 = 0.25;
const WIDEST_OFFSET: f64 = 3600.0;

/// The ratios tried before refining: the coarse sweep's step, and the
/// finer one taken around whatever it liked best.
///
/// A step of 0.002 leaves at most 0.001 of ratio error, which over a
/// quarter of an hour is under a second: enough of the file still lands
/// within [`TOLERANCE`] for the right ratio to be the peak, even where it
/// is not yet the exact answer. The refinement and then the refit are what
/// make it exact.
const COARSE_STEP: f64 = 0.002;
const FINE_STEP: f64 = 0.0002;

impl Alignment {
    /// The share of the playing file's cues this line puts on a cue of the
    /// reference. Zero when the file has no cues at all.
    pub fn agreement(&self) -> f64 {
        if self.cues == 0 {
            0.0
        } else {
            self.matched as f64 / self.cues as f64
        }
    }

    /// Whether these two files agree well enough ([`CONVINCING`]) for the
    /// line to be worth applying.
    pub fn is_convincing(&self) -> bool {
        self.agreement() >= CONVINCING
    }
}

/// Solves for the line that maps `playing` onto `reference`, both being
/// cue starts as [`cue_starts`] answers them.
///
/// None when either file has too few cues to be evidence ([`FEWEST_CUES`]);
/// otherwise an [`Alignment`] and its score, *including* when the score is
/// hopeless -- refusing is [`Alignment::is_convincing`]'s call to make and
/// the count is what the viewer is owed either way.
///
/// The measurement is a sweep rather than anything cleverer because the
/// two unknowns are not independent: an offset can only be read once a
/// ratio is assumed, since the same pair of files at the wrong ratio has
/// no single offset at all. So for each ratio in the window the offset is
/// taken from the mode of the pairwise differences -- the offset the most
/// cues agree on -- and the ratio is judged by how well that lands the
/// cues. Then the winner is refined, and refitted until it stops
/// improving.
pub fn align(playing: &[f64], reference: &[f64]) -> Option<Alignment> {
    if playing.len() < FEWEST_CUES || reference.len() < FEWEST_CUES {
        return None;
    }
    let sampled_playing = sample(playing, SAMPLE_CAP);
    let sampled_reference = sample(reference, SAMPLE_CAP);
    let mut histogram = vec![0u32; (2.0 * WIDEST_OFFSET / OFFSET_BIN) as usize + 1];

    // Judged against the *whole* reference rather than its sample: the
    // sample is there to make the histogram affordable, and scoring a
    // sampled playing cue against a sampled reference would call a real
    // match a miss whenever the sampling dropped the cue it belongs to.
    let mut line = (1.0, 0.0);
    let mut closest = -1.0;
    let mut try_ratio = |ratio: f64, line: &mut (f64, f64), closest: &mut f64| {
        let offset = mode_offset(&sampled_playing, &sampled_reference, ratio, &mut histogram);
        let closeness = closeness(&sampled_playing, reference, ratio, offset);
        if closeness > *closest {
            *closest = closeness;
            *line = (ratio, offset);
        }
    };
    let coarse_steps = ((HIGHEST_RATIO - LOWEST_RATIO) / COARSE_STEP).round() as i32;
    for step in 0..=coarse_steps {
        try_ratio(
            LOWEST_RATIO + f64::from(step) * COARSE_STEP,
            &mut line,
            &mut closest,
        );
    }
    let around = line.0;
    let fine_steps = (COARSE_STEP / FINE_STEP).round() as i32;
    for step in -fine_steps..=fine_steps {
        let ratio = around + f64::from(step) * FINE_STEP;
        if (LOWEST_RATIO..=HIGHEST_RATIO).contains(&ratio) {
            try_ratio(ratio, &mut line, &mut closest);
        }
    }

    // From here on every cue counts, not only the sampled ones: the sweep
    // is over, and the line that comes out of this is the transform the
    // viewer gets. Bounded because a fit that neither improves nor settles
    // is oscillating between two equally good answers, and the loop is not
    // where that should be discovered.
    let mut closest = closeness(playing, reference, line.0, line.1);
    for _ in 0..8 {
        let Some(fitted) = refit(playing, reference, line.0, line.1) else {
            break;
        };
        if !(LOWEST_RATIO..=HIGHEST_RATIO).contains(&fitted.0) {
            break;
        }
        let closeness = closeness(playing, reference, fitted.0, fitted.1);
        if closeness <= closest {
            break;
        }
        closest = closeness;
        line = fitted;
    }
    Some(Alignment {
        ratio: line.0,
        offset: line.1,
        matched: matches(playing, reference, line.0, line.1),
        cues: playing.len(),
    })
}

/// The least-squares line through the pairs `ratio` and `offset` already
/// match, or None when they match too few to fit one.
///
/// The sweep answers to the precision of its own step and of the offset
/// histogram's bin. Fitting a line through the pairs it *found* costs one
/// pass and answers to the precision of the data instead -- on two files
/// that really are one recording it recovers the ratio exactly. It is also
/// how a coarse winner improves itself: a ratio that was slightly out
/// matched the middle of the file, and the fit through that middle points
/// at a ratio that reaches the ends too, so repeating it converges rather
/// than wandering.
fn refit(playing: &[f64], reference: &[f64], ratio: f64, offset: f64) -> Option<(f64, f64)> {
    let pairs: Vec<(f64, f64)> = playing
        .iter()
        .filter_map(|&start| {
            let want = ratio * start + offset;
            nearest(reference, want)
                .filter(|near| (near - want).abs() <= TOLERANCE)
                .map(|near| (start, near))
        })
        .collect();
    if pairs.len() < 2 {
        return None;
    }
    let count = pairs.len() as f64;
    let mean_playing = pairs.iter().map(|(start, _)| start).sum::<f64>() / count;
    let mean_reference = pairs.iter().map(|(_, near)| near).sum::<f64>() / count;
    let mut variance = 0.0;
    let mut covariance = 0.0;
    for (start, near) in pairs {
        variance += (start - mean_playing) * (start - mean_playing);
        covariance += (start - mean_playing) * (near - mean_reference);
    }
    if variance <= 0.0 {
        return None;
    }
    let ratio = covariance / variance;
    Some((ratio, mean_reference - ratio * mean_playing))
}

/// At most `cap` of `cues`, spread evenly so the sample keeps the file's
/// whole span -- which is what a ratio is measured over, and what taking
/// the first `cap` cues would throw away.
fn sample(cues: &[f64], cap: usize) -> Vec<f64> {
    if cues.len() <= cap {
        return cues.to_vec();
    }
    let step = cues.len() as f64 / cap as f64;
    (0..cap)
        .map(|index| cues[(index as f64 * step) as usize])
        .collect()
}

/// How many of `playing`'s starts land within [`TOLERANCE`] of a start in
/// `reference` under `ratio` and `offset`. Both must be sorted.
fn matches(playing: &[f64], reference: &[f64], ratio: f64, offset: f64) -> usize {
    playing
        .iter()
        .filter(|&&start| {
            let want = ratio * start + offset;
            nearest(reference, want).is_some_and(|near| (near - want).abs() <= TOLERANCE)
        })
        .count()
}

/// How well `playing` sits on `reference` under this line: every cue
/// counts for how close it landed, one for an exact coincidence and
/// nothing at all at [`TOLERANCE`] or beyond.
///
/// Used to choose between lines, where [`matches`] is used to report one.
/// A count of cues inside the tolerance is what the viewer is owed as
/// evidence, but it is a poor thing to steer by: it cannot tell a line
/// that lands every cue dead on from one that leaves them all a third of
/// a second out, and it lets a ratio that is slightly wrong beat the right
/// one on a single cue that crossed the threshold by luck. That was not
/// hypothetical -- it kept a fit at 1.0424 where the files said 1.0427.
fn closeness(playing: &[f64], reference: &[f64], ratio: f64, offset: f64) -> f64 {
    playing
        .iter()
        .map(|&start| {
            let want = ratio * start + offset;
            match nearest(reference, want) {
                Some(near) => (1.0 - (near - want).abs() / TOLERANCE).max(0.0),
                None => 0.0,
            }
        })
        .sum()
}

/// The value in a sorted `cues` closest to `want`.
fn nearest(cues: &[f64], want: f64) -> Option<f64> {
    let after = cues.partition_point(|&start| start < want);
    let before = after.checked_sub(1).map(|index| cues[index]);
    match (before, cues.get(after).copied()) {
        (Some(before), Some(after)) => Some(if want - before <= after - want {
            before
        } else {
            after
        }),
        (Some(only), None) | (None, Some(only)) => Some(only),
        (None, None) => None,
    }
}

/// The offset the most cues agree on at this `ratio`: the mode of every
/// pairwise difference, binned at [`OFFSET_BIN`].
///
/// The mode rather than a mean or a median of the differences, because
/// most of the pairs are between cues that have nothing to do with each
/// other -- with a few hundred cues on each side, only a few hundred of
/// the tens of thousands of differences are real. An average over that is
/// an average over noise; the pile-up at one value is the signal.
///
/// `histogram` is borrowed rather than allocated because this runs once
/// per ratio tried, a couple of hundred times per alignment.
fn mode_offset(playing: &[f64], reference: &[f64], ratio: f64, histogram: &mut [u32]) -> f64 {
    histogram.fill(0);
    let middle = (histogram.len() / 2) as i64;
    for &start in playing {
        let scaled = ratio * start;
        for &near in reference {
            let difference = near - scaled;
            if difference.abs() <= WIDEST_OFFSET {
                let bin = middle + (difference / OFFSET_BIN).round() as i64;
                if let Some(count) = histogram.get_mut(bin as usize) {
                    *count += 1;
                }
            }
        }
    }
    // Three bins wide, so an offset that falls on a bin edge is not beaten
    // by a worse one that happens to sit in the middle of its own.
    let mut best_bin = middle;
    let mut best_count = 0;
    for bin in 1..histogram.len() - 1 {
        let count = histogram[bin - 1] + histogram[bin] + histogram[bin + 1];
        if count > best_count {
            best_count = count;
            best_bin = bin as i64;
        }
    }
    (best_bin - middle) as f64 * OFFSET_BIN
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Cue starts that look like a real file's: `count` of them, with
    /// irregular gaps averaging about three seconds.
    ///
    /// Irregular deliberately. Cues spaced exactly alike are a comb, and a
    /// comb aligns onto itself at every shift of one tooth, so an aligner
    /// with a real bug in it would still score perfectly against evenly
    /// spaced test data. What makes a subtitle file identifiable is that
    /// the *pattern* of its gaps occurs once.
    fn synthetic_cues(count: usize) -> Vec<f64> {
        let mut state = 0x2545_f491_4f6c_dd1d_u64;
        let mut at = 12.0;
        (0..count)
            .map(|_| {
                state = state
                    .wrapping_mul(6364136223846793005)
                    .wrapping_add(1442695040888963407);
                let gap = 0.4 + 5.6 * f64::from((state >> 40) as u32) / 16_777_216.0;
                at += gap;
                (at * 1000.0).round() / 1000.0
            })
            .collect()
    }

    /// `cues` as another file would carry them: the same moments through
    /// `ratio` and `offset`.
    fn retimed(cues: &[f64], ratio: f64, offset: f64) -> Vec<f64> {
        cues.iter().map(|start| ratio * start + offset).collect()
    }

    #[test]
    fn recovers_a_known_ratio_and_offset() {
        let playing = synthetic_cues(400);
        let reference = retimed(&playing, 1.0427, 2.5);
        let alignment = align(&playing, &reference).expect("align");
        assert!((alignment.ratio - 1.0427).abs() < 1e-9, "{alignment:?}");
        assert!((alignment.offset - 2.5).abs() < 1e-6, "{alignment:?}");
        assert_eq!((alignment.matched, alignment.cues), (400, 400));
    }

    #[test]
    fn cues_missing_from_the_reference_cost_only_themselves() {
        // Every translation drops and adds lines. What that may not do is
        // move the line the rest of them agree on.
        let playing = synthetic_cues(400);
        let reference: Vec<f64> = retimed(&playing, 1.0427, 2.5)
            .into_iter()
            .enumerate()
            .filter(|(index, _)| index % 5 != 0)
            .map(|(_, start)| start)
            .collect();
        let alignment = align(&playing, &reference).expect("align");
        assert!((alignment.ratio - 1.0427).abs() < 1e-9, "{alignment:?}");
        assert_eq!(alignment.matched, 320);
        assert!(alignment.is_convincing(), "{alignment:?}");
    }

    #[test]
    fn a_reference_covering_half_the_episode_is_not_convincing() {
        // The half it covers really does line up, and the ratio it implies
        // is right -- but half a file of evidence is exactly the CD1
        // against a whole film that must be refused rather than applied.
        let playing = synthetic_cues(400);
        let reference = retimed(&playing[..200], 1.0427, 2.5);
        let alignment = align(&playing, &reference).expect("align");
        assert!((alignment.ratio - 1.0427).abs() < 1e-6, "{alignment:?}");
        assert_eq!(alignment.matched, 200);
        assert!(!alignment.is_convincing(), "{alignment:?}");
    }

    #[test]
    fn noise_around_each_cue_averages_out() {
        // Two subtitlers do not agree to the millisecond about when a line
        // goes up, so every real pair is this test with a smaller number.
        let playing = synthetic_cues(400);
        let mut state = 0x9e37_79b9_7f4a_7c15_u64;
        let reference: Vec<f64> = retimed(&playing, 1.0427, 2.5)
            .into_iter()
            .map(|start| {
                state = state
                    .wrapping_mul(6364136223846793005)
                    .wrapping_add(1442695040888963407);
                start + (0.3 * f64::from((state >> 40) as u32) / 16_777_216.0 - 0.15)
            })
            .collect();
        let alignment = align(&playing, &reference).expect("align");
        assert!((alignment.ratio - 1.0427).abs() < 1e-4, "{alignment:?}");
        assert_eq!(alignment.matched, 400, "{alignment:?}");
    }

    #[test]
    fn an_unrelated_pair_is_measured_and_refused() {
        // The answer is still an alignment with a count in it: the viewer
        // is told how badly it matched, which is the evidence for the
        // refusal, rather than being shown an error with no number in it.
        let playing = synthetic_cues(400);
        let unrelated = synthetic_cues(400)
            .iter()
            .map(|start| start * 1.11 + 173.0)
            .collect::<Vec<_>>();
        let alignment = align(&playing, &unrelated).expect("align");
        assert!(!alignment.is_convincing(), "{alignment:?}");
        assert_eq!(alignment.cues, 400);
    }

    #[test]
    fn the_sampling_cap_does_not_change_the_answer() {
        // A three-hour film costs what an episode does because only a few
        // hundred cues reach the quadratic step. That is only affordable
        // if it is also free of consequences.
        let short = synthetic_cues(SAMPLE_CAP - 50);
        let long = synthetic_cues(SAMPLE_CAP * 5);
        let under = align(&short, &retimed(&short, 1.0427, 2.5)).expect("align");
        let over = align(&long, &retimed(&long, 1.0427, 2.5)).expect("align");
        assert!((under.ratio - 1.0427).abs() < 1e-9, "{under:?}");
        assert!((over.ratio - 1.0427).abs() < 1e-9, "{over:?}");
        assert_eq!(over.matched, over.cues);
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
    fn reads_the_starts_of_an_srt() {
        let srt = "1\r\n00:00:01,000 --> 00:00:03,500\r\nFirst line\r\n\r\n\
                   2\r\n00:01:02,250 --> 00:01:04,000\r\nSecond line\r\n";
        assert_eq!(cue_starts(srt), vec![1.0, 62.25]);
    }

    #[test]
    fn reads_the_starts_of_a_webvtt() {
        // Hours omitted, dots for the fraction, cue settings after the end
        // time, a header and a NOTE block -- all of which a WebVTT file
        // from an addon that does not normalise to SRT really carries.
        let vtt = "WEBVTT\n\nNOTE this file came from a broadcast\n\n\
                   00:01.000 --> 00:03.500 line:90% align:middle\nFirst line\n\n\
                   intro\n01:02.250 --> 01:04.000\nSecond line\n";
        assert_eq!(cue_starts(vtt), vec![1.0, 62.25]);
    }

    #[test]
    fn skips_what_it_cannot_read_rather_than_refusing_the_file() {
        // A damaged cue costs its own observation and no other: the file
        // is still worth aligning against.
        let srt = "1\n00:00:01,000 --> 00:00:03,500\nGood\n\n\
                   2\n00:00:9x,000 --> 00:00:12,000\nBroken\n\n\
                   3\n00:00:20,000 --> 00:00:22,000\nGood\n";
        assert_eq!(cue_starts(srt), vec![1.0, 20.0]);
        assert!(cue_starts("nothing here at all\n").is_empty());
    }

    #[test]
    fn sorts_and_counts_one_moment_once() {
        // Two boxes on screen together are one speech onset; a file out of
        // order is still a set of observations.
        let srt = "00:00:10,000 --> 00:00:12,000\nOne\n\n\
                   00:00:10,000 --> 00:00:11,000\n- Two\n\n\
                   00:00:05,000 --> 00:00:06,000\nEarlier\n";
        assert_eq!(cue_starts(srt), vec![5.0, 10.0]);
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
