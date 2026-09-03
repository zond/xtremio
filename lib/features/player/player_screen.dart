import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../widgets/remote_press.dart';
import 'language_names.dart';
import 'playback_engine.dart';
import 'playback_stats_overlay.dart';
import 'player_controls.dart';
import 'torrent_startup_overlay.dart';
import 'track_menus.dart';
import 'up_next_card.dart';

/// Plays one stream.
///
/// Dispatches `Load Player` for [stream], waits for the engine to resolve it
/// (`player.stream` becomes `Ready` with a `streaming_url`: the direct URL
/// for HTTP streams, the embedded stream-server's URL for torrents), opens
/// that URL in the [PlaybackEngine], and reports progress back so the
/// library and continue-watching stay in sync. Unloads on dispose.
///
/// The controls are our own (media_kit's are switched off): a top bar with
/// the track menus, a bottom bar with the seek bar, transport, time, volume
/// and fullscreen, keyboard shortcuts, and an up-next card when an episode
/// ends. They fade after [controlsTimeout] while playing.
///
/// `profile.settings` (the `ctx` field) drives the seek steps
/// (`seekTimeDuration`; Shift + arrows is the *short* `seekShortTimeDuration`,
/// as in stremio-core), whether an ending episode moves on at all
/// (`bingeWatching`), how long the up-next card counts down first
/// (`nextVideoNotificationDuration`; 0 skips the card and plays at once),
/// whether hiding the app pauses (`pauseOnMinimize`), whether Esc leaves
/// fullscreen (`escExitFullscreen`), and the subtitle style.
///
/// On a TV ([DeviceScope.isTv]) the remote drives it: the D-pad's centre
/// brings the controls up when they are hidden and toggles play/pause when
/// they show, up and down move focus onto the shown control bar (and off
/// it again at its edges), where select presses the focused control and the
/// seek bar seeks with left/right, and the media keys (play, pause,
/// play/pause, stop, fast forward, rewind, next and previous track) do what
/// they say. The controls do not fade while a control holds focus. The
/// media keys work off a TV too; nothing else about the keyboard changes
/// there.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.stream,
    this.streamRequest,
    this.metaRequest,
    this.subtitlesPath,
  });

  /// Raw stream JSON as it came out of `meta_details.streams` (or a
  /// hand-built one; see the dev entries in Settings).
  final Map<String, dynamic> stream;

  /// The addon request the stream came from, when known.
  final ResourceRequest? streamRequest;

  /// The meta request, so the engine tracks the library item / next video.
  final ResourceRequest? metaRequest;

  /// `subtitles/<type>/<video id>`: the resource the engine asks subtitle
  /// addons for once the video parameters are known.
  final ResourcePath? subtitlesPath;

  /// Minimum spacing of `TimeChanged` reports to the core.
  static const Duration timeReportInterval = Duration(seconds: 1);

  /// How long the stats OSD stays up after the pointer stops moving.
  static const Duration statsHoverTimeout = Duration(seconds: 3);

  /// How often the server's `stats.json` is polled while a torrent starts
  /// up (from `open` until the engine reports the media loaded).
  static const Duration torrentStatsInterval = Duration(milliseconds: 500);

  /// How long the controls stay up without input while playing.
  static const Duration controlsTimeout = Duration(seconds: 3);

  static const List<double> rates = [0.75, 1, 1.25, 1.5, 2];

  /// Below this width the transport sits in the middle of the video and
  /// the volume slider is dropped (hardware keys on phones).
  static const double wideBreakpoint = 720;

  /// Subtitle padding above the bottom edge with the controls up / hidden.
  static const double subtitlePaddingWithControls = 96;
  static const double subtitlePaddingBare = 24;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

/// Popped as the route result when the user asked for the next episode but
/// the engine found no stream for it: the caller should show that video's
/// streams.
final class PlayerScreenResult {
  const PlayerScreenResult({required this.selectVideoId});

  final String selectVideoId;
}

class _PlayerScreenState extends State<PlayerScreen> {
  CoreClient? _client;
  CoreFieldNotifier? _player;

  /// The `ctx` field, for `profile.settings`.
  CoreFieldNotifier? _ctx;

  /// The settings map of the last `UpdateSettings` sent, until the next
  /// `ctx` pull: what [_settings] answers and what the next write builds
  /// on, so two chips in a row do not send the pre-first-change map.
  Map<String, dynamic>? _pendingSettings;
  late final AppLifecycleListener _lifecycle;
  PlaybackEngine? _engine;
  FullscreenController? _fullscreen;
  SubtitleStyle _subtitleStyle = const SubtitleStyle();
  final List<StreamSubscription<void>> _subscriptions = [];
  final FocusNode _focusNode = FocusNode(debugLabel: 'player');

  /// [DeviceScope.isTv], read with the dependencies.
  bool _isTv = false;

  /// A [_scheduleFocusCheck] callback is pending for the coming frame.
  bool _focusCheckScheduled = false;

  /// The controls' own focus scope on a TV: what [_controlFocused] asks
  /// whether the remote is on the bar, and what keeps the D-pad inside it.
  /// Off a TV the controls are not wrapped in it at all, so desktop
  /// traversal is what it always was.
  final FocusScopeNode _controlsScope = FocusScopeNode(
    debugLabel: 'player controls',
  );

  /// The up-next card's own scope on a TV. It sits outside the control
  /// bar in the stack, so it cannot share [_controlsScope], but it counts
  /// as a control for everything the remote does.
  final FocusScopeNode _upNextScope = FocusScopeNode(
    debugLabel: 'player up next',
  );

  /// Where focus lands when the remote moves down (the bottom bar's
  /// play/pause, or "Play now" while the countdown runs) and up (the top
  /// bar's back button) onto the controls.
  final FocusNode _playPauseFocus = FocusNode(debugLabel: 'play/pause');

  /// The seek bar's node on a television. It is the one stop on the bar
  /// with nothing to press, so [_onKeyEvent] has to know when the remote
  /// is on it and take the centre key itself.
  final FocusNode _seekBarFocus = FocusNode(debugLabel: 'seek bar');
  final FocusNode _topBarFocus = FocusNode(debugLabel: 'player top bar');
  final FocusNode _playNextFocus = FocusNode(debugLabel: 'play next');

  Uri? _opened;
  Duration _duration = Duration.zero;
  final ValueNotifier<Duration> _position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _buffer = ValueNotifier(Duration.zero);
  final ValueNotifier<PlaybackTracks> _tracks = ValueNotifier(
    const PlaybackTracks(),
  );
  Duration? _lastReported;
  bool? _lastPlaying;
  bool _playing = false;
  bool _buffering = false;
  String? _engineError;
  double _volume = 100;
  double? _volumeBeforeMute;
  double _rate = 1;
  bool _fullscreenOn = false;
  bool _showRemaining = false;

  /// Set once the next episode's screen has been pushed in our place: this
  /// screen then neither unloads the core's player nor reacts to its state.
  bool _handedOver = false;

  /// Whether the session's subtitle preference has been applied to this
  /// media yet (once per `open`), and whether an attempt is in flight.
  bool _autoPickedSubtitles = false;
  bool _autoPickingSubtitles = false;

  /// Whether the engine has reported the opened media loaded (a duration,
  /// or that it is playing). Until then mpv is between files and refuses
  /// `sub-add` ("Cannot add track at the moment"), so the subtitle
  /// auto-pick waits for this.
  bool _mediaLoaded = false;

  /// The pre-playback overlay for torrents: while [_torrentStatsRequest]
  /// is set the server's stats are polled every
  /// [PlayerScreen.torrentStatsInterval] and the latest answer shown (null
  /// until the server answers for this torrent). Cleared once the media
  /// loads, on an engine error and on dispose.
  ///
  /// [_torrentStatsRequest] asks for the stream's file, which focuses it
  /// and reports its initial window; when the server has no answer for
  /// that (an index the torrent turns out not to have) a poll asks for the
  /// torrent-level [_torrentStatsFallback] instead.
  TorrentStatsClient? _torrentStatsClient;
  TorrentStatsRequest? _torrentStatsRequest;
  TorrentStatsRequest? _torrentStatsFallback;
  Timer? _torrentStatsTimer;
  bool _torrentStatsFetching = false;
  TorrentStats? _torrentStats;

  bool _controlsVisible = true;
  Timer? _controlsTimer;
  bool _menuOpen = false;
  bool _scrubbing = false;

  /// Seconds left on the up-next card; null while it is not showing.
  int? _upNextSecondsLeft;
  Timer? _upNextTimer;

  /// Stats OSD visibility. Hover shows it until the pointer rests for
  /// [PlayerScreen.statsHoverTimeout]; Shift+I pins it on or off, after
  /// which hover no longer matters (a non-null [_statsPinned]).
  bool _statsHover = false;
  bool? _statsPinned;
  Timer? _statsHoverTimer;

  bool get _statsVisible => _statsPinned ?? _statsHover;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onHide: _onAppHidden);
    _controlsScope.addListener(_onControlsFocusChange);
    _upNextScope.addListener(_onControlsFocusChange);
  }

  /// A control took or lost focus: the controls may not fade while one has
  /// it, and they must start fading again once it is gone.
  void _onControlsFocusChange() {
    if (!mounted) return;
    setState(() {});
    _restartControlsTimer();
  }

  /// After every rebuild on a television: takes the remote back onto the
  /// video when the control it was on has left the tree.
  ///
  /// The top bar builds Next, Subtitles and Audio only when there is
  /// something behind them, so the button holding the remote can vanish
  /// mid-playback (the engine reports the last episode, the second audio
  /// track goes away). Focus is then on a node that is no longer in the
  /// tree — the controls' scope is not told, so its listener cannot be
  /// the hook — and the video's [Focus] never gets it back, its
  /// `autofocus` having been spent when it first attached. [_onKeyEvent]
  /// would stop running for good: the remote dead and the controls stuck
  /// at full opacity until the player is left.
  ///
  /// [_focusNode] wraps the whole screen, so "nothing here has focus" is
  /// exactly `!_focusNode.hasFocus`. A sheet this screen opened keeps the
  /// remote, as the player is not the current route while it is up.
  void _scheduleFocusCheck() {
    if (_focusCheckScheduled) return;
    _focusCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusCheckScheduled = false;
      if (!mounted || !_isTv || _focusNode.hasFocus) return;
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
      _focusNode.requestFocus();
    });
  }

  /// The remote is on a control (the bar or the up-next card) rather than
  /// on the video.
  bool get _controlFocused =>
      _isTv && (_controlsScope.hasFocus || _upNextScope.hasFocus);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _isTv = DeviceScope.isTv(context);
    if (_client != null) return;
    final client = CoreScope.of(context);
    _client = client;
    _player = CoreFieldNotifier(client, CoreField.player)
      ..addListener(_onPlayerState);
    _ctx = CoreFieldNotifier(client, CoreField.ctx)..addListener(_onCtx);
    client.dispatch(
      CoreActions.loadPlayer(
        stream: widget.stream,
        streamRequest: widget.streamRequest,
        metaRequest: widget.metaRequest,
        subtitlesPath: widget.subtitlesPath,
      ),
    );

    _fullscreen = PlaybackScope.fullscreenOf(context);
    _torrentStatsClient = PlaybackScope.torrentStatsOf(context);
    // A television has no window to be one part of: the video fills the
    // screen from the moment the player opens, with the system bars out of
    // the way, until the player is left ([dispose] leaves fullscreen).
    if (_isTv) {
      _fullscreenOn = true;
      _fullscreen?.enter().ignore();
    }

    final engine = PlaybackScope.of(context)();
    _engine = engine;
    engine.setSubtitleStyle(_subtitleStyle);
    _subscriptions.addAll([
      engine.duration.listen(_onDuration),
      engine.position.listen(_onPosition),
      engine.buffer.listen((b) => _buffer.value = b),
      engine.playing.listen(_onPlaying),
      engine.completed.listen(_onCompleted),
      engine.buffering.listen(_onBuffering),
      engine.errors.listen(_onEngineError),
      engine.volume.listen((v) => setState(() => _volume = v)),
      engine.tracks.listen(_onTracks),
    ]);
  }

  PlayerState? get _state {
    final json = _player?.value;
    return json == null ? null : PlayerState.fromJson(json);
  }

  /// The profile settings; empty (every accessor at its default) until the
  /// `ctx` field has been pulled, the last map sent while a write is in
  /// flight.
  ProfileSettings get _settings {
    final pending = _pendingSettings;
    if (pending != null) return ProfileSettings(pending);
    final json = _ctx?.value;
    return json == null
        ? const ProfileSettings({})
        : ProfileState.fromCtx(json).settings;
  }

  void _onCtx() {
    if (!mounted) return;
    // The engine's settings are the authority again.
    _pendingSettings = null;
    final style = SubtitleStyle.fromSettings(_settings);
    if (style != _subtitleStyle) {
      _subtitleStyle = style;
      _engine?.setSubtitleStyle(style);
    }
    // The seek labels follow the settings too.
    setState(() {});
  }

  /// The arrow-key / button seek step (`seekTimeDuration`).
  Duration get _seekStep => Duration(milliseconds: _settings.seekTimeDuration);

  /// The Shift + arrow seek step (`seekShortTimeDuration`).
  Duration get _shortSeekStep =>
      Duration(milliseconds: _settings.seekShortTimeDuration);

  /// `pauseOnMinimize`: the window was minimised or the app went to the
  /// background while playing.
  void _onAppHidden() {
    if (_settings.pauseOnMinimize && _playing && !_handedOver) {
      _engine?.pause();
    }
  }

  /// Writes one profile setting: the whole map with [key] changed, as the
  /// engine has no per-field defaults. Never with unknown settings (see
  /// [PlayerSettingsSheet.onSetting]).
  void _updateSetting(String key, Object? value) {
    final settings = _settings;
    if (settings.isEmpty) return;
    final next = settings.withValue(key, value);
    _pendingSettings = next;
    _client?.dispatch(CoreActions.updateSettings(next));
  }

  void _onPlayerState() {
    if (_handedOver || !mounted) return;
    final state = _state;
    final url = state?.streamingUrl;
    if (state == null || url == null || url == _opened) {
      setState(() {});
      _maybeAutoPickSubtitles();
      return;
    }
    _opened = url;
    _autoPickedSubtitles = false;
    _mediaLoaded = false;
    _dismissUpNext();
    final progress = state.progress;
    final start = progress != null && progress.isResumable
        ? Duration(milliseconds: progress.timeOffset)
        : Duration.zero;
    _position.value = start;
    _engine
        ?.open(url, start: start)
        .then((_) => _reportVideoParams(state, url))
        .catchError((Object error) {
          if (mounted && _opened == url) _failPlayback('$error');
        });
    // After `open` is on its way: the stream request creates the torrent's
    // engine with everything the URL carries (its `f=` filters included);
    // a stats request that got there first would create it from the bare
    // hash and trackers, and the stream request would then reuse that.
    _startTorrentStats(state);
    setState(() => _engineError = null);
    _restartControlsTimer();
  }

  /// Tells the engine what it can know about the file, which is what makes
  /// it ask the subtitle addons (they want a filename, hash or size; we
  /// have at best the filename). Without a real one, none is sent: the
  /// engine asks the addons anyway from its converted stream, and a
  /// stand-in such as the stream's label ("1080p") would only mislead the
  /// filename matching at OpenSubtitles.
  void _reportVideoParams(PlayerState state, Uri url) {
    if (!mounted || _handedOver || _opened != url) return;
    final segment = url.pathSegments.isEmpty ? null : url.pathSegments.last;
    final filename =
        state.convertedStream?.filename ??
        state.selectedStream?.filename ??
        (segment != null && segment.contains('.') ? segment : null);
    _client?.dispatch(CoreActions.playerVideoParamsChanged(filename: filename));
  }

  String get _device => Platform.operatingSystem;

  void _onPosition(Duration position) {
    if (_handedOver) return;
    _position.value = position;
    if (_opened == null || _duration == Duration.zero) return;
    final last = _lastReported;
    if (last != null &&
        (position - last).abs() < PlayerScreen.timeReportInterval) {
      return;
    }
    _lastReported = position;
    _client?.dispatch(
      CoreActions.playerTimeChanged(
        time: position.inMilliseconds,
        duration: _duration.inMilliseconds,
        device: _device,
      ),
    );
  }

  void _onDuration(Duration duration) {
    setState(() => _duration = duration);
    if (duration > Duration.zero) _onMediaLoaded();
  }

  /// The first sign from the engine that the opened media is in: what the
  /// subtitle auto-pick waits for, and the end of the start-up overlay.
  void _onMediaLoaded() {
    if (_mediaLoaded || _opened == null || _handedOver) return;
    setState(() {
      _mediaLoaded = true;
      _stopTorrentStats();
    });
    _maybeAutoPickSubtitles();
  }

  void _onEngineError(String error) => _failPlayback(error);

  /// Shows "Playback failed: [error]" in place of whatever was waiting for
  /// the media (the start-up overlay included, whose polling ends here).
  void _failPlayback(String error) {
    setState(() {
      _engineError = error;
      _stopTorrentStats();
    });
  }

  // --- Torrent start-up ----------------------------------------------------

  /// Begins polling the server's stats for the torrent [state] plays (see
  /// [TorrentStatsRequest.forStream]); anything else (a direct HTTP stream)
  /// shows no overlay. The first request goes out on the first tick, never
  /// before the engine's `open` has been issued.
  void _startTorrentStats(PlayerState state) {
    _stopTorrentStats();
    final stream = state.selectedStream;
    if (stream?.kind != StreamKind.torrent) return;
    final request = TorrentStatsRequest.forStream(stream);
    if (request == null) return;
    _torrentStatsRequest = request;
    final fallback = request.torrentLevel;
    _torrentStatsFallback = fallback == request ? null : fallback;
    _torrentStatsTimer = Timer.periodic(
      PlayerScreen.torrentStatsInterval,
      (_) => _pollTorrentStats(),
    );
  }

  /// Stops polling and forgets the last answer. Callers that need a
  /// rebuild wrap this in `setState`.
  void _stopTorrentStats() {
    _torrentStatsTimer?.cancel();
    _torrentStatsTimer = null;
    _torrentStatsRequest = null;
    _torrentStatsFallback = null;
    _torrentStats = null;
  }

  /// One poll: the per-file stats, or the torrent-level ones when the
  /// server has no answer for the file (an index the torrent does not
  /// have; a stopped server fails the second ask as fast as the first).
  Future<void> _pollTorrentStats() async {
    final request = _torrentStatsRequest;
    final fallback = _torrentStatsFallback;
    final client = _torrentStatsClient;
    if (request == null || client == null || _torrentStatsFetching) return;
    _torrentStatsFetching = true;
    TorrentStats? stats;
    try {
      stats = await client.fetch(request);
      if (stats == null &&
          fallback != null &&
          _torrentStatsRequest == request) {
        stats = await client.fetch(fallback);
      }
    } on Object {
      stats = null;
    } finally {
      _torrentStatsFetching = false;
    }
    // Still the same torrent, still waiting for it, and something changed.
    if (!mounted || _torrentStatsRequest != request || stats == _torrentStats) {
      return;
    }
    setState(() => _torrentStats = stats);
  }

  /// The start-up overlay replaces the status text from `open` until the
  /// media loads, for torrents the server streams.
  bool get _startupOverlayShown =>
      _torrentStatsRequest != null && !_mediaLoaded;

  void _onPlaying(bool playing) {
    if (_handedOver) return;
    if (playing) _onMediaLoaded();
    if (_playing != playing) {
      setState(() => _playing = playing);
      _showControls();
    }
    if (_opened == null || playing == _lastPlaying) return;
    _lastPlaying = playing;
    _client?.dispatch(CoreActions.playerPausedChanged(!playing));
  }

  void _onBuffering(bool buffering) {
    setState(() => _buffering = buffering);
    _restartControlsTimer();
  }

  void _onCompleted(bool completed) {
    if (!completed || _opened == null || _handedOver) return;
    _client?.dispatch(CoreActions.playerEnded());
    // `bingeWatching` off: the episode just ends; the Next button remains.
    if (_state?.nextVideo != null && _settings.bingeWatching) _startUpNext();
    _showControls();
  }

  void _onTracks(PlaybackTracks tracks) {
    // The bars read the selection and the track count directly.
    setState(() => _tracks.value = tracks);
    _maybeAutoPickSubtitles();
  }

  // --- Controls visibility -------------------------------------------------

  /// The controls may fade only while something is playing with nothing
  /// else demanding attention.
  bool get _canAutoHide =>
      _playing &&
      !_menuOpen &&
      !_scrubbing &&
      !_controlFocused &&
      _opened != null &&
      _upNextSecondsLeft == null &&
      !_startupOverlayShown &&
      _statusText(_state) == null;

  bool get _controlsShown => _controlsVisible || !_canAutoHide;

  void _showControls() {
    if (!_controlsVisible && mounted) {
      setState(() => _controlsVisible = true);
    }
    _restartControlsTimer();
  }

  void _restartControlsTimer() {
    _controlsTimer?.cancel();
    _controlsTimer = null;
    if (!_canAutoHide) return;
    _controlsTimer = Timer(PlayerScreen.controlsTimeout, () {
      if (mounted && _canAutoHide && _controlsVisible) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _hideControls() {
    _controlsTimer?.cancel();
    _controlsTimer = null;
    if (_canAutoHide && _controlsVisible) {
      setState(() => _controlsVisible = false);
    }
  }

  void _onVideoTap() {
    if (_upNextSecondsLeft != null) {
      _dismissUpNext();
      return;
    }
    if (_controlsShown) {
      _hideControls();
    } else {
      _showControls();
    }
  }

  /// Double-tapping the left/right third of the video on a touch screen
  /// skips back/forward.
  void _onVideoDoubleTap(TapDownDetails details, double width) {
    if (details.kind != PointerDeviceKind.touch) return;
    final x = details.localPosition.dx;
    if (x < width / 3) {
      _seekBy(-_seekStep);
    } else if (x > width * 2 / 3) {
      _seekBy(_seekStep);
    }
  }

  // --- Transport -----------------------------------------------------------

  void _togglePlay() {
    _engine?.playOrPause();
    _showControls();
  }

  void _seekTo(Duration target) {
    final upper = _duration > Duration.zero ? _duration : target;
    final clamped = target < Duration.zero
        ? Duration.zero
        : target > upper
        ? upper
        : target;
    _position.value = clamped;
    _engine?.seek(clamped);
    if (_opened != null && _duration > Duration.zero) {
      _client?.dispatch(
        CoreActions.playerSeek(
          time: clamped.inMilliseconds,
          duration: _duration.inMilliseconds,
          device: _device,
        ),
      );
    }
    // The next TimeChanged must go through even if it is within the
    // throttle window: the core only moves time forward on TimeChanged and
    // relies on Seek/TimeChanged agreeing.
    _lastReported = null;
    _dismissUpNext();
    _showControls();
  }

  void _seekBy(Duration delta) => _seekTo(_position.value + delta);

  void _setVolume(double volume) {
    final clamped = volume.clamp(0, 100).toDouble();
    if (clamped > 0) _volumeBeforeMute = null;
    setState(() => _volume = clamped);
    _engine?.setVolume(clamped);
    _showControls();
  }

  void _toggleMute() {
    if (_volume == 0) {
      _setVolume(_volumeBeforeMute ?? 100);
    } else {
      final before = _volume;
      _setVolume(0);
      _volumeBeforeMute = before;
    }
  }

  void _setRate(double rate) {
    setState(() => _rate = rate);
    _engine?.setRate(rate);
  }

  void _toggleFullscreen() {
    // Nothing to toggle on a television: it is fullscreen the whole time
    // the player is up, and F/the centre key only wake the controls.
    if (_isTv) {
      _showControls();
      return;
    }
    final on = !_fullscreenOn;
    setState(() => _fullscreenOn = on);
    (on ? _fullscreen?.enter() : _fullscreen?.exit())?.ignore();
    _showControls();
  }

  void _toggleStatsPinned() =>
      setState(() => _statsPinned = !(_statsPinned ?? false));

  // --- Tracks --------------------------------------------------------------

  void _selectAudio(TrackInfo track) {
    _tracks.value = _tracks.value.copyWith(activeAudioId: track.id);
    _engine?.setAudioTrack(track.id);
  }

  void _selectEmbeddedSubtitle(TrackInfo track) {
    _tracks.value = _tracks.value.copyWith(activeSubtitleId: track.id);
    _engine?.setSubtitleTrack(track.id);
    _client?.dispatch(
      CoreActions.playerSubtitlePreferenceChanged(
        enabled: true,
        source: 'embedded',
        language: track.language,
      ),
    );
  }

  void _selectExternalSubtitle(SubtitleInfo subtitle) {
    _tracks.value = _tracks.value.copyWith(
      activeSubtitleId: subtitle.url.toString(),
    );
    _engine?.setExternalSubtitle(
      subtitle.url,
      title: SubtitleMenu.externalLabel(subtitle),
      language: subtitle.lang.isEmpty ? null : subtitle.lang,
    );
    _client?.dispatch(
      CoreActions.playerSubtitlePreferenceChanged(
        enabled: true,
        source: 'external',
        language: subtitle.lang.isEmpty ? null : subtitle.lang,
      ),
    );
  }

  void _disableSubtitles() {
    _tracks.value = _tracks.value.copyWith(clearSubtitle: true);
    _engine?.disableSubtitles();
    _client?.dispatch(
      CoreActions.playerSubtitlePreferenceChanged(enabled: false),
    );
  }

  /// Applies the session's subtitle preference (set by an earlier pick in
  /// this Player session, e.g. the previous episode) to freshly opened
  /// media: off stays off; otherwise the first track in the preferred
  /// language, from the preferred source first. Waits for the engine to
  /// report the media loaded (see [_mediaLoaded]), then retries as tracks
  /// and addon results arrive until something matches, and counts as done
  /// only once the engine accepted the pick.
  void _maybeAutoPickSubtitles() {
    if (_autoPickedSubtitles ||
        _autoPickingSubtitles ||
        !_mediaLoaded ||
        _opened == null ||
        _handedOver) {
      return;
    }
    final state = _state;
    final preference = state?.subtitlePreference;
    if (state == null || preference == null) return;
    final before = _tracks.value;
    final Future<void>? applied;
    if (!preference.enabled) {
      _tracks.value = before.copyWith(clearSubtitle: true);
      applied = _engine?.disableSubtitles();
    } else {
      final language = preference.language;
      bool matches(String? candidate) =>
          language == null ||
          (candidate != null &&
              languageName(candidate).toLowerCase() ==
                  languageName(language).toLowerCase());
      final external = state.externalSubtitles
          .where((s) => matches(s.lang))
          .firstOrNull;
      final embedded = before.subtitle
          .where((t) => matches(t.language))
          .firstOrNull;
      final externalFirst = preference.source != 'embedded';
      if (externalFirst && external != null ||
          embedded == null && external != null) {
        _tracks.value = before.copyWith(
          activeSubtitleId: external.url.toString(),
        );
        applied = _engine?.setExternalSubtitle(
          external.url,
          title: SubtitleMenu.externalLabel(external),
          language: external.lang.isEmpty ? null : external.lang,
        );
      } else if (embedded != null) {
        _tracks.value = before.copyWith(activeSubtitleId: embedded.id);
        applied = _engine?.setSubtitleTrack(embedded.id);
      } else {
        return;
      }
    }
    if (applied == null) return;
    final url = _opened;
    _autoPickingSubtitles = true;
    applied
        .then(
          (_) {
            if (_opened == url) _autoPickedSubtitles = true;
          },
          onError: (Object _) {
            // Rejected (mpv could not add the track): show what is really
            // selected and try again on the next tracks/state change.
            if (_opened == url && mounted) _tracks.value = before;
          },
        )
        .whenComplete(() => _autoPickingSubtitles = false);
  }

  // --- Menus ---------------------------------------------------------------

  /// Shows a bottom sheet over the player. The up-next countdown does not
  /// run while one is open (the hand-off would replace the sheet's route,
  /// not this one); it resumes when the sheet closes.
  Future<void> _showSheet(WidgetBuilder builder) async {
    _controlsTimer?.cancel();
    _pauseUpNext();
    // On a television the remote opened this from a button on the bar:
    // remember which, so closing the sheet puts it back there and the
    // neighbouring menu stays one press away.
    final opener = _controlsScope.hasFocus && _isTv
        ? FocusManager.instance.primaryFocus
        : null;
    setState(() => _menuOpen = true);
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      // Size to the content (a long subtitle list scrolls within the
      // screen) rather than the fixed 9/16 of the height.
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: builder,
    );
    if (!mounted) return;
    setState(() => _menuOpen = false);
    if (opener != null &&
        opener.context != null &&
        opener.ancestors.contains(_controlsScope)) {
      opener.requestFocus();
    } else {
      _focusNode.requestFocus();
    }
    _showControls();
    _resumeUpNext();
  }

  Future<void> _openSubtitleMenu() => _showSheet(
    (context) => ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: _player!,
      builder: (context, json, _) {
        final state = json == null ? null : PlayerState.fromJson(json);
        return ValueListenableBuilder<PlaybackTracks>(
          valueListenable: _tracks,
          builder: (context, tracks, _) => SubtitleMenu(
            embedded: tracks.subtitle,
            external: state?.externalSubtitles ?? const [],
            activeId: tracks.activeSubtitleId,
            loading: state?.subtitlesLoading ?? false,
            onOff: () {
              _disableSubtitles();
              Navigator.of(context).pop();
            },
            onEmbedded: (track) {
              _selectEmbeddedSubtitle(track);
              Navigator.of(context).pop();
            },
            onExternal: (subtitle) {
              _selectExternalSubtitle(subtitle);
              Navigator.of(context).pop();
            },
          ),
        );
      },
    ),
  );

  Future<void> _openAudioMenu() => _showSheet(
    (context) => ValueListenableBuilder<PlaybackTracks>(
      valueListenable: _tracks,
      builder: (context, tracks, _) => AudioMenu(
        tracks: tracks.audio,
        activeId: tracks.activeAudioId,
        onSelect: (track) {
          _selectAudio(track);
          Navigator.of(context).pop();
        },
      ),
    ),
  );

  Future<void> _openSettings() => _showSheet(
    (context) => ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: _ctx!,
      builder: (context, _, _) => StatefulBuilder(
        builder: (context, setSheetState) {
          final settings = _settings;
          return PlayerSettingsSheet(
            rate: _rate,
            rates: PlayerScreen.rates,
            onRate: (rate) {
              _setRate(rate);
              setSheetState(() {});
            },
            settings: settings,
            onSetting: settings.isEmpty
                ? null
                : (key, value) {
                    _updateSetting(key, value);
                    setSheetState(() {});
                  },
          );
        },
      ),
    ),
  );

  // --- Next episode --------------------------------------------------------

  /// Shows the up-next card with the full `nextVideoNotificationDuration`
  /// countdown and starts it ticking (once no sheet is open; see
  /// [_showSheet]). A duration of 0 ("disabled") shows no card: the next
  /// episode plays as soon as this one ends.
  void _startUpNext() {
    final millis = _settings.nextVideoNotificationDuration;
    setState(() => _upNextSecondsLeft = (millis / 1000).ceil());
    _resumeUpNext();
  }

  /// Ticks the countdown once a second while the card shows and no sheet
  /// is open; at zero the next episode plays.
  void _resumeUpNext() {
    _pauseUpNext();
    final left = _upNextSecondsLeft;
    if (left == null || _menuOpen) return;
    if (left <= 0) {
      _playNext();
      return;
    }
    _upNextTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final left = _upNextSecondsLeft;
      if (!mounted || left == null) return;
      if (left <= 1) {
        _playNext();
      } else {
        setState(() => _upNextSecondsLeft = left - 1);
      }
    });
  }

  /// Stops the ticking but keeps the card and the seconds left on it.
  void _pauseUpNext() {
    _upNextTimer?.cancel();
    _upNextTimer = null;
  }

  void _dismissUpNext() {
    _pauseUpNext();
    if (_upNextSecondsLeft != null && mounted) {
      setState(() => _upNextSecondsLeft = null);
    }
  }

  /// Moves on to the next episode: the engine advances the library item,
  /// and either a new player takes this one's place with the stream the
  /// engine found (same addon, same binge group), or we return to the
  /// details screen pointing at the episode so its streams can be picked.
  void _playNext() {
    final state = _state;
    final next = state?.nextVideo;
    // Nothing to move on to (the next episode has gone from the state):
    // the countdown must not keep ticking.
    _dismissUpNext();
    if (state == null || next == null || _handedOver) return;
    _client?.dispatch(CoreActions.playerNextVideo());
    final nextStream = state.nextStream;
    final navigator = Navigator.of(context);
    // Whatever sits over this screen (a sheet) goes first, so that the
    // pop/replacement below acts on the player's own route.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      navigator.popUntil((candidate) => candidate == route);
    }
    if (nextStream == null) {
      navigator.pop(PlayerScreenResult(selectVideoId: next.id));
      return;
    }
    _handedOver = true;
    final streamRequest = state.streamRequest ?? widget.streamRequest;
    final subtitlesPath = state.subtitlesPath ?? widget.subtitlesPath;
    navigator.pushReplacement(
      MaterialPageRoute<PlayerScreenResult>(
        settings: const RouteSettings(name: 'player'),
        builder: (_) => PlayerScreen(
          stream: nextStream.json,
          streamRequest: streamRequest?.copyWith(
            path: streamRequest.path.copyWith(id: next.id),
          ),
          metaRequest: state.metaRequest ?? widget.metaRequest,
          subtitlesPath: subtitlesPath?.copyWith(id: next.id),
        ),
      ),
    );
  }

  // --- Keyboard ------------------------------------------------------------

  /// Moves focus onto the shown controls: [direction] down lands on
  /// play/pause in the bottom bar — or on the up-next card's "Play now"
  /// while the countdown runs, as that is the decision in front of the
  /// viewer — and up on the top bar. False when that control is not on
  /// screen (the narrow layout's transport lives in the middle of the
  /// video), leaving the key to whatever it means otherwise.
  bool _focusControls(TraversalDirection direction) {
    final node = direction == TraversalDirection.up
        ? _topBarFocus
        : _upNextSecondsLeft != null
        ? _playNextFocus
        : _playPauseFocus;
    if (node.context == null) return false;
    node.requestFocus();
    return true;
  }

  /// Up or down with a control focused: the next stop in that direction
  /// inside the bar, or back to the video when the bar ends there.
  void _moveWithinControls(TraversalDirection direction) {
    final focused = FocusManager.instance.primaryFocus;
    if (focused != null && focused.focusInDirection(direction)) return;
    _focusNode.requestFocus();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final shift = keyboard.isShiftPressed;
    final shownBefore = _controlsShown;
    _showControls();

    // A control on the bar has the remote: select presses it and left/right
    // walk the bar (the seek bar seeks; both are handled below us, before
    // this ever runs). Up and down leave the control, and the bar itself.
    // The seek bar is the exception to select: it is not a button, so the
    // key falls through to the play/pause below.
    if (_controlFocused) {
      if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown) {
        if (event is KeyDownEvent) {
          _moveWithinControls(
            key == LogicalKeyboardKey.arrowUp
                ? TraversalDirection.up
                : TraversalDirection.down,
          );
        }
        return KeyEventResult.handled;
      }
      if ((RemotePress.activateKeys.contains(key) && !_seekBarFocus.hasFocus) ||
          key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight ||
          key == LogicalKeyboardKey.tab) {
        return KeyEventResult.ignored;
      }
    }

    // The remote's centre key (and Enter, a gamepad's A) on a TV: hidden
    // controls come up, showing ones mean play/pause. Off a TV these keys
    // keep their default meaning (nothing, on the video itself).
    if (RemotePress.activateKeys.contains(key)) {
      if (!_isTv) return KeyEventResult.ignored;
      if (event is KeyDownEvent && shownBefore) {
        // On the video the centre key is the tap that [_onVideoTap]
        // handles, so with the countdown up it calls the hand-off off
        // instead of toggling playback.
        if (_upNextSecondsLeft != null) {
          _dismissUpNext();
        } else {
          _togglePlay();
        }
      }
      return KeyEventResult.handled;
    }

    // Up and down on a TV are how the remote reaches the controls; the
    // television has its own volume keys, so they never fall through to
    // the volume there. The first press only brings the controls back when
    // they had faded. Down has nothing to land on while the stream is
    // still resolving (there is no bottom bar without a video), so it
    // falls back to the top bar, which is always built.
    if (_isTv &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown)) {
      if (event is! KeyDownEvent) return KeyEventResult.handled;
      if (!shownBefore) return KeyEventResult.handled;
      final direction = key == LogicalKeyboardKey.arrowUp
          ? TraversalDirection.up
          : TraversalDirection.down;
      if (!_focusControls(direction)) _focusControls(TraversalDirection.up);
      return KeyEventResult.handled;
    }

    // Shift+I toggles the stats OSD, as in mpv; only the initial press.
    if (key == LogicalKeyboardKey.keyI) {
      if (!shift) return KeyEventResult.ignored;
      if (event is KeyDownEvent &&
          (ModalRoute.of(context)?.isCurrent ?? true)) {
        _toggleStatsPinned();
      }
      return KeyEventResult.handled;
    }
    if (shift &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      _seekBy(
        key == LogicalKeyboardKey.arrowLeft ? -_shortSeekStep : _shortSeekStep,
      );
      return KeyEventResult.handled;
    }
    switch (key) {
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.keyK:
      case LogicalKeyboardKey.mediaPlayPause:
        if (event is KeyDownEvent) _togglePlay();
      case LogicalKeyboardKey.mediaPlay:
        if (event is KeyDownEvent) _engine?.play();
      case LogicalKeyboardKey.mediaPause:
        if (event is KeyDownEvent) _engine?.pause();
      case LogicalKeyboardKey.mediaStop:
        // Stop ends the session: leave the player (unloading pauses and
        // reports the position), as the Back key does.
        if (event is KeyDownEvent) Navigator.of(context).maybePop();
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.keyJ:
      case LogicalKeyboardKey.mediaRewind:
        _seekBy(-_seekStep);
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.keyL:
      case LogicalKeyboardKey.mediaFastForward:
        _seekBy(_seekStep);
      case LogicalKeyboardKey.arrowUp:
        _setVolume(_volume + 5);
      case LogicalKeyboardKey.arrowDown:
        _setVolume(_volume - 5);
      case LogicalKeyboardKey.keyM:
        if (event is KeyDownEvent) _toggleMute();
      case LogicalKeyboardKey.keyF:
        if (event is KeyDownEvent) _toggleFullscreen();
      case LogicalKeyboardKey.escape:
        if (event is! KeyDownEvent) break;
        // `escExitFullscreen` only decides whether Esc leaves fullscreen
        // first; otherwise it leaves the player, as in stremio-web.
        if (!_isTv && _fullscreenOn && _settings.escExitFullscreen) {
          _toggleFullscreen();
        } else {
          Navigator.of(context).maybePop();
        }
      case LogicalKeyboardKey.keyS:
        if (event is KeyDownEvent) _openSubtitleMenu();
      case LogicalKeyboardKey.keyA:
        if (event is KeyDownEvent && _tracks.value.audio.length > 1) {
          _openAudioMenu();
        }
      case LogicalKeyboardKey.keyN:
      case LogicalKeyboardKey.mediaTrackNext:
        if (event is KeyDownEvent && _state?.nextVideo != null) _playNext();
      case LogicalKeyboardKey.mediaTrackPrevious:
        // There is no previous episode in the player's state; the remote's
        // previous-track key starts this one over, as music players do.
        if (event is KeyDownEvent) _seekTo(Duration.zero);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // --- Stats hover ---------------------------------------------------------

  void _onPointerMoved() {
    _showControls();
    _statsHoverTimer?.cancel();
    _statsHoverTimer = Timer(PlayerScreen.statsHoverTimeout, () {
      if (mounted && _statsHover) setState(() => _statsHover = false);
    });
    if (!_statsHover) setState(() => _statsHover = true);
  }

  void _onPointerLeft() {
    _statsHoverTimer?.cancel();
    _statsHoverTimer = null;
    if (_statsHover) setState(() => _statsHover = false);
  }

  // --- Lifecycle -----------------------------------------------------------

  @override
  void dispose() {
    _lifecycle.dispose();
    _statsHoverTimer?.cancel();
    _controlsTimer?.cancel();
    _upNextTimer?.cancel();
    _stopTorrentStats();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    if (_fullscreenOn) _fullscreen?.exit().ignore();
    final engine = _engine;
    _engine = null;
    if (engine != null) _disposeAfterFrame(engine);
    _player?.removeListener(_onPlayerState);
    _player?.dispose();
    _ctx?.removeListener(_onCtx);
    _ctx?.dispose();
    if (!_handedOver) _client?.dispatch(CoreActions.unload(CoreField.player));
    _position.dispose();
    _buffer.dispose();
    _tracks.dispose();
    _focusNode.dispose();
    _controlsScope.removeListener(_onControlsFocusChange);
    _controlsScope.dispose();
    _upNextScope.removeListener(_onControlsFocusChange);
    _upNextScope.dispose();
    _playPauseFocus.dispose();
    _seekBarFocus.dispose();
    _topBarFocus.dispose();
    _playNextFocus.dispose();
    super.dispose();
  }

  /// Releases [engine] two frames from now instead of synchronously here.
  ///
  /// This `dispose` runs while the frame that unmounts the video surface is
  /// being built, and the raster thread may still be drawing the previous
  /// frame, which references the video texture. media_kit unregisters and
  /// frees that texture from the platform thread as soon as `Player.dispose`
  /// reaches it, so disposing right away can free the texture under the
  /// raster thread (a SIGSEGV inside the engine on Linux, seen with
  /// media_kit's software-rendered texture).
  ///
  /// The engine's layer-tree pipeline holds at most two frames, so once the
  /// UI thread has produced a second frame the raster thread has finished
  /// the last one that showed the texture. [SchedulerBinding.endOfFrame]
  /// schedules a frame when none is pending, so this also works when called
  /// outside a frame.
  static void _disposeAfterFrame(PlaybackEngine engine) {
    Future<void> release() async {
      await SchedulerBinding.instance.endOfFrame;
      await SchedulerBinding.instance.endOfFrame;
      await engine.dispose();
    }

    release().ignore();
  }

  // --- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final engine = _engine;
    final startup = _startupOverlayShown;
    final status = startup ? null : _statusText(state);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= PlayerScreen.wideBreakpoint;
    final shown = _controlsShown;
    final nextVideo = state?.nextVideo;
    final upNext = _upNextSecondsLeft;
    final hasVideo = engine != null && _opened != null;
    final seekStep = _seekStep;
    if (_isTv) _scheduleFocusCheck();
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: MouseRegion(
          cursor: shown ? MouseCursor.defer : SystemMouseCursors.none,
          onEnter: (_) => _onPointerMoved(),
          onHover: (_) => _onPointerMoved(),
          onExit: (_) => _onPointerLeft(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _onVideoTap,
                onDoubleTapDown: (details) => _onVideoDoubleTap(details, width),
                onDoubleTap: () {},
                child: hasVideo
                    ? engine.buildVideo(
                        context,
                        subtitleBottomPadding: shown
                            ? PlayerScreen.subtitlePaddingWithControls
                            : PlayerScreen.subtitlePaddingBare,
                      )
                    : const SizedBox.expand(),
              ),
              if (hasVideo && _statsVisible)
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12, top: 64),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: PlaybackStatsOverlay(
                        stats: engine.stats,
                        source: _opened,
                      ),
                    ),
                  ),
                ),
              if (startup)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: TorrentStartupOverlay(stats: _torrentStats),
                  ),
                ),
              if (status != null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_engineError == null &&
                            state?.unplayableReason == null)
                          const CircularProgressIndicator()
                        else
                          const Icon(Icons.error_outline, size: 48),
                        const SizedBox(height: 12),
                        Text(status, textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                ),
              AnimatedOpacity(
                opacity: shown ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !shown,
                  child: SafeArea(
                    child: _controlsFocus(
                      Column(
                        children: [
                          PlayerTopBar(
                            title: state?.title ?? '',
                            subtitlesOn: _tracks.value.activeSubtitleId != null,
                            onSubtitles: _openSubtitleMenu,
                            onAudio: _tracks.value.audio.length > 1
                                ? _openAudioMenu
                                : null,
                            statsOn: _statsPinned ?? false,
                            onStats: _toggleStatsPinned,
                            onSettings: _openSettings,
                            onNext: nextVideo == null ? null : _playNext,
                            firstFocusNode: _topBarFocus,
                          ),
                          Expanded(
                            child:
                                !wide && hasVideo && status == null && !startup
                                ? Center(
                                    child: PlayerCenterControls(
                                      playing: _playing,
                                      seekStep: seekStep,
                                      onPlayPause: _togglePlay,
                                      onSeekBack: () => _seekBy(-seekStep),
                                      onSeekForward: () => _seekBy(seekStep),
                                    ),
                                  )
                                : const SizedBox.expand(),
                          ),
                          if (hasVideo)
                            PlayerBottomBar(
                              wide: wide,
                              playing: _playing,
                              seekStep: seekStep,
                              position: _position,
                              buffered: _buffer,
                              duration: _duration,
                              showRemaining: _showRemaining,
                              volume: _volume,
                              fullscreen: _fullscreenOn,
                              onPlayPause: _togglePlay,
                              onSeekBack: () => _seekBy(-seekStep),
                              onSeekForward: () => _seekBy(seekStep),
                              onSeek: _seekTo,
                              onScrubStart: () {
                                _scrubbing = true;
                                _controlsTimer?.cancel();
                              },
                              onScrubEnd: () {
                                _scrubbing = false;
                                _restartControlsTimer();
                              },
                              onToggleTimeDisplay: () => setState(
                                () => _showRemaining = !_showRemaining,
                              ),
                              onVolume: _setVolume,
                              onMute: _toggleMute,
                              onFullscreen: _toggleFullscreen,
                              playPauseFocusNode: _playPauseFocus,
                              seekBarFocusNode: _seekBarFocus,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (upNext != null && upNext > 0 && nextVideo != null)
                Positioned(
                  right: 16,
                  bottom: hasVideo ? 112 : 16,
                  child: SafeArea(
                    child: _upNextFocus(
                      UpNextCard(
                        label: nextVideo.seasonEpisodeLabel,
                        title: nextVideo.title,
                        secondsLeft: upNext,
                        onPlay: _playNext,
                        onDismiss: _dismissUpNext,
                        playFocusNode: _playNextFocus,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The controls in their own focus scope on a TV, so the D-pad walks the
  /// bar and this screen can tell whether the remote is on it. Off a TV
  /// they are the bare column they have always been.
  Widget _controlsFocus(Widget controls) =>
      _isTv ? FocusScope(node: _controlsScope, child: controls) : controls;

  /// The up-next card in its own scope on a TV, for the same reasons: the
  /// D-pad walks Cancel and "Play now", and leaving the card in either
  /// vertical direction hands the remote back to the video.
  Widget _upNextFocus(Widget card) =>
      _isTv ? FocusScope(node: _upNextScope, child: card) : card;

  String? _statusText(PlayerState? state) {
    if (_engineError != null) return 'Playback failed: $_engineError';
    if (state == null || !state.isLoaded) return 'Loading…';
    final unplayable = state.unplayableReason;
    if (unplayable != null) return unplayable;
    if (_opened == null) return 'Resolving stream…';
    if (_buffering) {
      return state.selectedStream?.kind == StreamKind.torrent
          ? 'Buffering from the torrent…'
          : 'Buffering…';
    }
    return null;
  }
}
