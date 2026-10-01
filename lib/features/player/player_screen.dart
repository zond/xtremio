import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../shell/display_frame_rate.dart';
import '../../widgets/remote_press.dart';
import '../cast/cast_client.dart';
import '../cast/cast_compatibility.dart';
import '../cast/cast_widgets.dart';
import '../details/stream_facts.dart';
import '../downloads/download_labels.dart';
import '../downloads/downloads_screen.dart';
import '../downloads/offline_play.dart';
import 'archive_route.dart';
import 'archive_sniff.dart';
import 'playback_engine.dart';
import 'playback_stats_overlay.dart';
import 'player_controls.dart';
import 'seek_hold.dart';
import 'subtitle_calibration.dart';
import 'subtitle_groups.dart';
import 'subtitle_match.dart';
import 'subtitle_timing.dart';
import 'torrent_stall_overlay.dart';
import 'torrent_startup_overlay.dart';
import 'track_menus.dart';
import '../local/local_media.dart';
import '../local/local_playback.dart';
import 'up_next_card.dart';

part 'player_screen_open.dart';
part 'player_screen_polls.dart';
part 'player_screen_subtitles.dart';
part 'player_screen_next.dart';
part 'player_screen_casting.dart';
part 'player_screen_keys.dart';
part 'player_screen_leaving.dart';

/// Plays one stream.
///
/// Dispatches `Load Player` for [stream], waits for the engine to resolve it
/// (`player.stream` becomes `Ready` with a `streaming_url`), opens that URL
/// in the [PlaybackEngine], and reports progress back so the library and
/// continue-watching stay in sync. Unloads on dispose.
///
/// The controls are our own (media_kit's are off): a top bar with the track
/// menus, a bottom bar with the seek bar, transport, time, volume and
/// fullscreen, keyboard shortcuts, and an up-next card when an episode ends.
/// They fade after [controlsTimeout] while playing.
///
/// `profile.settings` drives the seek steps (`seekTimeDuration`; Shift +
/// arrows is `seekShortTimeDuration`), whether an ending episode moves on
/// (`bingeWatching`), the up-next countdown (`nextVideoNotificationDuration`;
/// 0 plays at once), `pauseOnMinimize`, whether Esc leaves fullscreen
/// (`escExitFullscreen`), and the subtitle style.
///
/// On a TV ([DeviceScope.isTv]) the remote drives it in two modes. With the
/// OSD down there is nothing to aim at: the centre key is play/pause and
/// leaves the remote on play/pause with the bar up, so a second press
/// restarts the film; up and down bring the bar up onto the top bar and the
/// seek bar; left and right scan. With the OSD up the ordinary focus rules
/// apply: the centre key presses what is focused (play/pause on the seek bar
/// and the video), up walks the bar, and down goes to the seek bar and then
/// play/pause, so home is never more than two presses away. The D-pad stays
/// inside the bar, and Back puts away the up-next card, then the controls,
/// then leaves. The controls fade whether or not a control holds focus,
/// taking the remote back to the video, but not while paused. The media
/// keys work in both modes and off a TV.
///
/// The State is split by concern across the `player_screen_*.dart` parts.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.stream,
    this.streamRequest,
    this.metaRequest,
    this.subtitlesPath,
    this.driveOpener = const ServerDriveFileOpener(),
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

  /// What opens the next episode's linked Drive file when up-next moves on
  /// to one ([_PlayerScreenState._playNext]). A parameter for the reason
  /// `MetaDetailsScreen.driveOpener` is: a test plays a file without FFI.
  final DriveFileOpener driveOpener;

  /// The name every route that mounts this screen is pushed under, so
  /// whoever is about to open something over the player can tell there is
  /// one. There is only ever meant to be one: two of these load the same
  /// shared `player` field, and the one underneath opens the other's
  /// stream on its own engine too (see `XtremioApp`'s downloads path and
  /// [_PlayerScreenState._openDownloads]).
  static const String routeName = 'player';

  /// Minimum spacing of `TimeChanged` reports to the core.
  static const Duration timeReportInterval = Duration(seconds: 1);

  /// How long the position may stand still, with the player saying it is
  /// playing and not buffering, before the viewer is told it is waiting.
  ///
  /// mpv reports a position at least once a second while decoding, so five
  /// missed reports is unambiguous, and still a fraction of the 26 to 51 s a
  /// starved read took in the field. Longer than [controlsTimeout]: a hiccup
  /// shorter than the controls take to fade is not worth a card.
  static const Duration stuckAfter = Duration(seconds: 5);

  /// How long "this subtitle could not be loaded" stays over the picture.
  static const Duration subtitleFailureShown = Duration(seconds: 6);

  /// How often that is checked. A position that has stopped produces no
  /// events at all, which is exactly why it needs a clock and not a
  /// listener.
  static const Duration stuckInterval = Duration(seconds: 1);

  /// How far the position has to move before a player that stood still is
  /// playing again rather than twitching.
  ///
  /// A film that really resumed passes this inside a second; a decoder
  /// putting out the odd frame behind a frozen picture does not (a 4K remux
  /// frozen for seventy seconds reported a position a fraction of a second
  /// along).
  static const Duration stuckTwitch = Duration(milliseconds: 500);

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

  /// How often the server is asked what it holds of the stream on screen
  /// (the panel's cache and sharing rows): the swarm rows' slow cadence,
  /// since nothing waits on them. A constant of its own because it also runs
  /// for a proxied stream, which has no torrent poll to ride on.
  static const Duration streamNumbersInterval = Duration(seconds: 5);

  /// How long after a seek the position is checked to see whether the seek
  /// happened, and how far from the target it may land and still count.
  ///
  /// mpv seeks to a keyframe unless asked for an exact position, so a couple
  /// of seconds either way is an ordinary seek; what is watched for is a seek
  /// of minutes that leaves the position where it started. Short enough that
  /// the viewer's next press replaces the check rather than queueing behind
  /// it.
  static const Duration seekCheckDelay = Duration(seconds: 2);
  static const Duration seekTolerance = Duration(seconds: 5);

  /// How long a receiver may sit on a load before this screen asks what the
  /// LAN listener has actually been asked for.
  ///
  /// A receiver handed an address it cannot reach never says so: the connect
  /// hangs on the same splash screen a slow start shows. The wait allows for
  /// a receiver that is on its way but unhurried, and is short enough that
  /// nobody is left watching a splash screen wondering.
  static const Duration castFetchTimeout = Duration(seconds: 20);

  /// How long the controls stay up without input while playing.
  static const Duration controlsTimeout = Duration(seconds: 3);

  /// Below this width the transport sits in the middle of the video and
  /// the volume slider is dropped (hardware keys on phones).
  static const double wideBreakpoint = 720;

  /// How long the screen waits for the player to stop before it leaves
  /// anyway, and how long the teardown gets before it is logged as late.
  ///
  /// **It bounds the viewer's wait, not the teardown.** The `quit` has
  /// already gone out when it starts; expiring only means the screen stops
  /// waiting, and the teardown carries on in the background and still logs
  /// how it ended. Every teardown measured answered in well under half a
  /// second (430 ms at worst), so two seconds is about five times that. It
  /// is kept as the instrument for the one unexplained failure, a player on
  /// a Chromecast that kept downloading after its screen was left. See
  /// docs/ARCHITECTURE.md, "Leaving the player".
  static const Duration teardownBound = Duration(seconds: 2);

  /// Where subtitles sit above the bottom of the picture at rest, as a
  /// fraction of the player's height, so they sit in the same place on every
  /// screen (24 logical px on a 960x540-logical television).
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

/// What a player screen says about its playback when asked from outside
/// the widget tree: the app driver's `player` command
/// (`lib/dev/driver/`, docs/DRIVING.md) and nothing else. It reads fields
/// the screen already keeps and nothing in the app calls it; a release
/// build keeps only the interface's name.
abstract interface class PlayerProbe {
  /// The screen's playback state as JSON-ready values. Every URL in it has
  /// been through [DiagnosticsLog.url], the same rule as a log line.
  Map<String, Object?> probe();

  /// Seeks as the seek bar does ([_PlayerScreenState._seekTo]): the
  /// driver's `seek` command, since the bar takes taps at a place.
  void seekTo(Duration target);
}

class _PlayerScreenState extends State<PlayerScreen> implements PlayerProbe {
  @override
  void seekTo(Duration target) => _seekTo(target);

  @override
  Map<String, Object?> probe() => {
    'opened': _opened == null ? null : DiagnosticsLog.url(_opened!),
    'engineUrl': _engineUrl == null ? null : DiagnosticsLog.url(_engineUrl!),
    'mediaId': _playingMediaId,
    'engine': _engine != null,
    'mediaLoaded': _mediaLoaded,
    'positionMs': _position.value.inMilliseconds,
    'durationMs': _duration.inMilliseconds,
    'bufferMs': _buffer.value.inMilliseconds,
    'playing': _playing,
    'buffering': _buffering,
    'positionStuck': _positionStuck,
    'casting': _casting,
    'leaving': _leaving,
    'engineError': _engineError == null
        ? null
        : DiagnosticsLog.redactUrls(_engineError!),
    'openError': _openError == null
        ? null
        : DiagnosticsLog.redactUrls(_openError!),
  };

  CoreClient? _client;
  CoreFieldNotifier? _player;

  /// The `ctx` field, for `profile.settings`.
  CoreFieldNotifier? _ctx;

  /// The embedded server's base URL, which a stream on anybody else's host
  /// is fetched through ([proxiedThroughServer]).
  ///
  /// From `CoreInitInfo`, because it must be known before the first `open`,
  /// and `profile.settings.streamingServerUrl` arrives with a `ctx` pull that
  /// may land after the player state. The two name the same server: the
  /// profile's URL is pinned to this one (`core::pin_to_embedded`), so a
  /// torrent's URL is on it already and [_mediaUrl] only adds `buffer=`.
  ///
  /// Null only in a build that started no embedded server (nothing the app
  /// ships: a server that will not start fails the boot); the stream then
  /// plays direct.
  Uri? _serverBase;

  /// This player screen's token, `<viewer>.<screen>`: the install's viewer
  /// id ([AppPrefs.viewerId]) and this screen's number. Written into every
  /// URL this screen hands the engine -- the `/proxy` URLs (`p=`, where it
  /// is also the only thing that says which of the server's live streams
  /// are this screen's, [_closeProxiedStreams]) and the torrent's own
  /// ([withPlayerToken]) -- and what tells the server a request is the
  /// viewer's playback: the viewer's play session follows the newest screen
  /// of the viewer, so the next episode's screen moves it, and a request
  /// from an older screen (its player still reconnecting as this one takes
  /// over) moves nothing.
  ///
  /// A name, not a credential: it is acted on only through the server's
  /// bearer-protected loopback control API, and the server strips it before
  /// asking the origin for anything. Unique per screen, whole, is what a
  /// proxy close retires for good.
  late final String _proxyToken =
      '${(_prefs ?? (_ownPrefs ??= AppPrefs.inMemory())).viewerId}.${++_proxyTokenSeq}';

  /// The last screen number handed out. Seeded from the clock, not zero, so
  /// it never goes backwards across a restart of the app. The server is the
  /// app's own -- embedded, it dies with the process, and no other device's
  /// player ever uses it -- so nothing on it remembers a screen across a
  /// restart today; a number that only grows keeps that from mattering.
  static int _proxyTokenSeq = DateTime.now().millisecondsSinceEpoch;

  /// How this screen ends those streams on the way out, from
  /// [PlaybackScope].
  ProxyStreamControl? _proxyStreams;

  /// Whether any URL this player was given actually went through the
  /// proxy. A torrent does not (it is already on the server, and gets
  /// `buffer=` instead), and neither does an offline file, so those
  /// teardowns have nothing to close and do not ask.
  bool _proxiedStream = false;

  /// The settings map of the last `UpdateSettings` sent, until the next
  /// `ctx` pull: what [_settings] answers and what the next write builds
  /// on, so two chips in a row do not send the pre-first-change map.
  Map<String, dynamic>? _pendingSettings;
  late final AppLifecycleListener _lifecycle;
  PlaybackEngine? _engine;

  /// The teardown of [_engine], from the moment it was started. Held so it
  /// is started once and no more: [_leave] awaits it and [dispose] falls
  /// back to it unwatched, and a screen can go through both.
  Future<void>? _teardown;

  /// Whether the player is on its way out: the teardown has begun and the
  /// screen stays only so mpv has something to hand its last frames to. The
  /// controls come down at the same moment ([build]): media_kit throws on a
  /// player that has been released.
  bool _leaving = false;

  /// Whether this screen is still the one that should act on the player:
  /// built, and not on its way out. **Every continuation in this class asks
  /// this rather than `mounted`.**
  ///
  /// [_detach] ends everything that could *arrive* before the first `await`
  /// in [_leave], but an `await` already in flight resumes into the teardown
  /// wait, while `mounted` is still true. Without this, a cast `connect`
  /// returning during the wait hands the receiver the film after Back, and a
  /// hand-over pushes a second player over the leaving one. See
  /// docs/ARCHITECTURE.md, "Leaving the player".
  bool get _stillOurs => mounted && !_leaving;

  /// Whether [_detach] has run. Once per screen, from whichever of the two
  /// ways out reaches it first.
  bool _detached = false;
  FullscreenController? _fullscreen;
  SubtitleStyle _subtitleStyle = const SubtitleStyle();
  final List<StreamSubscription<void>> _subscriptions = [];
  final FocusNode _focusNode = FocusNode(debugLabel: 'player');

  /// [DeviceScope.isTv], read with the dependencies.
  bool _isTv = false;

  /// What the display is asked to present the film at, read with the
  /// dependencies. Only a television is ever asked (see
  /// [_onVideoFrameRate]).
  DisplayFrameRate? _displayFrameRate;

  /// Whether this player is holding a frame rate on the display, so that
  /// the release is made once and only by a player that made an ask -- and
  /// so that nothing is said to the channel at all on a phone.
  bool _frameRateAsked = false;

  /// What rate the file on screen declares (`container-fps`), remembered
  /// so the ask can be made again. The engine reports a rate once per
  /// value and never repeats it, and an ask does not survive everything
  /// that happens to a playback (see [_askDisplayFrameRate]), so a rate
  /// kept only in the event is a rate that can be lost for good.
  double? _containerFrameRate;

  /// What the display last said it is *really* refreshing at, which is a
  /// different number from [_containerFrameRate] and arrives from the
  /// other direction. Remembered for the same reason: it is reported when
  /// it changes, so a display already on the right mode reports once and
  /// then never again, and the ask can be made after that.
  double? _displayRefreshRate;

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

  /// The URL the engine was actually handed for [_opened], recorded by
  /// [_open] rather than derived again: [_mediaUrl] is not a pure function
  /// of the core's URL, and for every stream that is not a torrent it wraps
  /// the origin in this server's `/proxy` route. The server finds a stream's
  /// store by the path it is asked with, so [_heldStreamUrl] must ask with
  /// this URL and not the core's bare origin.
  ///
  /// Not an identity: a re-open for a new buffer window writes a different
  /// one for the same video. [_opened] says which video is playing.
  Uri? _engineUrl;

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

  /// **Whether the viewer is waiting**, which is not the same question as
  /// whether mpv says it is buffering.
  ///
  /// mpv's flag means its demuxer cache ran dry during playback; it does not
  /// cover a read blocked in the server while mpv seeks (one such session
  /// played nothing for three and a half minutes with no stall reported). A
  /// position that stands still while the player says it is playing cannot
  /// be fooled, so the overlay adds it, counted in ticks of
  /// [PlayerScreen.stuckInterval].
  Timer? _stuckTimer;
  int _stillTicks = 0;

  /// The position the standing-still is measured from: the last one far
  /// enough from the one before it to be film playing
  /// ([PlayerScreen.stuckTwitch]).
  Duration _stillFrom = Duration.zero;
  bool _positionStuck = false;

  /// Whether the player has reported a position at all yet.
  ///
  /// A position cannot have *stopped* moving before it has moved: until the
  /// first report there is nothing to compare against, and a player that is
  /// still opening is not one that is stuck. It is also what keeps a
  /// backend that reports no positions at all -- which is every fake -- from
  /// looking stuck forever.
  bool _positionSeen = false;

  /// Where the server is told how long the film is, which is what its
  /// retention sizes a stream's lookahead from. Not where it is told where
  /// the viewer is: it works that out from what the reads do.
  PlaybackHints? _playbackHints;

  /// How a torrent is registered with the server and played by id
  /// ([PlaybackScope.mediaIdsOf]).
  MediaIds? _mediaIds;

  /// The media id the stream [_mediaIdSource] was registered as, which mpv
  /// is handed as `xtremio://<id>` ([_mediaUrl]). Kept across re-opens of
  /// the same stream -- a retry, a false end -- so the server's answer
  /// about it is found again rather than asked again; a different stream
  /// registers anew.
  String? _mediaId;
  Uri? _mediaIdSource;

  /// The media id a player was last reported opened on
  /// ([_reportMediaOpened]): once per id, after its first resolve, since
  /// before that the server does not know which torrent the id is.
  String? _mediaOpenedReported;

  /// What a stream that failed before it loaded is asked, to tell an
  /// archive from a film ([PlaybackScope.archiveSniffOf]).
  Future<ArchiveKind?> Function(Uri url) _archiveSniff = sniffArchive;

  /// How a container that turned out to be one is handed to the server, to
  /// be read as ranges of itself ([PlaybackScope.archiveRouteOf]).
  ArchiveRouter _archiveRoute = routeArchive;

  /// The film inside the container [_opened] turned out to be, as a URL on
  /// the streaming server ([_explainArchive]). Null for every ordinary
  /// stream, which is almost all of them.
  ///
  /// It stands *in place of* [_opened] at every `open` from the moment it
  /// is set, so a re-open for a new buffer window or after a network error
  /// goes back to the film and not to the archive around it; [_opened]
  /// itself stays the URL the core published, because that is what the
  /// core's next state is compared against. Cleared with the stream.
  Uri? _translatedUrl;

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

  /// Whether the auto-pick is settled for this media (once per `open`):
  /// what is on screen is the best it can be, or every subtitle addon has
  /// answered and nothing better came. Until then each answer that lands
  /// asks again, and a better file replaces the one on screen. And
  /// whether an attempt is in flight.
  bool _autoPickedSubtitles = false;
  bool _autoPickingSubtitles = false;

  /// How good the subtitle the auto-pick put on screen is, as
  /// `_subtitleRank` scores it; null while it has put nothing there. A
  /// candidate has to beat this to replace it.
  int? _autoPickRank;

  /// Whether the viewer has said what they want of the subtitles for this
  /// media -- picked a file, an embedded track or none, or moved the timing
  /// by hand -- which leaves the auto-pick nothing to guess at.
  ///
  /// [_autoPickedSubtitles] records only that the engine *accepted* a pick,
  /// so an engine that keeps refusing one would leave the auto-pick retrying
  /// on every state and tracks event, replacing the timing and the selection
  /// under a viewer who has just adjusted them.
  bool _subtitlesChosenByHand = false;

  /// The addon files mpv has said it could not load for this media
  /// ([externalSubtitleFailure]), by URL. The auto-pick passes over them:
  /// a dead link is dead on the next tracks event too, and picking it
  /// again would only fetch it again.
  final Set<String> _deadSubtitles = {};

  /// What the last addon file put on screen replaced, for as long as it
  /// might yet turn out not to load: its URL, the tracks as they were,
  /// the file whose timing was in force, whether the auto-pick made the
  /// choice (and so should make another), and how good what it replaced
  /// was ([_autoPickRank], put back with it). `sub-add` does not answer
  /// a failure (see [externalSubtitleFailure]); the error that says so
  /// arrives on its own, and this is what it is undone from.
  ({
    String url,
    PlaybackTracks before,
    SubtitleInfo? beforeSubtitle,
    bool auto,
    int? rankBefore,
  })?
  _subtitlePick;

  /// What is said about a subtitle file that would not load, over the
  /// picture for [PlayerScreen.subtitleFailureShown]; null otherwise.
  String? _subtitleFailure;
  Timer? _subtitleFailureTimer;

  /// Whether the engine has reported the opened media loaded (a duration,
  /// or that it is playing). Until then mpv is between files and refuses
  /// `sub-add` ("Cannot add track at the moment"), so the subtitle
  /// auto-pick waits for this.
  bool _mediaLoaded = false;

  /// Whether the file the last `open` asked for has shown up: a duration, or
  /// a position past zero. Reset by every `open` ([_open]), re-opens and
  /// retries included, which is where it differs from [_mediaLoaded].
  ///
  /// media_kit's `open` stops the player first, and the stop announces
  /// itself (`position: 0`, then `duration: 0`) before a byte of the new
  /// file is read; it also reports `playing: true` as soon as the `loadfile`
  /// is issued. So a zero before this is that announcement, not the viewer
  /// at the start of the film, and neither is believed ([_onPosition],
  /// [_onDuration]): believed, it would report the viewer at the start to the
  /// core, and a re-open issued meanwhile would resume from it
  /// ([_resumePosition]).
  ///
  /// It is also where an engine error stops being fatal ([_onEngineError]).
  bool _mediaIn = false;

  /// What the viewer has asked of the subtitles on screen, and the whole
  /// of what mpv is playing them at: nothing else writes either property.
  ///
  /// One value for both, because they are put back together:
  /// [_resetSubtitleTiming] replaces the whole of it, so a shift belongs
  /// to the file it was made for exactly as strictly as the multiplier
  /// does.
  SubtitleTiming _timing = const SubtitleTiming();

  /// The marks made against the subtitle on screen, and what the last of
  /// them did. Working state, not remembered: a mark belongs to one file, so
  /// [_resetSubtitleTiming] drops them with the rest of it; only what they
  /// derive (the multiplier and offset in [_timing]) is kept.
  SubtitleCalibration _calibration = SubtitleCalibration.none;
  String? _markNote;

  /// The addon file [_timing] belongs to, and null whenever what is
  /// shown is not one -- an embedded track, subtitles off, another video.
  ///
  /// Kept because an `open` is a fresh `loadfile` and a file added with
  /// `sub-add` does not survive one: the engine drops its record of it
  /// too, so after a re-open mpv is drawing whatever it selects by its
  /// own rules. Re-applying the multiplier and the offset onto *that* is
  /// worse than doing nothing, so the file goes back first.
  SubtitleInfo? _externalSubtitle;

  /// The write of what the viewer has adjusted that has not been made yet,
  /// and null when there is nothing to write.
  ///
  /// A press does not write: the shift repeats eight times a second under a
  /// held key, and overlapping `prefsSet` calls land on FRB's worker pool in
  /// no particular order, so the file could end up holding a number the
  /// panel is not showing. The write is made when the adjusting is over --
  /// the panel closing, something changing what is on screen, or the player
  /// going away -- and it is a closure so it remembers the file the press
  /// was made on.
  VoidCallback? _pendingSync;

  /// What "Match to another subtitle" asks for a ratio and an offset,
  /// and what a widget test answers with instead of reaching FFI.
  SubtitleMatchClient? _subtitleMatchClient;

  /// Whether a measurement is running, and what the last one against the
  /// file on screen said.
  ///
  /// The note is the count either way -- it is the evidence for applying
  /// a transform and the evidence for refusing one -- and it belongs to
  /// the file it was measured for, so [_resetSubtitleTiming] drops it
  /// with everything else that file's.
  bool _matchingSubtitle = false;
  String? _subtitleMatchNote;

  /// Whether the timing panel is up. Not part of the OSD, so it is not
  /// what [_controlsVisible] says (see [_showSubtitleTiming]).
  bool _timingShown = false;

  /// The torrent overlays: while [_torrentStatsTimer] runs the server's
  /// stats are polled and the latest answer shown ([_torrentStats], null
  /// until the server answers for this torrent).
  ///
  /// [_torrentStatsRequest] is set while the player is on a torrent **this
  /// device's server is serving**; the timer says whether anything wants the
  /// numbers: [PlayerScreen.torrentStatsInterval] until the media loads,
  /// then a stall ([PlayerScreen.torrentStallStatsInterval]) or the stats
  /// OSD ([PlayerScreen.torrentStatsOverlayInterval]); [_syncTorrentStats]
  /// owns the cadence. An engine error and dispose end both. When the server
  /// has no answer for the stream's file, a poll asks for the torrent-level
  /// [_torrentStatsFallback].
  ///
  /// Null means: not a torrent, or no embedded server. Read it as "there is
  /// a torrent here we can ask our own server about".
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

  /// What the stats panel's cache and sharing rows read: what the server
  /// holds of the stream on screen, asked with [_heldStreamUrl].
  ///
  /// Polled only while the panel is up and the app is in front, at
  /// [PlayerScreen.streamNumbersInterval], proxied streams included.
  /// **[_streamNumbers] is a reading and nothing else**: set only from an
  /// answer about the URL open now, and dropped the moment nothing polls
  /// it, so the past is never shown as the present.
  StreamNumbersReader? _streamNumbersReader;
  Timer? _streamNumbersTimer;
  bool _streamNumbersFetching = false;
  StreamNumbers? _streamNumbers;

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

  /// Whether the film has actually been playing since the current `open` or
  /// the last seek, so a buffering popup from here on is a stall the server
  /// is told about ([_reportStall]) and not the window filling after a load
  /// or a seek, which the server sizes for itself.
  ///
  /// **A tick of playback in total, not one advancing report**: a scrub back
  /// decodes a few frames between rewinds, and if those re-armed this each
  /// next rewind would be reported as a stall. [_playedSinceSeek] sums the
  /// forward steps; a seek resets it.
  bool _playingNormally = false;

  /// Forward playback since the current `open` or the last seek, summed
  /// from the position reports; see [_playingNormally].
  Duration _playedSinceSeek = Duration.zero;

  /// How much film has to have played since the last seek before a
  /// buffering popup is a stall the server is told about. Two seconds: long
  /// enough that the few frames between two rewinds of a scrub back cannot
  /// reach it, short enough that a viewer who is genuinely watching has
  /// passed it before anything could stall. See [_playingNormally].
  static const Duration _playedBeforeAStallCounts = Duration(seconds: 2);

  /// The most a position can move between two reports and still be
  /// playback rather than a seek or a load; see [_playingNormally].
  static const Duration _playbackTick = Duration(seconds: 2);

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

  /// The receivers discovery has found, as a notifier because the device
  /// sheet is a route of its own: this screen's `setState` does not reach
  /// it, and a list frozen at the moment it opened is the list a viewer
  /// waiting for their television to appear watches not change.
  final ValueNotifier<List<CastDevice>> _castDeviceList = ValueNotifier(
    const [],
  );

  List<CastDevice> get _castDevices => _castDeviceList.value;
  CastDevice? _castingTo;
  CastStatus _castStatus = const CastStatus(state: CastPlayerState.idle);

  /// Whether this screen turned the LAN media listener on, and so owes it
  /// an off. A stream the receiver fetches straight from its own host needs
  /// no listener at all, and must not leave one running.
  bool _lanMediaOn = false;

  /// Runs [PlayerScreen.castFetchTimeout] after a load served off this
  /// device and asks whether the receiver ever reached us
  /// ([_castFetchCheck]). Nothing the receiver says cancels it (the receiver
  /// this exists to catch reports a healthy session); only the ways out of a
  /// session do, picking another receiver among them.
  Timer? _castFetchTimer;

  /// The last sample mpv gave for the open media, taken while the cast
  /// sheet is up: the one place the compatibility check can hear what the
  /// file actually is instead of what its name claims.
  PlaybackStats? _lastStats;
  StreamSubscription<PlaybackStats>? _castStatsSubscription;

  /// The sample asked for while the position stands still; see
  /// [_logWhatMpvIsDoing]. Held only until it answers.
  StreamSubscription<PlaybackStats>? _stuckSample;

  /// The receiver has reported the media finished and the core has been
  /// told. A receiver keeps saying so; the core hears it once.
  bool _castEnded = false;

  /// Where the receiver was told to start, and whether it has yet reported a
  /// position of its own. The Cast SDK reports status and position on two
  /// streams, and the client folds them together with the last position it
  /// saw, which before the receiver's first tick is a zero it never
  /// reported. Taken at its word, that zero reaches the core as
  /// `TimeChanged{0}` and is where local playback resumes if the session
  /// ends, so until then the handed-over position stands in
  /// ([_trustedCastStatus]).
  Duration _castHandedAt = Duration.zero;
  bool _castReported = false;

  bool get _casting => _castingTo != null;

  /// How many [_startCast]s are between asking for a session and handing the
  /// receiver the media; see [_onCastSession].
  int _castStarts = 0;

  /// How many times [_stopCast] has ended a cast: how a start that is still
  /// under way learns that the viewer pressed Stop during it.
  int _castStops = 0;

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

  /// The check waiting on the last seek this screen issued; see
  /// [_watchSeek]. At most one: a new seek replaces it, since only the
  /// last one of a run of presses is the one the viewer is waiting on.
  Timer? _seekCheck;

  /// Where the position was when that run of seeks began, and when. A
  /// press during a run keeps them: with each press moving the position
  /// optimistically, the press's own idea of where it came from is the
  /// last target rather than anywhere playback has been.
  Duration? _seekFrom;
  DateTime? _seekFromAt;

  /// The last position the engine reported, as against the one the seek
  /// bar shows -- [_seekTo] moves that one itself so the bar does not sit
  /// still under the press. Only this one is evidence about where playback
  /// really is (see [_watchSeek]). Null until the engine has said.
  Duration? _reportedPosition;

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
    _serverBase = CoreScope.initInfoOf(context)?.serverBaseUrl;
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
    final displayFrameRate = PlaybackScope.displayFrameRateOf(context);
    _displayFrameRate = displayFrameRate;
    _torrentStatsClient = PlaybackScope.torrentStatsOf(context);
    _streamNumbersReader = PlaybackScope.streamNumbersOf(context);
    _playbackHints = PlaybackScope.hintsOf(context);
    _mediaIds = PlaybackScope.mediaIdsOf(context);
    _archiveSniff = PlaybackScope.archiveSniffOf(context);
    _archiveRoute = PlaybackScope.archiveRouteOf(context);
    _subtitleMatchClient = PlaybackScope.subtitleMatchOf(context);
    _dhtStatusProvider = PlaybackScope.dhtStatusOf(context);
    _proxyStreams = PlaybackScope.proxyStreamsOf(context);
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
      engine.videoFrameRate.listen(_onVideoFrameRate),
      displayFrameRate.refreshRate.listen(_onDisplayRefreshRate),
    ]);
  }

  PlayerState? get _state => _stateOf(_player?.value);

  /// The last `player` value parsed, and what it parsed to.
  Map<String, dynamic>? _parsedJson;
  PlayerState? _parsed;

  /// [json] as a [PlayerState], parsed once per value of the field rather
  /// than once per read: a build reads [_state] several times, and the
  /// subtitle sheets several more. The field notifier replaces its map on
  /// every change and never edits one in place, so identity is the key.
  PlayerState? _stateOf(Map<String, dynamic>? json) {
    if (json == null) return null;
    if (!identical(json, _parsedJson)) {
      _parsed = PlayerState.fromJson(json);
      _parsedJson = json;
    }
    return _parsed;
  }

  /// The profile, for the installed addons' names; null until the `ctx`
  /// field has been pulled.
  ProfileState? get _profile {
    final json = _ctx?.value;
    return json == null ? null : ProfileState.fromCtx(json);
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

  /// The acceleration of a held seek key. The player's own, because the
  /// keys it answers are the ones the video has; the seek bar keeps a
  /// second one for the presses it takes while it holds focus.
  final SeekHold _seekHold = SeekHold();

  /// The arrow-key / button seek step (`seekTimeDuration`).
  Duration get _seekStep => Duration(milliseconds: _settings.seekTimeDuration);

  /// The Shift + arrow seek step (`seekShortTimeDuration`).
  Duration get _shortSeekStep =>
      Duration(milliseconds: _settings.seekShortTimeDuration);

  /// The window was minimised or the app went to the background: with
  /// `pauseOnMinimize` a playing video pauses, and the torrent polls stop,
  /// since nobody can see what they feed.
  ///
  /// The start-up poll is stopped here by hand: [_syncTorrentStats] manages
  /// only a *loaded* torrent's polling, so the start-up timer would otherwise
  /// go on firing twice a second in the background.
  void _onAppHidden() {
    _appHidden = true;
    if (_settings.pauseOnMinimize && _playing && !_handedOver) {
      _engine?.pause();
    }
    if (!_mediaLoaded) _pauseTorrentStats();
    _syncStatsPolls();
  }

  /// Back in front: whatever was left on screen -- a stall, an open stats
  /// panel, the start-up card -- gets its numbers moving again.
  void _onAppShown() {
    _appHidden = false;
    // The surface this app draws into is destroyed when it goes away and
    // a new one built on the way back, and a `Surface.setFrameRate` vote
    // lives on the surface it was made against. So a claim we still think
    // we hold is one the platform has already forgotten.
    if (_frameRateAsked) _askDisplayFrameRate();
    // A torrent still starting up: the card is back on screen, so its
    // polling comes back with it. `_syncTorrentStats` leaves this alone
    // until the media has loaded, and takes over from it then.
    if (!_mediaLoaded && _torrentStatsRequest != null) _startStartupPolling();
    _syncStatsPolls();
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
    // Another stream, so whatever the last one turned out to hold is not
    // this one's to play.
    _translatedUrl = null;
    _autoPickedSubtitles = false;
    _autoPickRank = null;
    _subtitlesChosenByHand = false;
    _mediaLoaded = false;
    // A different video: the adjustment the last subtitle was played
    // with says nothing about it, and neither does the rate the last
    // container declared -- this one reports its own, and until it does
    // there is nothing to ask again for.
    _containerFrameRate = null;
    _resetSubtitleTiming();
    _dismissUpNext();
    final progress = state.progress;
    final start = progress != null && progress.isResumable
        ? Duration(milliseconds: progress.timeOffset)
        : Duration.zero;
    _position.value = start;
    _reportedPosition = null;
    _cancelOpenRetry();
    _openState = state;
    _openStart = start;
    _openRetries = 0;
    _openError = null;
    _stalls = 0;
    _playingNormally = false;
    _playedSinceSeek = Duration.zero;
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
    _startStreamNumbers();
    setState(() => _engineError = null);
    _restartControlsTimer();
  }

  /// The default changed in Settings while this player is up. It does not
  /// disturb a playback that has an override of its own, and it does not
  /// re-open one that has not: what the sheet shows is what the next
  /// playback starts with.
  void _onPrefsChanged() {
    if (!mounted) return;
    setState(_publishBuffer);
  }

  String get _device => Platform.operatingSystem;

  void _onPosition(Duration position) {
    if (_handedOver || _casting) return;
    if (!_mediaIn) {
      // The stop an `open` starts with, announcing itself; see [_mediaIn].
      if (position == Duration.zero) return;
      _mediaIn = true;
    }
    _positionSeen = true;
    if (position != _position.value) {
      final advanced = position - _position.value;
      if (advanced > Duration.zero && advanced < _playbackTick) {
        // Summed, not taken one report at a time: see [_playingNormally].
        _playedSinceSeek += advanced;
        if (_playedSinceSeek >= _playedBeforeAStallCounts) {
          _playingNormally = true;
        }
      } else {
        // **A seek this player never made.** The remote's rewind and
        // fast-forward keys reach mpv directly, so `_seekTo` does not run. A
        // position that moves backwards, or forwards by more than a tick, is
        // a seek whoever asked for it, and what follows is a window filling.
        _playingNormally = false;
        _playedSinceSeek = Duration.zero;
      }
      // Far enough to be film, not a frame or two behind a picture that
      // is standing still ([PlayerScreen.stuckTwitch]).
      if ((position - _stillFrom).abs() >= PlayerScreen.stuckTwitch) {
        _stillTicks = 0;
        _stillFrom = position;
        if (_positionStuck) {
          DiagnosticsLog.info(
            'player',
            'playing again at ${position.inSeconds}s, after the position '
                'stood still with mpv reporting no stall',
          );
          setState(() => _positionStuck = false);
          _stuckSample?.cancel();
          _stuckSample = null;
          // The card going leaves the stall cadence behind otherwise: the
          // stats poll picks its interval only when asked to, as
          // [_onBuffering] asks.
          _syncStatsPolls();
        }
      }
    }
    _reportedPosition = position;
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
    // The same stop's `duration: 0` ([_mediaIn]). Believed, it left the
    // film with no length until the re-opened file reported one, and an
    // early end of file in that gap passed for the end of the film
    // ([_endLooksReal] with nothing to compare against).
    if (!_mediaIn && duration == Duration.zero) return;
    setState(() => _duration = duration);
    if (duration > Duration.zero) {
      _mediaIn = true;
      // **The one number the server cannot work out for itself.** Length and
      // size give the bitrate that sizes every stream's lookahead; the reads
      // cannot, since a player that is behind asks for more the instant it
      // is answered. Stated once; a cast reports it from [_onCastStatus].
      unawaited(_reportDuration(duration));
      _onMediaLoaded();
    }
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
    _startStuckWatch();
    _syncStatsPolls();
    _maybeAutoPickSubtitles();
  }

  /// Watches for a position that has stopped moving while the player says
  /// it is playing; see [_positionStuck].
  void _startStuckWatch() {
    _stuckTimer?.cancel();
    _stillTicks = 0;
    _stillFrom = Duration.zero;
    _positionSeen = false;
    _stuckTimer = Timer.periodic(
      PlayerScreen.stuckInterval,
      (_) => _checkStuck(),
    );
  }

  void _checkStuck() {
    // Paused is not waiting, mpv's own flag is already drawn, and while a
    // receiver has the stream the local position is not the viewer's.
    if (!mounted ||
        !_playing ||
        !_positionSeen ||
        _buffering ||
        _casting ||
        _handedOver) {
      _stillTicks = 0;
      _stillFrom = _position.value;
      return;
    }
    if (_positionStuck) return;
    _stillTicks++;
    final still = PlayerScreen.stuckInterval * _stillTicks;
    if (still < PlayerScreen.stuckAfter) return;
    DiagnosticsLog.warn(
      'player',
      'the position has not moved for '
          '${still.inSeconds}s at '
          '${_position.value.inSeconds}s, and mpv reports no stall',
    );
    setState(() => _positionStuck = true);
    _syncStatsPolls();
    _logWhatMpvIsDoing();
  }

  /// Logs what mpv is doing with the film, once, when the position has
  /// stood still: a frozen picture is either a decoder that cannot keep up
  /// or a read that never arrived, and one [PlaybackStats] sample (decoder,
  /// codec and size, dropped frames, demuxer cache) tells them apart.
  ///
  /// Silent on a player that will not answer: a diagnostic must not hold up
  /// anything.
  void _logWhatMpvIsDoing() {
    final engine = _engine;
    if (engine == null) return;
    _stuckSample?.cancel();
    _stuckSample = engine.stats.listen(_logStats);
  }

  /// The one sample [_logWhatMpvIsDoing] asked for, written down and the
  /// asking ended: the panel's cadence is not something a log line needs.
  void _logStats(PlaybackStats stats) {
    _stuckSample?.cancel();
    _stuckSample = null;
    if (!mounted || !_positionStuck) return;
    String? size() => stats.width == null || stats.height == null
        ? null
        : '${stats.width}x${stats.height}';
    DiagnosticsLog.info(
      'player',
      'what mpv is doing with it: '
          'hwdec=${stats.hwdec ?? '?'} '
          'video=${stats.videoCodec ?? '?'} ${size() ?? '?'} '
          'audio=${stats.audioCodec ?? '?'} '
          'fps=${stats.outputFps ?? '?'}/${stats.containerFps ?? '?'} '
          'dropped=${stats.droppedFrames ?? '?'}'
          '/${stats.decoderDroppedFrames ?? '?'} '
          'cache=${stats.cacheDuration?.inMilliseconds ?? '?'}ms '
          'paused_for_cache=${stats.pausedForCache ?? '?'}',
    );
  }

  /// mpv's own error log. Not shown, only recorded: this is where the
  /// demuxer and ffmpeg name what actually went wrong (`tcp: Connection
  /// timed out`), which is the line a report needs and the one nobody can
  /// read off a phone.
  void _onEngineLog(String line) => DiagnosticsLog.warn('mpv', line);

  /// An error from the engine, which is fatal only while the file the last
  /// `open` asked for has not shown up ([_mediaIn]).
  ///
  /// media_kit makes these out of mpv's error-level log lines
  /// ([PlaybackEngine.errors]), so after the film is in one is a log line,
  /// not the end of playback: a dead subtitle link, a damaged frame, a read
  /// that was retried. A playback that has really stopped says so on its own
  /// terms -- an early end of file ([_onFalseEnd]) or a position that stands
  /// still ([_checkStuck]).
  void _onEngineError(String error) {
    final subtitle = externalSubtitleFailure(error);
    if (subtitle != null) {
      _onSubtitleFailed(subtitle);
      return;
    }
    if (_mediaIn) {
      DiagnosticsLog.warn('player', 'engine error while playing: $error');
      return;
    }
    DiagnosticsLog.error('player', 'engine error: $error');
    _failPlayback(error);
  }

  /// The start-up overlay replaces the status text from `open` until the
  /// media loads, for torrents the server streams.
  bool get _startupOverlayShown =>
      _torrentStatsRequest != null && !_mediaLoaded;

  /// Either of the two ways of waiting; see [_positionStuck].
  bool get _waiting => _buffering || _positionStuck;

  /// The stall card replaces the plain spinner-and-sentence status once
  /// playback has begun, for a torrent the server can still be asked about.
  /// Everything the status text puts before buffering (a failure, an
  /// unplayable stream, a stream not resolved yet) keeps its own
  /// presentation.
  bool _stallOverlayShown(PlayerState? state) =>
      _waiting &&
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
    // Playing again with the rate given back: the film ended and the
    // viewer has rewound into it, or an open that failed has been retried.
    // Either way the picture is back and wants the rate the picture is.
    if (playing && !_frameRateAsked) _askDisplayFrameRate();
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
    if (buffering) _reportStall();
    setState(() => _buffering = buffering);
    _syncStatsPolls();
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
    // Nothing is being presented at the film's rate any more, and what is
    // left on screen is the up-next card and the controls.
    _releaseDisplayFrameRate();
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
    _syncStatsPolls();
    _showControls();
    _reopenAt(position, reason: 'false-end $_falseEnds');
  }

  void _onTracks(PlaybackTracks tracks) {
    // The bars read the selection and the track count directly.
    setState(() => _tracks.value = tracks);
    _maybeAutoPickSubtitles();
  }

  // --- The display's own frame rate ----------------------------------------

  /// The engine has read what rate the container declares, which is once
  /// per value: write it down and ask the display to present at it.
  ///
  /// Nothing is asked when the rate is unknown, because nothing arrives:
  /// the engine emits only a rate it read. Asking for a rate we are
  /// guessing at is worse than not asking, since what a wrong guess buys
  /// is a mode change and the same uneven cadence afterwards.
  void _onVideoFrameRate(double fps) {
    _containerFrameRate = fps;
    _askDisplayFrameRate();
  }

  /// Asks the display for [_containerFrameRate], if the file has said what
  /// it is. A television only: a phone's panel is not the film's to switch,
  /// and a desktop has no such API.
  ///
  /// Not once per file: on Android 12+ the ask is a vote on the surface
  /// Flutter draws into, which is rebuilt when the app returns from the
  /// background, and every path that releases the rate leaves the file
  /// playable (rewinding after the end). Repeating the ask is free when the
  /// panel is already on the rate.
  void _askDisplayFrameRate() {
    final fps = _containerFrameRate;
    if (!_isTv || fps == null || _engineError != null) return;
    _frameRateAsked = true;
    _displayFrameRate?.request(fps).ignore();
    // The display may already be on the rate being asked for, in which
    // case nothing changes and nothing is reported: what it last said is
    // then the whole of what will ever be said, and this is where it
    // reaches mpv.
    _applyDisplaySync();
  }

  /// The display has reported what it is really refreshing at -- at
  /// subscription, and again whenever it changes, which is how the rate
  /// that a mode switch settled on arrives.
  void _onDisplayRefreshRate(double hz) {
    _displayRefreshRate = hz;
    // Only while this player is holding a rate on the display. The first
    // reading arrives as soon as the display is listened to, which is
    // before any film has said what rate it is, and a screen nobody is
    // presenting on has no rate worth telling mpv about.
    if (_frameRateAsked) _applyDisplaySync();
  }

  /// Tells the engine what the screen is doing, so mpv can time frames
  /// against it (`MediaKitEngine.displayRateProperties`).
  ///
  /// Tied to the ask rather than to the playback: once the rate is given
  /// back the number describes a mode nobody is in, so the paths that clear
  /// the ask clear this too, through [_releaseDisplayFrameRate].
  /// [_frameRateAsked] is only ever true on a television.
  void _applyDisplaySync() {
    _engine
        ?.setDisplayRefreshRate(_frameRateAsked ? _displayRefreshRate : null)
        .ignore();
  }

  /// Gives the display's rate back: when the film ends, playback fails, the
  /// viewer leaves, and in [dispose], which every route out passes through.
  /// [_frameRateAsked] makes the repeats free.
  ///
  /// Not on a pause: a mode change costs a second of black picture each way.
  void _releaseDisplayFrameRate() {
    if (!_frameRateAsked) return;
    _frameRateAsked = false;
    _displayFrameRate?.clear().ignore();
    // And the override with it. A rate mpv is still holding after the
    // platform has taken the mode back is the stale claim this exists to
    // avoid.
    _applyDisplaySync();
  }

  // --- Controls visibility -------------------------------------------------

  /// The controls may fade only while something is playing with nothing
  /// else demanding attention.
  ///
  /// A control holding focus is deliberately not on this list: on a
  /// television the remote always has focus somewhere on the bar, so such a
  /// veto would keep the OSD up for good. [_hideControls] takes the remote
  /// back to the video as it hides the bar instead.
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
    // Nothing to fade once the player is stopping ([build]), and a timer
    // armed after [_detach] would outlive the screen.
    if (_leaving || !_canAutoHide || !_controlsVisible) return;
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

  /// The transport keys that name what they want, rather than toggling:
  /// whoever has the stream is who they are for, as for [_togglePlay].
  /// Answered locally, a phone would play the film alongside the television.
  void _play() {
    if (_casting) {
      _cast?.play().ignore();
    } else {
      _engine?.play();
    }
    _showControls();
  }

  void _pause() {
    if (_casting) {
      _cast?.pause().ignore();
    } else {
      _engine?.pause();
    }
    _showControls();
  }

  /// Puts the playback at [target] and tells everything that watches where
  /// it went.
  ///
  /// [scanning] is the distance a *step* asked for: a step is a scan that
  /// lands on a keyframe at once ([PlaybackEngine.scanBy]), where a position
  /// the viewer named (a tap on the bar) is seeked to exactly. The target is
  /// still computed here for the bar, the core and the seek check. A step
  /// that would land outside the file is the exception; see the body.
  void _seekTo(Duration target, {Duration? scanning}) {
    final from = _position.value;
    final upper = _duration > Duration.zero ? _duration : target;
    final clamped = target < Duration.zero
        ? Duration.zero
        : target > upper
        ? upper
        : target;
    _position.value = clamped;
    // The buffering that follows is the new window filling, not a stall;
    // see [_playingNormally].
    _playingNormally = false;
    _playedSinceSeek = Duration.zero;
    if (_casting) {
      // The receiver will report the new position itself; showing it at
      // once keeps the bar from snapping back while the round trip runs.
      setState(() => _castStatus = _castStatus.at(clamped));
      _cast?.seek(clamped).ignore();
    } else {
      // Relative, from where playback actually is, so a run of presses under
      // a held key adds up in libmpv as it does here.
      //
      // **Except where the step would land outside the file.** mpv reports
      // a relative seek's raw target on `time-pos` until the first frame
      // after it (a step back of 10 s from 2.586 s reports -7.414), and the
      // core, whose times are `u64`, throws the whole action out. So a step
      // off either end is asked for as the clamped position.
      if (scanning != null && clamped == target) {
        _engine?.scanBy(scanning);
      } else {
        _engine?.seek(clamped);
      }
      _watchSeek(from: from, to: clamped);
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

  /// A step of [delta]: the seek keys, the bar's own left and right, the
  /// buttons either side of play, and a double tap on the video. All of
  /// them are scanning.
  void _seekBy(Duration delta) =>
      _seekTo(_position.value + delta, scanning: delta);

  /// Logs the one thing about a seek nobody watching can see: that it did
  /// not happen.
  ///
  /// mpv refuses a seek the demuxer calls unseekable (for instance when a
  /// Matroska index has not arrived) and restores the position, which from
  /// the sofa looks like the film jumping back. The stats OSD shows mpv's
  /// own answer (`PlaybackStats.seekable`); this asks it of the playback, so
  /// a report taken without the panel still shows it. One info line per
  /// seek; a burst of presses is one check.
  void _watchSeek({required Duration from, required Duration to}) {
    _seekCheck?.cancel();
    final start = _seekFrom ?? from;
    final startedAt = _seekFromAt ?? DateTime.now();
    _seekFrom = start;
    _seekFromAt = startedAt;
    _seekCheck = Timer(PlayerScreen.seekCheckDelay, () {
      _seekCheck = null;
      _seekFrom = null;
      _seekFromAt = null;
      if (!mounted || _handedOver || _casting) return;
      // The engine's own position, never the bar's: [_seekTo] writes the
      // target there, and a refusal while paused moves nothing, so the bar
      // would say the seek landed.
      final now = _reportedPosition;
      if (now == null) return;
      if ((now - to).abs() <= PlayerScreen.seekTolerance) return;
      // Playback goes on while the check waits, so "back where it
      // started" is the starting position plus however long the run of
      // presses and the wait after it took. Anywhere else and something
      // other than a refusal moved the position -- a re-open, the film
      // ending -- and this line would name the wrong cause.
      final elapsed = DateTime.now().difference(startedAt);
      final drift = now - start;
      if (drift < -PlayerScreen.seekTolerance ||
          drift > elapsed + PlayerScreen.seekTolerance) {
        return;
      }
      DiagnosticsLog.info(
        'player',
        'seek to ${to.inSeconds}s did not take: the position is back at '
            '${now.inSeconds}s (from ${start.inSeconds}s)',
      );
    });
  }

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
    _syncStatsPolls();
  }

  // --- Tracks --------------------------------------------------------------

  void _selectAudio(TrackInfo track) {
    _tracks.value = _tracks.value.copyWith(activeAudioId: track.id);
    _engine?.setAudioTrack(track.id);
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
    if (!_stillOurs) return;
    setState(() => _menuOpen = false);
    if (opener != null &&
        opener.context != null &&
        opener.ancestors.contains(_controlsScope)) {
      opener.requestFocus();
    } else if (_timingShown && _isTv) {
      // A sheet opened from the timing panel goes back to the panel: the
      // video is not a legitimate place for the ring while something
      // visible is on screen, and a direction key there seeks instead of
      // walking the panel's row.
      _timingFocus.requestFocus();
    } else {
      _focusNode.requestFocus();
    }
    _showControls();
    _resumeUpNext();
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

  // --- Lifecycle -----------------------------------------------------------

  @override
  void dispose() {
    // Ordinarily a no-op: [_leave] detaches at the press. This covers a
    // screen that went without a leave (a hand-over's `pushReplacement`, a
    // route dismantled from above).
    _detach();
    // Discovery is the process's, not this screen's, and a hand-over's
    // successor has started it again by now: `pushReplacement` builds the
    // new player before this one goes, so a stop from here would end the
    // search the next episode's cast button is waiting on.
    if (!_handedOver) _cast?.stopDiscovery().ignore();
    // Nothing of ours is left on the LAN: the session ends and the listener
    // with it.
    if (_casting || _lanMediaOn) unawaited(_teardownCast());
    // A television leaves fullscreen only when the player is really over: on
    // a hand-over the replacement entered fullscreen while this screen was
    // alive and is disposed after it, so exiting here would drop the new
    // player out of fullscreen.
    if (_fullscreenOn && !(_isTv && _handedOver)) _fullscreen?.exit().ignore();
    // The rate goes back whatever else is true: a display held at 24 Hz by a
    // player that no longer exists judders every menu. A hand-over has
    // already released it ([_handOver]), so this is a no-op there.
    _releaseDisplayFrameRate();
    // Ordinarily already finished: [_leave] runs the teardown before the
    // pop. This covers the screen that went without a leave, where the
    // engine would otherwise keep its packet memory and socket. Unawaited;
    // the teardown logs how it ended ([_runTeardown]).
    unawaited(_endPlayback());
    // The listener goes first: the flush below writes a preference, which
    // notifies synchronously, and [_onPrefsChanged]'s `mounted` guard does
    // not stop a `setState` inside `dispose`.
    _prefs?.removeListener(_onPrefsChanged);
    // Whatever the last press asked for, before the preferences this
    // screen writes through go out of reach.
    _flushRememberedTiming();
    _ownPrefs?.dispose();
    _bufferStatus.dispose();
    _castDeviceList.dispose();
    // Both were unsubscribed from in [_detach]; what is left is the
    // notifiers themselves.
    _player?.dispose();
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

  // --- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final engine = _engine;
    final casting = _casting;
    // Once the player is stopping the picture is all this screen draws
    // ([_leave]): anything else would aim at an engine on its way out, and
    // media_kit throws on a released player.
    final leaving = _leaving;
    // While a receiver has the stream there is no video here, nothing is
    // buffering here and no torrent is starting up for this screen: every
    // overlay about local playback is about a player that is paused.
    final startup = _startupOverlayShown && !casting && !leaving;
    final status = startup || casting || leaving ? null : _statusText(state);
    final stall = status != null && _stallOverlayShown(state);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= PlayerScreen.wideBreakpoint;
    final shown = _controlsShown && !leaving;
    final nextVideo = state?.nextVideo;
    final upNext = leaving ? null : _upNextSecondsLeft;
    final hasVideo = engine != null && _opened != null && !casting;
    final seekStep = _seekStep;
    if (_isTv) _scheduleFocusCheck();
    if (hasVideo) _measureControlBarAfterFrame();
    // Never poppable by the framework, so that every way out of the
    // player runs the teardown before the screen goes: Back and Escape
    // both arrive here rather than taking the route out from under a
    // player that is still reading. The ladder comes first -- Back is one
    // key for every layer -- and [_leave] is its last rung.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_backDismisses) {
          _popBack();
          return;
        }
        _leavePlayer();
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
            // Nothing on a stopping player is aimed at, however it is
            // reached: the bar and the up-next card are already out of the
            // tree above, and this covers the video's own taps.
            child: IgnorePointer(
              ignoring: leaving,
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
                            held: _streamNumbers,
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
                                onBack: _leavePlayer,
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
                                          onSeekForward: () =>
                                              _seekBy(seekStep),
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
                                  onStep: _seekBy,
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
                  // Outside the OSD's fade: it says why the
                  // subtitle the viewer is looking for is not there, and
                  // the bar is not what they are looking at.
                  if (_subtitleFailure case final failure?)
                    SafeArea(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 64),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              child: Text(
                                failure,
                                style: const TextStyle(color: Colors.white),
                              ),
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
                              // Null with nothing else on offer, which is
                              // what leaves the whole option undrawn.
                              onMatch: _hasOtherSubtitleFile(state)
                                  ? () => unawaited(_openSubtitleMatch())
                                  : null,
                              matching: _matchingSubtitle,
                              matchNote: _subtitleMatchNote,
                              onMark: () => unawaited(_markSubtitleTiming()),
                              markNote: _markNote,
                              onShift: (step) =>
                                  _adjustTiming(_timing.shiftedBy(step)),
                              onReset: _undoSubtitleTiming,
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
      ),
    );
  }

  /// The controls in their own focus scope on a TV, so the D-pad walks the
  /// bar and this screen can tell whether the remote is on it. Off a TV, the
  /// bare column.
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
    if (_waiting) {
      // For a torrent this is what the stall card says with nothing from
      // the server yet, and the whole of what a stall says without one.
      return state.selectedStream?.kind == StreamKind.torrent
          ? TorrentStallOverlay.waiting
          : 'Buffering…';
    }
    return null;
  }
}
