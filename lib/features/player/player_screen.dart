import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kDebugMode;
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

  /// The name every route that mounts this screen is pushed under, so
  /// whoever is about to open something over the player can tell there is
  /// one. There is only ever meant to be one: two of these load the same
  /// shared `player` field, and the one underneath opens the other's
  /// stream on its own engine too (see `XtremioApp`'s downloads path and
  /// [_PlayerScreenState._openDownloads]).
  static const String routeName = 'player';

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

  static const List<double> rates = [0.75, 1, 1.25, 1.5, 2];

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

/// What the auto-pick is looking for, from whichever of the two answers
/// there is: the engine's session preference, or what this show was last
/// watched with (`SubtitlePickMemory`).
///
/// One shape for both so there is one piece of code that applies it. What
/// the two can say differs -- only the memory names a release group, and
/// only it survives the app being closed -- but what is *done* about it
/// must not, or the file a viewer gets would depend on which memory
/// answered.
final class _WantedSubtitle {
  const _WantedSubtitle({
    required this.enabled,
    required this.language,
    this.releaseGroup,
    this.embeddedFirst = false,
  });

  /// False means subtitles off, and it is an answer rather than the
  /// absence of one: a viewer who turned them off is not asking to be
  /// asked again next episode.
  final bool enabled;

  /// The label the menu prints (`Swedish`), not the code; null matches
  /// any language, which is what an enabled preference naming none does.
  final String? language;

  /// The lower-cased release group to prefer among that language's files,
  /// when one is remembered. Only a preference: nothing here refuses a
  /// language because the group it named is not on offer this episode.
  final String? releaseGroup;

  /// Whether a track inside the video wins over an addon's file of the
  /// same language.
  final bool embeddedFirst;
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

  /// Whether the engine has reported the opened media loaded (a duration,
  /// or that it is playing). Until then mpv is between files and refuses
  /// `sub-add` ("Cannot add track at the moment"), so the subtitle
  /// auto-pick waits for this.
  bool _mediaLoaded = false;

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
    _syncTorrentStats();
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
          // already put back. The file it was computed for goes back
          // first, because `loadfile` took that with it
          // ([_restoreExternalSubtitle]).
          if (_stillOurs && _opened == url) {
            _restoreExternalSubtitle();
            _applySubtitleTiming();
          }
        })
        .catchError((Object error) {
          if (!_stillOurs || _opened != url) return;
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

  /// [url] as the engine should fetch it, which is always a URL on our own
  /// server: the core's stream URL with `buffer=` added when it is a
  /// torrent the server is already serving, and the same stream wrapped in
  /// the server's `/proxy` route when it is anybody else's host.
  ///
  /// `buffer=` goes on the torrent alone. A remote host knows nothing about
  /// the parameter, and an offline `file://` URL has no server at the other
  /// end at all; adding a query to either would be noise at best.
  ///
  /// The proxy is the other half of having one cache instead of two
  /// ([proxiedThroughServer]). The player keeps nothing on disk now, so a
  /// stream it fetched itself would be the one kind of playback with no
  /// local copy anywhere -- and that was the kind that filled the owner's
  /// television.
  Uri _mediaUrl(Uri url) {
    if (!url.isScheme('http') && !url.isScheme('https')) return url;
    final stream = _state?.selectedStream ?? _state?.convertedStream;
    if (stream?.infoHash != null) return withBufferAhead(url, _bufferAhead);
    final proxied = proxiedThroughServer(
      url,
      serverBase: _serverBase,
      playerToken: _proxyToken,
    );
    // Recorded rather than inferred from the URL later, because a re-open
    // for a new buffer window, a next episode or a stream the core
    // resolved differently can each change what this answers -- and what
    // the teardown needs to know is whether *anything* was ever proxied
    // under this token, not what the last URL happened to be. The server
    // has to be ours for that to mean anything: with none there is nothing
    // to wrap, and a target host that happens to serve its own `/proxy`
    // path would otherwise read as one of ours.
    _proxiedStream |= _serverBase != null && isProxiedByServer(proxied);
    return proxied;
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
    // The registry took a round trip to answer and a refusal re-opens the
    // stream ([_failBuffer]), so this is a way back onto the engine.
    if (!_stillOurs) return;
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
    if (!_stillOurs) return;
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
    if (!_stillOurs || _handedOver || _opened != url) return;
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
    // Nothing is being presented any more, and this screen stays up: the
    // card and every menu drawn over it would otherwise sit on a panel
    // held at the film's rate until the viewer pressed Back, which is the
    // juddering system UI this feature exists to avoid.
    _releaseDisplayFrameRate();
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
    _startStartupPolling();
    _refreshDhtStatus();
  }

  /// Arms the start-up cadence ([PlayerScreen.torrentStatsInterval]) for
  /// the torrent [_startTorrentStats] set up, or leaves it running if it
  /// already is. The first request goes out on the first tick, never at
  /// once (see [_startTorrentStats]); the app coming back to the front
  /// during start-up re-arms it here ([_onAppShown]).
  void _startStartupPolling() {
    if (_torrentStatsTimer != null &&
        _torrentStatsCadence == PlayerScreen.torrentStatsInterval) {
      return;
    }
    _torrentStatsTimer?.cancel();
    _torrentStatsCadence = PlayerScreen.torrentStatsInterval;
    _torrentStatsTimer = Timer.periodic(
      PlayerScreen.torrentStatsInterval,
      (_) => _pollTorrentStats(),
    );
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
    _syncTorrentStats();
    _showControls();
    _reopenAt(position, reason: 'failBuffer $_falseEnds');
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
    _syncTorrentStats();
  }

  // --- Tracks --------------------------------------------------------------

  void _selectAudio(TrackInfo track) {
    _tracks.value = _tracks.value.copyWith(activeAudioId: track.id);
    _engine?.setAudioTrack(track.id);
  }

  /// Puts libmpv's subtitle multiplier and offset back to untouched --
  /// 1.0 and 0.0 -- and records [subtitle] as the addon file they now
  /// belong to, or null when what is shown is not one.
  ///
  /// Every path that changes what is on screen calls this, which is the
  /// whole of the reset rule: the timing belongs to the player, not to
  /// the file, so one left behind by the previous pick would silently
  /// ruin a subtitle that was correct. An offset made for a file that
  /// started late is nonsense on the next one, and mpv keeps `sub-delay`
  /// across a track change exactly as it keeps `sub-speed`.
  ///
  /// Nothing but the viewer ever moves either value away from untouched,
  /// so this is also the only thing that undoes their work: an
  /// adjustment is theirs from the first press until something changes
  /// what is shown.
  void _resetSubtitleTiming([SubtitleInfo? subtitle]) {
    // Before anything moves: a press a moment ago belongs to the file
    // that is on its way out, not to the one replacing it.
    _flushRememberedTiming();
    _externalSubtitle = subtitle;
    // A count measured against the file going off says nothing about the
    // one coming on, and left on screen it would look like a claim about
    // it.
    _subtitleMatchNote = null;
    // The same for the marks, and worse: a mark is a point on the old
    // file's timeline, so one left behind would pair with the next file's
    // marks to give a lever arm across two files and a rate solved from
    // neither.
    _calibration = SubtitleCalibration.none;
    _markNote = null;
    _timing = _rememberedTiming(subtitle);
    _applySubtitleTiming();
  }

  /// What the viewer is remembered to have fixed about [subtitle] here,
  /// and untouched when nothing is -- which is every embedded track,
  /// every subtitle turned off, and every file from an addon that names
  /// no release group.
  ///
  /// The two halves are looked up under different keys because they have
  /// different causes: the speed under the series and the release group,
  /// since what a file was timed against is a property of where it came
  /// from; the offset under the video release as well, since it is the
  /// video's pre-roll less whatever the subtitle's source assumed. See
  /// [SubtitleSyncMemory].
  ///
  /// Both come back as the measured halves of a [SubtitleTiming] rather
  /// than as presses, because that is what they were when they were
  /// written: a ratio and an offset in seconds, which no whole number of
  /// presses names. The presses then count on top, so the first shift
  /// after a file is put back moves it by a tenth from where it was left
  /// rather than from nothing.
  SubtitleTiming _rememberedTiming(SubtitleInfo? subtitle) {
    final memory = _prefs?.subtitleSync;
    final releaseGroup = subtitle?.releaseGroupKey;
    if (memory == null || releaseGroup == null) return const SubtitleTiming();
    final series = _syncSeries;
    final seconds = memory.shiftSecondsFor(
      series: series,
      releaseGroup: releaseGroup,
      release: _syncRelease,
    );
    return SubtitleTiming(
      // Nothing remembered is what nothing applied looks like, so a
      // stored zero and a stored 1.0 both come back as untouched rather
      // than as a correction Reset would offer to undo.
      calibratedSpeed: _rememberedSpeed(memory, series, releaseGroup),
      calibratedDelay: seconds == 0 ? null : seconds,
    );
  }

  /// The multiplier [memory] holds for [releaseGroup]'s files of
  /// [series], and null when it holds none this build will put on a
  /// player.
  ///
  /// The file is forgiving by design and this is the one place a number
  /// out of it becomes `sub-speed`, so the range is checked here rather
  /// than there. media_kit writes the property with
  /// `mpv_set_property_string` and throws the return code away, so a
  /// value outside `<0.1-10.0>` is refused in silence and the multiplier
  /// the *previous* file left behind stays in force while the panel
  /// claims a new one -- a hand-edited preferences file is not worth
  /// that. A stored 1.0 is the file's own timing and is nothing applied,
  /// which is what nothing remembered looks like too.
  double? _rememberedSpeed(
    SubtitleSyncMemory memory,
    String? series,
    String releaseGroup,
  ) {
    final stored = memory.speedFor(series: series, releaseGroup: releaseGroup);
    if (stored == null || stored == 1) return null;
    return stored >= minSubtitleSpeed && stored <= maxSubtitleSpeed
        ? stored
        : null;
  }

  /// The show or film an adjustment made here belongs to: the meta item's
  /// id and not the episode's, because a subtitle group is timed against
  /// a series and not against one of its episodes.
  ///
  /// Read off the request rather than the loaded meta item, which is a
  /// resource that may still be in flight while the subtitle it would key
  /// is already on screen. Null -- an offline play, a stream with no meta
  /// behind it -- means nothing is remembered.
  String? get _syncSeries {
    final id = _state?.metaRequest?.path.id.trim();
    return id == null || id.isEmpty ? null : id;
  }

  /// The video release an offset was measured against: the best filename
  /// known ([castFilename] -- the file the server says it opened, else
  /// the addon's claim about what it linked to), as a bare lower-case
  /// name.
  ///
  /// The whole filename rather than a release group parsed out of it. A
  /// parse is a guess, and the same evening's worth of pre-roll is a
  /// property of the exact file: two encodes by one group can still start
  /// in different places. A narrower key is forgotten more often, which is
  /// the price of never being wrong.
  String? get _syncRelease {
    final name = castFilename(_state, serverFilename: _serverFilename);
    if (name == null) return null;
    final file = name.split(RegExp(r'[/\\]')).last.trim().toLowerCase();
    return file.isEmpty ? null : file;
  }

  /// [sources] in the order both of the list's consumers offer them: the
  /// menu, and the auto-pick that applies a file with nobody looking.
  ///
  /// One place, because a consumer that skipped the ordering would apply
  /// whichever addon answered first -- and the ranking is read from the
  /// same three things a correction is: the release the server named,
  /// the series, and what the viewer has already fixed. A third consumer
  /// calls this too.
  List<SubtitleSource> _offeredSubtitles(Iterable<SubtitleSource> sources) =>
      subtitlesByRelease(
        sources,
        release: _syncRelease,
        series: _syncSeries,
        memory: _prefs?.subtitleSync ?? SubtitleSyncMemory.empty,
      );

  /// Holds what is on screen now for [_flushRememberedTiming] to write,
  /// replacing whatever was waiting.
  ///
  /// Everything the write needs is read here rather than when it is
  /// made, so that what is written down is the file the press was made
  /// on however long the panel then stays up.
  void _rememberTiming() {
    final releaseGroup = _externalSubtitle?.releaseGroupKey;
    final series = _syncSeries;
    final release = _syncRelease;
    // What is on the player, not how it got there: a toggle, a
    // calibration and a match all arrive at one multiplier and one
    // offset, and next episode only the two numbers matter. 1.0 and 0.0
    // are what untouched looks like, and untouched is forgotten.
    final speed = _timing.speed == 1 ? null : _timing.speed;
    final shiftSeconds = _timing.delay;
    _pendingSync = null;
    // No release group from the addon, or no series: there is nothing to
    // key the adjustment on, and applying it to the files it might belong
    // to is worse than forgetting it.
    if (releaseGroup == null || series == null) return;
    _pendingSync = () {
      final prefs = _prefs;
      if (prefs == null) return;
      prefs
          .setSubtitleSync(
            prefs.subtitleSync.remembering(
              series: series,
              releaseGroup: releaseGroup,
              release: release,
              speed: speed,
              shiftSeconds: shiftSeconds,
            ),
          )
          .ignore();
    };
  }

  /// Makes the waiting write, if there is one: the adjusting is over.
  ///
  /// Called when the panel closes, before anything changes what is on
  /// screen, and on the way out. The first of those is the ordinary one;
  /// the second is what keeps a press made a moment ago from being
  /// dropped by the next press on the file that replaced it.
  void _flushRememberedTiming() {
    final pending = _pendingSync;
    _pendingSync = null;
    pending?.call();
  }

  /// Puts the addon file back that a re-open took away, before the timing
  /// made for it is written again.
  ///
  /// `open` is `loadfile`, which drops every subtitle `sub-add` put in --
  /// [MediaKitEngine.open] clears its own record of them for the same
  /// reason -- and mpv then selects by its own rules, typically a
  /// default-flagged embedded track. Nothing else re-adds it: the
  /// auto-pick has counted itself done and a re-open does not re-arm it,
  /// so without this the viewer loses the file they chose and inherits
  /// its multiplier on a track that was in step.
  void _restoreExternalSubtitle() {
    final subtitle = _externalSubtitle;
    if (subtitle == null) return;
    _engine
        ?.setExternalSubtitle(
          subtitle.url,
          title: SubtitleMenu.externalLabel(subtitle),
          language: subtitle.lang.isEmpty ? null : subtitle.lang,
        )
        .ignore();
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
  /// what it draws is what mpv is really playing.
  ///
  /// It ends the auto-pick ([_subtitlesChosenByHand]): a viewer judging
  /// the subtitle in front of them has answered the question the session
  /// preference exists to guess at, and a guess that keeps swapping the
  /// file under them is the wrong half of that answer.
  ///
  /// And it is the only path that remembers anything. Every *other* call
  /// on the timing is the machine putting a file back the way it was
  /// found ([_resetSubtitleTiming]), which is not a judgement about
  /// anything and must not be written down as one -- Reset on the panel
  /// is a judgement, and comes through here.
  void _adjustTiming(SubtitleTiming timing) {
    if (timing == _timing) return;
    _subtitlesChosenByHand = true;
    setState(() => _timing = timing);
    _applySubtitleTiming();
    _rememberTiming();
  }

  /// The panel's Reset: back to untouched, and the marks with it.
  ///
  /// Reset is the viewer undoing their own work, and the marks *are*
  /// that work -- what is on `sub-speed` and `sub-delay` after two of
  /// them is the line through them, so putting the two numbers back
  /// without dropping the points they came from undoes nothing. The
  /// next mark would join a pair the viewer has just discarded, which is
  /// still the widest pair and so still the answer, and the panel
  /// would go on saying the episode was fixed over a row reading 1.000x
  /// and +0.0 s. Short of switching files there would then be no way to
  /// take back a mark at all.
  ///
  /// It is not [_resetSubtitleTiming]: that one is the machine putting a
  /// file back the way it found it and deliberately does not remember
  /// what it did. This is a press, so it goes through [_adjustTiming]
  /// like every other press -- back to untouched is *forgotten* rather
  /// than stored as a zero, which is what that path already does.
  void _undoSubtitleTiming() {
    _calibration = SubtitleCalibration.none;
    setState(() => _markNote = null);
    _adjustTiming(const SubtitleTiming());
  }

  /// A press of "This is right": the line on screen is where it belongs,
  /// which is one mark.
  ///
  /// The mark pairs the cue's raw time in the file
  /// ([PlaybackEngine.subtitleCueStart]) with the video position that cue
  /// is *drawn* at under the transform the viewer has just approved --
  /// `speed * cue + delay` -- and never with the position the button was
  /// pressed at. **A cue is on screen for seconds and the property
  /// answers throughout them**, so the press instant is the viewer's
  /// reaction time and not a measurement of anything: taken as the mark,
  /// it would push a subtitle that was already in step late by however
  /// long they took to press, off the button that says it was right, and
  /// would put a second or two of reaction into each end of the lever arm
  /// a rate is read off -- [SubtitleCalibration.rateSpan] is sized for a
  /// tenth of a second of error at each end, and this is twenty times
  /// that.
  ///
  /// So a single mark changes nothing, and that is the shape of the
  /// feature rather than a hole in it: the viewer has already shifted the
  /// line into place by hand, and the mark only writes down where they
  /// put it. What learns a rate is a *second* mark far off, made after
  /// shifting the picture into place again out there, which is what the
  /// shift's strides exist for. The two are points on one line because
  /// each is the viewer's judgement about where a cue belongs, and that
  /// stays true whatever transform was in force when it was made -- which
  /// is what [SubtitleCalibration] fits, and why a mark is not the shift
  /// in force written down.
  ///
  /// The answer is dropped if the subtitle changed while the read was
  /// out: a property read is not the seconds-long fetch a match is, but a
  /// mark landing on the file that replaced the one it was made against
  /// is the same wrong answer.
  Future<void> _markSubtitleTiming() async {
    final engine = _engine;
    if (engine == null) return;
    final marked = _externalSubtitle?.url;
    final cueStart = await engine.subtitleCueStart();
    if (!_stillOurs || _externalSubtitle?.url != marked) return;
    if (cueStart == null) {
      // Between two lines, or subtitles off: there is nothing on screen
      // the viewer can have been pointing at, and a mark invented from
      // the position would say the file is already right.
      setState(() => _markNote = subtitleNoCueNote);
      return;
    }
    // What mpv is drawing that cue at, which is what `_timing` is: it is
    // the only thing written to either property, so the picture the
    // viewer judged is this line at this cue.
    final inForce = _timing;
    final result = _calibration.marking(
      SubtitleMark(
        cueStart: cueStart,
        videoPosition: inForce.speed * cueStart + inForce.delay,
      ),
      inForce: inForce,
    );
    _calibration = result.calibration;
    setState(() => _markNote = result.outcome.note);
    // Through the ordinary press path, because that is what it is: the
    // viewer judged the picture in front of them, so the answer is
    // theirs to keep and is remembered under the same keys as a shift.
    _adjustTiming(result.timing);
  }

  /// Whether any file *other* than the one playing is on offer, which is
  /// what a match can be measured against.
  ///
  /// Nothing about matching is drawn without one: with a single file
  /// there is nothing to compare it with, and an embedded track has no
  /// URL to fetch at all. Hiding it is the honest answer -- an offered
  /// control that cannot work says the app has a way of fixing this
  /// video that it has not got.
  bool _hasOtherSubtitleFile(PlayerState? state) {
    final playing = _externalSubtitle?.url;
    if (playing == null || state == null) return false;
    return state.externalSubtitleSources.any(
      (source) => source.subtitle.url != playing,
    );
  }

  /// Asks which file to measure the playing one against, and measures it.
  ///
  /// The list is the subtitle menu's own ordering, so what is at the head
  /// of a language here is what the addon says was cut for this release --
  /// the likeliest to be in sync, which is the whole of what makes a
  /// reference worth choosing. The choice itself is the viewer's, because
  /// nothing else knows.
  Future<void> _openSubtitleMatch() async {
    final playing = _externalSubtitle;
    if (playing == null) return;
    SubtitleInfo? reference;
    await _showSheet(
      (context) => ValueListenableBuilder<Map<String, dynamic>?>(
        valueListenable: _player!,
        builder: (context, json, _) {
          final state = json == null ? null : PlayerState.fromJson(json);
          return SubtitleReferenceMenu(
            groups: groupSubtitlesByLanguage(
              _offeredSubtitles(state?.externalSubtitleSources ?? const []),
              addonName: _subtitleAddonName,
              release: _syncRelease,
            ),
            playingId: playing.url.toString(),
            onPick: (subtitle) {
              reference = subtitle;
              Navigator.of(context).pop();
            },
          );
        },
      ),
    );
    final picked = reference;
    if (picked != null && _stillOurs) await _matchSubtitleTo(playing, picked);
  }

  /// Measures [playing] against [reference] and applies the answer, or
  /// says why it did not.
  ///
  /// The score is what is shown either way. A pair that does not match --
  /// two files for different episodes, half a film against a whole one, a
  /// reference that is itself adrift -- comes back with the same number in
  /// it, and with the transform beside it, which is what makes the refusal
  /// something the viewer can judge instead of an apology. A fraction of
  /// cues is what this replaced: it is not comparable between a file that
  /// merges lines and one that does not, and it sent the owner looking for
  /// a different reference when the reference was fine.
  ///
  /// A convincing answer goes through [_adjustTiming] like a press does,
  /// because it is one: the viewer chose the file it was measured
  /// against, so the result is their judgement and not the machine
  /// putting anything back.
  Future<void> _matchSubtitleTo(
    SubtitleInfo playing,
    SubtitleInfo reference,
  ) async {
    final client = _subtitleMatchClient;
    if (client == null || _matchingSubtitle) return;
    setState(() {
      _matchingSubtitle = true;
      _subtitleMatchNote = null;
    });
    SubtitleMatch? match;
    String note;
    try {
      match = await client.match(
        playing: playing.url,
        reference: reference.url,
      );
      note = subtitleMatchNote(match);
    } on Object {
      // One sentence for every failure: what went wrong is a fetch of a
      // URL, and an addon's subtitle URL can carry a debrid API key,
      // which this app neither logs nor puts on a screen.
      note = subtitleMatchFailureNote;
    }
    if (!_stillOurs) return;
    // Two fetches take seconds, and the viewer can have changed the
    // subtitle in the meantime: a transform measured for a file that is
    // no longer on screen would ruin the one that replaced it, and its
    // score would be a claim about a file nobody measured.
    if (_externalSubtitle?.url != playing.url) {
      setState(() => _matchingSubtitle = false);
      return;
    }
    setState(() {
      _matchingSubtitle = false;
      _subtitleMatchNote = note;
    });
    if (match != null && match.convincing) {
      _adjustTiming(
        SubtitleTiming(
          calibratedSpeed: match.ratio,
          calibratedDelay: match.offset,
        ),
      );
    }
  }

  void _selectEmbeddedSubtitle(TrackInfo track) {
    _subtitlesChosenByHand = true;
    _tracks.value = _tracks.value.copyWith(activeSubtitleId: track.id);
    _resetSubtitleTiming();
    _engine?.setSubtitleTrack(track.id);
    _client?.dispatch(
      CoreActions.playerSubtitlePreferenceChanged(
        enabled: true,
        source: 'embedded',
        language: track.language,
      ),
    );
    // A track in the file has no release group and no URL that means
    // anything on the next episode; what is worth remembering is the
    // language, and that the file's own track was preferred to a
    // download.
    final language = track.language;
    if (language != null && language.trim().isNotEmpty) {
      _rememberPick(language: subtitleLanguageLabel(language), embedded: true);
    }
  }

  void _selectExternalSubtitle(SubtitleInfo subtitle) {
    _subtitlesChosenByHand = true;
    _tracks.value = _tracks.value.copyWith(
      activeSubtitleId: subtitle.url.toString(),
    );
    _resetSubtitleTiming(subtitle);
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
    // A file the addon gave no language for is a row reading `Unknown`,
    // which names nothing to look for next episode -- the same rule that
    // keeps an unnamed release group out of the timing memory.
    if (subtitle.lang.trim().isNotEmpty) {
      _rememberPick(
        language: subtitleLanguageLabel(subtitle.lang),
        releaseGroup: subtitle.releaseGroupKey,
      );
    }
  }

  void _disableSubtitles() {
    _subtitlesChosenByHand = true;
    _tracks.value = _tracks.value.copyWith(clearSubtitle: true);
    _resetSubtitleTiming();
    _engine?.disableSubtitles();
    _client?.dispatch(
      CoreActions.playerSubtitlePreferenceChanged(enabled: false),
    );
    _rememberPick();
  }

  /// Writes a pick by hand down against this show: the language and,
  /// where the addon named one, the release group of the very file, or --
  /// with no [language] -- that subtitles were turned off here on
  /// purpose.
  ///
  /// **Only the three handlers above call this.** The auto-pick applying
  /// what is remembered must never write, or one choice made in January
  /// becomes twenty-two counts by March and the two pinned languages can
  /// never change again. It is the discipline `_adjustTiming` keeps for
  /// `subtitleSync`, for the same reason: what is stored has to be a
  /// judgement, and a machine putting something back is not one.
  ///
  /// Nothing is remembered for a play with no meta behind it -- an
  /// offline file, a deep link straight to a stream -- because there is
  /// no show to key it on.
  void _rememberPick({
    String? language,
    String? releaseGroup,
    bool embedded = false,
  }) {
    final prefs = _prefs;
    final series = _syncSeries;
    if (prefs == null || series == null) return;
    prefs
        .setSubtitlePicks(
          prefs.subtitlePicks.remembering(
            language == null
                ? SubtitleShowPick.off(series: series)
                : SubtitleShowPick(
                    series: series,
                    language: language,
                    releaseGroup: releaseGroup,
                    embedded: embedded,
                  ),
          ),
        )
        .ignore();
  }

  /// What the auto-pick should look for, or null when nothing says.
  ///
  /// The session preference wins: it is what the viewer did a moment ago,
  /// on this very run, and the memory is what they did some other
  /// evening. It carries no release group -- the core's field has no
  /// room for one -- so the group only ever comes from the memory.
  ///
  /// The languages are compared as the *labels* the menu prints, since
  /// that is what a pick is remembered as; a code coming from the core
  /// goes through the same function to get there, so `sv` and `swe` are
  /// still one language on both paths.
  _WantedSubtitle? _wanted(PlayerState state) {
    final preference = state.subtitlePreference;
    if (preference != null) {
      final language = preference.language;
      return _WantedSubtitle(
        enabled: preference.enabled,
        language: language == null ? null : subtitleLanguageLabel(language),
        embeddedFirst: preference.source == 'embedded',
      );
    }
    final remembered = _prefs?.subtitlePicks.forSeries(_syncSeries);
    if (remembered == null) return null;
    return _WantedSubtitle(
      enabled: remembered.enabled,
      language: remembered.language,
      releaseGroup: remembered.releaseGroup,
      embeddedFirst: remembered.embedded,
    );
  }

  /// Applies the session's subtitle preference (set by an earlier pick in
  /// this Player session, e.g. the previous episode) to freshly opened
  /// media: off stays off; otherwise the first track in the preferred
  /// language, from the preferred source first. Waits for the engine to
  /// report the media loaded (see [_mediaLoaded]), then retries as
  /// tracks and addon results arrive until something matches, and counts
  /// as done only once the engine accepted the pick.
  ///
  /// With no session preference -- which is every fresh start, since the
  /// core clears it on `Unload` -- what this show was last watched with
  /// stands in ([_wanted]). The two are read the same way and differ in
  /// one thing: a remembered row can also name the release group of the
  /// file that was picked, and among the files of the right language one
  /// from that group is preferred.
  ///
  /// A show never watched is still left alone. Putting this viewer's
  /// commonest language on a programme nothing is known about would put
  /// subtitles on a film that needs none, and off is the honest floor;
  /// what the menu does for that case is lift the two languages they
  /// usually pick to the top of it.
  ///
  /// **Nothing here dispatches `SubtitlePreferenceChanged`.** The core's
  /// field means "the viewer said so, this session", and writing a
  /// remembered guess into it would make a memory indistinguishable from
  /// a judgement -- which is the distinction `_subtitlesChosenByHand`
  /// rests on -- as well as counting the guess as a pick next time the
  /// menu is opened.
  void _maybeAutoPickSubtitles() {
    if (_autoPickedSubtitles ||
        _autoPickingSubtitles ||
        _subtitlesChosenByHand ||
        !_mediaLoaded ||
        _opened == null ||
        _handedOver) {
      return;
    }
    final state = _state;
    if (state == null) return;
    final preference = _wanted(state);
    if (preference == null) return;
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
      _resetSubtitleTiming();
      applied = _engine?.disableSubtitles();
    } else {
      final language = preference.language;
      bool matches(String? candidate) =>
          language == null ||
          (candidate != null &&
              subtitleLanguageLabel(candidate).toLowerCase() ==
                  language.toLowerCase());
      // The same list the menu is built from, in the same order. This is
      // the one path that applies a subtitle without the viewer looking,
      // so it is the one that has to take the language's best-known file
      // rather than whichever addon answered first.
      final offered = _offeredSubtitles(state.externalSubtitleSources);
      final candidates = offered
          .map((source) => source.subtitle)
          .where((s) => matches(s.lang));
      // A remembered group is a preference among the files of the
      // language, never a condition on the language: a show that changes
      // release family between seasons, and the six files in ten that
      // name no group at all, both land on the head of the language the
      // way they would with nothing remembered.
      final group = preference.releaseGroup;
      final external =
          (group == null
              ? null
              : candidates
                    .where((s) => s.releaseGroupKey == group)
                    .firstOrNull) ??
          candidates.firstOrNull;
      final embedded = before.subtitle
          .where((t) => matches(t.language))
          .firstOrNull;
      final externalFirst = !preference.embeddedFirst;
      if (externalFirst && external != null ||
          embedded == null && external != null) {
        _tracks.value = before.copyWith(
          activeSubtitleId: external.url.toString(),
        );
        _resetSubtitleTiming(external);
        applied = _engine?.setExternalSubtitle(
          external.url,
          title: SubtitleMenu.externalLabel(external),
          language: external.lang.isEmpty ? null : external.lang,
        );
      } else if (embedded != null) {
        _tracks.value = before.copyWith(activeSubtitleId: embedded.id);
        _resetSubtitleTiming();
        applied = _engine?.setSubtitleTrack(embedded.id);
      } else {
        return;
      }
    }
    if (applied == null) return;
    final url = _opened;
    // What this pick put on screen, so the revert below can tell whether
    // it is still undoing its own work. `sub-add` fetches the URL under
    // mpv's `network-timeout`, so a refusal can land minutes after the
    // call, and by then the viewer may have chosen a file of their own.
    final applying = _tracks.value.activeSubtitleId;
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
            if (_opened != url ||
                !_stillOurs ||
                _tracks.value.activeSubtitleId != applying) {
              return;
            }
            _tracks.value = before;
            // The one path that moves the timing outside a build: the
            // panel is drawn from [_timing], so without the rebuild it
            // would go on showing the shift and the multiplier mpv has
            // already been taken off.
            setState(() => _resetSubtitleTiming(beforeSubtitle));
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
  ///
  /// The panel closing is what says the adjusting is over, so it is
  /// where what was pressed gets written down.
  void _hideSubtitleTiming() {
    if (!_timingShown) return;
    _flushRememberedTiming();
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

  Future<void> _openSubtitleMenu() async {
    var adjustTiming = false;
    await _showSheet(
      (context) => ValueListenableBuilder<Map<String, dynamic>?>(
        valueListenable: _player!,
        builder: (context, json, _) {
          final state = json == null ? null : PlayerState.fromJson(json);
          final groups = groupSubtitlesByLanguage(
            // Ordered before grouping, so the numbering and "the first
            // option is what a tap applies" hold over the order the rows
            // are actually in.
            _offeredSubtitles(state?.externalSubtitleSources ?? const []),
            addonName: _subtitleAddonName,
            // The same name a shift is remembered against, so a row
            // marked for this release and a correction put back for it
            // are talking about the same file.
            release: _syncRelease,
          );
          return ValueListenableBuilder<PlaybackTracks>(
            valueListenable: _tracks,
            builder: (context, tracks, _) => SubtitleMenu(
              embedded: tracks.subtitle,
              groups: groups,
              // The counts, and not which languages they lift: the menu
              // ranks what it draws, so its heading's note reports a
              // comparison over the whole sheet however this screen
              // assembles it (`SubtitleMenu.picks`).
              //
              // The pins are the menu's own presentation and are applied
              // after the ordering, not inside it: both consumers of the
              // list still get the same order, and the auto-pick's one
              // case that reads it (an enabled preference naming no
              // language takes the head of the whole list) is untouched.
              picks: _prefs?.subtitlePicks,
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
    if (adjustTiming && _stillOurs) _showSubtitleTiming();
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
    if (_leaving) return;
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
    // Gone, or leaving, while the registry was answering: there is no
    // route left to replace, and a screen waiting for its own teardown
    // must not put a second player over itself -- a second engine and a
    // fresh open, from a press that asked to stop watching.
    if (!_stillOurs) return;
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
      // A leave like any other, and it takes the same road out: this
      // player is over, and the screen it goes back to would rather have
      // its answer a fraction of a second late than have mpv still
      // reading behind it.
      unawaited(_leave(PlayerScreenResult(selectVideoId: next.id)));
      return;
    }
    _handedOver = true;
    DiagnosticsLog.info('player', 'handing over to the next episode');
    // Before the push, not in [dispose]. `pushReplacement` keeps this
    // screen alive until the transition finishes, and the new player can
    // read its file's rate and ask for it inside that -- an already
    // downloaded episode opens at once -- whereupon this screen's dispose
    // would clear the ask the successor had just made. Nothing is left
    // holding a rate either way, because the release comes first.
    _releaseDisplayFrameRate();
    final streamRequest = state.streamRequest ?? widget.streamRequest;
    final subtitlesPath = state.subtitlesPath ?? widget.subtitlesPath;
    navigator.pushReplacement(
      MaterialPageRoute<PlayerScreenResult>(
        settings: const RouteSettings(name: PlayerScreen.routeName),
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
  void _onCastStatus(CastStatus reported) {
    if (!mounted) return;
    final status = _casting ? _trustedCastStatus(reported) : reported;
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

  /// [reported] as it is to be believed: with a zero the receiver has not
  /// actually reported replaced by the position it was handed (see
  /// [_castHandedAt]). The first position that is not zero is the
  /// receiver's own tick, and from then on every report is its own --
  /// including a later zero, which is then a receiver really at the start.
  CastStatus _trustedCastStatus(CastStatus reported) {
    if (_castReported) return reported;
    if (reported.position != Duration.zero) {
      _castReported = true;
      return reported;
    }
    return reported.at(_castHandedAt);
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
  /// leaves nothing behind -- no session, no LAN listener, and no remains
  /// of the session this one was picked in place of -- and says what
  /// happened.
  ///
  /// **Leaving the player is one of those endings.** Each step here is a
  /// round trip, so the viewer can press Back inside any of them, and what
  /// comes back then would pause the engine being released, open a
  /// listener on the network and hand a receiver the film -- measured, off
  /// a `connect` that took two seconds. So every continuation asks
  /// [_stillOurs], and the one that says no unwinds whatever this call has
  /// started ([_teardownCast]) rather than merely returning: a session and
  /// a socket are exactly what must not outlive the screen, and until the
  /// last line here nothing else knows they exist.
  Future<void> _startCast(CastDevice device) async {
    final cast = _cast;
    final local = _opened;
    if (cast == null || local == null || !_stillOurs) return;
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
    // Whatever session is running now is about to be replaced, so its wait
    // ends here rather than at its twenty seconds. Starting a cast zeroes
    // the listener's count even when the listener is already up, and the
    // load below is a round trip: a timer left armed for the last receiver
    // would fire in the middle of that, read the new session's zero, and
    // end a session that has had no chance to fetch anything. The next
    // wait is armed after the load, by [_watchCastFetch].
    _cancelCastFetch();
    // What comes back, not the row that was tapped: the platform is asked
    // where the receiver is as a session starts and never during discovery,
    // so the answer is the only one of the two that can carry an address.
    final receiver = await cast.connect(device);
    if (receiver == null) {
      await _explainCast('Could not start a session with ${device.name}.');
      return;
    }
    // Starting a session is a round trip to the platform and then to the
    // receiver, and the viewer can leave the player during it. Every step
    // below acts -- on the engine, on the LAN listener, on the receiver --
    // so a leave stops here, and takes the session this call has just
    // started with it: it is the one thing that must not outlive the
    // screen, and nothing else knows about it yet.
    if (!_stillOurs) {
      await _teardownCast();
      return;
    }
    final url = await _castUrl(local, receiver);
    if (url == null) {
      DiagnosticsLog.warn(
        'player',
        'no address to give a receiver at '
            '${receiver.address ?? 'an address it did not report'}',
      );
      await _endLanMedia();
      await cast.disconnect();
      // That disconnect ended whatever session was running, which on a
      // switch away from a live one is the session this screen is still
      // showing. It is ended here rather than left to the client's own
      // report of it: the report does come, and is what has been clearing
      // this, but the screen would otherwise go on presenting a cast this
      // very method has just torn down -- with its wait disarmed and its
      // listener closed -- for as long as the platform takes to say so. A
      // no-op when nothing was casting, which is every other way in here.
      await _stopCast(disconnect: false);
      await _explainCast(
        '${device.name} cannot reach this device over the network, so there '
        'is no address to give it. Casting a loopback URL it could never '
        'fetch would only look like it worked.',
      );
      return;
    }
    // The LAN listener is up by now, so this takes that with it too.
    if (!_stillOurs) {
      await _teardownCast();
      return;
    }
    final position = _position.value;
    // Local playback stops here, before the receiver starts: two copies of
    // the same film, a few seconds apart, is nobody's idea of casting.
    await _engine?.pause();
    // Pausing is a round trip too, and the continuation after it is the
    // one that must not be skipped: below is a `setState` that puts this
    // screen into casting, and while a receiver has the stream [build]
    // draws no video. On a screen that is leaving, that takes the picture
    // out of the tree for the rest of the teardown wait -- the wait whose
    // whole point is that the sinks stay alive and draining while mpv
    // stops ([_leave]) -- and nothing rebuilds it, since the unwinding
    // below clears `_castingTo` without a `setState`. Measured: the
    // surface gone from the frame, and the film handed to the receiver on
    // the way past.
    if (!_stillOurs) {
      await _teardownCast();
      return;
    }
    setState(() {
      _castingTo = device;
      _castEnded = false;
      _castHandedAt = position;
      _castReported = false;
      _castStatus = CastStatus(
        state: CastPlayerState.buffering,
        position: position,
        duration: _duration > Duration.zero ? _duration : null,
      );
    });
    // The one line that was missing while a Chromecast sat on a splash
    // screen: what we handed it, and which receiver we picked that address
    // for. The receiver's name is not in it -- it is as often a person's
    // as a room's, and the address is what the report is about.
    DiagnosticsLog.info(
      'player',
      'casting ${DiagnosticsLog.url(url)} to a receiver at '
          '${receiver.address ?? 'an address it did not report'}',
    );
    try {
      await cast.load(
        CastMedia(
          url: url,
          contentType: (compatibility as CastReady).contentType,
          title: state?.title ?? '',
        ),
        start: position,
      );
    } catch (error) {
      // A receiver turning the media down does not come back this way --
      // the plugin hands the load to the SDK and answers at once, and the
      // refusal arrives later as a media status, which the wait armed
      // below is for. What does come back this way is the platform itself
      // refusing: a session that went away between connect and load, a
      // native exception, a plugin that one day awaits the result. This
      // call is not awaited by anyone, so an error out of it would land
      // nowhere -- and the screen would sit in casting, the engine paused,
      // the listener open, with no wait armed and only Stop left. Undone
      // the way the no-address branch undoes it: the session and the
      // listener go, the film comes back here at the position it was
      // handed over at, and the viewer hears why.
      DiagnosticsLog.warn(
        'player',
        'the receiver did not take the media: $error',
      );
      if (!_stillOurs) {
        await _teardownCast();
        return;
      }
      await _stopCast();
      await _explainCast('${device.name} did not accept the stream.');
      return;
    }
    // A receiver accepting the media is another round trip. Left during
    // it, the wait below would be a timer armed after [_detach] ran, and
    // the receiver would be left playing a stream off a device whose
    // listener is about to go.
    if (!_stillOurs) {
      await _teardownCast();
      return;
    }
    _watchCastFetch();
  }

  /// Starts the wait that asks, once, whether the receiver ever came back
  /// for the stream ([_castFetchCheck]).
  ///
  /// Only for a stream served off this device: a receiver fetching from a
  /// host on the internet owes our listener nothing, and its count would
  /// stay at zero however well the cast was going.
  void _watchCastFetch() {
    _cancelCastFetch();
    if (!_lanMediaOn) return;
    _castFetchTimer = Timer(
      PlayerScreen.castFetchTimeout,
      () => unawaited(_castFetchCheck()),
    );
  }

  /// Ends the wait. What it asks is about a session, so every way out of
  /// one comes through here -- Stop, a session that ended elsewhere, a
  /// failed start, another receiver picked in its place, [dispose] -- and
  /// so does arming the next one.
  void _cancelCastFetch() {
    _castFetchTimer?.cancel();
    _castFetchTimer = null;
  }

  /// Whether the receiver ever reached this device, which is the whole of
  /// what the listener's count says and the whole of what this asks.
  ///
  /// Nothing has reached it: the address it was given is one it cannot
  /// route to. There is nothing to wait for -- a hanging connect never
  /// fails on its own -- so the session ends the way Stop ends it and the
  /// film comes back to this device, with the reason said out loud.
  ///
  /// Something has, and the viewer hears nothing at all. Whether a receiver
  /// that found us is buffering slowly or cannot decode what it fetched is
  /// not something twenty seconds can tell -- a cold torrent has made
  /// requests by then and is still filling its window -- and a modal
  /// blaming the file for a wait that is going fine is worse than silence.
  /// The log gets it; Stop is where it always was.
  Future<void> _castFetchCheck() async {
    _castFetchTimer = null;
    if (!mounted || !_casting) return;
    final served = _lanMedia?.lanMediaRequestsServed ?? 0;
    if (served > 0) {
      DiagnosticsLog.info(
        'player',
        'receiver has asked the LAN listener for $served request(s)',
      );
      return;
    }
    final device = _castingTo;
    DiagnosticsLog.warn(
      'player',
      'receiver asked the LAN listener for nothing; ending the session',
    );
    await _stopCast();
    await _explainCast(
      '${device?.name ?? 'The receiver'} never asked for the stream, so it '
      'could not reach this device at the address it was given. The film is '
      'back on this screen.',
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
    if (!isLoopbackHost(local.host)) return local;
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

  /// Ends the session and brings playback back to this device, at the point
  /// the receiver had reached.
  ///
  /// [disconnect] false when the session is already gone (it ended
  /// elsewhere) and there is nothing left to end.
  Future<void> _stopCast({bool disconnect = true}) async {
    if (!_casting) return;
    _cancelCastFetch();
    final position = _castStatus.position;
    _castingTo = null;
    if (mounted) setState(() {});
    if (disconnect) await _cast?.disconnect();
    await _endLanMedia();
    // Ending the session is a round trip, and what follows it puts the
    // film back on this device's engine -- which is the one thing a
    // player being released must not be asked to do.
    if (!_stillOurs) return;
    _position.value = position;
    await _engine?.seek(position);
    await _engine?.play();
  }

  /// Closes the LAN media listener, if this screen is what opened it. The
  /// listener exists for the length of a session and no longer, so every
  /// way out of one comes through here: Stop, a session that ended
  /// elsewhere, a failed start, and [dispose].
  Future<void> _endLanMedia() async {
    _cancelCastFetch();
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
    if (!_stillOurs) return;
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
  /// first. Only called while there is a rung to take: the last one is
  /// leaving the player, and [build]'s `PopScope` sends that to
  /// [_leavePlayer] instead, because a pop the framework makes for us
  /// would take the route out from under a player that is still reading.
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

  /// Leaves the player past that ladder: the remote's Stop key and the
  /// bar's own back arrow both end the session, and what happens to be on
  /// screen at the time does not change that.
  ///
  /// The ladder belongs to Back, which is one key for every layer and so
  /// has to take them in order. The arrow is a control the viewer aimed
  /// at, and the layer it would put away first is the OSD it is drawn on.
  void _leavePlayer() => unawaited(_leave());

  /// Cuts this screen off from everything that could still act on the
  /// player, before anything about the leaving is awaited.
  ///
  /// The wait put this screen somewhere it had never been. It used to pop
  /// at the press and release the engine two frames later, so by the time
  /// mpv was being stopped there was no screen left to answer an event.
  /// Now it stays -- built, subscribed, and holding an engine that is
  /// being released -- for as long as the teardown takes, and every
  /// subscription and every timer it still owns is a way for the last
  /// seconds of a session to reach a player on its way out. An `open` on
  /// it (the false-end recovery), a `pause` (the app going to the
  /// background), a `seek` and a `play` (a cast session ending
  /// elsewhere), and -- the one that cost the viewer something -- a
  /// `TimeChanged` of zero, because media_kit's `stop` announces itself
  /// with `position: Duration.zero` while the duration is still the
  /// film's, and a film left half-watched came back offering itself from
  /// the beginning.
  ///
  /// **So it is one act rather than a guard per handler.** A guard has to
  /// be remembered by whoever writes the next handler, and there is
  /// nothing about a handler that says it needs one; a screen with no
  /// subscriptions and no timers cannot be reached by anything, including
  /// what has not been written yet. What is left running afterwards is the
  /// build -- the picture, which is the whole reason the screen is still
  /// here.
  ///
  /// **What it cannot cancel is a continuation.** An `await` that was
  /// already in flight when the press landed is neither a subscription nor
  /// a timer; there is nothing here to cancel it with, and it resumes into
  /// the middle of the wait. That half is [_stillOurs], which every such
  /// continuation asks -- and which says there why `mounted` on its own
  /// stopped being an answer the moment this wait existed.
  ///
  /// **[State.dispose] is no longer the place for this.** It used to be
  /// the moment the screen stopped existing and so the moment everything
  /// it owned stopped mattering; with the wait in front of it, it runs
  /// after the events it was cancelling have already been answered. It
  /// still calls this, because a screen can go without a leave (the
  /// hand-over's `pushReplacement`, a route dismantled from above), and
  /// this is idempotent so that a screen going through both paths detaches
  /// once.
  ///
  /// The core field listeners go too: `player` is what opens a stream, and
  /// `ctx` writes the subtitle style onto the engine. The preferences
  /// listener stays where it is, because what it answers is a `setState`
  /// and it reaches neither the engine nor the core.
  void _detach() {
    if (_detached) return;
    _detached = true;
    _lifecycle.dispose();
    _player?.removeListener(_onPlayerState);
    _ctx?.removeListener(_onCtx);
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    unawaited(_castStatsSubscription?.cancel());
    _castStatsSubscription = null;
    _cancelCastFetch();
    _cancelOpenRetry();
    _stopTorrentStats();
    _statsHoverTimer?.cancel();
    _statsHoverTimer = null;
    _seekCheck?.cancel();
    _seekCheck = null;
    _pauseUpNext();
    _controlsTimer?.cancel();
    _controlsTimer = null;
  }

  /// Stops the player, waits for it, and only then leaves the screen.
  ///
  /// The order is the whole of it, and it is the reverse of what this
  /// screen used to do. The `quit` goes out first, because it is the kill
  /// and because it is what makes the `stop` inside the teardown come back
  /// promptly instead of waiting out a five-minute `network-timeout`. Then
  /// the teardown is awaited *with the video still in the tree and the
  /// audio device still open* -- media_kit releases both from inside it,
  /// after the stop, so the sinks are alive and being drained for exactly
  /// as long as mpv might still be handing them something. Only then does
  /// the screen go.
  ///
  /// It used to be the other way round -- leave at once, release two
  /// frames later through a future nobody held, quit only on a deadline --
  /// which is what [PlayerScreen.teardownBound] and [PlaybackEngine.quit]
  /// are each written against from their own side.
  ///
  /// **The wait yields; it never blocks.** An `await` leaves Flutter free
  /// to go on producing frames, which is what keeps something draining the
  /// video sink. A blocking join here would deadlock in precisely the case
  /// worth waiting for -- mpv waiting on the sink, the sink waiting on us
  /// -- and that is not hypothetical: it is what the community Android
  /// client does, `pthread_join` and then `mpv_terminate_destroy` inline
  /// on the UI thread, and an ANR is what it gets for it.
  ///
  /// **Keeping the sinks alive means keeping them consuming**, not merely
  /// undestroyed, which is why the wait happens here rather than from
  /// [dispose]: a screen that has already gone has nothing drawing the
  /// texture. Measured on both platforms, mpv's video output does not in
  /// fact block when nothing consumes -- eight seconds with the `Video`
  /// widget out of the tree advanced playback normally on Linux and on the
  /// Chromecast -- so this is the ordering that is safe by construction
  /// rather than by measurement, and it costs nothing.
  ///
  /// The wait is bounded and the pop is not conditional on it: a player
  /// that will not stop keeps the viewer for [PlayerScreen.teardownBound]
  /// and no longer, and finishes -- or does not -- in the background,
  /// where the teardown itself says which.
  Future<void> _leave([PlayerScreenResult? result]) async {
    if (_leaving) return;
    setState(() => _leaving = true);
    // Nothing may act on the player from here on, and this is the line
    // that says so: it comes before the first `await` below, because what
    // it stops is precisely what would otherwise get a turn during one.
    _detach();
    // The control bar leaves the frame with this ([build]), so nothing may
    // be left focused on it: hiding the bar and handing the remote back to
    // the video are one act, and a leave is no exception. The timer that
    // would have done it has gone with [_detach].
    if (_controlFocused) _focusNode.requestFocus();
    // From the press, not from the pop: the display is not presenting a
    // film any more the moment the viewer says so.
    _releaseDisplayFrameRate();
    final navigator = Navigator.of(context);
    // Nothing is logged here when the bound expires. The teardown times
    // itself, because it outlives this wait and because a hand-over runs
    // it with no screen waiting on it at all.
    await _endPlayback().timeout(PlayerScreen.teardownBound, onTimeout: () {});
    // Gone under us while we waited -- a hand-over, or the route
    // dismantled from above. There is no screen of ours left to leave.
    if (!mounted) return;
    if (navigator.canPop()) navigator.pop(result);
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // The screen is only still here to hold the picture up while the
    // player stops. Nothing it offers is aimed at anything any more, and
    // media_kit throws on a player it has released, so a late press is
    // swallowed rather than passed on -- Back included, since leaving is
    // what is already happening.
    if (_leaving) return KeyEventResult.handled;
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
      // The short step is the precise one and stays an exact seek. It is
      // three seconds by default, which is shorter than the gap between
      // one keyframe and the next on a great many releases, so a scan
      // would answer a press for three seconds with a jump of ten -- and
      // this is the key a viewer reaches for when the step is too coarse
      // already.
      _seekTo(
        _position.value +
            (key == LogicalKeyboardKey.arrowLeft
                ? -_shortSeekStep
                : _shortSeekStep),
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
        _seekBy(-_seekHold.stepFor(event, _seekStep));
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.keyL:
      case LogicalKeyboardKey.mediaFastForward:
        _seekBy(_seekHold.stepFor(event, _seekStep));
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
    // The `MouseRegion` sits above the `IgnorePointer` that covers the
    // rest of the screen ([build]), so a hover still arrives while the
    // player is stopping. It is aimed at nothing, exactly as a key press
    // is ([_onKeyEvent]): bringing the OSD back over a picture on its way
    // out is the opposite of what the viewer asked for, and the timer
    // below would be armed after [_detach] had run.
    if (_leaving) return;
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
    // Ordinarily a second call that does nothing: [_leave] detaches at the
    // press, which is where it has to happen now that this method runs
    // after the wait rather than instead of it. What is left for this line
    // is the screen that went without a leave -- the hand-over's
    // `pushReplacement`, a route dismantled from above -- where this is
    // still the moment nothing may act on the player any more.
    _detach();
    // Whatever else is true when this screen goes, nothing of ours is left
    // on the LAN: the session ends and the listener with it. Everything
    // that could report back was cancelled above, so nothing lands in a
    // disposed screen while this runs.
    _cast?.stopDiscovery().ignore();
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

  /// Ends the server's reads for this player, and retires the name they
  /// were opened under.
  ///
  /// The engine's release is about to be waited on and can block for as
  /// long as mpv is blocked, and what mpv is most often blocked *on* is a
  /// read from a stream that has stopped arriving. `network-timeout` is
  /// five minutes on purpose -- a thin swarm legitimately takes minutes to
  /// hand over the next piece, and a shorter bound would end healthy
  /// playbacks -- so waiting for it is waiting for a player nobody wants
  /// any more. This makes the read fail now instead.
  ///
  /// **Breaking the read is only half of it, and on its own it is not even
  /// the useful half.** ffmpeg runs with `reconnect=1`, so a body that
  /// stops mid-file is re-fetched through the URL it already has, token and
  /// all: measured against real libmpv, three closes on one live reader
  /// produced three fresh fetches from the origin. What ends the stream is
  /// that the server *retires the token* at the same time and answers `410
  /// Gone` to anything that arrives bearing it afterwards. The order the
  /// server documents is quit-then-close, because a demuxer that has
  /// already been cancelled never reaches its reconnect at all -- and that
  /// is now the order this runs in, since [_endPlayback] sends the quit
  /// before it gets here. The refusal is what covers the case where mpv
  /// had not reached the quit yet: a reconnect provoked on the way out
  /// meets a `410` rather than a fresh body.
  ///
  /// **It is a socket and nothing more.** A demuxer wedged somewhere other
  /// than a read -- handing a frame to the Flutter texture, waiting on the
  /// audio device -- is not polling this stream and is untouched by
  /// closing it. What covers that player is the quit ahead of this and the
  /// bound behind it. And a player that has stopped reading altogether
  /// observes the close when it next reads, or never.
  ///
  /// Synchronous and unawaited: it is a map scan on the Rust side, and a
  /// teardown has nothing to do with its answer. The answer is written
  /// down when it is not zero, and that line is the point -- the evening
  /// this whole path was built for produced a player that outlived its
  /// screen by ninety seconds and a log that said nothing at all about it,
  /// so "this player left and took its stream with it" is exactly the
  /// sentence a report was missing. Zero is ordinary (the stream may have
  /// finished on its own, or the server may be gone) and is worth no
  /// line.
  ///
  /// **Nothing it does may escape.** It reaches FFI, and FFI throws -- if
  /// the core panicked, if the bridge is not up. A throw crossing this
  /// would take the release that follows it down as well, leaving a player
  /// holding everything the close was added to free. A close that failed
  /// is a report worth a line and nothing more: the server times the
  /// stream out eventually, and the player is being released either way.
  void _closeProxiedStreams() {
    if (!_proxiedStream) return;
    final int closed;
    try {
      closed = _proxyStreams?.closeProxyStreams(_proxyToken) ?? 0;
    } catch (error) {
      DiagnosticsLog.error(
        'player',
        'could not end the proxied streams for the player being left: $error',
      );
      return;
    }
    if (closed > 0) {
      DiagnosticsLog.info(
        'player',
        'ended $closed proxied stream${closed == 1 ? '' : 's'} for the '
            'player being left',
      );
    }
  }

  /// Ends this player: the `quit`, then the streams it was reading, then
  /// the release -- and answers for how long the whole of it took.
  ///
  /// Run once per screen and shared: [_leave] awaits what this returns
  /// with the video still on screen, and [dispose] falls back to it
  /// unwatched for the screens that never had a leave. Both can happen to
  /// one screen -- a leave that gave up at the bound is disposed while its
  /// teardown is still out -- so the future is kept rather than the work
  /// repeated. Sending a second `quit` would be harmless (the engine
  /// refuses it) and disposing a released media_kit `Player` twice is an
  /// `AssertionError`.
  ///
  /// **The quit is dispatched before anything is awaited.** It is the
  /// first statement, it is an enqueue on mpv's dispatch queue and nothing
  /// else, and it is what everything after it depends on being fast.
  ///
  /// Neither half may throw out of here. The quit throws when libmpv
  /// refused the command outright, which means the player is still
  /// running and is worth a line. The release throws when mpv refused to
  /// stop, which is worth a line and must not skip the rest -- the streams
  /// are closed before it for exactly that reason, and there is nothing
  /// after it to skip.
  Future<void> _endPlayback() => _teardown ??= _runTeardown();

  /// The body of [_endPlayback], separate only so that the memo above it
  /// stays a single line.
  Future<void> _runTeardown() async {
    final engine = _engine;
    final started = DateTime.now();
    // The instrument, and the only one there is. Nothing is escalated to
    // when it fires -- the quit two lines below is the kill, and it will
    // have gone out long since -- so all it does is write down that a
    // player which should have stopped in a fraction of a second has not.
    // Armed here rather than by the waiting screen because it has to cover
    // the hand-over too, where no screen is waiting to notice.
    var overdue = false;
    final bound = Timer(PlayerScreen.teardownBound, () {
      overdue = true;
      DiagnosticsLog.warn(
        'player',
        'the player has not stopped ${PlayerScreen.teardownBound.inSeconds}s '
            'after it was left; it is still holding its memory and its socket',
      );
    });
    try {
      try {
        await engine?.quit();
      } catch (error) {
        DiagnosticsLog.error(
          'player',
          'the player refused the quit on the way out: $error',
        );
      }
      _closeProxiedStreams();
      try {
        await engine?.dispose();
      } catch (error) {
        DiagnosticsLog.error('player', 'releasing the player failed: $error');
      }
    } finally {
      bound.cancel();
      // Only a teardown that came back at all can say it was late, which
      // is the distinction a report is read for: "slow" and "never
      // stopped" want different things looked at next.
      if (overdue) {
        final took = DateTime.now().difference(started);
        DiagnosticsLog.info(
          'player',
          'the player stopped ${took.inSeconds}s after it was left',
        );
      }
    }
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
