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
/// On a TV ([DeviceScope.isTv]) the remote drives it, and the player has
/// two modes: the OSD is up or it is not.
///
/// With it down there is nothing on screen to aim at, so no press is aimed
/// at anything. The centre key means play/pause -- the one button a hidden
/// player has -- and leaves the remote on play/pause with the bar up, so
/// pressing it again is what starts the film: one key, twice, for the
/// whole of stopping and starting. Up and down bring the bar up and land
/// on it in the same press, on the top bar and the seek bar; left and
/// right scan, and the bar comes up showing where they went.
///
/// With it up the ordinary focus rules apply: the centre key presses
/// whatever is focused, and means play/pause on the seek bar and on the
/// video, which are the two stops with nothing to press. Up walks the bar
/// as it is drawn. Down is the way back rather than a walk: it lands on
/// the seek bar from anywhere on the bar, and on play/pause from the seek
/// bar, so the player's home stop is never more than two presses away.
///
/// The media keys (play, pause, play/pause, stop, fast forward, rewind,
/// next and previous track) do what they say in both. Once the remote is
/// on the bar the D-pad stays inside it, and Back is the way out: it puts
/// away the up-next card, then the controls, and only then leaves the
/// player. The controls fade on their own timer whether or not a control
/// holds focus, and take the remote back to the video with them -- but
/// never while something is paused, which is what leaves the second press
/// of the centre key something to land on. The media keys work off a TV
/// too; nothing else about the keyboard changes there.
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
  /// mpv reports a position at least once a second while it is decoding,
  /// so five missed reports is unambiguous -- and still a fraction of the
  /// 26 to 51 seconds a starved read really took in the field. Above
  /// [controlsTimeout] deliberately: a hiccup shorter than the controls
  /// take to fade is not worth putting a card over the picture for.
  static const Duration stuckAfter = Duration(seconds: 5);

  /// How long "this subtitle could not be loaded" stays over the picture.
  static const Duration subtitleFailureShown = Duration(seconds: 6);

  /// How often that is checked. A position that has stopped produces no
  /// events at all, which is exactly why it needs a clock and not a
  /// listener.
  static const Duration stuckInterval = Duration(seconds: 1);

  /// How far the position has to have moved before a player that stood
  /// still is playing again rather than twitching.
  ///
  /// A film that really resumed passes this inside a second; a decoder
  /// putting out the odd frame behind a picture that is not moving does
  /// not. Taken from the field log of 2026-09-20, where a 4K remux froze
  /// for seventy seconds: a position report a fraction of a second along
  /// cleared the flag, the log said "playing again", and nothing was ever
  /// said about the minute that followed.
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
  /// (the panel's cache and sharing rows) -- the same slow cadence as the
  /// swarm rows above, and for the same reason: nothing waits on these,
  /// they are only worth a poll while somebody is reading them, and the
  /// ask costs a listing of the stream's own directories. It is a
  /// constant of its own because it runs for a proxied stream too, which
  /// has no swarm and so no torrent poll to ride on.
  static const Duration streamNumbersInterval = Duration(seconds: 5);

  /// How long after a seek the position is looked at again to see whether
  /// the seek happened at all, and how far from the target it may land and
  /// still count as having happened.
  ///
  /// mpv seeks to a keyframe unless asked for an exact position, so a
  /// couple of seconds either way is an ordinary seek; the case being
  /// watched for is a seek of minutes that leaves the position where it
  /// started. The wait is long enough for a demuxer that really is
  /// seeking to have got there and short enough that the viewer's next
  /// press replaces it rather than queueing behind it.
  static const Duration seekCheckDelay = Duration(seconds: 2);
  static const Duration seekTolerance = Duration(seconds: 5);

  /// How long a receiver may sit on a load before this screen asks what
  /// the LAN listener has actually been asked for.
  ///
  /// A receiver handed an address it cannot reach never says so: the
  /// connect hangs, and the splash screen it is on is the same one a slow
  /// start looks like. What the wait allows for is a receiver that is on
  /// its way but unhurried -- the load, the redirect and the first range
  /// request take a moment between them -- and not for telling a stall
  /// from a failure, which the count does whenever it is read. Short
  /// enough that nobody is left watching a splash screen wondering.
  static const Duration castFetchTimeout = Duration(seconds: 20);

  /// How long the controls stay up without input while playing.
  static const Duration controlsTimeout = Duration(seconds: 3);

  /// Below this width the transport sits in the middle of the video and
  /// the volume slider is dropped (hardware keys on phones).
  static const double wideBreakpoint = 720;

  /// How long the screen waits for the player to stop before it leaves
  /// anyway -- and how long the teardown gets before it is written down as
  /// one that did not come back.
  ///
  /// **It bounds the viewer's wait, not a kill.** It used to be a deadline
  /// with something behind it, and there is nothing behind it: the `quit`
  /// is the kill and it has already gone out before this starts running.
  /// So all that expiring means is that the screen stops waiting; the
  /// teardown carries on in the background and still says how it ended.
  ///
  /// Two seconds because that is a wait, and a wait is what it is now.
  /// Every teardown ever measured here answered in well under half of one
  /// -- 145 ms against a socket wedged for good, 430 ms at the worst of
  /// seven runs on Linux, 230 ms on the Chromecast -- so this is roughly
  /// five times the slowest thing it will ordinarily see, and short enough
  /// that a player which has genuinely stopped answering does not hold a
  /// black screen while the viewer waits on it.
  ///
  /// **It is kept because it is the only instrument that would tell us the
  /// unexplained failure came back.** On the owner's Chromecast a player
  /// kept downloading at 32 Mbps for at least ninety seconds after its
  /// screen was left, and nothing but killing the process ended it. Every
  /// mechanism since measured resolves in a fraction of a second, so
  /// something happened there that is still not accounted for. Guarding
  /// against an observed failure we cannot explain is prudence; keeping
  /// the guard once we can explain it would be superstition.
  static const Duration teardownBound = Duration(seconds: 2);

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

  /// The embedded server's base URL, which is what a stream on anybody
  /// else's host is fetched through ([proxiedThroughServer]).
  ///
  /// From `CoreInitInfo`, read off the scope when this screen is wired,
  /// because it has to be known before the first `open` and it is: the
  /// server was started and its port settled before the core was built,
  /// while `profile.settings.streamingServerUrl` -- which names the same
  /// server -- arrives with a `ctx` pull that may land after the player
  /// state does. A first `open` that missed it would be the one playback
  /// of the session that went direct.
  ///
  /// **It names the embedded server and nothing else, whatever the viewer
  /// configured.** Choosing a streaming server somewhere else rewrites
  /// `streamingServerUrl`, not this: the embedded one keeps running and
  /// keeps being reported here, so on such a build a remote host's stream
  /// is proxied through the embedded server exactly as on any other. That
  /// is the right way round -- the whole point of the hop is that the one
  /// server this device can bound, sweep and answer for is in the path,
  /// and the bytes still cross the network only once -- but it is the
  /// opposite of what this comment used to claim, and the opposite of what
  /// happens to a torrent on that configured server: a torrent has an info
  /// hash, so [_mediaUrl] sends it straight there with `buffer=` and no
  /// proxy at all.
  ///
  /// Null when this build started no embedded server. Nothing the app
  /// ships gets there -- `CoreClient.init` always asks for one, and one
  /// that will not start fails the boot rather than carrying on without it
  /// -- so it stands for a build with none, and everything here keeps
  /// working when it is null: the stream plays direct, as every build did
  /// before the proxy.
  Uri? _serverBase;

  /// This player's name for its own proxied streams, written into the
  /// `/proxy` URLs it fetches (`p=`) and the only thing that says which of
  /// the server's live streams are this screen's ([_closeProxiedStreams]).
  ///
  /// A name, not a credential: the call that acts on it is on the server's
  /// bearer-protected loopback control API, and the token never leaves this
  /// device -- the server strips it before asking the origin for anything.
  /// So a counter is enough, and it is what makes a test's expectation
  /// readable. Unique within the process is the whole requirement, and
  /// nothing outlives the process: a stream from before a restart that is
  /// somehow still open is one this app would rather close than inherit.
  late final String _proxyToken = 'player-${++_proxyTokenSeq}';
  static int _proxyTokenSeq = 0;

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
  /// screen is only still here so that mpv has something to hand its last
  /// frames to.
  ///
  /// It is what keeps the picture up across the wait, and it is why the
  /// controls come down at the same moment (see [build]) -- everything on
  /// the bar aims at an engine that is stopping, and media_kit throws on a
  /// player that has been released.
  bool _leaving = false;

  /// Whether this screen is still the one that should act on the player:
  /// built, and not on its way out. **What every continuation in this
  /// class asks, and the reason `mounted` on its own is not enough any
  /// more.**
  ///
  /// [_detach] ends everything that could *arrive* -- the subscriptions,
  /// the listeners, the timers -- before the first `await` in [_leave],
  /// and that is what makes a screen waiting for its teardown unreachable
  /// by an event. It cannot reach what is already suspended: an `await`
  /// that was in flight when the viewer left is neither a subscription
  /// nor a timer, and it resumes into the middle of the wait.
  ///
  /// It resumes into a screen that is *more* alive than the one these
  /// guards were written against. The player used to pop at the press and
  /// release its engine two frames later, so `mounted` was false by the
  /// time anything late came back and a `!mounted` return was the whole
  /// of the check. Now the screen stays -- built, and holding an engine
  /// that is being released -- for as long as mpv takes to stop, so
  /// `mounted` is true for exactly the stretch it used to be false for,
  /// and every one of those guards now passes precisely when it used to
  /// fail. `mounted` answers whether there is a widget to call
  /// [State.setState] on; it has never answered whether this screen is
  /// still the one whose engine, core, cast session and route these are.
  ///
  /// Two of them cost the viewer something, both measured. A cast start
  /// whose `connect` came back during the wait paused the engine, opened
  /// the LAN listener and handed the receiver the film at 37 minutes:
  /// Back was pressed, and the film started on the television. And a
  /// hand-over whose registry answer came back during the wait
  /// `pushReplacement`ed a second player over the screen still waiting
  /// for its own teardown -- a second engine and a fresh open: Back was
  /// pressed, and the next episode began.
  ///
  /// [_playNext] had the check already, because it was written after
  /// there was something to check; the rest were not, which is why this
  /// is one question with one name rather than a third `_leaving` test
  /// somebody has to think of.
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
  /// [_open] rather than derived again later: [_mediaUrl] is not a pure
  /// function of the core's URL (it reads the buffer window and the proxy
  /// token, and sets [_proxiedStream] on the way through), and for every
  /// stream that is not a torrent it wraps the origin in this server's
  /// `/proxy` route.
  ///
  /// That wrapping is why the difference matters. The bytes of a proxied
  /// stream are in this server's cache under the `/proxy/...` URL, and the
  /// server decides which of its stores a question is about from the
  /// *path* it is asked with -- so a question about the core's bare origin
  /// URL is a question about a stream this server has never heard of.
  /// [_heldStreamUrl] is what the stats panel asks with, and this is where
  /// it comes from.
  ///
  /// Null until the first `open`, and it is not an identity: a re-open for
  /// a new buffer window writes a different one for the same video. What
  /// says which video is playing stays [_opened].
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
  /// mpv's flag means its demuxer cache ran dry *during playback*. It does
  /// not cover a read that is blocked in the server while mpv is seeking,
  /// and on 2026-09-12 that is what happened: the flag cleared when the
  /// container index arrived, the overlay came down, and nothing played
  /// for three and a half minutes with reads blocking 26, 34, 44 and 51
  /// seconds. There is no second stall in that log, because by mpv's
  /// reckoning there was not one.
  ///
  /// A position that is not moving while the player says it is playing is
  /// the signal that cannot be fooled, so it is the one the overlay adds.
  /// Counted in ticks of [PlayerScreen.stuckInterval] rather than measured
  /// against a clock: a position that has stopped is only observable by
  /// looking, so the looking may as well be the unit.
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

  /// Whether the session's subtitle preference has been applied to this
  /// media yet (once per `open`), and whether an attempt is in flight.
  bool _autoPickedSubtitles = false;
  bool _autoPickingSubtitles = false;

  /// Whether the viewer has said what they want of the subtitles for this
  /// media -- picked a file, an embedded track or none of them, or moved
  /// the timing by hand -- which leaves the session preference nothing to
  /// guess at.
  ///
  /// [_autoPickedSubtitles] only records that the engine *accepted* a
  /// pick, so an engine that keeps refusing one leaves the auto-pick
  /// retrying on every state and tracks event for the rest of the media.
  /// Each retry replaces the whole [SubtitleTiming] and, on the way back
  /// out, the selection too, so without this a shift was undone a moment
  /// after it was made -- and again a second later, while the viewer
  /// watched the picture for it to take effect.
  bool _subtitlesChosenByHand = false;

  /// The addon files mpv has said it could not load for this media
  /// ([externalSubtitleFailure]), by URL. The auto-pick passes over them:
  /// a dead link is dead on the next tracks event too, and picking it
  /// again would only fetch it again.
  final Set<String> _deadSubtitles = {};

  /// What the last addon file put on screen replaced, for as long as it
  /// might yet turn out not to load: its URL, the tracks as they were,
  /// the file whose timing was in force, and whether the auto-pick made
  /// the choice (and so should make another). `sub-add` does not answer
  /// a failure (see [externalSubtitleFailure]); the error that says so
  /// arrives on its own, and this is what it is undone from.
  ({
    String url,
    PlaybackTracks before,
    SubtitleInfo? beforeSubtitle,
    bool auto,
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

  /// Whether the file the last `open` asked for has shown up: a duration,
  /// or a position past zero. Reset by every `open` ([_open]), re-opens and
  /// retries included, which is where it differs from [_mediaLoaded].
  ///
  /// Neither of that one's signals says so. media_kit's `open` stops the
  /// player first, and the stop announces itself -- `position: 0` and then
  /// `duration: 0` down the streams this screen listens to -- before a
  /// byte of the new file has been read; and once the `loadfile` is issued
  /// it reports `playing: true` straight away
  /// (`player/native/player/real.dart`). A zero before this is that
  /// announcement and not the viewer at the start of a film of no length,
  /// so neither is believed ([_onPosition], [_onDuration]). Believed, the
  /// position reported the viewer at the start to the core, and a second
  /// re-open issued before the first had started resumed from it
  /// ([_resumePosition]), since [_position] held it.
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
  /// them did.
  ///
  /// Working state and not something remembered: a mark is a point
  /// measured against one subtitle file, so it says nothing about
  /// another and [_resetSubtitleTiming] throws the lot away with the rest
  /// of what belongs to the file going off. Only what the marks *derive*
  /// -- the multiplier and the offset now in [_timing] -- is worth
  /// keeping, and it is kept under the ordinary keys with everything
  /// else the viewer fixes.
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

  /// The write of what the viewer has adjusted that has not been made
  /// yet, and null when there is nothing to write.
  ///
  /// A press does not write. The shift repeats eight times a second
  /// under a held key, a preferences file is not a keystroke log, and
  /// two overlapping `prefsSet` calls land on FRB's worker pool in no
  /// particular order -- twenty of them could leave the file holding a
  /// number the panel is not showing. So a press leaves this behind and
  /// the write is made when the adjusting is over: the panel closing,
  /// something changing what is on screen, or the player going away.
  ///
  /// It is a closure because it has to remember the *file* the press was
  /// made on rather than whatever is playing when it is finally made.
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
  /// [_torrentStatsRequest] is set for as long as the player is on a
  /// torrent **this device's server is the one serving** -- what is polled
  /// *for* -- and the timer is what says whether anything is waiting on
  /// it: every [PlayerScreen.torrentStatsInterval] until the media loads,
  /// then off until something wants the numbers again -- a stall, at
  /// [PlayerScreen.torrentStallStatsInterval], or the stats OSD, at the
  /// slower [PlayerScreen.torrentStatsOverlayInterval] ([_syncTorrentStats],
  /// which also owns [_torrentStatsCadence], the period the running timer
  /// was built with). An engine error and dispose end both.
  ///
  /// The request asks for the stream's file, which focuses it and reports
  /// its initial window; when the server has no answer for that (an index
  /// the torrent turns out not to have) a poll asks for the torrent-level
  /// [_torrentStatsFallback] instead.
  ///
  /// So null means one of three playbacks, not one: not on a torrent at
  /// all, on a torrent playing off a streaming server on another machine
  /// ([_servedHere], which [_startTorrentStats] returns on before it
  /// records anything), or a build with no embedded server to ask. Read it
  /// as "there is a torrent here we can ask our own server about", which
  /// is what everything downstream of it is entitled to assume.
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
  /// holds of the stream on screen, asked with [_heldStreamUrl] -- the URL
  /// the engine was handed, which is the whole of the question the server
  /// takes, and only when that URL is one of ours.
  ///
  /// Polled only while the panel is up and the app is in front, at
  /// [PlayerScreen.streamNumbersInterval]; unlike the swarm above this runs
  /// for a proxied stream too, which is why it has a timer of its own.
  ///
  /// **[_streamNumbers] is a reading and nothing else.** It is set only
  /// from an answer to an ask for the URL that is open now, and it is
  /// dropped the moment nothing is polling it -- the panel going away, the
  /// app going behind, another video -- because a window and a ratio
  /// describe a moment, and holding one past its poll would put the past
  /// on the panel as the present. There is nothing to hold across a start:
  /// this process has watched nothing, and the server says so by answering
  /// no window at all.
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

  /// Whether the film has actually been playing since the current `open`
  /// or the last seek -- so a buffering popup from here on is a stall the
  /// server is told about ([_reportStall]), and not the wait a load or a
  /// seek has anyway. A seek's buffering is the new window filling, which
  /// the server sizes for itself; zond does not want a seek to deepen the
  /// split.
  ///
  /// **A tick of playback in total, not one advancing report.** It was the
  /// latter, and a scrub back defeated it: each rewind lands, a few frames
  /// decode and play, that forward step re-armed this, and the *next*
  /// rewind's buffering went to the server as a stall. The field log of
  /// 2026-09-20 21:09:27 has six of them a second apart at descending
  /// positions -- 6190s, 6180s, 6170s ... -- two counted, and the split
  /// depth stepped up behind them. Summing the forward steps instead means
  /// a viewer has to watch [_playbackTick] of film before a stall counts,
  /// which no rewind can fake and which is what "playing normally" was
  /// always meant to say. [_playedSinceSeek] is the sum; a seek resets it.
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

  /// Runs [castFetchTimeout] after a load served off this device, and asks
  /// the one question that listener's count can answer: did the receiver
  /// ever reach us ([_castFetchCheck]). Nothing a receiver says about
  /// itself cancels it -- the receiver this exists to catch reports a
  /// healthy session and a player state the SDK cannot name, so its own
  /// account of itself is exactly what must not be listened to. Only the
  /// ways out of a session cancel it, picking another receiver among them.
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

  /// Where the receiver was told to start, and whether it has yet said
  /// where it actually is. The Cast SDK reports a media status and a
  /// position on two separate streams, and the client folds them into one
  /// report by carrying the last position it saw -- which, before the
  /// receiver's first progress tick, is a zero it never reported (or the
  /// last session's number). Taken at its word, that zero was dispatched
  /// to the core as `TimeChanged{0}`, drawn as a scrubber at 0:00, and,
  /// when a receiver never fetched and the session was ended for it, was
  /// where local playback resumed: from the start of a film that was forty
  /// minutes in. So until the receiver has reported a position of its own,
  /// a zero stands for "not yet", and the position it was handed is the
  /// best knowledge there is ([_trustedCastStatus]).
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

  /// The window was minimised, or the app went to the background: with
  /// `pauseOnMinimize` a playing video pauses, and either way the torrent
  /// polling stops -- a pinned stats panel nobody can see is no reason to
  /// keep asking the server every few seconds, and neither is a start-up
  /// card nobody can see.
  ///
  /// The start-up poll is stopped here by hand because it is not
  /// [_syncTorrentStats]'s to stop: that call keeps the cadence of a
  /// *loaded* torrent's polling and returns before the media has loaded,
  /// so the timer [_startTorrentStats] armed went on firing twice a second
  /// into the background -- measured: twenty requests in five hidden
  /// seconds -- while this comment said it did not.
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
        // fast-forward keys reach mpv directly, so `_seekTo` does not run
        // and nothing above disarms -- which is how a scrub back came to be
        // reported as six stalls (the field log of 2026-09-20). A position
        // that moves backwards, or forwards by more than a tick, is a seek
        // whoever asked for it, and what follows it is a window filling.
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
      // **The one number the server cannot work out for itself.** A film's
      // length with its size is its bitrate, and the bitrate is what every
      // stream's lookahead is sized from: a player that is behind asks for
      // more the instant it is answered, so its reads measure the server's
      // delivery and not its own consumption. Without this the server has
      // no honest absolute number at all.
      //
      // Here rather than on a timer, because it is stated once and does not
      // go stale. A cast reports it separately ([_onCastStatus]), since a
      // receiver does the reading and this stream never fires.
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

  /// Writes down what mpv is actually doing with the film, once, when the
  /// position has stood still.
  ///
  /// A frozen picture is either a decoder that cannot keep up or a read
  /// that never arrived, and the log could tell them apart in neither
  /// direction: a 4K remux froze on the television for seventy seconds
  /// leaving nothing but the warning above. The numbers that answer it --
  /// which decoder is in use, what the codec and the size are, how many
  /// frames went on the floor, how much the demuxer has in hand -- are
  /// sampled twice a second by [PlaybackStats] and thrown away whenever
  /// nobody has the stats panel open. This asks for one sample.
  ///
  /// Silent on a player that will not answer: the sample is a diagnostic,
  /// and a diagnostic that can hold up anything is worse than none.
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

  /// An error from the engine, which is fatal only while the file the
  /// last `open` asked for has not shown up ([_mediaIn]).
  ///
  /// media_kit makes these out of mpv's error-level log lines
  /// ([PlaybackEngine.errors]), so after the film is in, one is a line in
  /// a log and not the end of the playback: a dead subtitle link
  /// (`Can not open external file <url>.` and ffmpeg's `tcp:` line before
  /// it), a decoder complaining about a damaged frame, a read that failed
  /// and was retried. Treating those as "Playback failed" put the card,
  /// and the addon's URL, over a film that went on playing underneath it,
  /// with the controls pinned up, the display's rate given back and the
  /// stall reports stopped for good. A playback that really has stopped
  /// says so on its own terms -- an end of file that is not the end
  /// ([_onFalseEnd]) or a position that stands still ([_checkStuck]) --
  /// and those are what give up on it.
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

  /// The stall card replaces the plain spinner-and-sentence status once
  /// playback has begun: the same measurable card, for a torrent the
  /// server can still be asked about. Everything the status text puts
  /// before buffering (a failure, an unplayable stream, a stream not
  /// resolved yet) is not a stall and keeps its own presentation.
  /// Either of the two ways of waiting; see [_positionStuck].
  bool get _waiting => _buffering || _positionStuck;

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
  /// it is.
  ///
  /// Asking is not once per file, because an ask does not last as long as
  /// a file does. On Android 12 and up it is a vote on the surface Flutter
  /// draws into, and that surface is destroyed and rebuilt when the app
  /// goes to the background and comes back -- a vote made before goes with
  /// it, and the rest of the film then plays on the cadence this exists to
  /// remove. And every path that releases the rate leaves the file on
  /// screen playable: the film ends, the viewer rewinds into the last ten
  /// minutes, and nothing would ask again because the engine reports a
  /// rate it has already reported no further times.
  ///
  /// Repeating the same ask is cheap in the case that matters: the panel
  /// is already on the rate asked for, so the platform has nothing to
  /// change and no picture to blank.
  /// A television only. On a phone the panel is the phone's and nothing
  /// about a film is a reason to switch it, and on a desktop the platform
  /// has no such API at all -- so the gate is here, where the device is
  /// known, rather than in the channel.
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
  /// against it instead of against the audio clock
  /// (`MediaKitEngine.displayRateProperties`).
  ///
  /// Tied to the ask rather than to the playback, and deliberately: while
  /// this player holds a rate on the display it knows what the display is
  /// for, and the moment it gives that back the number describes a mode
  /// nobody is in any more. So the same list of paths that clears the ask
  /// clears this, by going through [_releaseDisplayFrameRate], and there
  /// is no second list to keep in step.
  ///
  /// So every caller is a path on which this player holds a rate or has
  /// just stopped holding one, and nothing is said at all on a phone or a
  /// desktop, where nothing asks: [_frameRateAsked] is only ever true on a
  /// television, and the engine refuses the override off Android anyway.
  void _applyDisplaySync() {
    _engine
        ?.setDisplayRefreshRate(_frameRateAsked ? _displayRefreshRate : null)
        .ignore();
  }

  /// Gives the display's rate back.
  ///
  /// Called from every path that ends this player's claim on it: the film
  /// reaching its end, playback failing, the viewer leaving, and
  /// [dispose]. The last is the one that makes the list complete -- Back
  /// down the ladder, the Stop key, the arrow on the bar and the hand-over
  /// to the next episode all pop or replace this route, and no route
  /// leaves without being disposed of -- and the ones before it are there
  /// because a film that has ended or failed is no longer being presented,
  /// and because leaving should not wait for a frame. [_frameRateAsked]
  /// makes the repeats free.
  ///
  /// Not called when playback merely pauses: a mode change costs a second
  /// of black picture each way, and a pause is usually seconds long.
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
    // The bar is out of the frame for good once the player is stopping
    // ([build]), so there is nothing left for this to fade -- and a timer
    // armed after [_detach] has run is one nothing cancels, which outlives
    // the screen. The focus change [_leave] makes on its way out arrives
    // here, so this is not a hypothetical door.
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
  /// whoever has the stream is who they are for, exactly as
  /// [_togglePlay] is. A phone that answered them itself went on playing
  /// the film locally while the television played it too.
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

  /// Puts the playback at [target] and tells everything that watches
  /// where it went.
  ///
  /// [scanning] is the distance a *step* asked for, and it changes what
  /// the engine is asked to do rather than where the bar goes: a step is
  /// a scan and lands on a keyframe at once ([PlaybackEngine.scanBy]),
  /// where a position the viewer named -- a tap on the bar, the start of
  /// a film they are coming back to -- is seeked to exactly. The target
  /// is still computed here, because the bar, the core and the check on
  /// the seek all want a position and mpv's answer to a scan arrives on
  /// the position stream a moment later. A step that would land outside
  /// the file is the exception, and the body says why.
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
      // Relative, and so from where playback actually is rather than
      // from the target this press computed: a run of presses under a
      // held key adds up in libmpv the same way it adds up here.
      //
      // **Except where the step would land outside the file**, which is
      // where the clamp above stops being cosmetic. mpv works a relative
      // seek's target out itself and does not clamp what it then
      // *reports*: `time-pos` answers `last_seek_pts`, the raw target,
      // from the moment the seek is queued until the first frame after
      // it arrives. Stepping ten seconds back from 2.586 s therefore
      // puts -7.414 on the position stream, and that is what the core is
      // told playback has got to -- where a time is a `u64` and the
      // whole action is thrown out (`Seek`/`TimeChanged` in
      // `stremio_core::runtime::msg`). So a step off either end of the
      // file is asked for as the position it lands *at*: mpv's own
      // `last_seek_pts` is then the clamped number, and the seek still
      // happens -- to the start, which is what the press asked for.
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

  /// Writes down the one thing about a seek nobody watching can see: that
  /// it did not happen.
  ///
  /// mpv does not wait for a position it cannot reach -- it refuses the
  /// seek and restores the position -- and a demuxer reports itself
  /// unseekable for reasons that have nothing to do with whether the
  /// bytes are available (a Matroska index that had not arrived when the
  /// file opened). From the sofa that is indistinguishable from the film
  /// jumping back on its own, and it is the event a report has no line
  /// for. The stats OSD carries mpv's own answer
  /// (`PlaybackStats.seekable`, and `partiallySeekable` where we forced
  /// the first); this is the same question asked from the outside, and it
  /// asks it of the playback rather than of the demuxer, so a report taken
  /// without the panel up still shows it.
  ///
  /// One line per seek, at info: it is not an error -- the viewer asking
  /// for a position we cannot reach is a legitimate thing to ask -- and a
  /// burst of presses is one check, because each seek replaces the one
  /// before it.
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
      // The engine's own position, never the one on the bar: [_seekTo]
      // writes the target there itself. A refusal while paused moves
      // nothing at all -- mpv leaves `time-pos` where it was and reports
      // nothing -- so reading the bar would find the target sitting there
      // and conclude the seek landed, which is exactly the refusal a
      // viewer scrubbing a paused film would hit and the one this line
      // exists to record.
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
    // Ordinarily a second call that does nothing: [_leave] detaches at the
    // press, which is where it has to happen now that this method runs
    // after the wait rather than instead of it. What is left for this line
    // is the screen that went without a leave -- the hand-over's
    // `pushReplacement`, a route dismantled from above -- where this is
    // still the moment nothing may act on the player any more.
    _detach();
    // Discovery is the process's, not this screen's, and a hand-over's
    // successor has started it again by now: `pushReplacement` builds the
    // new player before this one goes, so a stop from here ended the
    // search the next episode's cast button was waiting on.
    if (!_handedOver) _cast?.stopDiscovery().ignore();
    // Whatever else is true when this screen goes, nothing of ours is left
    // on the LAN: the session ends and the listener with it. Everything
    // that could report back was cancelled above, so nothing lands in a
    // disposed screen while this runs.
    if (_casting || _lanMediaOn) unawaited(_teardownCast());
    // A television gives the system its bars back when the player is
    // really over, not when it hands over to the next episode: the
    // replacement enters fullscreen while this screen is still alive, and
    // is disposed of after it, so exiting here would drop the *new*
    // player out of fullscreen. Off a television the successor makes no
    // such claim, and the window leaves fullscreen as it always has.
    if (_fullscreenOn && !(_isTv && _handedOver)) _fullscreen?.exit().ignore();
    // The rate goes back whatever else is true. Unlike fullscreen, leaving
    // it in force is the fault -- a display held at 24 Hz by a player that
    // no longer exists judders every menu the viewer goes back to. A
    // hand-over has already released it ([_handOver], before it pushes),
    // so this is a no-op there rather than a clear that would land after
    // the successor's own ask.
    _releaseDisplayFrameRate();
    // Ordinarily a teardown that has already finished: [_leave] runs it
    // before the pop, with the video still on screen, and what comes back
    // here is a future that completed a frame ago. What is left for this
    // line is the screen that went *without* a leave -- the hand-over's
    // `pushReplacement`, a route dismantled from above, the app being
    // taken down -- where there is nothing left to await from and the
    // engine would otherwise be left holding its packet memory, its
    // socket and the server engine that socket pins.
    //
    // Unwatched, because nothing here can wait; answered for, because a
    // discarded future is a teardown nobody can tell from one that never
    // happened, and an evening of exactly that is where the ninety
    // seconds went.
    unawaited(_endPlayback());
    // The listener goes first, and the order is the whole of it: the
    // flush below writes a preference, which notifies synchronously, and
    // a notification answered from here is a `setState` on an element
    // the framework has already marked defunct -- `mounted` is still
    // true inside `dispose`, so the guard on [_onPrefsChanged] does not
    // stop it. This screen has no use for a preference change it is on
    // its way out of anyway.
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
    // The picture is the only thing this screen still draws once the
    // player is stopping: it is what mpv hands its last frames to, and it
    // is the whole reason the screen is still here (see [_leave]).
    // Everything else would be a control aimed at an engine on its way
    // out, and media_kit throws on a player it has released.
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
