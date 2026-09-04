import 'dart:async';
import 'dart:io' show InternetAddress, Platform;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../widgets/remote_press.dart';
import '../cast/cast_client.dart';
import '../cast/cast_compatibility.dart';
import '../cast/cast_widgets.dart';
import '../details/stream_facts.dart';
import '../downloads/download_labels.dart';
import '../downloads/downloads_screen.dart';
import '../downloads/offline_play.dart';
import 'language_names.dart';
import 'playback_engine.dart';
import 'playback_stats_overlay.dart';
import 'player_controls.dart';
import 'subtitle_groups.dart';
import 'subtitle_timing.dart';
import 'torrent_stall_overlay.dart';
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
/// they show, up and down move focus onto the shown control bar, where
/// select presses the focused control and the seek bar seeks with
/// left/right, and the media keys (play, pause, play/pause, stop, fast
/// forward, rewind, next and previous track) do what they say. Once the
/// remote is on the bar the D-pad stays inside it, and Back is the way out:
/// it puts away the up-next card, then the controls, and only then leaves
/// the player. The controls fade on their own timer whether or not a
/// control holds focus, and take the remote back to the video with them.
/// The media keys work off a TV too; nothing else about the keyboard
/// changes there.
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

  /// How many times an `open` that failed while the torrent was still
  /// starting up is tried again before the failure is shown.
  static const int torrentOpenRetries = 4;

  /// How close to the duration a position has to be for an `Ended` from
  /// the engine to be the media actually ending, and the fraction of the
  /// duration that counts as the end regardless (a film whose last frames
  /// nobody sits through). See `_endLooksReal`.
  static const Duration endTolerance = Duration(seconds: 30);
  static const double endFraction = 0.98;

  /// How many times a stream that ended early is re-opened where it
  /// stopped before that is called a failure.
  static const int falseEndRecoveries = 3;

  /// The wait before the first of those retries; each further attempt waits
  /// one more multiple of it (0.7s, 1.4s, 2.1s, 2.8s: about seven seconds
  /// of patience in all, which is the order of a slow metadata fetch).
  static const Duration torrentOpenRetryBackoff = Duration(milliseconds: 700);

  /// How often it is polled once playback has begun and then stalled.
  /// Slower: nothing is waiting on the first frame any more, and a stall
  /// only has to keep a few numbers honest.
  static const Duration torrentStallStatsInterval = Duration(seconds: 2);

  /// How often it is polled when nothing is waiting for the torrent but
  /// the stats OSD is up: playback is fine, and the panel was opened on
  /// purpose to watch the swarm, so the numbers must move -- slowly, since
  /// no frame depends on them.
  static const Duration torrentStatsOverlayInterval = Duration(seconds: 5);

  /// How long the controls stay up without input while playing.
  static const Duration controlsTimeout = Duration(seconds: 3);

  /// How long the subtitle auto-pick waits for the engine to say what the
  /// video runs at before going ahead without it. One property read on a
  /// player that has already loaded its media is immediate; this only
  /// bounds a backend that answers neither way, so that a preferred
  /// subtitle is late rather than never.
  static const Duration frameRateTimeout = Duration(seconds: 2);

  static const List<double> rates = [0.75, 1, 1.25, 1.5, 2];

  /// Below this width the transport sits in the middle of the video and
  /// the volume slider is dropped (hardware keys on phones).
  static const double wideBreakpoint = 720;

  /// Where subtitles sit above the bottom of the picture at rest, as a
  /// fraction of the player's height.
  ///
  /// A fraction rather than a pixel count because the same count means
  /// different things on different screens: 24 logical px is a tenth of a
  /// phone's landscape height and a twenty-second of a desktop window's,
  /// and on a 1920x1080 television at density 320 (960x540 logical) it is
  /// the 4.5% this is. Every screen now puts them in the same place
  /// relative to the picture.
  static const double subtitleBottomFraction = 0.045;

  /// The gap left between lifted subtitles and the top of the control bar
  /// they are clearing. The lift itself is the bar's *measured* height (see
  /// [_PlayerScreenState._controlBarHeight]): the bar is built from the
  /// platform's own text and icon sizes and sits inside a safe area, so one
  /// constant cannot be right for a phone and a television at once.
  static const double subtitleControlGap = 12;

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

  /// The timing panel's own scope, on every device rather than only on a
  /// television: it is a small grid of buttons walked with the direction
  /// keys wherever it is shown, and a left press in it must never reach
  /// the seek below.
  final FocusScopeNode _timingScope = FocusScopeNode(
    debugLabel: 'player subtitle timing',
  );

  /// Where the remote lands when the timing panel opens: the shift's
  /// earlier button, with the rest a press away.
  final FocusNode _timingFocus = FocusNode(debugLabel: 'subtitle timing');

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

  /// The app's preferences, for [AppPrefs.bufferAhead]. From the
  /// [PrefsScope] the app puts above every screen; a player mounted without
  /// one (a widget test that does not care where the choice goes) gets
  /// [_ownPrefs] instead, which persists nothing.
  AppPrefs? _prefs;
  AppPrefs? _ownPrefs;

  /// This playback's read-ahead, when the viewer changed it in the settings
  /// sheet. It lives on the screen and dies with it: the next playback is
  /// back on [AppPrefs.bufferAhead], which is what "for this playback only"
  /// means.
  BufferAhead? _bufferOverride;

  /// The pin for [BufferAhead.wholeFile] is in flight.
  bool _keeping = false;

  /// What to say about the buffer choice, shown in the settings sheet: a
  /// refused pin, or that the file is being kept. Null once there is
  /// nothing to say.
  String? _bufferNote;

  /// The three above as one value the open settings sheet listens to. The
  /// sheet is a route of its own, so the screen's `setState` does not reach
  /// it -- and the pin it starts is answered while it is still up.
  final ValueNotifier<BufferAheadStatus> _bufferStatus = ValueNotifier(
    const BufferAheadStatus(BufferAhead.normal),
  );

  /// Set once moving on to the next episode has begun. Looking the episode
  /// up on the disk stands between the decision and the hand-over, and
  /// nothing on screen stops answering meanwhile, so without this a second
  /// Next -- or the countdown running out under one -- would advance the
  /// core's player twice and replace this route twice over.
  bool _advancing = false;

  /// Whether the session's subtitle preference has been applied to this
  /// media yet (once per `open`), and whether an attempt is in flight.
  bool _autoPickedSubtitles = false;
  bool _autoPickingSubtitles = false;

  /// Whether the engine has reported the opened media loaded (a duration,
  /// or that it is playing). Until then mpv is between files and refuses
  /// `sub-add` ("Cannot add track at the moment"), so the subtitle
  /// auto-pick waits for this.
  bool _mediaLoaded = false;

  /// What the video playing runs at, once the engine has said
  /// ([_sampleFrameRate]); null until then, and for a backend that cannot
  /// say at all. Read only to order the subtitle files and to re-time the
  /// one applied -- it is never shown: the point is a subtitle that keeps
  /// time, not a number to reason about.
  double? _videoFrameRate;

  /// Whether the engine has been asked and has answered (or declined, or
  /// timed out): the difference between "no rate" and "no rate yet",
  /// which is what the subtitle auto-pick waits on.
  bool _frameRateSampled = false;

  /// What the subtitles on screen are being played at: the multiplier the
  /// automatic path decided, plus whatever the viewer has since asked of
  /// it by hand.
  ///
  /// One value for both properties, because they are put back together:
  /// [_retimeSubtitles] replaces the whole of it, so a shift belongs to
  /// the file it was made for exactly as strictly as the multiplier does.
  SubtitleTiming _timing = const SubtitleTiming();

  /// Whether the timing panel is up. Not part of the OSD, so it is not
  /// what [_controlsVisible] says (see [_showSubtitleTiming]).
  bool _timingShown = false;

  /// The torrent overlays: while [_torrentStatsTimer] runs the server's
  /// stats are polled and the latest answer shown ([_torrentStats], null
  /// until the server answers for this torrent).
  ///
  /// [_torrentStatsRequest] is set for as long as the player is on a
  /// torrent -- what is polled *for* -- and the timer is what says whether
  /// anything is waiting on it: every
  /// [PlayerScreen.torrentStatsInterval] until the media loads, then off
  /// until something wants the numbers again -- a stall, at
  /// [PlayerScreen.torrentStallStatsInterval], or the stats OSD, at the
  /// slower [PlayerScreen.torrentStatsOverlayInterval] ([_syncTorrentStats],
  /// which also owns [_torrentStatsCadence], the period the running timer
  /// was built with). An engine error and dispose end both.
  ///
  /// The request asks for the stream's file, which focuses it and reports
  /// its initial window; when the server has no answer for that (an index
  /// the torrent turns out not to have) a poll asks for the torrent-level
  /// [_torrentStatsFallback] instead.
  TorrentStatsClient? _torrentStatsClient;
  TorrentStatsRequest? _torrentStatsRequest;
  TorrentStatsRequest? _torrentStatsFallback;
  Timer? _torrentStatsTimer;
  Duration? _torrentStatsCadence;
  bool _torrentStatsFetching = false;
  TorrentStats? _torrentStats;

  /// The name of the file the server says it opened for this torrent
  /// ([TorrentStats.streamName]), kept from the last answer that carried
  /// one. It is what the cast check judges the container by, above the
  /// addon's `behaviorHints.filename`: the addon claims, the server serves.
  ///
  /// Sticky on purpose. [_torrentStats] describes a moment and is dropped
  /// when it would state the past as the present, but which file this is
  /// does not go stale, and the polling stops entirely once playback is
  /// under way. It is cleared only with the torrent itself.
  String? _serverFilename;

  /// What reads [_dhtStatus] (absent the FFI one). Cheap and synchronous,
  /// so unlike the stats client above this is called directly rather than
  /// awaited.
  DhtStatus Function()? _dhtStatusProvider;

  /// The DHT's status, read once when this torrent's polling started --
  /// never on a timer of its own, and never re-read for the rest of this
  /// stream: it explains a start-up that has not found peers, and that
  /// explanation does not need to track a bootstrap that happens later.
  DhtStatus? _dhtStatus;

  /// The open being retried: the state and start position [_opened] was
  /// opened with, how many retries it has had, the timer waiting to make
  /// the next one, and the failure that would be shown if there were no
  /// more. All of it is reset by the next `open`.
  PlayerState? _openState;
  Duration _openStart = Duration.zero;
  int _openRetries = 0;

  /// When the current `open` was issued, how many times playback has run
  /// out of data since, and when the stall on now began -- the report's
  /// side of a playback that keeps stopping. See [_logStall].
  DateTime? _openedAt;
  int _stalls = 0;
  DateTime? _stallStart;

  /// How many times the engine has reported an end of file that was not
  /// one for the media on screen. See [_onFalseEnd].
  int _falseEnds = 0;

  /// How many stalls are written out one by one before only every tenth is.
  static const int _stallsLogged = 10;
  Timer? _openRetryTimer;
  String? _openError;

  /// Casting: the sender, the LAN media listener a cast URL is served from,
  /// the receivers found so far and the one that has the stream.
  ///
  /// [_castingTo] non-null is the whole of "this screen is a remote now":
  /// local playback is paused, the engine's own reports are ignored, and
  /// what is drawn and what reaches the core both come from [_castStatus].
  CastClient? _cast;
  LanMediaControl? _lanMedia;
  List<CastDevice> _castDevices = const [];
  CastDevice? _castingTo;
  CastStatus _castStatus = const CastStatus(state: CastPlayerState.idle);

  /// Whether this screen turned the LAN media listener on, and so owes it
  /// an off. A stream the receiver fetches straight from its own host needs
  /// no listener at all, and must not leave one running.
  bool _lanMediaOn = false;

  /// The last sample mpv gave for the open media, taken while the cast
  /// sheet is up: the one place the compatibility check can hear what the
  /// file actually is instead of what its name claims.
  PlaybackStats? _lastStats;
  StreamSubscription<PlaybackStats>? _castStatsSubscription;

  /// The receiver has reported the media finished and the core has been
  /// told. A receiver keeps saying so; the core hears it once.
  bool _castEnded = false;

  bool get _casting => _castingTo != null;

  bool _controlsVisible = true;
  Timer? _controlsTimer;
  bool _menuOpen = false;
  bool _scrubbing = false;

  /// The bottom control bar, so its height can be read off the frame that
  /// laid it out.
  final GlobalKey _bottomBarKey = GlobalKey(debugLabel: 'player bottom bar');

  /// How much of the picture's bottom edge the control bar covers, in
  /// logical pixels, as last laid out -- the bar's own height plus the
  /// safe area it sits inside. Null until a frame has drawn one.
  double? _controlBarHeight;
  bool _barMeasureScheduled = false;

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

  /// The app is in the background (see [_onAppHidden]): nothing on this
  /// screen is being looked at, whatever is on it.
  bool _appHidden = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: _onAppHidden,
      onShow: _onAppShown,
    );
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
    // Reading the scope here is what subscribes to it, so a default changed
    // in Settings while this player is on the stack is what the next
    // playback opens with. Above the early return: the scope can change
    // without the core client changing.
    final prefs =
        PrefsScope.maybeOf(context) ?? (_ownPrefs ??= AppPrefs.inMemory());
    if (_prefs != prefs) {
      _prefs?.removeListener(_onPrefsChanged);
      _prefs = prefs..addListener(_onPrefsChanged);
      _publishBuffer();
    }
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
    _dhtStatusProvider = PlaybackScope.dhtStatusOf(context);
    // A television has no window to be one part of: the video fills the
    // screen from the moment the player opens, with the system bars out of
    // the way, until the player is left ([dispose] leaves fullscreen,
    // unless this screen is handing over to the next episode's).
    if (_isTv) {
      _fullscreenOn = true;
      _fullscreen?.enter().ignore();
    }

    _wireCast(CastScope.of(context), CastScope.lanMediaOf(context));

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
      engine.engineLog.listen(_onEngineLog),
      engine.volume.listen((v) => setState(() => _volume = v)),
      engine.tracks.listen(_onTracks),
    ]);
  }

  PlayerState? get _state {
    final json = _player?.value;
    return json == null ? null : PlayerState.fromJson(json);
  }

  /// The profile, for the installed addons' names; null until the `ctx`
  /// field has been pulled.
  ProfileState? get _profile {
    final json = _ctx?.value;
    return json == null ? null : ProfileState.fromCtx(json);
  }

  /// What to call the addon a subtitle file came from: the installed
  /// addon's own name, else the host its manifest URL names -- the same
  /// fallback the sources list uses.
  String _subtitleAddonName(String manifestUrl) =>
      _profile?.installedAddon(manifestUrl)?.manifest.name ??
      Uri.tryParse(manifestUrl)?.host ??
      manifestUrl;

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

  /// The window was minimised, or the app went to the background: with
  /// `pauseOnMinimize` a playing video pauses, and either way the torrent
  /// polling stops -- a pinned stats panel nobody can see is no reason to
  /// keep asking the server every few seconds.
  void _onAppHidden() {
    _appHidden = true;
    if (_settings.pauseOnMinimize && _playing && !_handedOver) {
      _engine?.pause();
    }
    _syncTorrentStats();
  }

  /// Back in front: whatever was left on screen -- a stall, an open stats
  /// panel -- gets its numbers moving again.
  void _onAppShown() {
    _appHidden = false;
    _syncTorrentStats();
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
    // A different video: what the last one ran at says nothing about it,
    // and neither does the multiplier the last subtitle was re-timed by.
    _videoFrameRate = null;
    _frameRateSampled = false;
    _retimeSubtitles();
    _dismissUpNext();
    final progress = state.progress;
    final start = progress != null && progress.isResumable
        ? Duration(milliseconds: progress.timeOffset)
        : Duration.zero;
    _position.value = start;
    _cancelOpenRetry();
    _openState = state;
    _openStart = start;
    _openRetries = 0;
    _openError = null;
    _stalls = 0;
    _falseEnds = 0;
    _openedAt = DateTime.now();
    _open(
      url,
      reason: 'initial (${state.selectedStream?.kind.name ?? 'stream'})',
    );
    // After `open` is on its way: the stream request creates the torrent's
    // engine with everything the URL carries (its `f=` filters included);
    // a stats request that got there first would create it from the bare
    // hash and trackers, and the stream request would then reuse that.
    _startTorrentStats(state);
    setState(() => _engineError = null);
    _restartControlsTimer();
  }

  /// Issues the engine's `open` for [url], with the start position the
  /// current stream was resolved with. Every failure goes through
  /// [_failPlayback], which decides whether it is worth another attempt --
  /// which is why a retry is this call again and nothing else.
  void _open(Uri url, {required String reason}) {
    final state = _openState;
    DiagnosticsLog.info(
      'player',
      'open ${DiagnosticsLog.url(_mediaUrl(url))} '
          'at ${_openStart.inSeconds}s ($reason)',
    );
    _engine
        ?.open(_mediaUrl(url), start: _openStart)
        .then((_) {
          if (state != null) _reportVideoParams(state, url);
          // A re-open is a fresh `loadfile` on the same player, and what
          // is in force belongs to the playback rather than to the file
          // the demuxer just re-read: the stream is re-opened on a
          // network error and on a buffer change, both keeping the
          // position, and a correction the viewer made ten minutes ago
          // has to survive that. Writing it again is what makes the
          // guarantee ours instead of a property mpv happens to carry
          // over; on a first open it re-states what [_onPlayerState] has
          // already put back.
          if (mounted && _opened == url) _applySubtitleTiming();
        })
        .catchError((Object error) {
          if (!mounted || _opened != url) return;
          DiagnosticsLog.error('player', 'open rejected: $error');
          _failPlayback('$error');
        });
  }

  /// How far ahead this playback buffers: the viewer's override for the
  /// playback on screen, else the app-wide default.
  BufferAhead get _bufferAhead =>
      _bufferOverride ?? _prefs?.bufferAhead ?? BufferAhead.normal;

  /// The default changed in Settings while this player is up. It does not
  /// disturb a playback that has an override of its own, and it does not
  /// re-open one that has not: what the sheet shows is what the next
  /// playback starts with.
  void _onPrefsChanged() {
    if (!mounted) return;
    setState(_publishBuffer);
  }

  /// Republishes what the settings sheet shows about the buffer.
  void _publishBuffer() {
    _bufferStatus.value = BufferAheadStatus(
      _bufferAhead,
      busy: _keeping,
      note: _bufferNote,
    );
  }

  /// [url] as the engine should fetch it: the core's stream URL with
  /// `buffer=` added when it is a torrent served by the streaming server.
  ///
  /// Only then. A `url` stream is an addon's own host, which knows nothing
  /// about the parameter, and an offline `file://` URL has no server at the
  /// other end at all; adding a query to either would be noise at best.
  Uri _mediaUrl(Uri url) {
    if (!url.isScheme('http') && !url.isScheme('https')) return url;
    final stream = _state?.selectedStream ?? _state?.convertedStream;
    if (stream?.infoHash == null) return url;
    return withBufferAhead(url, _bufferAhead);
  }

  /// The viewer changed the buffer for this playback.
  ///
  /// The window itself only reaches the engine through the URL, and libmpv
  /// is already fetching the old one, so a change of window re-opens the
  /// stream at the position it is at -- one `open`, no reload of the
  /// player, no `Load Player`, and the core's own idea of the stream
  /// unchanged ([_opened] stays the URL the core published).
  /// [BufferAhead.wholeFile] additionally pins the stream as an offline
  /// download; the pin is what stores the file, so it outlives this
  /// playback and is deleted from the Downloads screen like any other.
  void _setBufferAhead(BufferAhead choice) {
    if (choice == _bufferAhead) return;
    final previousWire = _bufferAhead.wire;
    setState(() {
      _bufferOverride = choice;
      _bufferNote = choice.storesTheFile
          ? 'Keeping this file on the device. It will appear in Downloads.'
          : null;
      _publishBuffer();
    });
    if (choice.wire != previousWire) _reopenForBuffer();
    if (choice.storesTheFile) unawaited(_keepWholeFile());
  }

  /// Re-opens the stream at the position it is playing at, so a new
  /// `buffer=` takes effect without restarting the playback.
  void _reopenForBuffer() =>
      _reopenAt(_resumePosition, reason: 'reopen-buffer=${_bufferAhead.wire}');

  /// Where a re-open of the stream on screen should start.
  ///
  /// [_position] only means something once the media is in: media_kit
  /// reports `position: 0` as soon as an `open` is issued, so a re-open
  /// while the start-up card is still up would otherwise throw away the
  /// position the playback was resumed at and start the film from the
  /// beginning.
  Duration get _resumePosition => _mediaLoaded ? _position.value : _openStart;

  /// Re-opens the stream at [start] on the same engine -- no `Load Player`,
  /// no new route, and the core's idea of the stream untouched.
  void _reopenAt(Duration start, {required String reason}) {
    final url = _opened;
    if (url == null || _handedOver || _casting) return;
    _cancelOpenRetry();
    _openStart = start;
    _openRetries = 0;
    _openError = null;
    _open(url, reason: reason);
  }

  /// Pins what is playing as an offline download, which is what
  /// [BufferAhead.wholeFile] is: the existing mechanism, not a second one.
  ///
  /// A refusal is shown rather than swallowed -- a device that cannot fit
  /// the file is told so, with the numbers the server refused on -- and the
  /// choice falls back to the widest window that needs no room.
  Future<void> _keepWholeFile() async {
    final client = DownloadsScope.maybeOf(context);
    final state = _state;
    final stream = state?.selectedStream;
    final meta = state?.metaItem?.contentOrNull;
    if (client == null || state == null || stream == null || meta == null) {
      _failBuffer('This stream cannot be kept on the device.');
      return;
    }
    final videoId = state.selectedVideoId ?? meta.id;
    setState(() {
      _keeping = true;
      _publishBuffer();
    });
    DownloadAddResult? result;
    Object? thrown;
    try {
      result = await client.add(
        DownloadRequest(
          metaId: meta.id,
          videoId: videoId,
          type: meta.type,
          name: downloadName(meta, meta.videoById(videoId)),
          poster: meta.poster,
          stream: stream,
          meta: meta.json,
          streamRequest: state.streamRequest?.toJson(),
          metaRequest: state.metaRequest?.toJson(),
        ),
      );
    } catch (error) {
      thrown = error;
    }
    if (!mounted) return;
    setState(() {
      _keeping = false;
      _publishBuffer();
    });
    if (thrown != null) {
      _failBuffer('This stream could not be kept on the device.');
      return;
    }
    final failure = result!.error;
    if (failure != null) {
      _failBuffer(downloadFailureMessage(failure));
      return;
    }
    setState(() {
      _bufferNote =
          'Keeping this file on the device. It is in Downloads, where it '
          'can be deleted.';
      _publishBuffer();
    });
  }

  /// The file cannot be kept: say why, and buffer as far ahead as the
  /// server will instead, which is the most that can be done without room
  /// on the disk.
  void _failBuffer(String reason) {
    if (!mounted) return;
    setState(() {
      _bufferOverride = BufferAhead.maximum;
      _keeping = false;
      _bufferNote = '$reason Buffering as far ahead as possible instead.';
      _publishBuffer();
    });
    _reopenForBuffer();
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
    if (_handedOver || _casting) return;
    _position.value = position;
    _reportTime(position);
  }

  /// Tells the core where playback has got to, no more often than
  /// [PlayerScreen.timeReportInterval]. Shared by the local engine and the
  /// receiver, so continue-watching is kept the same way either way.
  void _reportTime(Duration position) {
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
    _cancelOpenRetry();
    final openedAt = _openedAt;
    DiagnosticsLog.info(
      'player',
      'media loaded'
          '${openedAt == null ? '' : ' after ${DateTime.now().difference(openedAt).inMilliseconds}ms'}',
    );
    setState(() {
      _mediaLoaded = true;
      // The start-up cadence is over. The torrent is not: a stall brings
      // the polling back, at once if the media arrived already stalled.
      _pauseTorrentStats();
    });
    _syncTorrentStats();
    // Before the auto-pick, which waits on its answer: the pick has to be
    // made out of the same list the menu will show.
    _sampleFrameRate();
    _maybeAutoPickSubtitles();
  }

  /// Asks the engine what the video runs at, once per opened media and as
  /// soon as there is a video to ask about.
  ///
  /// Not before the menu can be opened, though -- the Subtitles button
  /// works from the moment the controls do -- so a manual pick can still
  /// predate the answer, and a file picked in that window plays at its
  /// own timing. Nothing is hidden by the rate, so the cost is a menu
  /// ordered as the addons answered rather than a file taken away.
  ///
  /// The stats OSD samples the same property, but only while it is up.
  /// This must not depend on that, and must not turn the poll on to get
  /// one number, so it is a single read (see
  /// [PlaybackEngine.videoFrameRate]).
  void _sampleFrameRate() {
    final url = _opened;
    final engine = _engine;
    if (engine == null) {
      _onFrameRateSampled(url, null);
      return;
    }
    engine
        .videoFrameRate()
        // An engine that has not answered by now has not said, and an
        // unknown rate corrects nothing. Without the bound the auto-pick
        // below would wait on it for the whole film.
        .timeout(PlayerScreen.frameRateTimeout, onTimeout: () => null)
        .then(
          (rate) => _onFrameRateSampled(url, rate),
          // A backend that refused the read simply has not said.
          onError: (Object _) => _onFrameRateSampled(url, null),
        );
  }

  /// The engine's answer for [url], or the absence of one -- and the
  /// go-ahead for the auto-pick that was waiting on it.
  void _onFrameRateSampled(Uri? url, double? rate) {
    if (!mounted || _opened != url) return;
    setState(() {
      _videoFrameRate = rate;
      _frameRateSampled = true;
    });
    _maybeAutoPickSubtitles();
  }

  /// mpv's own error log. Not shown, only recorded: this is where the
  /// demuxer and ffmpeg name what actually went wrong (`tcp: Connection
  /// timed out`), which is the line a report needs and the one nobody can
  /// read off a phone.
  void _onEngineLog(String line) => DiagnosticsLog.warn('mpv', line);

  void _onEngineError(String error) {
    DiagnosticsLog.error('player', 'engine error: $error');
    _failPlayback(error);
  }

  /// Shows "Playback failed: [error]" in place of whatever was waiting for
  /// the media (the start-up overlay included, whose polling ends here) --
  /// unless the torrent is still starting up, in which case the open is
  /// simply tried again ([_scheduleOpenRetry]).
  void _failPlayback(String error) {
    if (_scheduleOpenRetry(error)) return;
    DiagnosticsLog.error('player', 'playback failed: $error');
    _cancelOpenRetry();
    setState(() {
      _engineError = error;
      _stopTorrentStats();
    });
  }

  // --- Retrying a slow torrent's open --------------------------------------

  /// Whether a failed `open` is worth another attempt.
  ///
  /// Only for a torrent the embedded server is serving, only before the
  /// media has loaded, and only while the server says the torrent is not
  /// ready yet -- still resolving its metadata, hash-checking, or filling
  /// the initial window -- or has not answered about it at all, which is
  /// where a start-up spends its first seconds. mpv gives up on the first
  /// refusal; the server, at that moment, has nothing to serve yet and is
  /// perfectly entitled to say so.
  ///
  /// A direct HTTP stream, a torrent the server has given up on
  /// ([TorrentPhase.error]), a phase we do not recognise, and a `ready`
  /// torrent that still would not open are all real failures: nothing about
  /// them will be different in a second.
  bool get _retryableTorrentStart {
    if (!mounted || _handedOver || _mediaLoaded) return false;
    if (_torrentStatsRequest == null) return false;
    final stats = _torrentStats;
    if (stats == null) return true;
    return switch (stats.phase) {
      TorrentPhase.resolvingMetadata ||
      TorrentPhase.checking ||
      TorrentPhase.buffering => true,
      TorrentPhase.ready || TorrentPhase.error || TorrentPhase.unknown => false,
    };
  }

  /// Answers [error] with another attempt instead of a failure, and says so.
  ///
  /// The start-up card stays up untouched meanwhile -- the poller behind it
  /// was never stopped -- so what the user sees is the torrent still
  /// starting, which is exactly what is happening. At most one attempt is
  /// ever waiting: `open`'s rejection and the engine's error stream both
  /// land here for the same failure.
  bool _scheduleOpenRetry(String error) {
    if (!_retryableTorrentStart ||
        _openRetries >= PlayerScreen.torrentOpenRetries) {
      return false;
    }
    _openError = error;
    if (_openRetryTimer != null) return true;
    _openRetries++;
    DiagnosticsLog.warn(
      'player',
      'open refused while the torrent is ${_torrentStats?.phase.name ?? 'starting'}; '
          'retry $_openRetries of ${PlayerScreen.torrentOpenRetries}',
    );
    _openRetryTimer = Timer(
      PlayerScreen.torrentOpenRetryBackoff * _openRetries,
      _retryOpen,
    );
    return true;
  }

  void _retryOpen() {
    _openRetryTimer = null;
    final url = _opened;
    if (!mounted || _handedOver || url == null) return;
    // The wait is also how the server gets to change its mind: a torrent
    // that failed while we were being patient is a failure after all.
    if (!_retryableTorrentStart) {
      _failPlayback(_openError ?? 'the torrent could not be opened');
      return;
    }
    _open(url, reason: 'retry $_openRetries');
  }

  void _cancelOpenRetry() {
    _openRetryTimer?.cancel();
    _openRetryTimer = null;
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
    _torrentStatsCadence = PlayerScreen.torrentStatsInterval;
    _torrentStatsTimer = Timer.periodic(
      PlayerScreen.torrentStatsInterval,
      (_) => _pollTorrentStats(),
    );
    _refreshDhtStatus();
  }

  /// Reads the DHT's status once: for the start-up card's one explanation
  /// (a trackerless magnet on a network where it never bootstrapped) and
  /// the stats panel's own row. Never on a timer -- called only here, when
  /// this torrent's polling begins -- and never throws: a provider that
  /// fails (the server not up yet) simply shows nothing.
  void _refreshDhtStatus() {
    final provider = _dhtStatusProvider;
    if (provider == null) {
      _dhtStatus = null;
      return;
    }
    try {
      _dhtStatus = provider();
    } on Object {
      _dhtStatus = null;
    }
  }

  /// Stops polling for good and forgets the torrent: this player will not
  /// ask about it again. Callers that need a rebuild wrap this in
  /// `setState`.
  void _stopTorrentStats() {
    _pauseTorrentStats();
    _torrentStats = null;
    _torrentStatsRequest = null;
    _torrentStatsFallback = null;
    _serverFilename = null;
    _dhtStatus = null;
  }

  /// Stops polling but keeps the torrent, so a stall or the stats OSD can
  /// pick it up again. The last answer outlives the timer, because a pause
  /// is often only the panel going away for a moment (hovering off, on a
  /// desktop) and the numbers it showed are still the numbers to show when
  /// it comes back; [_syncTorrentStats] is where they are dropped as too
  /// old to show.
  void _pauseTorrentStats() {
    _torrentStatsTimer?.cancel();
    _torrentStatsTimer = null;
    _torrentStatsCadence = null;
  }

  /// Keeps the polling in step with whoever wants the numbers, from
  /// [_onMediaLoaded], [_onBuffering], the app going to the background and
  /// back, and every change of the stats OSD's visibility. Once the media has loaded a torrent's stats are worth
  /// asking for while playback is stalled (the stall card measures them)
  /// and, more slowly, while the OSD shows them -- playback being fine is
  /// no reason for a panel someone opened to freeze. Anything else -- no
  /// watcher, a backgrounded app, a direct stream, a failure that cleared
  /// the request -- leaves no timer behind.
  void _syncTorrentStats() {
    if (!_mediaLoaded || _torrentStatsRequest == null) return;
    final cadence = _appHidden
        ? null
        : _buffering
        ? PlayerScreen.torrentStallStatsInterval
        : _statsVisible
        ? PlayerScreen.torrentStatsOverlayInterval
        : null;
    if (cadence == null) {
      _pauseTorrentStats();
      // Nobody wants numbers any more, but the cast check still wants the
      // name of the file the server opened, and a torrent that started
      // before the first poll came back has never been told one. This is
      // the one ask that would otherwise never happen: with no timer left
      // there is no later poll to carry it. Not while the app is in the
      // background, which asks the server for nothing at all; coming back
      // runs this again.
      if (!_appHidden && _serverFilename == null) _pollTorrentStats();
      return;
    }
    if (_torrentStatsTimer != null && _torrentStatsCadence == cadence) return;
    // A stall that starts under an open OSD (or ends under one) changes
    // only the pace: the last answer stands until the next one lands. The
    // same goes for a panel that comes back before the answer does. Wanting
    // the numbers again after nothing was showing them is another matter:
    // those describe a start-up, or a stall, however long ago, and the
    // stall card showing them would be stating the past as the present.
    if (_torrentStatsTimer == null && !_statsVisible) _torrentStats = null;
    _torrentStatsTimer?.cancel();
    _torrentStatsCadence = cadence;
    _torrentStatsTimer = Timer.periodic(cadence, (_) => _pollTorrentStats());
    // Unlike the start-up poll this one goes out at once: the stream
    // request created the torrent's engine long ago, so there is no
    // ordering to respect, and whoever just started watching wants numbers
    // now, not in two seconds.
    _pollTorrentStats();
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
    // Whether the answer is about the file being streamed rather than the
    // torrent as a whole. It matters for the name below: the torrent-level
    // `streamName` is the file the server *guessed*, which is the streamed
    // one only when the stream carried no `fileIdx` -- and then the primary
    // request is the torrent-level one anyway.
    var aboutTheFile = false;
    try {
      stats = await client.fetch(request);
      aboutTheFile = stats != null;
      if (stats == null &&
          fallback != null &&
          _torrentStatsRequest == request) {
        stats = await client.fetch(fallback);
      }
    } on Object {
      stats = null;
      aboutTheFile = false;
    } finally {
      _torrentStatsFetching = false;
    }
    final opened = aboutTheFile ? stats?.streamName : null;
    if (!mounted || _torrentStatsRequest != request) return;
    // The numbers describe a moment, so an answer that came back after the
    // polling stopped -- a stall that ended while the fetch was out -- is
    // not one to show. The name is not a moment: which file this is does
    // not go stale, and the poll that carries it is very often the last
    // one there will be, since the polling stops for good once playback is
    // under way. A poll that came back empty says nothing about the file
    // the server opened; only an answer that names one replaces the name.
    final names = opened != null && opened != _serverFilename;
    final counts = _torrentStatsTimer != null && stats != _torrentStats;
    if (!names && !counts) return;
    setState(() {
      if (counts) _torrentStats = stats;
      if (names) _serverFilename = opened;
    });
  }

  /// The start-up overlay replaces the status text from `open` until the
  /// media loads, for torrents the server streams.
  bool get _startupOverlayShown =>
      _torrentStatsRequest != null && !_mediaLoaded;

  /// The stall card replaces the plain spinner-and-sentence status once
  /// playback has begun: the same measurable card, for a torrent the
  /// server can still be asked about. Everything the status text puts
  /// before buffering (a failure, an unplayable stream, a stream not
  /// resolved yet) is not a stall and keeps its own presentation.
  bool _stallOverlayShown(PlayerState? state) =>
      _buffering &&
      _mediaLoaded &&
      _engineError == null &&
      _opened != null &&
      state?.unplayableReason == null &&
      _torrentStatsRequest != null;

  void _onPlaying(bool playing) {
    // While a receiver has the stream the local engine is paused on
    // purpose, and its report says nothing about what is being watched.
    if (_handedOver || _casting) return;
    if (playing) _onMediaLoaded();
    if (_playing != playing) {
      setState(() => _playing = playing);
      _showControls();
    }
    _reportPlaying(playing);
  }

  /// Tells the core whether playback is running, once per change. Shared by
  /// the local engine and the receiver, which are never both playing.
  void _reportPlaying(bool playing) {
    if (_opened == null || playing == _lastPlaying) return;
    _lastPlaying = playing;
    _client?.dispatch(CoreActions.playerPausedChanged(!playing));
  }

  void _onBuffering(bool buffering) {
    _logStall(buffering);
    setState(() => _buffering = buffering);
    _syncTorrentStats();
    _restartControlsTimer();
  }

  /// Puts a stall and its end in the report -- the shape of a playback that
  /// keeps stopping, which is invisible in the Rust half of the log.
  ///
  /// Bounded rather than complete: a playback that stalls every few seconds
  /// for an hour would otherwise be the only thing left in a 400-line ring.
  /// The first [_stallsLogged] of them are written one by one, and after
  /// that every tenth, so the pattern still shows and the rest of the
  /// session survives.
  void _logStall(bool buffering) {
    if (buffering) {
      _stalls++;
      _stallStart = DateTime.now();
      if (_stalls <= _stallsLogged || _stalls % 10 == 0) {
        DiagnosticsLog.warn(
          'player',
          'stalled at ${_position.value.inSeconds}s (stall $_stalls)',
        );
      }
      return;
    }
    final started = _stallStart;
    _stallStart = null;
    if (started == null) return;
    if (_stalls <= _stallsLogged || _stalls % 10 == 0) {
      DiagnosticsLog.info(
        'player',
        'playing again after ${DateTime.now().difference(started).inMilliseconds}ms',
      );
    }
  }

  void _onCompleted(bool completed) {
    if (!completed || _opened == null || _handedOver || _casting) return;
    final position = _position.value;
    DiagnosticsLog.info(
      'player',
      'completed at ${position.inSeconds}s of '
          '${_duration == Duration.zero ? 'unknown' : '${_duration.inSeconds}s'}',
    );
    if (!_endLooksReal(position)) {
      _onFalseEnd(position);
      return;
    }
    _client?.dispatch(CoreActions.playerEnded());
    // `bingeWatching` off: the episode just ends; the Next button remains.
    if (_state?.nextVideo != null && _settings.bingeWatching) _startUpNext();
    _showControls();
  }

  /// Whether a `completed` from the engine is the film ending.
  ///
  /// It is not always. A read that stops making progress reaches mpv as an
  /// end of file, and with `keep-open=yes` that is all it looks like: the
  /// media "completed" ten seconds into a two-hour film. Reporting that to
  /// the core marks the title watched and moves continue-watching to the
  /// end, which is not something a later correction undoes.
  ///
  /// So an ending is believed when the position is at one: within
  /// [PlayerScreen.endTolerance] of the duration, or past
  /// [PlayerScreen.endFraction] of it. With no duration known there is
  /// nothing to compare against, and only an ending that took longer than
  /// the tolerance to arrive is believed at all.
  bool _endLooksReal(Duration position) {
    if (_duration <= Duration.zero) return position > PlayerScreen.endTolerance;
    return _duration - position <= PlayerScreen.endTolerance ||
        position >= _duration * PlayerScreen.endFraction;
  }

  /// An end of file that is not the end of the film: the stream stopped
  /// producing data. Nothing is reported to the core -- no `Ended`, no
  /// up-next -- and the position is kept, because it is still where the
  /// viewer is.
  ///
  /// mpv sits at the end of the file with `keep-open=yes` and will not go
  /// on by itself, so the stream is re-opened where playback stopped, which
  /// is what recovers it. [PlayerScreen.falseEndRecoveries] of those and it
  /// is a failure like any other: a stream that ends instantly every time
  /// is broken, not slow.
  void _onFalseEnd(Duration position) {
    _falseEnds++;
    if (_falseEnds > PlayerScreen.falseEndRecoveries) {
      DiagnosticsLog.error(
        'player',
        'stream ended early $_falseEnds times; giving up',
      );
      _failPlayback('the stream stopped sending data');
      return;
    }
    DiagnosticsLog.warn(
      'player',
      'end of file at ${position.inSeconds}s is not the end of the media; '
          're-opening ($_falseEnds of ${PlayerScreen.falseEndRecoveries})',
    );
    setState(() => _buffering = true);
    _syncTorrentStats();
    _showControls();
    _reopenAt(position, reason: 'failBuffer $_falseEnds');
  }

  void _onTracks(PlaybackTracks tracks) {
    // The bars read the selection and the track count directly.
    setState(() => _tracks.value = tracks);
    _maybeAutoPickSubtitles();
  }

  // --- Controls visibility -------------------------------------------------

  /// The controls may fade only while something is playing with nothing
  /// else demanding attention.
  ///
  /// A control holding focus is deliberately not on that list. On a
  /// television the remote has nowhere to put focus but the bar, so a veto
  /// on it meant the first D-pad press disabled the fade for the rest of
  /// the session -- the OSD up for good, and the subtitles lifted clear of
  /// it for just as long. [_hideControls] takes the remote back to the
  /// video as it hides the bar, so nothing is ever left focused on
  /// something invisible. Off a television the controls are not in a focus
  /// scope at all and never vetoed anything.
  bool get _canAutoHide =>
      _playing &&
      !_menuOpen &&
      !_scrubbing &&
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
    if (!_canAutoHide || !_controlsVisible) return;
    _controlsTimer = Timer(PlayerScreen.controlsTimeout, _hideControls);
  }

  /// Puts the controls away, and on a television hands the remote back to
  /// the video in the same breath.
  ///
  /// The two go together on purpose: a focus ring that fades out with the
  /// bar is focus the viewer can no longer see, and the next press would
  /// act on a control that is not on screen.
  void _hideControls() {
    _controlsTimer?.cancel();
    _controlsTimer = null;
    if (!mounted || !_canAutoHide || !_controlsVisible) return;
    setState(() => _controlsVisible = false);
    if (_controlFocused) _focusNode.requestFocus();
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

  // --- Subtitle position ---------------------------------------------------

  /// Reads the control bar's real height off the frame that laid it out.
  ///
  /// The bar is built once per frame whether or not it is visible (it fades
  /// with an opacity, it is not taken out of the tree), so this measures the
  /// same thing at rest as it does with the OSD up, and the lift is ready
  /// before the OSD is. Only a change is written back, so the post-frame
  /// callback this schedules on every build does not rebuild anything by
  /// itself.
  void _measureControlBarAfterFrame() {
    if (_barMeasureScheduled) return;
    _barMeasureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _barMeasureScheduled = false;
      if (!mounted) return;
      final box = _bottomBarKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      // From the bottom of the picture rather than the bar's own height:
      // the safe area the bar sits inside is part of what it covers, and
      // the video runs underneath all of it.
      final covered =
          MediaQuery.sizeOf(context).height - box.localToGlobal(Offset.zero).dy;
      if (covered <= 0 || covered == _controlBarHeight) return;
      setState(() => _controlBarHeight = covered);
    });
  }

  /// How far above the bottom of the picture the subtitles are drawn.
  ///
  /// At rest a fraction of the height ([PlayerScreen.subtitleBottomFraction]);
  /// with the controls up, clear of what they actually cover. Never lower
  /// than the resting position: a bar shorter than the fraction would
  /// otherwise push the subtitles down when it appeared.
  double _subtitleBottomPadding({required bool controlsShown}) {
    final rest =
        MediaQuery.sizeOf(context).height * PlayerScreen.subtitleBottomFraction;
    final bar = _controlBarHeight;
    if (!controlsShown || bar == null) return rest;
    final lifted = bar + PlayerScreen.subtitleControlGap;
    return lifted > rest ? lifted : rest;
  }

  // --- Transport -----------------------------------------------------------

  void _togglePlay() {
    if (_casting) {
      final cast = _cast;
      (_castStatus.state.isPlaying ? cast?.pause() : cast?.play())?.ignore();
    } else {
      _engine?.playOrPause();
    }
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
    if (_casting) {
      // The receiver will report the new position itself; showing it at
      // once keeps the bar from snapping back while the round trip runs.
      setState(() => _castStatus = _castStatus.at(clamped));
      _cast?.seek(clamped).ignore();
    } else {
      _engine?.seek(clamped);
    }
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

  void _toggleStatsPinned() {
    setState(() => _statsPinned = !(_statsPinned ?? false));
    // The panel carries the torrent's numbers: showing it is what asks the
    // server for them, hiding it is what stops.
    _syncTorrentStats();
  }

  // --- Tracks --------------------------------------------------------------

  void _selectAudio(TrackInfo track) {
    _tracks.value = _tracks.value.copyWith(activeAudioId: track.id);
    _engine?.setAudioTrack(track.id);
  }

  /// Puts libmpv's subtitle multiplier where [subtitle] needs it against
  /// the video that is playing ([subtitleSpeed]), or back to 1.0 when
  /// there is no file whose own timing is in question -- an embedded
  /// track, subtitles off, another video -- and drops any hand
  /// adjustment with it.
  ///
  /// Every path that changes what is on screen calls this, which is the
  /// whole of the reset rule: the timing belongs to the player, not to
  /// the file, so one left behind by the previous pick would silently
  /// ruin a subtitle that was correct. That now covers the shift as
  /// well, and for the same reason: an offset made for a file that
  /// started late is nonsense on the next one, and mpv keeps `sub-delay`
  /// across a track change exactly as it keeps `sub-speed`.
  ///
  /// This is also where the viewer hands the speed back. It is theirs
  /// from the moment they touch the control until something changes what
  /// is shown -- switching subtitles is what gives the automatic path
  /// its file again.
  void _retimeSubtitles([SubtitleInfo? subtitle]) {
    _timing = SubtitleTiming(
      automaticSpeed: subtitle == null
          ? 1
          : subtitleSpeed(subtitle, videoFrameRate: _videoFrameRate),
    );
    _applySubtitleTiming();
  }

  /// Writes [_timing] to the player: the multiplier and the offset
  /// together, always both, so neither can be left holding a value the
  /// other half of the pair has moved on from.
  void _applySubtitleTiming() {
    final engine = _engine;
    if (engine == null) return;
    engine.setSubtitleSpeed(_timing.speed);
    engine.setSubtitleDelay(_timing.delay);
  }

  /// A press on the timing panel. The panel is rebuilt from [_timing], so
  /// a step that was refused (see [SubtitleTiming.stretchedBy]) redraws
  /// the same number rather than a number mpv is not really playing.
  void _adjustTiming(SubtitleTiming timing) {
    if (timing == _timing) return;
    setState(() => _timing = timing);
    _applySubtitleTiming();
  }

  void _selectEmbeddedSubtitle(TrackInfo track) {
    _tracks.value = _tracks.value.copyWith(activeSubtitleId: track.id);
    _retimeSubtitles();
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
    _retimeSubtitles(subtitle);
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
    _retimeSubtitles();
    _engine?.disableSubtitles();
    _client?.dispatch(
      CoreActions.playerSubtitlePreferenceChanged(enabled: false),
    );
  }

  /// Applies the session's subtitle preference (set by an earlier pick in
  /// this Player session, e.g. the previous episode) to freshly opened
  /// media: off stays off; otherwise the first track in the preferred
  /// language, from the preferred source first. Waits for the engine to
  /// report the media loaded (see [_mediaLoaded]) and to have answered
  /// about the frame rate (see [_frameRateSampled]), then retries as
  /// tracks and addon results arrive until something matches, and counts
  /// as done only once the engine accepted the pick.
  void _maybeAutoPickSubtitles() {
    if (_autoPickedSubtitles ||
        _autoPickingSubtitles ||
        !_mediaLoaded ||
        // The rate decides which file of a language fits best and what
        // it has to be re-timed by, and this applies one without the
        // viewer looking: picking before the engine has answered would
        // take the addons' first answer and play it uncorrected.
        !_frameRateSampled ||
        _opened == null ||
        _handedOver) {
      return;
    }
    final state = _state;
    final preference = state?.subtitlePreference;
    if (state == null || preference == null) return;
    final before = _tracks.value;
    // Where the multiplier has to go back to if the engine refuses the
    // pick below: the file playing now, if it is one of the addons'.
    // Putting the tracks back without this leaves the refused file's
    // multiplier on a subtitle that was in step.
    final beforeSubtitle = state.externalSubtitleSources
        .map((source) => source.subtitle)
        .where((subtitle) => subtitle.url.toString() == before.activeSubtitleId)
        .firstOrNull;
    final Future<void>? applied;
    if (!preference.enabled) {
      _tracks.value = before.copyWith(clearSubtitle: true);
      _retimeSubtitles();
      applied = _engine?.disableSubtitles();
    } else {
      final language = preference.language;
      bool matches(String? candidate) =>
          language == null ||
          (candidate != null &&
              languageName(candidate).toLowerCase() ==
                  languageName(language).toLowerCase());
      // The same list the menu is built from, in the same order. This is
      // the one path that applies a subtitle without the viewer looking,
      // so it is the one that has to take the language's best-fitting
      // file rather than whichever addon answered first.
      final offered = subtitlesByFrameRateFit(
        state.externalSubtitleSources,
        videoFrameRate: _videoFrameRate,
      );
      final external = offered
          .map((source) => source.subtitle)
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
        _retimeSubtitles(external);
        applied = _engine?.setExternalSubtitle(
          external.url,
          title: SubtitleMenu.externalLabel(external),
          language: external.lang.isEmpty ? null : external.lang,
        );
      } else if (embedded != null) {
        _tracks.value = before.copyWith(activeSubtitleId: embedded.id);
        _retimeSubtitles();
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
            // Reverting is a change of what is on screen like any other,
            // so the multiplier comes back with it.
            if (_opened == url && mounted) {
              _tracks.value = before;
              _retimeSubtitles(beforeSubtitle);
            }
          },
        )
        .whenComplete(() => _autoPickingSubtitles = false);
  }

  // --- Subtitle timing by hand ---------------------------------------------

  /// Puts the timing panel up and the remote on it.
  ///
  /// Deliberately not part of the OSD: the bar fades on its three-second
  /// timer while this stays, because adjusting means pressing and then
  /// watching the picture for several seconds to see what the press did.
  /// It is drawn outside the fade and it is not on [_canAutoHide]'s list
  /// of things that stop it -- pinning the bar up over the very picture
  /// being judged would be the wrong half of the problem to solve. What
  /// makes that safe is that the panel is visible for as long as it holds
  /// focus, which is the rule [_hideControls] keeps for the bar.
  void _showSubtitleTiming() {
    if (_timingShown) return;
    setState(() => _timingShown = true);
    // After the frame that builds it: there is no node to focus until
    // the panel is in the tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _timingShown) _timingFocus.requestFocus();
    });
  }

  /// Takes it away, and the remote back to the video with it -- a ring on
  /// a panel that is gone is focus the viewer can no longer see.
  void _hideSubtitleTiming() {
    if (!_timingShown) return;
    final focused = _timingScope.hasFocus;
    setState(() => _timingShown = false);
    if (focused) _focusNode.requestFocus();
  }

  void _toggleSubtitleTiming() {
    if (_timingShown) {
      _hideSubtitleTiming();
    } else {
      _showSubtitleTiming();
    }
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

  Future<void> _openSubtitleMenu() async {
    var adjustTiming = false;
    await _showSheet(
      (context) => ValueListenableBuilder<Map<String, dynamic>?>(
        valueListenable: _player!,
        builder: (context, json, _) {
          final state = json == null ? null : PlayerState.fromJson(json);
          return ValueListenableBuilder<PlaybackTracks>(
            valueListenable: _tracks,
            builder: (context, tracks, _) => SubtitleMenu(
              embedded: tracks.subtitle,
              groups: groupSubtitlesByLanguage(
                // Ordered before grouping, so the numbering and "the first
                // option is what a tap applies" hold over the order the
                // rows are actually in.
                subtitlesByFrameRateFit(
                  state?.externalSubtitleSources ?? const [],
                  videoFrameRate: _videoFrameRate,
                ),
                addonName: _subtitleAddonName,
                // Which rows say they will be re-timed; the same rate the
                // ordering above was decided on, so a row that says so is
                // one `subtitleSpeed` will really correct.
                videoFrameRate: _videoFrameRate,
              ),
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
              onAdjustTiming: () {
                adjustTiming = true;
                Navigator.of(context).pop();
              },
            ),
          );
        },
      ),
    );
    // Once the sheet is really gone, not from inside it: [_showSheet]
    // puts the remote back on the button that opened it as it closes,
    // which would take it straight off the panel again.
    if (adjustTiming && mounted) _showSubtitleTiming();
  }

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
      // The buffer choice is answered while the sheet is up (a whole-file
      // pin waits on the server), so the sheet listens for it rather than
      // reading it once.
      builder: (context, _, _) => ValueListenableBuilder<BufferAheadStatus>(
        valueListenable: _bufferStatus,
        builder: (context, buffer, _) => StatefulBuilder(
          builder: (context, setSheetState) {
            final settings = _settings;
            return PlayerSettingsSheet(
              onDownloads: DownloadsScope.maybeOf(context) == null
                  ? null
                  : () {
                      Navigator.of(context).pop();
                      _openDownloads();
                    },
              rate: _rate,
              rates: PlayerScreen.rates,
              onRate: (rate) {
                _setRate(rate);
                setSheetState(() {});
              },
              buffer: buffer,
              onBufferAhead: _setBufferAhead,
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
    ),
  );

  /// Everything kept on this device, from the menu of the player that is
  /// running. Nothing there opens a player of its own: a second
  /// [PlayerScreen] would load the same shared `player` field and start an
  /// engine beside the one still playing, so the list is the one that only
  /// shows and removes ([DownloadsScreen.canPlay]).
  void _openDownloads() {
    Navigator.of(context).push(DownloadsScreen.route(canPlay: false));
  }

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
  /// and either a new player takes this one's place, or we return to the
  /// details screen pointing at the episode so its streams can be picked.
  ///
  /// A finished download of that episode is what the new player gets,
  /// connection or not: a whole file on this disk is the better source,
  /// and it is the *only* one offline, where the next episode's streams
  /// never load and the engine finds nothing to binge into. Otherwise it
  /// is the stream the engine found (same addon, same binge group).
  ///
  /// Asking the registry is a round trip, so [_advancing] holds the second
  /// press: the countdown running out under a finger on Next would
  /// otherwise advance twice.
  void _playNext() {
    final state = _state;
    final next = state?.nextVideo;
    // Nothing to move on to (the next episode has gone from the state):
    // the countdown must not keep ticking.
    _dismissUpNext();
    if (state == null || next == null || _handedOver || _advancing) return;
    _advancing = true;
    _client?.dispatch(CoreActions.playerNextVideo());
    final navigator = Navigator.of(context);
    // Whatever sits over this screen (a sheet) goes first, so that the
    // pop/replacement below acts on the player's own route.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      navigator.popUntil((candidate) => candidate == route);
    }
    final downloads = DownloadsScope.maybeOf(context);
    final metaId = (state.metaRequest ?? widget.metaRequest)?.path.id;
    if (downloads == null || metaId == null) {
      _handOver(navigator, state, next, state.nextStream?.json);
      return;
    }
    unawaited(_handOverFromDisk(navigator, downloads, metaId, state, next));
  }

  /// Hands over to the next episode's own file when the registry has a
  /// finished download of it, and to whatever the engine found otherwise.
  Future<void> _handOverFromDisk(
    NavigatorState navigator,
    DownloadsClient downloads,
    String metaId,
    PlayerState state,
    VideoInfo next,
  ) async {
    final playback = await offlinePlaybackOf(downloads, metaId, next.id);
    // Gone while the registry was answering: there is no route left to
    // replace, and the screen that took ours over is not ours to steer.
    if (!mounted) return;
    _handOver(
      navigator,
      state,
      next,
      playback.stream ?? state.nextStream?.json,
    );
  }

  /// Puts a player for [next] in this screen's place, or -- with no
  /// [stream] anywhere for it -- goes back to the caller pointing at the
  /// episode so its streams can be picked.
  void _handOver(
    NavigatorState navigator,
    PlayerState state,
    VideoInfo next,
    Map<String, dynamic>? stream,
  ) {
    if (stream == null) {
      navigator.pop(PlayerScreenResult(selectVideoId: next.id));
      return;
    }
    _handedOver = true;
    DiagnosticsLog.info('player', 'handing over to the next episode');
    final streamRequest = state.streamRequest ?? widget.streamRequest;
    final subtitlesPath = state.subtitlesPath ?? widget.subtitlesPath;
    navigator.pushReplacement(
      MaterialPageRoute<PlayerScreenResult>(
        settings: const RouteSettings(name: 'player'),
        builder: (_) => PlayerScreen(
          stream: stream,
          streamRequest: streamRequest?.copyWith(
            path: streamRequest.path.copyWith(id: next.id),
          ),
          metaRequest: state.metaRequest ?? widget.metaRequest,
          subtitlesPath: subtitlesPath?.copyWith(id: next.id),
        ),
      ),
    );
  }

  // --- Casting -------------------------------------------------------------

  /// Takes the sender and the LAN media listener from the scope and starts
  /// looking for receivers, once, when the screen comes up.
  ///
  /// Discovery costs radio and battery, so it runs while a player is open
  /// and not for the life of the app; [dispose] stops it. A television
  /// starts none of it: a TV *is* a receiver, and the button that would
  /// open this is never built there.
  void _wireCast(CastClient client, LanMediaControl lanMedia) {
    _cast = client;
    _lanMedia = lanMedia;
    if (_isTv || !client.isSupported) return;
    _castDevices = client.currentDevices;
    _subscriptions.addAll([
      client.devices.listen(_onCastDevices),
      client.session.listen(_onCastSession),
      client.status.listen(_onCastStatus),
    ]);
    client.startDiscovery().ignore();
  }

  /// Whether there is anything to cast to, which is the whole condition for
  /// the button being on the bar: a sender platform, not a television, and
  /// a receiver that has actually answered.
  bool get _castAvailable =>
      !_isTv &&
      (_cast?.isSupported ?? false) &&
      (_castDevices.isNotEmpty || _casting);

  void _onCastDevices(List<CastDevice> devices) {
    if (!mounted) return;
    setState(() => _castDevices = devices);
  }

  /// The session as the sender sees it. A null while this screen thinks it
  /// is casting means the session ended somewhere else -- the receiver's
  /// own remote, the system notification, another phone -- and playback
  /// comes back to this device exactly as if Stop had been pressed here.
  void _onCastSession(CastDevice? device) {
    if (!mounted || device != null || !_casting) return;
    unawaited(_stopCast(disconnect: false));
  }

  /// What the receiver reports: what is drawn, and what the core is told.
  ///
  /// The same three actions local playback dispatches -- `TimeChanged`,
  /// `PausedChanged`, `Ended` -- so the library and continue-watching do not
  /// notice which device the pixels were on.
  void _onCastStatus(CastStatus status) {
    if (!mounted) return;
    setState(() => _castStatus = status);
    if (!_casting || _opened == null) return;
    final duration = status.duration;
    if (duration != null && duration > Duration.zero) _duration = duration;
    _position.value = status.position;
    _reportTime(status.position);
    _reportPlaying(status.state.isPlaying);
    // A receiver keeps repeating "idle, finished" once it is done; the core
    // is told the once, as mpv's own completion tells it once.
    if (status.ended && !_castEnded) {
      _castEnded = true;
      _client?.dispatch(CoreActions.playerEnded());
    }
  }

  /// The receivers, and Stop when one of them has the stream.
  ///
  /// mpv is sampled while the sheet is up, because the compatibility check
  /// would rather hear what the decoder is actually reading than what the
  /// release name claims. The subscription is what makes the engine sample
  /// at all, so it is held for exactly as long as the list is open.
  Future<void> _openCastSheet() async {
    _castStatsSubscription = _engine?.stats.listen((stats) {
      _lastStats = stats;
    });
    await _showSheet(
      (context) => CastDeviceSheet(
        devices: _castDevices,
        connected: _castingTo,
        onSelect: (device) {
          Navigator.of(context).pop();
          unawaited(_startCast(device));
        },
        onDisconnect: () {
          Navigator.of(context).pop();
          unawaited(_stopCast());
        },
      ),
    );
    await _castStatsSubscription?.cancel();
    _castStatsSubscription = null;
  }

  /// What the stream says about itself, for the compatibility check: the
  /// stream the engine resolved when there is one, else the one this screen
  /// was opened with.
  StreamFacts get _streamFacts =>
      StreamFacts.of(_state?.selectedStream ?? StreamInfo(widget.stream));

  /// Hands the stream to [device], or explains why it cannot be.
  ///
  /// Nothing is loaded until every step has answered: the stream has to be
  /// one a receiver could play at all, the session has to start, and a URL
  /// the receiver can actually fetch has to exist. A failure at any point
  /// leaves nothing behind -- no session, no LAN listener -- and says what
  /// happened.
  Future<void> _startCast(CastDevice device) async {
    final cast = _cast;
    final local = _opened;
    if (cast == null || local == null || !mounted) return;
    final state = _state;
    final compatibility = CastCompatibility.of(
      url: local,
      facts: _streamFacts,
      filename: castFilename(state, serverFilename: _serverFilename),
      stats: _lastStats,
      // A torrent the server has not named the file of yet: the answer is
      // "not until it has", and it comes without reopening anything, since
      // the poll that names it rebuilds this screen.
      containerPending: _torrentStatsRequest != null && _serverFilename == null,
    );
    if (compatibility is CastRefused) {
      await _explainCast(compatibility.explanation, title: compatibility.title);
      return;
    }
    if (!await cast.connect(device)) {
      await _explainCast('Could not start a session with ${device.name}.');
      return;
    }
    final url = await _castUrl(local, device);
    if (url == null) {
      await _endLanMedia();
      await cast.disconnect();
      await _explainCast(
        '${device.name} cannot reach this device over the network, so there '
        'is no address to give it. Casting a loopback URL it could never '
        'fetch would only look like it worked.',
      );
      return;
    }
    if (!mounted) return;
    final position = _position.value;
    // Local playback stops here, before the receiver starts: two copies of
    // the same film, a few seconds apart, is nobody's idea of casting.
    await _engine?.pause();
    setState(() {
      _castingTo = device;
      _castEnded = false;
      _castStatus = CastStatus(
        state: CastPlayerState.buffering,
        position: position,
        duration: _duration > Duration.zero ? _duration : null,
      );
    });
    await cast.load(
      CastMedia(
        url: url,
        contentType: (compatibility as CastReady).contentType,
        title: state?.title ?? '',
      ),
      start: position,
    );
  }

  /// The URL to give [device] for the stream this player has open, or null
  /// when there is none it could fetch.
  ///
  /// A stream served from somewhere else on the internet is handed over as
  /// it is; the receiver has a network connection of its own. Only a URL on
  /// this device needs the server's LAN media listener, which is therefore
  /// the only case that starts one.
  Future<Uri?> _castUrl(Uri local, CastDevice device) async {
    if (!_isLoopback(local.host)) return local;
    final lan = _lanMedia;
    if (lan == null) return null;
    try {
      await lan.setLanMedia(enabled: true);
    } catch (error) {
      if (kDebugMode) debugPrint('LAN media listener refused: $error');
      return null;
    }
    _lanMediaOn = true;
    final base = await lan.lanMediaBaseUrl(peerIp: device.address);
    if (base == null) return null;
    return local.replace(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
    );
  }

  static bool _isLoopback(String host) =>
      host == 'localhost' ||
      (InternetAddress.tryParse(host)?.isLoopback ?? false);

  /// Ends the session and brings playback back to this device, at the point
  /// the receiver had reached.
  ///
  /// [disconnect] false when the session is already gone (it ended
  /// elsewhere) and there is nothing left to end.
  Future<void> _stopCast({bool disconnect = true}) async {
    if (!_casting) return;
    final position = _castStatus.position;
    _castingTo = null;
    if (mounted) setState(() {});
    if (disconnect) await _cast?.disconnect();
    await _endLanMedia();
    if (!mounted) return;
    _position.value = position;
    await _engine?.seek(position);
    await _engine?.play();
  }

  /// Closes the LAN media listener, if this screen is what opened it. The
  /// listener exists for the length of a session and no longer, so every
  /// way out of one comes through here: Stop, a session that ended
  /// elsewhere, a failed start, and [dispose].
  Future<void> _endLanMedia() async {
    if (!_lanMediaOn) return;
    _lanMediaOn = false;
    try {
      await _lanMedia?.setLanMedia(enabled: false);
    } catch (error) {
      if (kDebugMode) debugPrint('could not stop the LAN listener: $error');
    }
  }

  /// Leaving the player while a receiver has the stream: the session goes
  /// and so does the listener. Leaving the receiver playing would mean
  /// leaving a socket open to the network for it, which is exactly what
  /// must not outlive a session.
  Future<void> _teardownCast() async {
    _castingTo = null;
    await _cast?.disconnect();
    await _endLanMedia();
  }

  /// Says why casting did not happen. A dialog, because it is the answer to
  /// something that was asked for and it is worth reading.
  Future<void> _explainCast(String explanation, {String? title}) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => CastRefusedDialog(
        explanation: explanation,
        title: title ?? CastRefusedDialog.defaultTitle,
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
  /// inside the bar -- or inside the timing panel, which is confined to
  /// its own scope for the same reason -- and nothing at all at its
  /// edges.
  ///
  /// Neither wrapping round nor stepping out onto the video. The video
  /// draws no focus ring, so it cannot be a legitimate stop while
  /// something visible is on screen, and a viewer who is not looking
  /// closely would only see the ring vanish. Back is the way out of the
  /// controls (see [_popBack]).
  void _moveWithinControls(TraversalDirection direction) {
    FocusManager.instance.primaryFocus?.focusInDirection(direction);
  }

  /// Whether Back has something to put away before it leaves the player:
  /// the timing panel first, then the up-next card, then a control bar
  /// that is up and free to go.
  ///
  /// The panel is the one rung that exists off a television too. It is
  /// opened deliberately and it does not fade, so on a phone Back is the
  /// only way out of it and on a desktop Escape comes down the same
  /// ladder; the other two are the OSD's, where the pointer hides the
  /// controls and Escape means what `escExitFullscreen` says it means, so
  /// Back and Escape keep leaving the player as they always have.
  ///
  /// A bar that cannot fade -- paused, buffering, a menu open -- is not on
  /// the ladder: there is nothing Back could do about it, so it leaves the
  /// player instead of appearing to do nothing.
  bool get _backDismisses =>
      _timingShown ||
      (_isTv &&
          (_upNextSecondsLeft != null || (_controlsVisible && _canAutoHide)));

  /// One rung down the ladder [_backDismisses] describes, most transient
  /// first. Only ever called for a Back that [PopScope] held back, so the
  /// pop itself is the last rung and is not handled here.
  void _popBack() {
    if (_timingShown) {
      _hideSubtitleTiming();
      return;
    }
    if (_upNextSecondsLeft != null) {
      _dismissUpNext();
      return;
    }
    _hideControls();
  }

  /// Leaves the player past that ladder: Stop ends the session, and what
  /// happens to be on screen at the time does not change that.
  void _leavePlayer() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // Back belongs to the route, not to this handler: Android delivers it
    // as a key first and pops only if nothing took it, and [PopScope] is
    // what answers. Above `_showControls` below, because the OSD flashing
    // up on the way out of the player would be the opposite of what the
    // press asked for.
    if (event.logicalKey == LogicalKeyboardKey.goBack) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final shift = keyboard.isShiftPressed;

    // The timing panel is a layer of its own with focus of its own: the
    // direction keys walk its buttons, select presses one (its own
    // handler has already had the key by the time this runs), Escape
    // closes it and Back comes down the ladder below. None of them are
    // the player's while it is up, and none of them bring the OSD back
    // either -- adjusting means watching the picture between presses,
    // and a bar flashing up on every one of them is the opposite of
    // that. Everything else still means what it always did.
    if (_timingScope.hasFocus) {
      if (key == LogicalKeyboardKey.escape) {
        if (event is KeyDownEvent) _hideSubtitleTiming();
        return KeyEventResult.handled;
      }
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
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight ||
          key == LogicalKeyboardKey.tab ||
          RemotePress.activateKeys.contains(key)) {
        // The panel's own traversal, and its own buttons.
        return KeyEventResult.ignored;
      }
    }

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
        // reports the position). Unlike Back it has no ladder to come down
        // first -- there is nothing transient about a stop.
        if (event is KeyDownEvent) _leavePlayer();
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
        // S is the list of subtitles; Shift+S is what to do about the
        // one that is playing.
        if (event is! KeyDownEvent) break;
        if (shift) {
          _toggleSubtitleTiming();
        } else {
          _openSubtitleMenu();
        }
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
      if (!mounted || !_statsHover) return;
      setState(() => _statsHover = false);
      _syncTorrentStats();
    });
    if (!_statsHover) {
      setState(() => _statsHover = true);
      _syncTorrentStats();
    }
  }

  void _onPointerLeft() {
    _statsHoverTimer?.cancel();
    _statsHoverTimer = null;
    if (!_statsHover) return;
    setState(() => _statsHover = false);
    _syncTorrentStats();
  }

  // --- Lifecycle -----------------------------------------------------------

  @override
  void dispose() {
    _lifecycle.dispose();
    _castStatsSubscription?.cancel();
    // Whatever else is true when this screen goes, nothing of ours is left
    // on the LAN: the session ends and the listener with it. The
    // subscriptions below are cancelled first, so nothing reports back into
    // a disposed screen while this runs.
    _cast?.stopDiscovery().ignore();
    if (_casting || _lanMediaOn) unawaited(_teardownCast());
    _cancelOpenRetry();
    _statsHoverTimer?.cancel();
    _controlsTimer?.cancel();
    _upNextTimer?.cancel();
    _stopTorrentStats();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    // A television gives the system its bars back when the player is
    // really over, not when it hands over to the next episode: the
    // replacement enters fullscreen while this screen is still alive, and
    // is disposed of after it, so exiting here would drop the *new*
    // player out of fullscreen. Off a television the successor makes no
    // such claim, and the window leaves fullscreen as it always has.
    if (_fullscreenOn && !(_isTv && _handedOver)) _fullscreen?.exit().ignore();
    final engine = _engine;
    _engine = null;
    if (engine != null) _disposeAfterFrame(engine);
    _prefs?.removeListener(_onPrefsChanged);
    _ownPrefs?.dispose();
    _bufferStatus.dispose();
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
    _timingScope.dispose();
    _timingFocus.dispose();
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
    final casting = _casting;
    // While a receiver has the stream there is no video here, nothing is
    // buffering here and no torrent is starting up for this screen: every
    // overlay about local playback is about a player that is paused.
    final startup = _startupOverlayShown && !casting;
    final status = startup || casting ? null : _statusText(state);
    final stall = status != null && _stallOverlayShown(state);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= PlayerScreen.wideBreakpoint;
    final shown = _controlsShown;
    final nextVideo = state?.nextVideo;
    final upNext = _upNextSecondsLeft;
    final hasVideo = engine != null && _opened != null && !casting;
    final seekStep = _seekStep;
    if (_isTv) _scheduleFocusCheck();
    if (hasVideo) _measureControlBarAfterFrame();
    return PopScope(
      canPop: !_backDismisses,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _popBack();
      },
      child: Scaffold(
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
                  onDoubleTapDown: (details) =>
                      _onVideoDoubleTap(details, width),
                  onDoubleTap: () {},
                  child: hasVideo
                      ? engine.buildVideo(
                          context,
                          subtitleBottomPadding: _subtitleBottomPadding(
                            controlsShown: shown,
                          ),
                        )
                      : const SizedBox.expand(),
                ),
                // Above the tap-to-show-controls surface rather than inside
                // it: its buttons are the only thing on screen while a
                // receiver has the stream, and they must not have to win an
                // arena against the video's double-tap-to-seek first.
                if (casting)
                  SafeArea(
                    child: CastRemotePanel(
                      deviceName: _castingTo!.name,
                      title: state?.title ?? '',
                      status: _castStatus,
                      onPlayPause: _togglePlay,
                      onSeek: _seekTo,
                      onStop: () => unawaited(_stopCast()),
                      playPauseFocusNode: _isTv ? _playPauseFocus : null,
                    ),
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
                          isTorrent: _torrentStatsRequest != null,
                          torrent: _torrentStats,
                          dht: _dhtStatus,
                        ),
                      ),
                    ),
                  ),
                if (startup)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: TorrentStartupOverlay(
                        stats: _torrentStats,
                        hasTrackers:
                            _torrentStatsRequest?.trackers.isNotEmpty ?? true,
                        dht: _dhtStatus,
                      ),
                    ),
                  ),
                if (status != null)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: stall
                          ? TorrentStallOverlay(stats: _torrentStats)
                          : Column(
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
                              subtitlesOn:
                                  _tracks.value.activeSubtitleId != null,
                              onSubtitles: _openSubtitleMenu,
                              onAudio: _tracks.value.audio.length > 1
                                  ? _openAudioMenu
                                  : null,
                              statsOn: _statsPinned ?? false,
                              onStats: _toggleStatsPinned,
                              onSettings: _openSettings,
                              onNext: nextVideo == null || casting
                                  ? null
                                  : _playNext,
                              onCast: _castAvailable ? _openCastSheet : null,
                              castOn: casting,
                              firstFocusNode: _topBarFocus,
                            ),
                            Expanded(
                              child:
                                  !wide &&
                                      hasVideo &&
                                      status == null &&
                                      !startup
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
                                key: _bottomBarKey,
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
                // Outside the bar's [AnimatedOpacity] on purpose: this
                // is the layer that must still be there when the OSD has
                // faded, which is the whole of what it is for. Top right,
                // opposite the stats panel and clear of the subtitles it
                // is being used to judge.
                if (_timingShown)
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 12, top: 64),
                      child: Align(
                        alignment: Alignment.topRight,
                        child: FocusScope(
                          node: _timingScope,
                          child: SubtitleTimingOverlay(
                            timing: _timing,
                            firstFocusNode: _timingFocus,
                            onShift: (step) =>
                                _adjustTiming(_timing.shiftedBy(step)),
                            onStretch: (step) =>
                                _adjustTiming(_timing.stretchedBy(step)),
                            onReset: () => _adjustTiming(_timing.automatic),
                            onClose: _hideSubtitleTiming,
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
      // For a torrent this is what the stall card says with nothing from
      // the server yet, and the whole of what a stall says without one.
      return state.selectedStream?.kind == StreamKind.torrent
          ? TorrentStallOverlay.waiting
          : 'Buffering…';
    }
    return null;
  }
}
