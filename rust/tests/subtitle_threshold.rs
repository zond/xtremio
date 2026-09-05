//! Where [`CONVINCING`] sits, and the measurement that put it there.
//!
//! The threshold decides whether a measured alignment is written onto the
//! playing subtitle, so what it has to be judged against is two
//! populations: pairings whose transform is right to apply, and pairings
//! that must be refused. `tests/fixtures/subtitle_threshold.json` is that
//! measurement -- the corpus it was taken over, what each population
//! scored, and the extreme pairs at either end -- and the tests here say
//! that the constant still falls where the numbers put it.
//!
//! **The corpus is real files, because the number the threshold replaced
//! was set on a case that does not occur.** That one came from
//! English-to-English pairs, which share a timing grid because one was
//! derived from the other, and it refused the owner's own Swedish file.
//! So this is gathered from the OpenSubtitles addon the app itself asks:
//! forty titles -- films and episodes of several series -- in every
//! language offered for them, which is both the languages that merge lines
//! heavily and the ones that split them.
//!
//! **What makes a pairing "right to apply" is not that the addon listed
//! the two files under one episode.** Uploads are mislabelled, tracks are
//! partial, and a listing carries trailers. The rule is a statistic the
//! score does not use: with the transform applied, the median distance
//! from a playing cue's start to the nearest reference start is under a
//! third of a second and at least half of them land that close.
//! [`RIGHT_MEDIAN`] and [`RIGHT_WITHIN`]. Not one of the pairings that
//! must be refused reaches it -- a different film's cues fall about a
//! second from the nearest, which is what chance gives at this cue
//! density -- so the two populations really are disjoint before a score is
//! looked at. The rule runs the other way too: the handful of pairings
//! listed under two different titles that *do* meet it are one recording
//! catalogued twice, and they are recorded as such rather than counted as
//! mismatches the threshold has to clear.
//!
//! Re-record it (it downloads some tens of megabytes of subtitle files and
//! measures a few thousand pairings, so give it a release build and a
//! quarter of an hour):
//!
//! ```text
//! cargo test --release --test subtitle_threshold -- --ignored --nocapture
//! ```

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use xtremio_core::subtitles::{align, cue_spans, Cue, CONVINCING};

/// The median start error, in seconds, under which a transform is taken to
/// be the right one, and the share of cues that must land that close.
///
/// A third of a second because that is what the measurement this replaced
/// called a matching cue; half of them because a translation that merges
/// lines gives the merged line its own beat, so a perfectly good pairing
/// only ever has some of its starts on the other file's.
const RIGHT_MEDIAN: f64 = 0.35;
const RIGHT_WITHIN: f64 = 0.5;

#[test]
fn nothing_that_must_be_refused_reaches_the_threshold() {
    let recorded = Calibration::read();
    for population in recorded.populations.iter().filter(|p| p.verdict == REFUSE) {
        assert!(
            population.max < CONVINCING,
            "{}: best of {} scored {:.3}, at or above CONVINCING {CONVINCING}",
            population.name,
            population.pairs,
            population.max
        );
    }
}

#[test]
fn nearly_every_pairing_that_should_be_applied_clears_it() {
    // The fifth percentile and not the recorded share, because the share
    // was worked out against whatever `CONVINCING` was when the fixture was
    // written and would not notice this constant moving. Against the
    // percentile the demand is exactly "it refuses at most one in twenty of
    // the pairings whose transform is right", which is what raising the
    // threshold spends.
    //
    // At most one in twenty rather than none of them: the two populations
    // *overlap* -- the worst pairing that should be applied scores below
    // the best mismatch -- so a threshold that accepted all of them would
    // accept mismatches too, and the fixture's own numbers say by how much.
    let recorded = Calibration::read();
    for population in recorded.populations.iter().filter(|p| p.verdict == APPLY) {
        assert!(
            CONVINCING <= population.p05,
            "{}: CONVINCING {CONVINCING} refuses more than one in twenty of {} pairings \
             whose transform is right, whose fifth percentile is {:.3}",
            population.name,
            population.pairs,
            population.p05
        );
    }
}

#[test]
fn the_threshold_sits_above_every_one_a_mismatch_reached() {
    let recorded = Calibration::read();
    // Named pairs rather than a percentile, because the case for the
    // number is that *these* mismatches -- the best of thirty thousand --
    // scored less than it.
    for extreme in &recorded.best_to_refuse {
        assert!(
            extreme.score < CONVINCING,
            "{extreme:?} must be refused and reaches CONVINCING {CONVINCING}"
        );
    }
    // And the recorded cost curve is the argument against lowering it: the
    // thresholds at which a mismatch really was accepted are all below the
    // one in force.
    for cost in recorded
        .costs
        .iter()
        .filter(|cost| cost.wrongly_applied > 0.0)
    {
        assert!(
            cost.threshold < CONVINCING,
            "at {} the measurement accepted {:.3} % of the mismatches",
            cost.threshold,
            100.0 * cost.wrongly_applied
        );
    }
    // What the threshold costs is written down rather than implied: the
    // pairings that should be applied and scored worst are in the fixture
    // by name, with the two start-error numbers that say they really do
    // line up.
    assert!(!recorded.worst_to_apply.is_empty(), "nothing recorded");
}

#[test]
fn the_measurement_is_wide_enough_to_have_set_a_number() {
    // Five pairings of one episode is what the placeholder was picked on,
    // and the reason it was a placeholder. Anything that thins the corpus
    // to that again should fail here rather than quietly weaken the case.
    let recorded = Calibration::read();
    assert!(recorded.gathered.titles >= 20, "{:?}", recorded.gathered);
    assert!(recorded.gathered.languages >= 15, "{:?}", recorded.gathered);
    assert!(
        recorded.gathered.measured >= 2_000,
        "{:?}",
        recorded.gathered
    );
    let refused: usize = recorded
        .populations
        .iter()
        .filter(|p| p.verdict == REFUSE)
        .map(|p| p.pairs)
        .sum();
    let applied: usize = recorded
        .populations
        .iter()
        .filter(|p| p.verdict == APPLY)
        .map(|p| p.pairs)
        .sum();
    assert!(refused >= 500, "{refused} pairings that must be refused");
    assert!(applied >= 500, "{applied} pairings that should be applied");
}

const APPLY: &str = "apply";
const REFUSE: &str = "refuse";
/// Neither: a half of a film against the whole, a different cut, and the
/// same-title pairings the start errors do not confirm. Recorded because
/// they were asked for and because what they show is that this score
/// cannot judge them -- see the fixture's note.
const UNJUDGED: &str = "unjudged";

/// The recorded measurement.
#[derive(Serialize, Deserialize)]
struct Calibration {
    note: String,
    gathered: Gathered,
    populations: Vec<Population>,
    /// What a threshold either side of the one in force would have cost,
    /// so that the number is a comparison rather than an assertion.
    costs: Vec<Cost>,
    /// The pairings that should be applied and scored worst, and the ones
    /// that must be refused and scored best: the two ends the threshold
    /// has to fit between.
    worst_to_apply: Vec<Pairing>,
    best_to_refuse: Vec<Pairing>,
    /// Every file the measurement was taken over, so it can be taken
    /// again over the same ones.
    corpus: Vec<Recorded>,
}

#[derive(Debug, Serialize, Deserialize)]
struct Gathered {
    titles: usize,
    files: usize,
    languages: usize,
    pairs: usize,
    /// Pairs that were measured at all; the rest had a file with too few
    /// cues to be evidence (a trailer, mostly).
    measured: usize,
}

/// One candidate threshold: the share of the pairings that should be
/// applied which reach it, and the share of the mismatches which do.
#[derive(Serialize, Deserialize)]
struct Cost {
    threshold: f64,
    applied: f64,
    wrongly_applied: f64,
}

#[derive(Serialize, Deserialize)]
struct Population {
    name: String,
    verdict: String,
    pairs: usize,
    min: f64,
    p05: f64,
    median: f64,
    p95: f64,
    max: f64,
    /// The share of them at or above the threshold in force when this was
    /// recorded, which is what it cost on the day.
    at_or_above_convincing: f64,
}

#[derive(Debug, Serialize, Deserialize)]
struct Pairing {
    population: String,
    playing: String,
    reference: String,
    score: f64,
    ratio: f64,
    offset: f64,
    /// The two numbers the verdict was read off, which is why they are
    /// here: the score is not what decided which population this is in.
    median_error: f64,
    within: f64,
}

#[derive(Clone, Serialize, Deserialize)]
struct Recorded {
    /// The addon's own id for the file, and the URL it answered with.
    id: String,
    title: String,
    lang: String,
    release: String,
    url: String,
}

impl Calibration {
    fn read() -> Self {
        serde_json::from_slice(&std::fs::read(fixture_path()).expect("read the fixture"))
            .expect("parse the fixture")
    }
}

fn fixture_path() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/subtitle_threshold.json")
}

// ---------------------------------------------------------------------
// The recorder.
// ---------------------------------------------------------------------

/// What the corpus is gathered over: films and episodes, chosen so that a
/// mismatch of every kind can be built out of it -- another episode of the
/// same season, another season, another title entirely -- and so that the
/// films with several cuts and the ones old enough to have been released
/// on two discs are both represented.
const TITLES: &[(&str, &str, &str, u32, u32)] = &[
    // key, addon path, series (empty for a film), season, episode
    ("gg_s01e01", "series/tt0238784:1:1", "gg", 1, 1),
    ("gg_s01e02", "series/tt0238784:1:2", "gg", 1, 2),
    ("gg_s05e01", "series/tt0238784:5:1", "gg", 5, 1),
    ("bb_s01e01", "series/tt0903747:1:1", "bb", 1, 1),
    ("bb_s01e02", "series/tt0903747:1:2", "bb", 1, 2),
    ("bb_s02e01", "series/tt0903747:2:1", "bb", 2, 1),
    ("got_s01e01", "series/tt0944947:1:1", "got", 1, 1),
    ("got_s01e02", "series/tt0944947:1:2", "got", 1, 2),
    ("got_s04e02", "series/tt0944947:4:2", "got", 4, 2),
    ("friends_s01e01", "series/tt0108778:1:1", "friends", 1, 1),
    ("friends_s01e02", "series/tt0108778:1:2", "friends", 1, 2),
    ("office_s02e01", "series/tt0386676:2:1", "office", 2, 1),
    ("sherlock_s01e01", "series/tt1475582:1:1", "sherlock", 1, 1),
    ("simpsons_s05e01", "series/tt0096697:5:1", "simpsons", 5, 1),
    ("stranger_s01e01", "series/tt4574334:1:1", "stranger", 1, 1),
    ("shawshank", "movie/tt0111161", "", 0, 0),
    ("godfather", "movie/tt0068646", "", 0, 0),
    ("matrix", "movie/tt0133093", "", 0, 0),
    ("inception", "movie/tt1375666", "", 0, 0),
    ("interstellar", "movie/tt0816692", "", 0, 0),
    ("forrestgump", "movie/tt0109830", "", 0, 0),
    ("pulpfiction", "movie/tt0110912", "", 0, 0),
    ("fellowship", "movie/tt0120737", "", 0, 0),
    ("bladerunner", "movie/tt0083658", "", 0, 0),
    ("se7en", "movie/tt0114369", "", 0, 0),
    ("lambs", "movie/tt0102926", "", 0, 0),
    ("bttf", "movie/tt0088763", "", 0, 0),
    ("terminator", "movie/tt0088247", "", 0, 0),
    ("endgame", "movie/tt4154796", "", 0, 0),
    ("amelie", "movie/tt0211915", "", 0, 0),
    ("spiritedaway", "movie/tt0245429", "", 0, 0),
    ("parasite", "movie/tt6751668", "", 0, 0),
    ("apocalypsenow", "movie/tt0078788", "", 0, 0),
    ("aliens", "movie/tt0090605", "", 0, 0),
    ("donniedarko", "movie/tt0246578", "", 0, 0),
    ("avatar", "movie/tt0499549", "", 0, 0),
    ("alien", "movie/tt0078748", "", 0, 0),
    ("watchmen", "movie/tt0409459", "", 0, 0),
    ("kingdomofheaven", "movie/tt0320661", "", 0, 0),
    ("dasboot", "movie/tt0082096", "", 0, 0),
];

/// How many files are taken per title, and how they are chosen.
///
/// English several times over because that is where the releases differ
/// most; every other language twice, so that a language's own habits show
/// up rather than one uploader's; and then the files whose release name
/// says they are half of a two-disc release or a cut of their own, which
/// are the mismatches that have to be built deliberately because nobody
/// uploads them under a separate id.
const PER_LANGUAGE: usize = 2;
const PER_ENGLISH: usize = 4;
const PER_TITLE: usize = 16;
const HALVES_PER_TITLE: usize = 4;
const CUTS_PER_TITLE: usize = 3;

const ADDON: &str = "https://opensubtitles-v3.strem.io/subtitles";

#[derive(Deserialize)]
struct Listing {
    subtitles: Vec<Offered>,
}

#[derive(Deserialize)]
struct Offered {
    id: String,
    url: String,
    lang: String,
    #[serde(rename = "movieReleaseName")]
    release: Option<String>,
    #[serde(rename = "subtitleFileName")]
    file_name: Option<String>,
}

impl Offered {
    fn describes(&self) -> String {
        format!(
            "{} {}",
            self.release.clone().unwrap_or_default(),
            self.file_name.clone().unwrap_or_default()
        )
    }
}

/// Which of the three shapes a file is, read off its release name. A file
/// that says nothing about a disc or a cut is taken to be the whole thing,
/// which is what all but a few dozen of them are.
#[derive(Clone, Copy, PartialEq)]
enum Shape {
    Whole,
    Half(u8),
    Cut,
}

fn shape_of(describes: &str) -> Shape {
    let lower = describes.to_lowercase();
    for (mark, half) in [("cd1", 1u8), ("cd 1", 1), ("cd2", 2), ("cd 2", 2)] {
        if lower.contains(mark) {
            return Shape::Half(half);
        }
    }
    for mark in [
        "extended",
        "director",
        "redux",
        "final cut",
        "final.cut",
        "theatrical",
        "special edition",
        "uncut",
        "ultimate",
        "remaster",
    ] {
        if lower.contains(mark) {
            return Shape::Cut;
        }
    }
    Shape::Whole
}

struct Subtitle {
    recorded: Recorded,
    shape: Shape,
    cues: Vec<Cue>,
}

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Runtime::new().expect("test runtime")
}

/// Where the downloaded files are kept between runs, so a second run of
/// the recorder costs the measurement and not the addon's bandwidth.
fn corpus_dir() -> std::path::PathBuf {
    match std::env::var("XTREMIO_SUBTITLE_CORPUS") {
        Ok(dir) => std::path::PathBuf::from(dir),
        Err(_) => std::env::temp_dir().join("xtremio-subtitle-corpus"),
    }
}

/// Fetches `url` into `path` unless it is already there. Sequential and
/// unhurried, and it backs off when the addon says it is being asked too
/// often: this is one machine taking a few hundred files off a service
/// that gives them away.
async fn fetch(
    client: &reqwest::Client,
    url: &str,
    path: &std::path::Path,
) -> anyhow::Result<bool> {
    if path.exists() && std::fs::metadata(path)?.len() > 0 {
        return Ok(true);
    }
    for attempt in 1..=5u32 {
        let answer = client.get(url).send().await;
        match answer {
            Ok(answer) if answer.status() == reqwest::StatusCode::TOO_MANY_REQUESTS => {
                tokio::time::sleep(std::time::Duration::from_secs(3 * u64::from(attempt))).await;
            }
            Ok(answer) if answer.status().is_success() => {
                let body = answer.bytes().await?;
                // Anything this small is an error page rather than a
                // subtitle, and it would only cost a pairing later.
                if body.len() < 200 {
                    return Ok(false);
                }
                std::fs::create_dir_all(path.parent().expect("a parent"))?;
                std::fs::write(path, &body)?;
                tokio::time::sleep(std::time::Duration::from_millis(600)).await;
                return Ok(true);
            }
            Ok(_) => return Ok(false),
            Err(_) => tokio::time::sleep(std::time::Duration::from_secs(2)).await,
        }
    }
    Ok(false)
}

/// The files this title contributes: the addon's own order, thinned to
/// [`PER_LANGUAGE`] a language and the halves and cuts on top.
fn chosen(offered: &[Offered]) -> Vec<&Offered> {
    let mut taken: Vec<&Offered> = Vec::new();
    let mut per_language: BTreeMap<&str, usize> = BTreeMap::new();
    for file in offered {
        if taken.len() >= PER_TITLE {
            break;
        }
        if shape_of(&file.describes()) != Shape::Whole {
            continue;
        }
        let want = if file.lang == "eng" {
            PER_ENGLISH
        } else {
            PER_LANGUAGE
        };
        let count = per_language.entry(file.lang.as_str()).or_default();
        if *count < want {
            *count += 1;
            taken.push(file);
        }
    }
    let mut halves = 0;
    let mut cuts = 0;
    for file in offered {
        match shape_of(&file.describes()) {
            Shape::Half(_) if halves < HALVES_PER_TITLE => halves += 1,
            Shape::Cut if cuts < CUTS_PER_TITLE => cuts += 1,
            _ => continue,
        }
        taken.push(file);
    }
    taken
}

/// The measurement of one pairing, plus the two numbers that say whether
/// its transform is the right one.
struct Measured {
    population: &'static str,
    verdict: &'static str,
    playing: String,
    reference: String,
    score: f64,
    ratio: f64,
    offset: f64,
    median_error: f64,
    within: f64,
}

/// Median distance from a transformed playing start to the nearest
/// reference start, and the share of them within [`RIGHT_MEDIAN`].
fn start_error(playing: &[Cue], reference: &[Cue], ratio: f64, offset: f64) -> (f64, f64) {
    let mut starts: Vec<f64> = reference.iter().map(|&(start, _)| start).collect();
    starts.sort_by(f64::total_cmp);
    let mut errors: Vec<f64> = playing
        .iter()
        .map(|&(start, _)| {
            let at = ratio * start + offset;
            let index = starts.partition_point(|&other| other < at);
            let after = starts.get(index).map(|&other| other - at);
            let before = index.checked_sub(1).map(|index| at - starts[index]);
            after
                .into_iter()
                .chain(before)
                .fold(f64::INFINITY, f64::min)
        })
        .collect();
    errors.sort_by(f64::total_cmp);
    let within = errors.iter().filter(|&&e| e <= RIGHT_MEDIAN).count() as f64 / errors.len() as f64;
    (errors[errors.len() / 2], within)
}

fn quantile(sorted: &[f64], at: f64) -> f64 {
    sorted[((at * sorted.len() as f64) as usize).min(sorted.len() - 1)]
}

#[test]
#[ignore = "needs internet access to opensubtitles-v3.strem.io, and downloads the corpus"]
fn record_the_calibration() -> anyhow::Result<()> {
    let runtime = runtime();
    let client = reqwest::Client::builder()
        .user_agent("xtremio-subtitle-calibration")
        .build()?;
    let dir = corpus_dir();

    // 1. The corpus: what the addon offers for each title, thinned, and on
    //    disk.
    let mut corpus: BTreeMap<&str, Vec<Subtitle>> = BTreeMap::new();
    for &(key, path, _, _, _) in TITLES {
        let listing = dir.join(key).join("_listing.json");
        if !runtime.block_on(fetch(&client, &format!("{ADDON}/{path}.json"), &listing))? {
            eprintln!("{key}: no listing");
            continue;
        }
        let offered: Listing = serde_json::from_slice(&std::fs::read(&listing)?)?;
        let mut files = Vec::new();
        for file in chosen(&offered.subtitles) {
            let at = dir.join(key).join(format!("{}_{}.srt", file.lang, file.id));
            if !runtime.block_on(fetch(&client, &file.url, &at))? {
                continue;
            }
            // Lossy on purpose: plenty of these files are Latin-1 or
            // cp1250, and the timing lines are ASCII in every one of them.
            let text = String::from_utf8_lossy(&std::fs::read(&at)?).into_owned();
            files.push(Subtitle {
                recorded: Recorded {
                    id: file.id.clone(),
                    title: key.to_owned(),
                    lang: file.lang.clone(),
                    release: file.describes().trim().to_owned(),
                    url: file.url.clone(),
                },
                shape: shape_of(&file.describes()),
                cues: cue_spans(&text),
            });
        }
        eprintln!("{key}: {} files", files.len());
        corpus.insert(key, files);
    }

    // 2. The pairings, each with the verdict its provenance gives it.
    let mut jobs: Vec<(&'static str, &'static str, &Subtitle, &Subtitle)> = Vec::new();
    for &(key, _, _, _, _) in TITLES {
        let Some(files) = corpus.get(key) else {
            continue;
        };
        for (index, playing) in files.iter().enumerate() {
            for reference in &files[index + 1..] {
                let (population, verdict) = match (playing.shape, reference.shape) {
                    (Shape::Whole, Shape::Whole)
                        if playing.recorded.lang == reference.recorded.lang =>
                    {
                        ("the same title, another release", APPLY)
                    }
                    (Shape::Whole, Shape::Whole) => ("the same title, another language", APPLY),
                    (Shape::Half(left), Shape::Half(right)) if left == right => {
                        ("the same half of a two-disc release", APPLY)
                    }
                    (Shape::Half(_), Shape::Half(_)) => ("the other half of the film", UNJUDGED),
                    (Shape::Cut, _) | (_, Shape::Cut) => ("a different cut of the film", UNJUDGED),
                    _ => ("half of a film against the whole", UNJUDGED),
                };
                jobs.push((population, verdict, playing, reference));
                // Both ways round for the mismatches, because which file
                // is the reference is the viewer's choice and the halves
                // are not symmetric in what they cover.
                if verdict == UNJUDGED {
                    jobs.push((population, verdict, reference, playing));
                }
            }
        }
    }
    for (left, right) in every_pair(TITLES) {
        let (Some(here), Some(there)) = (corpus.get(left.0), corpus.get(right.0)) else {
            continue;
        };
        let population = match (left.2 == right.2, left.3 == right.3) {
            (true, _) if left.2.is_empty() => "a different film",
            (true, true) => "a different episode of the season",
            (true, false) => "a different season",
            (false, _) => "a different title",
        };
        // Three references apiece rather than every combination: the
        // mismatches outnumber the pairings that belong together by two
        // orders of magnitude otherwise, and what is wanted from them is
        // the top of their range, not their bulk.
        for (index, playing) in here.iter().enumerate() {
            for reference in there.iter().skip(index % there.len().max(1)).take(3) {
                if playing.shape == Shape::Whole && reference.shape == Shape::Whole {
                    jobs.push((population, REFUSE, playing, reference));
                }
            }
        }
    }

    // 3. The measurement, which is the slow part.
    let pairs = jobs.len();
    let measured = Mutex::new(Vec::new());
    let next = AtomicUsize::new(0);
    let threads = std::thread::available_parallelism()
        .map(|threads| threads.get())
        .unwrap_or(4);
    std::thread::scope(|scope| {
        for _ in 0..threads {
            scope.spawn(|| loop {
                let index = next.fetch_add(1, Ordering::Relaxed);
                let Some(&(population, verdict, playing, reference)) = jobs.get(index) else {
                    break;
                };
                let Some(alignment) = align(&playing.cues, &reference.cues) else {
                    continue;
                };
                let (median_error, within) = start_error(
                    &playing.cues,
                    &reference.cues,
                    alignment.ratio,
                    alignment.offset,
                );
                // **The start errors overrule the listing, in both
                // directions.** A pairing the addon listed under one
                // episode is in the population to apply only if its
                // transform is confirmed, because mislabelled uploads and
                // partial tracks are the rule rather than the exception --
                // and a pairing listed under two *different* titles whose
                // transform is confirmed is not a mismatch at all but the
                // same recording uploaded twice, which this corpus really
                // does contain (Alien³ is on offer under Aliens as well).
                // Counting one of those as a mismatch would set the
                // threshold by how badly the addon is catalogued.
                let confirmed = median_error <= RIGHT_MEDIAN && within >= RIGHT_WITHIN;
                let (population, verdict) = match (verdict, confirmed) {
                    (APPLY, false) => (population, UNJUDGED),
                    (REFUSE, true) => ("listed apart, but the same recording", UNJUDGED),
                    _ => (population, verdict),
                };
                measured.lock().expect("lock").push(Measured {
                    population,
                    verdict,
                    playing: format!("{}/{}", playing.recorded.title, playing.recorded.id),
                    reference: format!("{}/{}", reference.recorded.title, reference.recorded.id),
                    score: alignment.score,
                    ratio: alignment.ratio,
                    offset: alignment.offset,
                    median_error,
                    within,
                });
            });
        }
    });
    let mut measured = measured.into_inner().expect("lock");
    measured.sort_by(|left, right| {
        (
            left.population,
            left.playing.as_str(),
            left.reference.as_str(),
        )
            .cmp(&(
                right.population,
                right.playing.as_str(),
                right.reference.as_str(),
            ))
    });

    // 4. The populations, and the two ends the threshold sits between.
    let mut populations: Vec<Population> = Vec::new();
    let mut names: Vec<(&str, &str)> = measured
        .iter()
        .map(|row| (row.population, row.verdict))
        .collect();
    names.sort_unstable();
    names.dedup();
    for (name, verdict) in names {
        let mut scores: Vec<f64> = measured
            .iter()
            .filter(|row| row.population == name && row.verdict == verdict)
            .map(|row| row.score)
            .collect();
        scores.sort_by(f64::total_cmp);
        populations.push(Population {
            name: name.to_owned(),
            verdict: verdict.to_owned(),
            pairs: scores.len(),
            min: scores[0],
            p05: quantile(&scores, 0.05),
            median: quantile(&scores, 0.5),
            p95: quantile(&scores, 0.95),
            max: scores[scores.len() - 1],
            at_or_above_convincing: scores.iter().filter(|&&s| s >= CONVINCING).count() as f64
                / scores.len() as f64,
        });
    }

    // 5. What the neighbouring thresholds would have cost.
    let share = |verdict: &str, threshold: f64| {
        let of: Vec<&Measured> = measured
            .iter()
            .filter(|row| row.verdict == verdict)
            .collect();
        of.iter().filter(|row| row.score >= threshold).count() as f64 / of.len() as f64
    };
    let costs = [0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60]
        .into_iter()
        .map(|threshold| Cost {
            threshold,
            applied: share(APPLY, threshold),
            wrongly_applied: share(REFUSE, threshold),
        })
        .collect();

    let pairing = |row: &Measured| Pairing {
        population: row.population.to_owned(),
        playing: row.playing.clone(),
        reference: row.reference.clone(),
        score: row.score,
        ratio: row.ratio,
        offset: row.offset,
        median_error: row.median_error,
        within: row.within,
    };
    let mut to_apply: Vec<&Measured> = measured.iter().filter(|row| row.verdict == APPLY).collect();
    to_apply.sort_by(|left, right| left.score.total_cmp(&right.score));
    let mut to_refuse: Vec<&Measured> = measured
        .iter()
        .filter(|row| row.verdict == REFUSE)
        .collect();
    to_refuse.sort_by(|left, right| right.score.total_cmp(&left.score));

    let corpus: Vec<Recorded> = corpus
        .values()
        .flat_map(|files| files.iter().map(|file| file.recorded.clone()))
        .collect();
    let mut languages: Vec<&str> = corpus.iter().map(|file| file.lang.as_str()).collect();
    languages.sort_unstable();
    languages.dedup();

    let calibration = Calibration {
        note: NOTE.to_owned(),
        gathered: Gathered {
            titles: corpus
                .iter()
                .map(|file| file.title.as_str())
                .collect::<std::collections::BTreeSet<_>>()
                .len(),
            files: corpus.len(),
            languages: languages.len(),
            pairs,
            measured: measured.len(),
        },
        populations,
        costs,
        worst_to_apply: to_apply.iter().take(15).map(|&row| pairing(row)).collect(),
        best_to_refuse: to_refuse.iter().take(15).map(|&row| pairing(row)).collect(),
        corpus,
    };
    std::fs::write(fixture_path(), serde_json::to_vec_pretty(&calibration)?)?;
    Ok(())
}

/// Every unordered pair of titles.
fn every_pair<T>(items: &[T]) -> impl Iterator<Item = (&T, &T)> {
    items
        .iter()
        .enumerate()
        .flat_map(|(index, left)| items[index + 1..].iter().map(move |right| (left, right)))
}

const NOTE: &str = "\
What CONVINCING was set against. Every pairing here is two subtitle files \
the OpenSubtitles addon offered, measured by subtitles::align. A pairing is \
in the population to apply when the transform it found puts the median \
playing cue start within 0.35 s of a reference start and at least half of \
them that close -- a statistic the score does not use -- and in the \
population to refuse when the two files are for different titles, \
different episodes or different seasons, where no transform is right. \
Nothing left in the population to refuse meets the start-error rule, so the \
two are disjoint before any score is looked at -- the few pairings listed \
under two different titles that do meet it are one recording catalogued \
twice (Alien3 is on offer under Aliens), and are recorded as such rather \
than counted as mismatches. The populations to apply and \
to refuse OVERLAP in score: the worst pairing that should be applied \
scores below the best pairing that must be refused, so there is no gap to \
sit in the middle of and the threshold is set above the mismatches' range \
instead. The unjudged rows are the pairings this score cannot be asked to \
judge -- half of a two-disc film against the whole (whose transform is \
usually right for the half it covers), a different cut of the same film \
(usually a linear stretch of most of it), and same-title pairings the \
start errors do not confirm, which are mislabelled uploads and partial \
tracks. Re-record with: cargo test --release --test subtitle_threshold -- \
--ignored";
