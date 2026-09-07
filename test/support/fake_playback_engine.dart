import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/shell/display_frame_rate.dart';

/// [PlaybackEngine] for widget tests: records every call and lets the test
/// feed position/playing/tracks/... events. No libmpv.
class FakePlaybackEngine implements PlaybackEngine {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _buffer = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _engineLog = StreamController<String>.broadcast();
  final _volume = StreamController<double>.broadcast();
  final _tracks = StreamController<PlaybackTracks>.broadcast();
  final _videoFrameRate = StreamController<double>.broadcast();
  late final _stats = StreamController<PlaybackStats>.broadcast(
    onListen: () => statsListeners++,
    onCancel: () => statsListeners--,
  );

  /// Live subscribers to [stats]; > 0 means the screen is sampling.
  int statsListeners = 0;
  bool get sampling => statsListeners > 0;

  /// Every `open` call: the URL and the requested start position.
  final List<(Uri, Duration)> opened = [];
  final List<Duration> seeks = [];

  /// Every `scanBy` call, in order: the step a scan asked mpv for, which
  /// is a different question from a [seeks] entry and so a different
  /// list. A test that wants "where did the viewer end up" reads the
  /// position; one that wants "was this a scan or an exact seek" reads
  /// which list grew.
  final List<Duration> scans = [];
  int playCalls = 0;
  int pauseCalls = 0;
  int playOrPauseCalls = 0;
  final List<double> volumes = [];
  final List<double> rates = [];
  final List<String> setAudioTrackIds = [];
  final List<String> setSubtitleTrackIds = [];

  /// Every `setExternalSubtitle` call: URL, title, language.
  final List<(Uri, String?, String?)> externalSubtitles = [];
  int disableSubtitlesCalls = 0;

  /// Every `setSubtitleSpeed` call, in order -- what a test reads to see
  /// which way the viewer's press stretched the file and that the next
  /// pick put the multiplier back.
  final List<double> subtitleSpeeds = [];

  /// The multiplier in force, which is the last one set.
  double get subtitleSpeed => subtitleSpeeds.isEmpty ? 1 : subtitleSpeeds.last;

  /// Every `setSubtitleDelay` call, in order -- what a test reads to see
  /// which way a shift moved the lines and that the next pick put the
  /// offset back.
  final List<double> subtitleDelays = [];

  /// The offset in force, which is the last one set.
  double get subtitleDelay => subtitleDelays.isEmpty ? 0 : subtitleDelays.last;

  /// When set, `open` records the call and then fails with it (mpv refusing
  /// the URL).
  Object? openError;

  /// Holds every `open` open until it completes: an `open` is a
  /// `loadfile` and a first read from the server, so the answer takes as
  /// long as the stream takes to start -- long enough for the viewer to
  /// give up and leave, which is what the continuation after it has to
  /// reckon with.
  Future<void>? openPending;

  /// The same for the `sub-start` read: a property read is quick, but it
  /// is still an `await`, and a test about what resumes during a teardown
  /// needs to choose when it resumes.
  Future<void>? cueStartPending;

  /// When set, `setSubtitleTrack` and `setExternalSubtitle` record the call
  /// and then fail with it (mpv refusing the track).
  Object? subtitleError;

  /// Holds the *next* subtitle call open until it is completed, then
  /// clears itself: mpv's `sub-add` fetches the URL under its own
  /// `network-timeout`, so an answer can be minutes late and the viewer
  /// can have done several things by the time it lands. Whichever
  /// [subtitleError] was set when the call was made is the one it fails
  /// with, so a later call can succeed while this one is still out.
  Completer<void>? subtitleGate;

  SubtitleStyle? subtitleStyle;
  double? lastSubtitleBottomPadding;

  /// Whether `dispose` has been *asked for*, which is a different question
  /// from [disposed]: the teardown a screen starts on its way out and the
  /// teardown finishing are two moments, and the whole of what a player
  /// left behind costs happens between them.
  bool disposeAsked = false;

  /// Whether `dispose` has *finished*. A real teardown stops libmpv before
  /// it releases the player, so until this is true the demuxer is still
  /// open: still filling its packet buffer, and still reading from the
  /// server.
  bool disposed = false;

  /// Holds the teardown open until the test completes it -- what
  /// `Player.stop()` does when mpv is blocked writing to a volume with no
  /// room left, which is exactly when it matters that the player die.
  /// Nothing completes it by itself, so a test that never does is asking
  /// "what happens when the teardown does not come back".
  Completer<void>? disposeGate;

  /// When set, `dispose` records the call and then fails with it.
  Object? disposeError;

  /// Every `setDisplayRefreshRate` call, in order, nulls included -- a
  /// null is the player giving display sync back, which is as much a call
  /// as setting one is.
  final List<double?> displayRefreshRates = [];

  /// When set, the calls a test may need to see in order are appended here
  /// -- `'open'`, `'quit'`, `'dispose'`: a log shared with other fakes,
  /// for tests about the order of calls across them.
  List<String>? callLog;

  void emitPosition(Duration position) => _position.add(position);
  void emitDuration(Duration duration) => _duration.add(duration);
  void emitBuffer(Duration buffer) => _buffer.add(buffer);
  void emitPlaying(bool playing) => _playing.add(playing);
  void emitBuffering(bool buffering) => _buffering.add(buffering);
  void emitCompleted() => _completed.add(true);

  /// The media reaching its end the way a real one does: the duration, the
  /// position at it, then playback stopping, then `completed`.
  ///
  /// The screen believes an ending only when the position agrees with one
  /// (`PlayerScreen._endLooksReal`): libmpv reports a read that stopped
  /// making progress as an end of file too, and that one is a stall.
  ///
  /// Playback stops first, and it stops on its own. mpv runs with
  /// `keep-open=yes`, so the end of a file is `eof-reached`, and media_kit
  /// answers that one property with `playing: false` and `completed: true`
  /// in that order, out of the same branch (`player/native/player/real.dart`).
  /// An end with the player still reporting itself as playing is a state no
  /// device produces, and a screen must not be reasoned about from it.
  void emitEnd({Duration duration = const Duration(minutes: 96)}) {
    emitDuration(duration);
    emitPosition(duration);
    emitPlaying(false);
    emitCompleted();
  }

  void emitError(String error) => _errors.add(error);

  /// One of mpv's own error-level log lines.
  void emitEngineLog(String line) => _engineLog.add(line);
  void emitVolume(double volume) => _volume.add(volume);
  void emitTracks(PlaybackTracks tracks) => _tracks.add(tracks);
  void emitStats(PlaybackStats stats) => _stats.add(stats);

  /// The rate the open container declares, as libmpv's `container-fps`
  /// observation reports it once the file is loaded.
  void emitVideoFrameRate(double fps) => _videoFrameRate.add(fps);

  @override
  Stream<Duration> get position => _position.stream;

  @override
  Stream<Duration> get duration => _duration.stream;

  @override
  Stream<Duration> get buffer => _buffer.stream;

  @override
  Stream<bool> get playing => _playing.stream;

  @override
  Stream<bool> get buffering => _buffering.stream;

  @override
  Stream<bool> get completed => _completed.stream;

  @override
  Stream<String> get errors => _errors.stream;

  @override
  Stream<String> get engineLog => _engineLog.stream;

  @override
  Stream<double> get volume => _volume.stream;

  @override
  Stream<PlaybackTracks> get tracks => _tracks.stream;

  @override
  Stream<PlaybackStats> get stats => _stats.stream;

  @override
  Stream<double> get videoFrameRate => _videoFrameRate.stream;

  @override
  Future<void> open(Uri url, {Duration start = Duration.zero}) async {
    opened.add((url, start));
    callLog?.add('open');
    if (openPending != null) await openPending;
    if (openError != null) throw openError!;
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
  }

  @override
  Future<void> scanBy(Duration delta) async {
    scans.add(delta);
  }

  @override
  Future<void> play() async {
    playCalls++;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  Future<void> playOrPause() async {
    playOrPauseCalls++;
  }

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
  }

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
  }

  @override
  Future<void> setAudioTrack(String id) async {
    setAudioTrackIds.add(id);
  }

  /// The gate the current call has to wait on, taken so that only the one
  /// call it was set for is held.
  Future<void>? _takeGate() {
    final gate = subtitleGate;
    subtitleGate = null;
    return gate?.future;
  }

  @override
  Future<void> setSubtitleTrack(String id) async {
    setSubtitleTrackIds.add(id);
    final error = subtitleError;
    await _takeGate();
    if (error != null) throw error;
  }

  @override
  Future<void> setExternalSubtitle(
    Uri url, {
    String? title,
    String? language,
  }) async {
    externalSubtitles.add((url, title, language));
    final error = subtitleError;
    await _takeGate();
    if (error != null) throw error;
  }

  @override
  Future<void> disableSubtitles() async {
    disableSubtitlesCalls++;
  }

  @override
  Future<void> setSubtitleSpeed(double speed) async {
    subtitleSpeeds.add(speed);
  }

  @override
  Future<void> setSubtitleDelay(double seconds) async {
    subtitleDelays.add(seconds);
  }

  /// What `subtitleCueStart` answers: the raw start of the cue a test
  /// says is on screen, and null for a moment with no subtitle on it.
  ///
  /// The file's own timeline, as libmpv's `sub-start` reports it, so a
  /// test sets the time written in the file and never the one the
  /// transform in force would draw it at.
  double? cueStart;

  /// How many times it has been asked.
  int cueStartReads = 0;

  @override
  Future<double?> subtitleCueStart() async {
    cueStartReads++;
    if (cueStartPending != null) await cueStartPending;
    return cueStart;
  }

  @override
  Future<void> setDisplayRefreshRate(double? hz) async =>
      displayRefreshRates.add(hz);

  @override
  Future<void> setSubtitleStyle(SubtitleStyle style) async {
    subtitleStyle = style;
  }

  /// How many times the screen has asked for the video surface. What it
  /// answers is whether the tree is still being rebuilt around a sink that
  /// is still attached -- which is a different question from whether the
  /// widget merely still exists.
  int videoBuilds = 0;

  @override
  Widget buildVideo(BuildContext context, {double subtitleBottomPadding = 24}) {
    videoBuilds++;
    lastSubtitleBottomPadding = subtitleBottomPadding;
    return const ColoredBox(
      color: Color(0xFF000000),
      child: Center(child: Text('video surface')),
    );
  }

  /// A real teardown stops the player before it releases it, and a stop
  /// *announces itself*: media_kit's own `stop` defaults to
  /// `notify: true`, and once its commands have come back it pushes
  /// `playing: false`, `completed: false`, `position: Duration.zero` and
  /// `duration: Duration.zero` down the very streams a screen has been
  /// listening to all session, in that order
  /// (`player/native/player/real.dart`).
  ///
  /// None of those is a fact about the playback -- they are the player
  /// being emptied -- and the zero *position* arrives while the duration
  /// is still the film's, which is exactly the shape a screen forwards to
  /// the core as "the viewer is at the start of this".
  ///
  /// So the fake emits them, in mpv's order and at mpv's moment: after
  /// [disposeGate], because the gate stands in for the stop commands that
  /// a wedged core never answers, and the announcement is what the stop
  /// makes on its way back. A fake that went quiet on the way out would
  /// leave nothing for a test to catch this with.
  @override
  Future<void> dispose() async {
    disposeAsked = true;
    callLog?.add('dispose');
    await disposeGate?.future;
    if (disposeError != null) throw disposeError!;
    emitPlaying(false);
    _completed.add(false);
    emitPosition(Duration.zero);
    emitDuration(Duration.zero);
    disposed = true;
  }

  /// How many times the player was sent the kill. Real mpv is sent `quit`
  /// on its own handle and the demuxer goes with it, so this is what "the
  /// read ended and the socket came back" looks like from a test.
  ///
  /// Deliberately not the same question as [disposeAsked]: the quit goes
  /// out first and the teardown behind it may take as long as it likes, so
  /// which of the two a test is asking about matters.
  int quitCalls = 0;

  /// What [quit] throws instead of answering, which is what a real engine
  /// does when libmpv refuses the command: nothing was ever enqueued and
  /// the player is still running.
  Object? quitError;

  @override
  Future<void> quit() async {
    quitCalls++;
    callLog?.add('quit');
    if (quitError != null) throw quitError!;
  }
}

/// Records fullscreen transitions instead of touching the window.
class FakeFullscreenController implements FullscreenController {
  int enters = 0;
  int exits = 0;

  @override
  Future<void> enter() async {
    enters++;
  }

  @override
  Future<void> exit() async {
    exits++;
  }
}

/// Records what the display was asked to present at instead of speaking to
/// the platform channel, and lets a test say what the display then did.
class FakeDisplayFrameRate implements DisplayFrameRate {
  final _refreshRate = StreamController<double>.broadcast();

  /// Every rate asked for, in order.
  final List<double> requested = [];

  /// How many times the rate was given back.
  int clears = 0;

  @override
  Future<void> request(double fps) async => requested.add(fps);

  @override
  Future<void> clear() async => clears++;

  @override
  Stream<double> get refreshRate => _refreshRate.stream;

  /// The display reporting what it settled on -- which is not necessarily
  /// what [request] asked for, and is the point of the two being separate.
  void reportRefreshRate(double hz) => _refreshRate.add(hz);

  Future<void> dispose() => _refreshRate.close();
}
