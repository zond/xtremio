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
  /// Fetches both files, reads their cue start times and solves for the
  /// line between them. Throws only when a file cannot be read; two files
  /// that do not describe the same recording come back as a measurement
  /// with `convincing: false` and the counts that say so.
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

/// What the panel says about [match], which is the count either way.
///
/// The number is the evidence, so it is shown whichever way the answer
/// went: "matched 613 of 694" is what makes a match believable, and
/// "only 184 of 694" is what makes the refusal something the viewer can
/// judge rather than an apology. Neither line names a file -- the panel
/// is drawn over the picture the viewer is watching, and the two files
/// involved are the one playing and the one they just picked.
String subtitleMatchNote(rust.SubtitleMatch match) => match.convincing
    ? 'Matched ${match.matched} of ${match.cues} cues'
    : 'Only ${match.matched} of ${match.cues} cues matched, '
          'so nothing was changed';

/// What it says when a file could not be read at all.
///
/// One sentence for every such failure -- a fetch that timed out, a 404,
/// something that was not a subtitle file -- because the reason lives in
/// a URL and an addon's subtitle URL can carry a debrid API key, which
/// this repository never writes down or puts on a screen.
const String subtitleMatchFailureNote = 'Could not read both subtitle files';

/// What it says while the measurement is running.
const String subtitleMatchingNote = 'Matching…';
