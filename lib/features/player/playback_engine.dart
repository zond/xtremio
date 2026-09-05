import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/core.dart';
import 'playback_stats.dart';
import 'playback_tracks.dart';
import 'subtitle_match.dart';
import 'torrent_stats.dart';

export 'playback_stats.dart';
export 'playback_tracks.dart';
export 'torrent_stats.dart';

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

  /// What the backend itself says went wrong, verbatim -- mpv's own error
  /// log, where the demuxer and ffmpeg write (`tcp: Connection timed out`).
  /// Not an error the screen shows: a line for the diagnostics report,
  /// which is the only place a failure on someone else's phone is legible.
  Stream<String> get engineLog;

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

  /// Multiplies the timestamps of the subtitle events being drawn by
  /// [speed], `1.0` being the file's own timing.
  ///
  /// This is how a file cut for a release of another frame rate is put
  /// back in step: the whole drift is linear, so one multiplier removes
  /// it. Only a viewer watching the picture ever asks for one -- a
  /// declared rate says where an upload came from, not how it is timed --
  /// so nothing sets this by itself. Only libmpv has the property; any
  /// other backend does nothing here.
  ///
  /// Every path that changes what is on screen sets it, 1.0 included: a
  /// multiplier is a property of the player, not of the file, so one left
  /// behind by the previous pick would ruin a subtitle that was correct.
  Future<void> setSubtitleSpeed(double speed);

  /// Shifts the subtitle events being drawn by [seconds]: positive makes
  /// a line appear later than the file asks for, negative earlier.
  ///
  /// The other half of putting a file back in step: a multiplier fixes a
  /// subtitle that drifts, an offset fixes one cut for a release that
  /// starts somewhere else -- a distributor logo this video does not
  /// have. Like the multiplier, only a viewer watching the picture can
  /// judge it, so nothing sets this by itself.
  ///
  /// libmpv's `sub-delay`; any other backend does nothing here.
  ///
  /// Like the multiplier it belongs to the player rather than to the
  /// file, so every path that changes what is on screen sets it, `0.0`
  /// included.
  Future<void> setSubtitleDelay(double seconds);

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
/// the [FullscreenController], the [TorrentStatsClient] the start-up
/// overlay polls the embedded server with (absent, the FFI one), and
/// [dhtStatus] (absent, `ServerClient().dhtStatus`). The subtitle style is
/// not here: the screen derives it from the profile's settings in the `ctx`
/// field.
class PlaybackScope extends InheritedWidget {
  const PlaybackScope({
    super.key,
    required this.createEngine,
    this.fullscreen,
    this.torrentStats,
    this.subtitleMatch,
    this.dhtStatus,
    required super.child,
  });

  final PlaybackEngineFactory createEngine;
  final FullscreenController? fullscreen;
  final TorrentStatsClient? torrentStats;

  /// What "Match to another subtitle" asks for a ratio and an offset.
  final SubtitleMatchClient? subtitleMatch;

  /// What the start-up card's one DHT explanation reads
  /// (`ServerHandle::dht_status`). A plain function rather than a client
  /// interface, because it is the only thing about the DHT the player ever
  /// asks: cheap and synchronous, read once when torrent polling starts,
  /// never on a timer of its own.
  final DhtStatus Function()? dhtStatus;

  static PlaybackScope? _maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlaybackScope>();

  static PlaybackEngineFactory of(BuildContext context) =>
      _maybeOf(context)?.createEngine ?? MediaKitEngine.new;

  static FullscreenController fullscreenOf(BuildContext context) =>
      _maybeOf(context)?.fullscreen ?? const NativeFullscreenController();

  static TorrentStatsClient torrentStatsOf(BuildContext context) =>
      _maybeOf(context)?.torrentStats ?? const RustTorrentStatsClient();

  static SubtitleMatchClient subtitleMatchOf(BuildContext context) =>
      _maybeOf(context)?.subtitleMatch ?? const RustSubtitleMatchClient();

  static DhtStatus Function() dhtStatusOf(BuildContext context) =>
      _maybeOf(context)?.dhtStatus ?? (() => const ServerClient().dhtStatus);

  @override
  bool updateShouldNotify(PlaybackScope oldWidget) =>
      createEngine != oldWidget.createEngine ||
      fullscreen != oldWidget.fullscreen ||
      torrentStats != oldWidget.torrentStats ||
      subtitleMatch != oldWidget.subtitleMatch ||
      dhtStatus != oldWidget.dhtStatus;
}

/// [PlaybackEngine] over `media_kit` (libmpv). Direct play only: whatever
/// the URL serves is decoded on this device; the server never transcodes.
///
/// [hardwareDecoding] (`profile.settings.hardwareDecoding`) is fixed at
/// creation: media_kit takes it as the video controller's configuration
/// (`hwdec=auto` vs `no`), and a controller cannot be reconfigured.
class MediaKitEngine implements PlaybackEngine {
  MediaKitEngine({bool hardwareDecoding = true}) : _player = Player() {
    _overrides = _applyOverrides(_player.platform);
    _controller = VideoController(
      _player,
      configuration: configurationFor(hardwareDecoding: hardwareDecoding),
    );
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
    final native = _player.platform;
    if (native is NativePlayer) {
      _observeSelection(native).ignore();
    }
  }

  final Player _player;
  late final VideoController _controller;
  bool _disposed = false;

  /// The mpv properties in [mpvOverrides], on their way to the backend.
  /// [open] waits for it: a property mpv reads when it opens a stream is
  /// worth nothing if it lands after the stream is open.
  late final Future<void> _overrides;

  /// mpv properties this app sets differently from media_kit's own
  /// defaults, applied once per player.
  ///
  /// `network-timeout`: media_kit 1.2.6 starts libmpv with
  /// `network-timeout=5` (`player/native/player/real.dart`), which is five
  /// seconds for the *whole* read to make progress. Our own stream is a
  /// torrent: on a thin swarm the embedded server legitimately takes
  /// minutes to hand over the next piece, and there is nothing wrong while
  /// it does. With mpv's `keep-open=yes` that timeout does not surface as
  /// an error either -- it arrives as a false end of file, on which
  /// media_kit's `play()` seeks back to 0, which is what "it plays ten
  /// seconds and starts over" is. Five minutes is long enough that no
  /// swarm trips it and short enough that a connection that is really gone
  /// still ends up an error rather than a hang.
  static const Map<String, String> mpvOverrides = {'network-timeout': '300'};

  /// Sets [mpvOverrides] on the native backend. Only libmpv has
  /// properties; any other backend keeps its own behaviour, and a player
  /// torn down before it initialised is not an error worth surfacing.
  static Future<void> _applyOverrides(PlatformPlayer? platform) async {
    if (platform is! NativePlayer) return;
    for (final MapEntry(:key, :value) in mpvOverrides.entries) {
      try {
        await platform.setProperty(key, value);
      } catch (_) {
        // Gone, or a build of libmpv without the property. Playback is
        // still playback.
      }
    }
  }

  /// The controller configuration for a `hardwareDecoding` setting:
  /// media_kit's default (GPU decode and render) when on, software
  /// decoding when off.
  static VideoControllerConfiguration configurationFor({
    required bool hardwareDecoding,
  }) => VideoControllerConfiguration(
    enableHardwareAcceleration: hardwareDecoding,
  );

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

  /// mpv's own `aid`/`sid` (a track id, `no` or `auto`), null until
  /// observed. media_kit only updates `stream.track` from its own
  /// `setAudioTrack`/`setSubtitleTrack`, so a track mpv selected by itself
  /// (a default or forced subtitle) would otherwise show as none.
  String? _mpvAudioId;
  String? _mpvSubtitleId;

  /// URLs handed to `sub-add`. mpv lists external files in `track-list`
  /// too (media_kit does not expose the `external` flag), so they are
  /// recognised by title — the URL is passed as the track title — and kept
  /// out of the embedded list; the screen lists them from the core's
  /// subtitles instead.
  final Set<String> _externalSubtitleUrls = {};

  SubtitleStyle _subtitleStyle = const SubtitleStyle();

  /// The live [Video], so [SubtitleLift] can reach the subtitle view
  /// inside it.
  final GlobalKey<VideoState> _videoKey = GlobalKey<VideoState>();

  /// Where the subtitles are, as far as that view is concerned. Starts as
  /// nothing so the first build's padding is pushed as well as configured:
  /// which of the two lands first is media_kit's business, and they agree.
  final SubtitleLift _lift = SubtitleLift();

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
  Stream<String> get engineLog => _player.stream.log
      .where((entry) => entry.level == 'error')
      .map((entry) => '${entry.prefix}: ${entry.text}');

  @override
  Stream<double> get volume => _player.stream.volume;

  @override
  Stream<PlaybackTracks> get tracks => _tracks.stream;

  @override
  Stream<PlaybackStats> get stats => _stats.stream;

  /// Follows mpv's `aid`/`sid` so the selection reflects what is really
  /// drawn, not only what went through media_kit's setters. Only the native
  /// (libmpv) backend exposes properties.
  Future<void> _observeSelection(NativePlayer native) async {
    try {
      await native.observeProperty('aid', (value) async {
        _mpvAudioId = value;
        _emitTracks();
      });
      await native.observeProperty('sid', (value) async {
        _mpvSubtitleId = value;
        _emitTracks();
      });
    } catch (_) {
      // Torn down before the player initialised: media_kit's own
      // selection reports still work.
    }
  }

  void _emitTracks() {
    if (_disposed || _tracks.isClosed) return;
    _tracks.add(
      mergeTracks(
        tracks: _lastTracks,
        selected: _lastTrack,
        mpvAudioId: _mpvAudioId,
        mpvSubtitleId: _mpvSubtitleId,
        externalSubtitleUrls: _externalSubtitleUrls,
      ),
    );
  }

  /// Merges media_kit's track list, its last selection and mpv's own
  /// `aid`/`sid` into one [PlaybackTracks], dropping the synthetic
  /// `auto`/`no` entries and the external subtitle files (recognised by
  /// their URL title; see [_externalSubtitleUrls]).
  ///
  /// mpv's ids win when known: they change with every selection, including
  /// the ones mpv makes by itself, whereas media_kit's [selected] only
  /// follows its own setters. An external file selected by mpv's `sid` is
  /// reported by its URL, the id the screen knows it by.
  static PlaybackTracks mergeTracks({
    required Tracks tracks,
    required Track selected,
    required String? mpvAudioId,
    required String? mpvSubtitleId,
    required Set<String> externalSubtitleUrls,
  }) {
    final String? activeAudioId;
    if (mpvAudioId != null) {
      activeAudioId = _isSynthetic(mpvAudioId) ? null : mpvAudioId;
    } else {
      activeAudioId = _isSynthetic(selected.audio.id)
          ? null
          : selected.audio.id;
    }
    final String? activeSubtitleId;
    if (mpvSubtitleId != null) {
      if (_isSynthetic(mpvSubtitleId)) {
        activeSubtitleId = null;
      } else {
        final track = tracks.subtitle
            .where((t) => t.id == mpvSubtitleId)
            .firstOrNull;
        final title = track?.title;
        activeSubtitleId = title != null && externalSubtitleUrls.contains(title)
            ? title
            : mpvSubtitleId;
      }
    } else {
      final subtitle = selected.subtitle;
      activeSubtitleId = _isSynthetic(subtitle.id) && !subtitle.uri
          ? null
          : subtitle.id;
    }
    return PlaybackTracks(
      audio: [
        for (final track in tracks.audio)
          if (!_isSynthetic(track.id)) _trackInfo(track),
      ],
      subtitle: [
        for (final track in tracks.subtitle)
          if (!_isSynthetic(track.id) &&
              !externalSubtitleUrls.contains(track.title))
            _subtitleInfo(track),
      ],
      activeAudioId: activeAudioId,
      activeSubtitleId: activeSubtitleId,
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
  Future<void> open(Uri url, {Duration start = Duration.zero}) async {
    _externalSubtitleUrls.clear();
    await _overrides;
    await _player.open(Media(url.toString(), start: start));
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

  /// The mpv property that multiplies subtitle event timestamps. It is in
  /// the libmpv we ship, alongside `sub-fps` and `sub-delay`; `sub-fps`
  /// is the wrong one of the three, since it only re-times a file mpv
  /// itself has to convert from frames.
  static const String subtitleSpeedProperty = 'sub-speed';

  /// [speed] as mpv reads it: a decimal string, at a precision that
  /// carries a frame-rate ratio (25 / 23.976 is 1.042709) without
  /// spelling out the whole of a double.
  static String subtitleSpeedValue(double speed) => speed.toStringAsFixed(6);

  @override
  Future<void> setSubtitleSpeed(double speed) async {
    final native = _player.platform;
    // Only the native (libmpv) backend has properties; a cast or an
    // offline backend re-times nothing and needs nothing reset.
    if (native is! NativePlayer || _disposed) return;
    try {
      await native.setProperty(
        subtitleSpeedProperty,
        subtitleSpeedValue(speed),
      );
    } catch (_) {
      // A player torn down mid-write, or a build of libmpv without the
      // property. The latter never re-times anything either, so there is
      // no stale multiplier for a failed reset to leave behind.
      //
      // A value mpv *refuses* does not come through here at all:
      // media_kit discards `mpv_set_property_string`'s return code, so an
      // out-of-range write is silent and leaves the property as it was.
      // That is why the range is enforced where the number is computed
      // (`minSubtitleSpeed` in `subtitle_groups.dart`) rather than here.
    }
  }

  /// The mpv property that shifts subtitle event timestamps, in seconds.
  /// Positive is later, which is mpv's own sign and the one the overlay
  /// puts in front of the number.
  static const String subtitleDelayProperty = 'sub-delay';

  /// [seconds] as mpv reads it. Three decimals is a millisecond, finer
  /// than the tenth of a second a viewer can ask for and finer than any
  /// subtitle format times its own cues.
  static String subtitleDelayValue(double seconds) =>
      seconds.toStringAsFixed(3);

  @override
  Future<void> setSubtitleDelay(double seconds) async {
    final native = _player.platform;
    // Only the native (libmpv) backend has properties; a cast or an
    // offline backend shifts nothing and needs nothing put back.
    if (native is! NativePlayer || _disposed) return;
    try {
      await native.setProperty(
        subtitleDelayProperty,
        subtitleDelayValue(seconds),
      );
    } catch (_) {
      // A player torn down mid-write, or a build of libmpv without the
      // property. The latter never shifted anything either, so there is
      // no stale offset for a failed reset to leave behind. Unlike
      // `sub-speed` this property has no range to fall outside of.
    }
  }

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
    final padding = EdgeInsets.fromLTRB(16, 0, 16, subtitleBottomPadding);
    if (_lift.changedTo(padding)) _pushSubtitlePadding(padding);
    return Video(
      key: _videoKey,
      controller: _controller,
      controls: NoVideoControls,
      fill: const Color(0xFF000000),
      subtitleViewConfiguration: SubtitleViewConfiguration(
        style: TextStyle(
          fontSize: style.fontSize,
          color: style.color,
          height: 1.4,
          fontWeight: FontWeight.w500,
          backgroundColor: style.backgroundColor,
          shadows: style.hasBackground
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
        padding: padding,
      ),
    );
  }

  /// Tells the live subtitle view about a padding the configuration cannot
  /// deliver, on the frame after the one that computed it.
  ///
  /// Not during the build that asked for it: `setPadding` is a `setState`
  /// on a widget under the one being built. media_kit's own
  /// `Video.didUpdateWidget` defers its configuration the same way, and it
  /// runs after this one, so the two land in that order and agree.
  void _pushSubtitlePadding(EdgeInsets padding) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _videoKey.currentState?.setSubtitleViewPadding(padding);
    });
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

/// Where the subtitles are drawn, as far as a live `SubtitleView` is
/// concerned, and whether it still has to be told about a change.
///
/// media_kit's `SubtitleView` reads `SubtitleViewConfiguration.padding`
/// exactly once. Its state initialises a `late` field from the
/// configuration and has no `didUpdateWidget` (unlike the style, the
/// alignment and the scaler, which it reads off the widget on every
/// build), while a `GlobalKey` inside `VideoState` keeps that one state
/// alive across every rebuild of the `Video`. So the configuration
/// delivers the first padding and no other: lifting the subtitles clear of
/// the controls later in the session means calling
/// `VideoState.setSubtitleViewPadding`, which is what media_kit's own
/// controls do.
///
/// This is the memo that makes that one call per change rather than per
/// frame -- it is a `setState` on the subtitle view, and the player screen
/// rebuilds on every position tick.
class SubtitleLift {
  /// Nothing shown yet: the first padding of a session is both configured
  /// and pushed, since which of the two the view ends up taking is
  /// media_kit's business and they carry the same value.
  EdgeInsets? _showing;

  /// What the view was last told to draw at, null before the first change.
  EdgeInsets? get showing => _showing;

  /// Records [padding] and answers whether the view has to be told.
  bool changedTo(EdgeInsets padding) {
    if (padding == _showing) return false;
    _showing = padding;
    return true;
  }
}
