import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/core.dart';
import 'playback_engine.dart';
import 'playback_stats_overlay.dart';
import 'player_controls.dart';
import 'track_menus.dart';

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
/// and fullscreen, and keyboard shortcuts. They fade after
/// [controlsTimeout] while playing.
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

  /// How long the controls stay up without input while playing.
  static const Duration controlsTimeout = Duration(seconds: 3);

  /// The arrow-key / button seek step; Shift+arrows use [longSeekStep].
  static const Duration seekStep = Duration(seconds: 10);
  static const Duration longSeekStep = Duration(seconds: 60);

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

class _PlayerScreenState extends State<PlayerScreen> {
  CoreClient? _client;
  CoreFieldNotifier? _player;
  PlaybackEngine? _engine;
  FullscreenController? _fullscreen;
  ValueNotifier<SubtitleStyle>? _subtitleStyle;
  final List<StreamSubscription<void>> _subscriptions = [];
  final FocusNode _focusNode = FocusNode(debugLabel: 'player');

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

  bool _controlsVisible = true;
  Timer? _controlsTimer;
  bool _menuOpen = false;
  bool _scrubbing = false;

  /// Stats OSD visibility. Hover shows it until the pointer rests for
  /// [PlayerScreen.statsHoverTimeout]; Shift+I pins it on or off, after
  /// which hover no longer matters (a non-null [_statsPinned]).
  bool _statsHover = false;
  bool? _statsPinned;
  Timer? _statsHoverTimer;

  bool get _statsVisible => _statsPinned ?? _statsHover;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_client != null) return;
    final client = CoreScope.of(context);
    _client = client;
    _player = CoreFieldNotifier(client, CoreField.player)
      ..addListener(_onPlayerState);
    client.dispatch(
      CoreActions.loadPlayer(
        stream: widget.stream,
        streamRequest: widget.streamRequest,
        metaRequest: widget.metaRequest,
        subtitlesPath: widget.subtitlesPath,
      ),
    );

    _fullscreen = PlaybackScope.fullscreenOf(context);
    final subtitleStyle = PlaybackScope.subtitleStyleOf(context);
    _subtitleStyle = subtitleStyle..addListener(_onSubtitleStyle);

    final engine = PlaybackScope.of(context)();
    _engine = engine;
    engine.setSubtitleStyle(subtitleStyle.value);
    _subscriptions.addAll([
      engine.duration.listen((d) => setState(() => _duration = d)),
      engine.position.listen(_onPosition),
      engine.buffer.listen((b) => _buffer.value = b),
      engine.playing.listen(_onPlaying),
      engine.completed.listen(_onCompleted),
      engine.buffering.listen(_onBuffering),
      engine.errors.listen((e) => setState(() => _engineError = e)),
      engine.volume.listen((v) => setState(() => _volume = v)),
      engine.tracks.listen(_onTracks),
    ]);
  }

  PlayerState? get _state {
    final json = _player?.value;
    return json == null ? null : PlayerState.fromJson(json);
  }

  void _onPlayerState() {
    if (!mounted) return;
    final state = _state;
    final url = state?.streamingUrl;
    if (state == null || url == null || url == _opened) {
      setState(() {});
      return;
    }
    _opened = url;
    final progress = state.progress;
    final start = progress != null && progress.isResumable
        ? Duration(milliseconds: progress.timeOffset)
        : Duration.zero;
    _position.value = start;
    _engine?.open(url, start: start).catchError((Object error) {
      if (mounted) setState(() => _engineError = '$error');
    });
    setState(() => _engineError = null);
    _restartControlsTimer();
  }

  String get _device => Platform.operatingSystem;

  void _onPosition(Duration position) {
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

  void _onPlaying(bool playing) {
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
    if (!completed || _opened == null) return;
    _client?.dispatch(CoreActions.playerEnded());
    _showControls();
  }

  void _onTracks(PlaybackTracks tracks) {
    // The bars read the selection and the track count directly.
    setState(() => _tracks.value = tracks);
  }

  void _onSubtitleStyle() {
    final style = _subtitleStyle?.value;
    if (style == null) return;
    _engine?.setSubtitleStyle(style);
    if (mounted) setState(() {});
  }

  // --- Controls visibility -------------------------------------------------

  /// The controls may fade only while something is playing with nothing
  /// else demanding attention.
  bool get _canAutoHide =>
      _playing &&
      !_menuOpen &&
      !_scrubbing &&
      _opened != null &&
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
      _seekBy(-PlayerScreen.seekStep);
    } else if (x > width * 2 / 3) {
      _seekBy(PlayerScreen.seekStep);
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
    final on = !_fullscreenOn;
    setState(() => _fullscreenOn = on);
    (on ? _fullscreen?.enter() : _fullscreen?.exit())?.ignore();
    _showControls();
  }

  void _toggleStatsPinned() =>
      setState(() => _statsPinned = !(_statsPinned ?? false));

  // --- Menus ---------------------------------------------------------------

  Future<void> _showSheet(WidgetBuilder builder) async {
    _controlsTimer?.cancel();
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
    _focusNode.requestFocus();
    _showControls();
  }

  Future<void> _openSettings() => _showSheet(
    (context) => StatefulBuilder(
      builder: (context, setSheetState) => PlayerSettingsSheet(
        rate: _rate,
        rates: PlayerScreen.rates,
        onRate: (rate) {
          _setRate(rate);
          setSheetState(() {});
        },
        subtitleStyle: _subtitleStyle!,
      ),
    ),
  );

  // --- Keyboard ------------------------------------------------------------

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
    _showControls();

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
        key == LogicalKeyboardKey.arrowLeft
            ? -PlayerScreen.longSeekStep
            : PlayerScreen.longSeekStep,
      );
      return KeyEventResult.handled;
    }
    switch (key) {
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.keyK:
      case LogicalKeyboardKey.mediaPlayPause:
        if (event is KeyDownEvent) _togglePlay();
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.keyJ:
        _seekBy(-PlayerScreen.seekStep);
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.keyL:
        _seekBy(PlayerScreen.seekStep);
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
        if (_fullscreenOn) {
          _toggleFullscreen();
        } else {
          Navigator.of(context).maybePop();
        }
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
    _statsHoverTimer?.cancel();
    _controlsTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subtitleStyle?.removeListener(_onSubtitleStyle);
    if (_fullscreenOn) _fullscreen?.exit().ignore();
    final engine = _engine;
    _engine = null;
    if (engine != null) _disposeAfterFrame(engine);
    _player?.removeListener(_onPlayerState);
    _player?.dispose();
    _client?.dispatch(CoreActions.unload(CoreField.player));
    _position.dispose();
    _buffer.dispose();
    _tracks.dispose();
    _focusNode.dispose();
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
    final status = _statusText(state);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= PlayerScreen.wideBreakpoint;
    final shown = _controlsShown;
    final hasVideo = engine != null && _opened != null;
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
                    child: Column(
                      children: [
                        PlayerTopBar(
                          title: state?.title ?? '',
                          subtitlesOn: _tracks.value.activeSubtitleId != null,
                          onSubtitles: null,
                          onAudio: null,
                          statsOn: _statsPinned ?? false,
                          onStats: _toggleStatsPinned,
                          onSettings: _openSettings,
                          onNext: null,
                        ),
                        Expanded(
                          child: !wide && hasVideo && status == null
                              ? Center(
                                  child: PlayerCenterControls(
                                    playing: _playing,
                                    onPlayPause: _togglePlay,
                                    onSeekBack: () =>
                                        _seekBy(-PlayerScreen.seekStep),
                                    onSeekForward: () =>
                                        _seekBy(PlayerScreen.seekStep),
                                  ),
                                )
                              : const SizedBox.expand(),
                        ),
                        if (hasVideo)
                          PlayerBottomBar(
                            wide: wide,
                            playing: _playing,
                            position: _position,
                            buffered: _buffer,
                            duration: _duration,
                            showRemaining: _showRemaining,
                            volume: _volume,
                            fullscreen: _fullscreenOn,
                            onPlayPause: _togglePlay,
                            onSeekBack: () => _seekBy(-PlayerScreen.seekStep),
                            onSeekForward: () => _seekBy(PlayerScreen.seekStep),
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
                          ),
                      ],
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
