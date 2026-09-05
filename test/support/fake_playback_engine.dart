import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:xtremio/features/player/playback_engine.dart';

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
  bool disposed = false;

  /// When set, `open` also appends `'open'` here: a log shared with other
  /// fakes, for tests about the order of calls across them.
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
  Future<void> open(Uri url, {Duration start = Duration.zero}) async {
    opened.add((url, start));
    callLog?.add('open');
    if (openError != null) throw openError!;
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
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

  @override
  Future<void> setSubtitleStyle(SubtitleStyle style) async {
    subtitleStyle = style;
  }

  @override
  Widget buildVideo(BuildContext context, {double subtitleBottomPadding = 24}) {
    lastSubtitleBottomPadding = subtitleBottomPadding;
    return const ColoredBox(
      color: Color(0xFF000000),
      child: Center(child: Text('video surface')),
    );
  }

  @override
  Future<void> dispose() async {
    disposed = true;
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
