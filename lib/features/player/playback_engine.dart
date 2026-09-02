import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// What the player screen needs from a video backend. `media_kit` is the
/// real one; tests substitute a fake through [PlaybackScope] so the screen's
/// core wiring can be exercised without libmpv.
abstract interface class PlaybackEngine {
  Stream<Duration> get position;
  Stream<Duration> get duration;
  Stream<bool> get playing;
  Stream<bool> get buffering;

  /// Fires once when the media reaches its end.
  Stream<bool> get completed;
  Stream<String> get errors;

  /// Opens [url] and starts playing from [start].
  Future<void> open(Uri url, {Duration start = Duration.zero});

  Future<void> seek(Duration position);
  Future<void> playOrPause();

  /// The video surface (with controls).
  Widget buildVideo(BuildContext context);

  Future<void> dispose();
}

typedef PlaybackEngineFactory = PlaybackEngine Function();

/// Supplies the [PlaybackEngineFactory] the player screen uses. Absent, the
/// screen builds a [MediaKitEngine].
class PlaybackScope extends InheritedWidget {
  const PlaybackScope({
    super.key,
    required this.createEngine,
    required super.child,
  });

  final PlaybackEngineFactory createEngine;

  static PlaybackEngineFactory of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<PlaybackScope>()
          ?.createEngine ??
      MediaKitEngine.new;

  @override
  bool updateShouldNotify(PlaybackScope oldWidget) =>
      createEngine != oldWidget.createEngine;
}

/// [PlaybackEngine] over `media_kit` (libmpv). Direct play only: whatever
/// the URL serves is decoded on this device; the server never transcodes.
class MediaKitEngine implements PlaybackEngine {
  MediaKitEngine() : _player = Player() {
    _controller = VideoController(_player);
  }

  final Player _player;
  late final VideoController _controller;

  @override
  Stream<Duration> get position => _player.stream.position;

  @override
  Stream<Duration> get duration => _player.stream.duration;

  @override
  Stream<bool> get playing => _player.stream.playing;

  @override
  Stream<bool> get buffering => _player.stream.buffering;

  @override
  Stream<bool> get completed => _player.stream.completed;

  @override
  Stream<String> get errors => _player.stream.error;

  @override
  Future<void> open(Uri url, {Duration start = Duration.zero}) =>
      _player.open(Media(url.toString(), start: start));

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> playOrPause() => _player.playOrPause();

  @override
  Widget buildVideo(BuildContext context) {
    // The player screen shows its own buffering spinner (driven by
    // [buffering]); suppress media_kit's built-in one so only one shows.
    // The default controls (play/pause/seek bar) stay for now — Phase 2
    // replaces them with our own.
    final video = Video(controller: _controller, fill: const Color(0xFF000000));
    return MaterialVideoControlsTheme(
      normal: kDefaultMaterialVideoControlsThemeData.copyWith(
        bufferingIndicatorBuilder: (_) => const SizedBox.shrink(),
      ),
      fullscreen: kDefaultMaterialVideoControlsThemeDataFullscreen.copyWith(
        bufferingIndicatorBuilder: (_) => const SizedBox.shrink(),
      ),
      child: MaterialDesktopVideoControlsTheme(
        normal: kDefaultMaterialDesktopVideoControlsThemeData.copyWith(
          bufferingIndicatorBuilder: (_) => const SizedBox.shrink(),
        ),
        fullscreen: kDefaultMaterialDesktopVideoControlsThemeDataFullscreen
            .copyWith(
              bufferingIndicatorBuilder: (_) => const SizedBox.shrink(),
            ),
        child: video,
      ),
    );
  }

  @override
  Future<void> dispose() => _player.dispose();
}
