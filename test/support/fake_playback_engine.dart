import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:xtremio/features/player/playback_engine.dart';

/// [PlaybackEngine] for widget tests: records `open` calls and lets the test
/// feed position/playing/completed events. No libmpv.
class FakePlaybackEngine implements PlaybackEngine {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _errors = StreamController<String>.broadcast();

  /// Every `open` call: the URL and the requested start position.
  final List<(Uri, Duration)> opened = [];
  final List<Duration> seeks = [];
  bool disposed = false;

  void emitPosition(Duration position) => _position.add(position);
  void emitDuration(Duration duration) => _duration.add(duration);
  void emitPlaying(bool playing) => _playing.add(playing);
  void emitBuffering(bool buffering) => _buffering.add(buffering);
  void emitCompleted() => _completed.add(true);
  void emitError(String error) => _errors.add(error);

  @override
  Stream<Duration> get position => _position.stream;

  @override
  Stream<Duration> get duration => _duration.stream;

  @override
  Stream<bool> get playing => _playing.stream;

  @override
  Stream<bool> get buffering => _buffering.stream;

  @override
  Stream<bool> get completed => _completed.stream;

  @override
  Stream<String> get errors => _errors.stream;

  @override
  Future<void> open(Uri url, {Duration start = Duration.zero}) async {
    opened.add((url, start));
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
  }

  @override
  Future<void> playOrPause() async {}

  @override
  Widget buildVideo(BuildContext context) => const ColoredBox(
    color: Color(0xFF000000),
    child: Center(child: Text('video surface')),
  );

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
