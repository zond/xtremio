import '../../core/core.dart';

/// A playback's stalls since its open: whether one counts as a stall the
/// server is told about, and the report's log of them.
///
/// **A stall counts once the film has really played since the open or the
/// last seek** ([counts]). Before that, a buffering popup is the window
/// filling after a load or a seek, which the server sizes for itself. Really
/// played is a tick of playback in total, not one advancing report: a scrub
/// back decodes a few frames between rewinds, and if those counted, each
/// next rewind would be reported as a stall.
class StallAccount {
  StallAccount({this.now = DateTime.now});

  /// The clock stalls and opens are timed by.
  final DateTime Function() now;

  /// How much film has to have played since the last seek before a
  /// buffering popup is a stall the server is told about. Two seconds: long
  /// enough that the few frames between two rewinds of a scrub back cannot
  /// reach it, short enough that a viewer who is genuinely watching has
  /// passed it before anything could stall.
  static const Duration playedBeforeAStallCounts = Duration(seconds: 2);

  /// The most a position can move between two reports and still be
  /// playback rather than a seek or a load.
  static const Duration playbackTick = Duration(seconds: 2);

  /// How many stalls are written out one by one before only every tenth is.
  static const int logged = 10;

  DateTime? _openedAt;
  int _stalls = 0;
  DateTime? _stallStart;
  bool _counts = false;
  Duration _played = Duration.zero;

  /// Whether a stall now is one the server is told about.
  bool get counts => _counts;

  /// How long ago the current `open` was issued, or null before one.
  Duration? get sinceOpened {
    final openedAt = _openedAt;
    return openedAt == null ? null : now().difference(openedAt);
  }

  /// A new stream was opened: nothing has played and nothing has stalled.
  void opened() {
    _openedAt = now();
    _stalls = 0;
    _counts = false;
    _played = Duration.zero;
  }

  /// A seek, or a re-open: what follows is a window filling.
  void seeked() {
    _counts = false;
    _played = Duration.zero;
  }

  /// The position moved by [advanced] between two reports. A step back, or
  /// forward by more than [playbackTick], is a seek whoever asked for it:
  /// the remote's rewind and fast-forward keys reach mpv without the
  /// player's own seek.
  void moved(Duration advanced) {
    if (advanced > Duration.zero && advanced < playbackTick) {
      _played += advanced;
      if (_played >= playedBeforeAStallCounts) _counts = true;
    } else {
      seeked();
    }
  }

  /// mpv began or ended a stall at [at]. Puts it in the report: the shape of
  /// a playback that keeps stopping, which is invisible in the Rust half of
  /// the log.
  ///
  /// Bounded rather than complete: a playback that stalls every few seconds
  /// for an hour would otherwise be the only thing left in a 400-line ring.
  /// The first [logged] of them are written one by one, and after that every
  /// tenth, so the pattern still shows and the rest of the session survives.
  void buffering(bool buffering, {required Duration at}) {
    if (buffering) {
      _stalls++;
      _stallStart = now();
      if (_written) {
        DiagnosticsLog.warn(
          'player',
          'stalled at ${at.inSeconds}s (stall $_stalls)',
        );
      }
      return;
    }
    final started = _stallStart;
    _stallStart = null;
    if (started == null) return;
    if (_written) {
      DiagnosticsLog.info(
        'player',
        'playing again after ${now().difference(started).inMilliseconds}ms',
      );
    }
  }

  bool get _written => _stalls <= logged || _stalls % 10 == 0;
}
