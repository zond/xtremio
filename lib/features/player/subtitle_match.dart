import '../../src/rust/api/subtitles.dart' as rust;

export '../../src/rust/api/subtitles.dart' show SubtitleMatch;

/// Measures the playing subtitle against another file the viewer says is
/// in sync, and answers the ratio and offset that map one onto the other.
///
/// An interface so the player's widget tests can answer with a fixed
/// measurement instead of reaching FFI, the way [TorrentStatsClient]
/// works for the start-up card.
///
/// [TorrentStatsClient]: torrent_stats.dart
abstract interface class SubtitleMatchClient {
  /// Fetches both files, reads when each of them has text on screen and
  /// solves for the line between them. Throws only when a file cannot be
  /// read; two files that do not describe the same recording come back as
  /// a measurement with `convincing: false` and the score and transform
  /// that say so.
  Future<rust.SubtitleMatch> match({
    required Uri playing,
    required Uri reference,
  });
}

/// [SubtitleMatchClient] over FFI. Two HTTP fetches and a sweep over two
/// arrays, all of it in Rust: it must not run on the UI thread of a
/// device as modest as a Chromecast with Google TV.
class RustSubtitleMatchClient implements SubtitleMatchClient {
  const RustSubtitleMatchClient();

  @override
  Future<rust.SubtitleMatch> match({
    required Uri playing,
    required Uri reference,
  }) => rust.subtitlesMatch(
    playingUrl: playing.toString(),
    referenceUrl: reference.toString(),
  );
}

/// What the panel says about [match], which is the score either way.
///
/// **The score and not a count of cues.** "Only 303 of 690 cues matched"
/// is what the measurement this replaced said about the owner's own
/// Swedish file against an English one, and the pairing was fine: a
/// translation that merges two lines into one has half the cues and the
/// same subtitle, so a count of cues is not comparable between two files
/// and never was evidence the viewer could judge. What is comparable is
/// how much more of the time the two files have text on screen together
/// than two files this talkative would manage by accident, which is what
/// the number in these sentences is.
///
/// **A refusal says what was found, not merely that it was not enough.**
/// The transform is in the sentence because it is the other half of the
/// judgement: a reference that wants a plausible speed and a small shift
/// and still scores badly is a file that disagrees, where one that wants
/// to be stretched a tenth and pushed four minutes is the wrong episode.
/// Told only a fraction, the owner went looking for a different reference
/// when the reference was fine.
///
/// **Nothing to measure is a different answer, and names the reference.**
/// No score at all means one of the two files had too few cues to be
/// evidence -- an ASS file, an addon answering with an error page, a
/// forced track of a dozen signs -- rather than two files that disagree.
/// Saying "only 0 %" there describes the file the viewer is trying to fix
/// and hides the one they chose badly, so both counts are what that
/// sentence is about. They are measured for exactly this.
///
/// No line names a file: the panel is drawn over the picture the viewer is
/// watching, and the two files involved are the one playing and the one
/// they just picked.
String subtitleMatchNote(rust.SubtitleMatch match) {
  final score = match.score;
  if (score == null) {
    return 'Nothing to measure: ${match.cues} cue timings in this file, '
        '${match.referenceCues} in the one you picked';
  }
  // Clamped, because a pair that does *worse* than chance and one that
  // merely does no better are the same answer to a viewer, and a negative
  // percentage invites a reading of it that is not there.
  final above = (score.clamp(0.0, 1.0) * 100).round();
  if (match.convincing) {
    return 'Matched: $above % more overlap than chance';
  }
  // The same shapes the panel's own rows use for these two numbers, since
  // this sentence sits directly above them.
  final speed = match.ratio.toStringAsFixed(3);
  final shift = match.offset.toStringAsFixed(1);
  return 'Only $above % more overlap than chance, at '
      '$speed× and ${match.offset > 0 ? '+' : ''}$shift s, '
      'so nothing was changed';
}

/// What it says when a file could not be read at all.
///
/// One sentence for every such failure -- a fetch that timed out, a 404,
/// something that was not a subtitle file -- because the reason lives in
/// a URL and an addon's subtitle URL can carry a debrid API key, which
/// this repository never writes down or puts on a screen.
const String subtitleMatchFailureNote = 'Could not read both subtitle files';

/// What it says while the measurement is running.
const String subtitleMatchingNote = 'Matching…';
