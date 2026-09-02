import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'playback_stats.dart';
import 'playback_tracks.dart';

export 'playback_stats.dart';
export 'playback_tracks.dart';

/// What the player screen needs from a video backend. `media_kit` is the
/// real one; tests substitute a fake through [PlaybackScope] so the screen's
/// core wiring can be exercised without libmpv.
abstract interface class PlaybackEngine {
  Stream<Duration> get position;
  Stream<Duration> get duration;

  /// How far ahead of the start the demuxer has buffered (the end of the
  /// buffered range, for the seek bar).
  Stream<Duration> get buffer;
  Stream<bool> get playing;
  Stream<bool> get buffering;

  /// Fires once when the media reaches its end.
  Stream<bool> get completed;
  Stream<String> get errors;

  /// Output volume, `0..100`.
  Stream<double> get volume;

  /// The audio/subtitle tracks in the open media and which are selected;
  /// re-emitted whenever either changes.
  Stream<PlaybackTracks> get tracks;

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
  Future<void> play();
  Future<void> pause();
  Future<void> playOrPause();

  /// `0..100`.
  Future<void> setVolume(double volume);

  /// Playback speed, `1.0` being normal.
  Future<void> setRate(double rate);

  Future<void> setAudioTrack(String id);

  /// Selects an embedded subtitle track by its [TrackInfo.id].
  Future<void> setSubtitleTrack(String id);

  /// Loads a subtitle file (SRT, WebVTT, ...) from [url] and selects it.
  Future<void> setExternalSubtitle(Uri url, {String? title, String? language});
  Future<void> disableSubtitles();

  /// Applies to the subtitles drawn over the video from the next build.
  Future<void> setSubtitleStyle(SubtitleStyle style);

  /// The video surface, without any built-in controls. Subtitles are drawn
  /// [subtitleBottomPadding] above the bottom edge, so the screen can lift
  /// them clear of its own controls.
  Widget buildVideo(BuildContext context, {double subtitleBottomPadding = 24});

  Future<void> dispose();
}

typedef PlaybackEngineFactory = PlaybackEngine Function();

/// Puts the window (desktop) or the activity (Android: immersive, landscape)
/// into and out of fullscreen. Injectable so widget tests record the calls
/// instead of touching the platform.
abstract interface class FullscreenController {
  Future<void> enter();
  Future<void> exit();
}

/// [FullscreenController] over media_kit_video's platform helpers: a native
/// window fullscreen on desktop, immersive sticky system UI plus a landscape
/// lock on Android/iOS.
class NativeFullscreenController implements FullscreenController {
  const NativeFullscreenController();

  @override
  Future<void> enter() => defaultEnterNativeFullscreen();

  @override
  Future<void> exit() => defaultExitNativeFullscreen();
}

/// Supplies what the player screen needs from the outside: the
/// [PlaybackEngineFactory] (absent, the screen builds a [MediaKitEngine]),
/// the [FullscreenController], and the user's [SubtitleStyle], which lives
/// in a notifier so it survives from one player to the next within a run.
/// (A Settings entry and persistence come later.)
class PlaybackScope extends InheritedWidget {
  const PlaybackScope({
    super.key,
    required this.createEngine,
    this.fullscreen,
    this.subtitleStyle,
    required super.child,
  });

  final PlaybackEngineFactory createEngine;
  final FullscreenController? fullscreen;
  final ValueNotifier<SubtitleStyle>? subtitleStyle;

  /// The app-wide subtitle style when no scope provides one.
  static final ValueNotifier<SubtitleStyle> defaultSubtitleStyle =
      ValueNotifier(const SubtitleStyle());

  static PlaybackScope? _maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlaybackScope>();

  static PlaybackEngineFactory of(BuildContext context) =>
      _maybeOf(context)?.createEngine ?? MediaKitEngine.new;

  static FullscreenController fullscreenOf(BuildContext context) =>
      _maybeOf(context)?.fullscreen ?? const NativeFullscreenController();

  static ValueNotifier<SubtitleStyle> subtitleStyleOf(BuildContext context) =>
      _maybeOf(context)?.subtitleStyle ?? defaultSubtitleStyle;

  @override
  bool updateShouldNotify(PlaybackScope oldWidget) =>
      createEngine != oldWidget.createEngine ||
      fullscreen != oldWidget.fullscreen ||
      subtitleStyle != oldWidget.subtitleStyle;
}

/// [PlaybackEngine] over `media_kit` (libmpv). Direct play only: whatever
/// the URL serves is decoded on this device; the server never transcodes.
class MediaKitEngine implements PlaybackEngine {
  MediaKitEngine() : _player = Player() {
    _controller = VideoController(_player);
    _trackSubscriptions = [
      _player.stream.tracks.listen((tracks) {
        _lastTracks = tracks;
        _emitTracks();
      }),
      _player.stream.track.listen((track) {
        _lastTrack = track;
        _emitTracks();
      }),
    ];
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

  final StreamController<PlaybackTracks> _tracks =
      StreamController<PlaybackTracks>.broadcast();
  late final List<StreamSubscription<void>> _trackSubscriptions;
  Tracks _lastTracks = const Tracks();
  Track _lastTrack = const Track();

  /// URLs handed to `sub-add`. mpv lists external files in `track-list`
  /// too (media_kit does not expose the `external` flag), so they are
  /// recognised by title — the URL is passed as the track title — and kept
  /// out of the embedded list; the screen lists them from the core's
  /// subtitles instead.
  final Set<String> _externalSubtitleUrls = {};

  SubtitleStyle _subtitleStyle = const SubtitleStyle();

  @override
  Stream<Duration> get position => _player.stream.position;

  @override
  Stream<Duration> get duration => _player.stream.duration;

  @override
  Stream<Duration> get buffer => _player.stream.buffer;

  @override
  Stream<bool> get playing => _player.stream.playing;

  @override
  Stream<bool> get buffering => _player.stream.buffering;

  @override
  Stream<bool> get completed => _player.stream.completed;

  @override
  Stream<String> get errors => _player.stream.error;

  @override
  Stream<double> get volume => _player.stream.volume;

  @override
  Stream<PlaybackTracks> get tracks => _tracks.stream;

  @override
  Stream<PlaybackStats> get stats => _stats.stream;

  /// Merges media_kit's track list with its currently selected tracks into
  /// one [PlaybackTracks], dropping the synthetic `auto`/`no` entries.
  void _emitTracks() {
    if (_disposed || _tracks.isClosed) return;
    final selectedSubtitle = _lastTrack.subtitle;
    _tracks.add(
      PlaybackTracks(
        audio: [
          for (final track in _lastTracks.audio)
            if (!_isSynthetic(track.id)) _trackInfo(track),
        ],
        subtitle: [
          for (final track in _lastTracks.subtitle)
            if (!_isSynthetic(track.id) &&
                !_externalSubtitleUrls.contains(track.title))
              _subtitleInfo(track),
        ],
        activeAudioId: _isSynthetic(_lastTrack.audio.id)
            ? null
            : _lastTrack.audio.id,
        activeSubtitleId:
            _isSynthetic(selectedSubtitle.id) && !selectedSubtitle.uri
            ? null
            : selectedSubtitle.id,
      ),
    );
  }

  static bool _isSynthetic(String id) => id == 'auto' || id == 'no';

  static TrackInfo _trackInfo(AudioTrack track) => TrackInfo(
    id: track.id,
    title: track.title,
    language: track.language,
    isDefault: track.isDefault ?? false,
    codec: track.codec,
    channels: track.channels,
  );

  static TrackInfo _subtitleInfo(SubtitleTrack track) => TrackInfo(
    id: track.id,
    title: track.title,
    language: track.language,
    isDefault: track.isDefault ?? false,
    codec: track.codec,
  );

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
  Future<void> open(Uri url, {Duration start = Duration.zero}) {
    _externalSubtitleUrls.clear();
    return _player.open(Media(url.toString(), start: start));
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> playOrPause() => _player.playOrPause();

  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume(volume.clamp(0, 100).toDouble());

  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  // Track equality in media_kit is by id (`_Track.==`), so a bare id is
  // enough to address a track from the list.
  @override
  Future<void> setAudioTrack(String id) =>
      _player.setAudioTrack(AudioTrack(id, null, null));

  @override
  Future<void> setSubtitleTrack(String id) =>
      _player.setSubtitleTrack(SubtitleTrack(id, null, null));

  @override
  Future<void> setExternalSubtitle(Uri url, {String? title, String? language}) {
    final text = url.toString();
    _externalSubtitleUrls.add(text);
    // `SubtitleTrack.uri` becomes mpv `sub-add <url> select <title> <lang>`;
    // the title only ever shows in our own menu (see
    // [_externalSubtitleUrls]), so it carries the URL.
    return _player.setSubtitleTrack(
      SubtitleTrack.uri(text, title: text, language: language),
    );
  }

  @override
  Future<void> disableSubtitles() =>
      _player.setSubtitleTrack(SubtitleTrack.no());

  @override
  Future<void> setSubtitleStyle(SubtitleStyle style) async {
    _subtitleStyle = style;
  }

  /// Text subtitles are rendered by Flutter here: media_kit's default
  /// `PlayerConfiguration(libass: false)` sets mpv `sub-visibility=no` and
  /// feeds the current subtitle text lines to a `SubtitleView` styled by
  /// [SubtitleViewConfiguration]. That works the same on every platform
  /// with no fonts to ship, but bitmap subtitles (PGS/VobSub) never reach
  /// it; selecting one shows nothing until this moves to libass.
  @override
  Widget buildVideo(BuildContext context, {double subtitleBottomPadding = 24}) {
    final style = _subtitleStyle;
    return Video(
      controller: _controller,
      controls: NoVideoControls,
      fill: const Color(0xFF000000),
      subtitleViewConfiguration: SubtitleViewConfiguration(
        style: TextStyle(
          fontSize: style.fontSize,
          color: style.color,
          height: 1.4,
          fontWeight: FontWeight.w500,
          backgroundColor: style.background
              ? const Color(0xAA000000)
              : const Color(0x00000000),
          shadows: style.background
              ? null
              : const [
                  Shadow(color: Color(0xFF000000), blurRadius: 4),
                  Shadow(
                    color: Color(0xFF000000),
                    offset: Offset(1, 1),
                    blurRadius: 2,
                  ),
                ],
        ),
        padding: EdgeInsets.fromLTRB(16, 0, 16, subtitleBottomPadding),
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
    for (final subscription in _trackSubscriptions) {
      await subscription.cancel();
    }
    await _tracks.close();
    await _stats.close();
    try {
      await _player.stop();
    } finally {
      await _player.dispose();
    }
  }
}
