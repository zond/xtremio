import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'playback_stats.dart';

export 'playback_stats.dart';

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

  /// Performance samples for the stats OSD, about twice a second.
  ///
  /// Sampling costs something (property reads into the decoder), so it runs
  /// only while this stream has a listener: the overlay subscribes when it
  /// is shown and cancels when hidden, and an engine with nothing to report
  /// simply never emits.
  Stream<PlaybackStats> get stats;

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
  bool _disposed = false;

  /// How often [stats] samples while listened to.
  static const Duration statsInterval = Duration(milliseconds: 500);

  late final StreamController<PlaybackStats> _stats =
      StreamController<PlaybackStats>.broadcast(
        onListen: _startStats,
        onCancel: _stopStats,
      );
  Timer? _statsTimer;
  bool _sampling = false;

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
  Stream<PlaybackStats> get stats => _stats.stream;

  /// Polls [PlaybackStats.mpvProperties] through libmpv every
  /// [statsInterval] while [stats] has a listener. Plain polling (rather
  /// than `observeProperty` per property) keeps the cost bounded and
  /// proportional to the OSD being on screen; a dozen
  /// `mpv_get_property_string` calls twice a second is negligible.
  void _startStats() {
    final native = _player.platform;
    // Only the native (libmpv) backend exposes raw properties.
    if (native is! NativePlayer || _disposed) return;
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(statsInterval, (_) => _sampleStats(native));
    _sampleStats(native);
  }

  void _stopStats() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  Future<void> _sampleStats(NativePlayer native) async {
    // One sample at a time; `getProperty` awaits the player's own
    // initialisation, so a slow start must not pile requests up.
    if (_sampling) return;
    _sampling = true;
    try {
      final values = <String, String>{};
      for (final property in PlaybackStats.mpvProperties) {
        values[property] = await native.getProperty(property);
        if (_disposed || !_stats.hasListener) return;
      }
      _stats.add(PlaybackStats.fromMpv(values));
    } catch (_) {
      // Unavailable property or a player torn down mid-sample: skip it.
    } finally {
      _sampling = false;
    }
  }

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

  /// Stops playback before releasing the player. Once stopped, libmpv posts
  /// no more frames to the video texture, so the texture is idle by the time
  /// `Player.dispose` unregisters it (media_kit tears the native
  /// `VideoOutput` down from `Player.dispose`, so there is nothing separate
  /// to dispose on the `VideoController`).
  @override
  Future<void> dispose() async {
    _disposed = true;
    _stopStats();
    await _stats.close();
    try {
      await _player.stop();
    } finally {
      await _player.dispose();
    }
  }
}
