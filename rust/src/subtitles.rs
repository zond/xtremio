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

#[cfg(test)]
mod tests {
    use super::*;

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
