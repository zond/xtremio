import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/core.dart';
import 'playback_stats.dart';

/// Watches a playback for the waits mpv does not report.
///
/// mpv's own flag says its demuxer cache ran dry during playback. It does not
/// cover a read blocked in the server while mpv seeks: one session played
/// nothing for three and a half minutes with no stall reported. Two things
/// here cover that:
///
/// * **A position that stands still** while the player says it is playing
///   ([positionStuck]), counted in ticks of [stuckInterval]. It cannot be
///   fooled, and it is a guess.
/// * **A read the server knows is parked** ([readStalled]): mpv's reader of
///   the playing media id has been blocked for [readWaitShown] and the
///   picture has not moved since the last ask. This is the truth the first
///   guessed at. Asked every [readWaitInterval].
///
/// It notifies when either changes.
class PlaybackWatchdog extends ChangeNotifier {
  PlaybackWatchdog({
    required this.stuckInterval,
    required this.stuckAfter,
    required this.stuckTwitch,
    required this.readWaitInterval,
    required this.readWaitShown,
    required this.position,
    required this.shouldMove,
    required this.playingLoaded,
    required this.readWaitId,
    required this.playingId,
    required this.askReadWait,
    required this.stats,
  });

  final Duration stuckInterval;

  /// How long a position may stand still before it counts.
  final Duration stuckAfter;

  /// The least a position must move to be film rather than a frame or two
  /// behind a picture that is standing still.
  final Duration stuckTwitch;

  final Duration readWaitInterval;

  /// How long a read must have waited before the viewer is waiting on it.
  final Duration readWaitShown;

  /// Where playback is now.
  final Duration Function() position;

  /// Whether the position should be moving now: playing, not in mpv's own
  /// stall, and on this screen rather than on a receiver.
  final bool Function() shouldMove;

  /// Whether the media is in and the player says it plays.
  final bool Function() playingLoaded;

  /// The media id whose reads the server can be asked about now, or null
  /// when nobody may be asked.
  final String? Function() readWaitId;

  /// The media id playing. An answer about any other is dropped.
  final String? Function() playingId;

  /// Asks the server about the reads of a media id.
  final Future<ReadWait> Function(String id) askReadWait;

  /// mpv's stats, for the one sample a standing position is logged with.
  final Stream<PlaybackStats>? Function() stats;

  Timer? _stuckTimer;
  Timer? _readWaitTimer;
  int _stillTicks = 0;
  Duration _stillFrom = Duration.zero;
  bool _positionSeen = false;
  bool _positionStuck = false;
  bool _readStalled = false;
  bool _readWaitFetching = false;
  Duration? _readWaitFrom;
  StreamSubscription<PlaybackStats>? _sample;
  bool _stopped = false;

  /// The position has stood still while the player said it played.
  bool get positionStuck => _positionStuck;

  /// The server says a read has waited while the picture stood still.
  bool get readStalled => _readStalled;

  /// Starts watching the media just loaded, from nothing.
  ///
  /// A position cannot have *stopped* moving before it has moved, so the
  /// count waits for the first report ([sawPosition]). That also keeps a
  /// backend that reports no positions at all, which is every fake, from
  /// looking stuck for ever.
  void start() {
    if (_stopped) return;
    _readWaitTimer?.cancel();
    _readWaitFrom = null;
    _readWaitTimer = Timer.periodic(readWaitInterval, (_) => _pollReadWait());
    _stuckTimer?.cancel();
    _stillTicks = 0;
    _stillFrom = Duration.zero;
    _positionSeen = false;
    _stuckTimer = Timer.periodic(stuckInterval, (_) => _checkStuck());
  }

  /// The player reported a position, moved or not.
  void sawPosition() => _positionSeen = true;

  /// The player reported [position], a different one from the last. Far
  /// enough from where the count began, it is film moving, and neither wait
  /// holds any more.
  void positionMoved(Duration position) {
    if ((position - _stillFrom).abs() < stuckTwitch) return;
    _stillTicks = 0;
    _stillFrom = position;
    var changed = false;
    if (_readStalled) {
      DiagnosticsLog.info(
        'player',
        'playing again at ${position.inSeconds}s, after a read waited',
      );
      // The next ask measures again from here.
      _readWaitFrom = position;
      _readStalled = false;
      changed = true;
    }
    if (_positionStuck) {
      DiagnosticsLog.info(
        'player',
        'playing again at ${position.inSeconds}s, after the position '
            'stood still with mpv reporting no stall',
      );
      _positionStuck = false;
      _sample?.cancel();
      _sample = null;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void _checkStuck() {
    // Paused is not waiting, mpv's own flag is already drawn, and while a
    // receiver has the stream the local position is not the viewer's.
    if (!_positionSeen || !shouldMove()) {
      _stillTicks = 0;
      _stillFrom = position();
      return;
    }
    if (_positionStuck) return;
    _stillTicks++;
    final still = stuckInterval * _stillTicks;
    if (still < stuckAfter) return;
    DiagnosticsLog.warn(
      'player',
      'the position has not moved for '
          '${still.inSeconds}s at '
          '${position().inSeconds}s, and mpv reports no stall',
    );
    _positionStuck = true;
    notifyListeners();
    _logWhatMpvIsDoing();
  }

  /// Logs what mpv is doing with the film, once, when the position has
  /// stood still: a frozen picture is either a decoder that cannot keep up
  /// or a read that never arrived, and one [PlaybackStats] sample (decoder,
  /// codec and size, dropped frames, demuxer cache) tells them apart.
  ///
  /// Silent on a player that will not answer: a diagnostic must not hold up
  /// anything.
  void _logWhatMpvIsDoing() {
    final source = stats();
    if (source == null) return;
    _sample?.cancel();
    _sample = source.listen(_logStats);
  }

  void _logStats(PlaybackStats stats) {
    _sample?.cancel();
    _sample = null;
    if (_stopped || !_positionStuck) return;
    String? size() => stats.width == null || stats.height == null
        ? null
        : '${stats.width}x${stats.height}';
    DiagnosticsLog.info(
      'player',
      'what mpv is doing with it: '
          'hwdec=${stats.hwdec ?? '?'} '
          'video=${stats.videoCodec ?? '?'} ${size() ?? '?'} '
          'audio=${stats.audioCodec ?? '?'} '
          'fps=${stats.outputFps ?? '?'}/${stats.containerFps ?? '?'} '
          'dropped=${stats.droppedFrames ?? '?'}'
          '/${stats.decoderDroppedFrames ?? '?'} '
          'cache=${stats.cacheDuration?.inMilliseconds ?? '?'}ms '
          'paused_for_cache=${stats.pausedForCache ?? '?'}',
    );
  }

  /// One ask of the server about the reads of the media id playing.
  ///
  /// The card goes up when a read has waited [readWaitShown] while the picture
  /// stood still since the last ask. It comes down at the first ask that finds
  /// reads flowing, whatever the read is: the file's head, its index, the
  /// resume point. No give-up: a read that waits for ever keeps the card up
  /// for ever, and the viewer decides.
  Future<void> _pollReadWait() async {
    final id = readWaitId();
    if (_stopped || id == null || _readWaitFetching) return;
    final at = position();
    _readWaitFetching = true;
    ReadWait wait;
    try {
      wait = await askReadWait(id);
    } on Object {
      wait = ReadWait.none;
    } finally {
      _readWaitFetching = false;
    }
    if (_stopped || playingId() != id) return;
    final from = _readWaitFrom;
    _readWaitFrom = at;
    final still = from != null && (at - from).abs() < stuckTwitch;
    final stalled =
        playingLoaded() && still && wait.waitedAtLeast(readWaitShown);
    if (stalled == _readStalled) return;
    if (stalled) {
      DiagnosticsLog.warn(
        'player',
        'a read has waited ${wait.waiting?.inMilliseconds}ms at byte '
            '${wait.offset} with the picture still at '
            '${at.inSeconds}s; buffering from the torrent',
      );
    } else {
      DiagnosticsLog.info(
        'player',
        'reads are flowing again at ${at.inSeconds}s',
      );
    }
    _readStalled = stalled;
    notifyListeners();
  }

  /// Nothing is watched from here on.
  void stop() {
    _stopped = true;
    _stuckTimer?.cancel();
    _stuckTimer = null;
    _readWaitTimer?.cancel();
    _readWaitTimer = null;
    _sample?.cancel();
    _sample = null;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
