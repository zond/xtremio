import '../../core/core.dart';

/// What the core is told about a playback's time, and when: the position
/// as it moves, a seek, the last word on the way out, and whether it plays.
///
/// The core keeps continue-watching from these. Shared by the local engine
/// and the receiver of a cast, so it is kept the same way either way.
class CoreTimeReporter {
  CoreTimeReporter({
    required this.dispatch,
    required this.device,
    required this.interval,
  });

  /// Sends one action to the core.
  final void Function(CoreAction action) dispatch;

  /// The device the core is told the playback is on.
  final String device;

  /// The least time between two reports of a position that only moved on.
  final Duration interval;

  bool _hasStream = false;
  Duration? _lastReported;
  Duration? _coreTime;
  bool _reported = false;
  bool? _lastPlaying;

  /// A stream is open, and the core holds [offset] as its time: the
  /// library's own, which is where continue-watching resumes. Nothing has
  /// been reported for it yet.
  void newStream(Duration offset) {
    _hasStream = true;
    _coreTime = offset;
    _reported = false;
  }

  /// Tells the core where playback has got to, no more often than
  /// [interval]. Nothing is told before the length is known.
  ///
  /// **A position behind the one the core holds is said as a `Seek`.**
  /// stremio-core takes a `TimeChanged` only when it is later than the offset
  /// it has (`models/player.rs`: a seek back is the app's to say). Some seeks
  /// back reach it only as positions: one made before the duration was known,
  /// which no `Seek` can carry, or the remote's rewind key, which reaches mpv
  /// without a seek of the player's. Those left continue-watching on the old
  /// timeline.
  void time(Duration position, Duration duration) {
    if (!_hasStream || duration == Duration.zero) return;
    final last = _lastReported;
    if (last != null && (position - last).abs() < interval) return;
    _lastReported = position;
    final core = _coreTime;
    _coreTime = position;
    _reported = true;
    dispatch(
      core != null && position < core
          ? CoreActions.playerSeek(
              time: position.inMilliseconds,
              duration: duration.inMilliseconds,
              device: device,
            )
          : CoreActions.playerTimeChanged(
              time: position.inMilliseconds,
              duration: duration.inMilliseconds,
              device: device,
            ),
    );
  }

  /// The viewer seeked to [to]. The core hears it as a `Seek` once the
  /// length is known. Either way the next position goes through whatever
  /// the throttle says: the core only moves time forward on `TimeChanged`,
  /// and relies on `Seek` and `TimeChanged` agreeing.
  void seek(Duration to, Duration duration) {
    if (_hasStream && duration > Duration.zero) {
      _coreTime = to;
      _reported = true;
      dispatch(
        CoreActions.playerSeek(
          time: to.inMilliseconds,
          duration: duration.inMilliseconds,
          device: device,
        ),
      );
    }
    _lastReported = null;
  }

  /// Tells the core the position now, throttle or not: the last report
  /// before the screen lets go.
  ///
  /// **A video left before it started is reported too, at its start.** Until
  /// the length is known nothing is reported ([time]), and the core moves
  /// its library item to another episode only on a report. Without this, a
  /// next episode left while its first bytes downloaded kept
  /// continue-watching on the episode before it. A length of zero is the
  /// core's "not known": it updates neither the length nor the watched mark.
  void flush(Duration position, Duration duration) {
    _lastReported = null;
    if (_hasStream && !_reported && duration == Duration.zero) {
      _reported = true;
      dispatch(
        CoreActions.playerTimeChanged(time: 0, duration: 0, device: device),
      );
      return;
    }
    time(position, duration);
  }

  /// Tells the core whether playback runs, once per change.
  void playing(bool playing) {
    if (!_hasStream || playing == _lastPlaying) return;
    _lastPlaying = playing;
    dispatch(CoreActions.playerPausedChanged(!playing));
  }
}
