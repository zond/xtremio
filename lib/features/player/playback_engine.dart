import 'dart:async';
// Only the names [MediaKitEngine.quit] needs: `dart:ffi` also declares a
// `Size`, and this file draws widgets.
import 'dart:ffi' show AllocatorAlloc, Int8, Pointer, PointerPointer, nullptr;

import 'package:ffi/ffi.dart' show StringUtf8Pointer, calloc;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/core.dart';
import '../../shell/display_frame_rate.dart';
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

  /// The frame rate the open video declares (`container-fps`), re-emitted
  /// whenever it changes -- which is once per file, as it is loaded.
  /// Nothing is emitted for media that declares no rate, nor on a backend
  /// without the property.
  ///
  /// The one consumer is the display: a 23.976 fps film presented on a
  /// 59.94 Hz output lands on a 3:2 cadence, which is what "the picture
  /// jumps" looks like, so the player asks the television for a refresh
  /// rate that matches (`DisplayFrameRate`). That is a statement about the
  /// video's own presentation, and it is the only thing a declared rate is
  /// allowed to decide: nothing about a subtitle's timing may read this
  /// (AGENTS.md, "Nothing re-times a subtitle but the viewer").
  Stream<double> get videoFrameRate;

  /// Tells the engine what the display is **really** refreshing at, in
  /// hertz, so it can time frames against the screen instead of against
  /// the audio clock; `null` gives that claim back.
  ///
  /// The other half of the story above. Asking the television for the
  /// film's own rate removes the cadence; this is what makes mpv aware of
  /// the rate it landed on, which on Android it cannot measure for itself
  /// -- see [MediaKitEngine.displaySyncProperties] for the reading that
  /// justifies it and for why it is Android's alone. The caller owns the
  /// lifetime: it is set while a rate is being held on the display and
  /// cleared the moment it is given back, because an override outliving
  /// the mode it described is worse than none.
  ///
  /// Only libmpv has the properties; any other backend does nothing here.
  Future<void> setDisplayRefreshRate(double? hz);

  /// Opens [url] and starts playing from [start].
  Future<void> open(Uri url, {Duration start = Duration.zero});

  /// Seeks to [position] exactly, decoding forward from the keyframe
  /// before it if that is what landing there takes.
  Future<void> seek(Duration position);

  /// Moves [delta] from wherever playback is, landing on a keyframe: the
  /// step a viewer scanning through the film asks for.
  ///
  /// It is a different question from [seek], not a cheaper way of asking
  /// the same one. An exact seek lands on the requested moment by
  /// decoding forward from the keyframe before it, invisibly, and on a
  /// 32-bit Amlogic television box with `hwdec=mediacodec-copy` that
  /// decode is what a press of the seek key costs. A scan does not need
  /// the moment -- a second or two either way is invisible while the
  /// picture is moving -- so it takes the keyframe and lands at once,
  /// which is what every television player does and what the owner
  /// noticed for himself: with the cache empty, mpv had nothing to seek
  /// within, fell back to a keyframe seek, and "the seeking becomes
  /// smooth".
  ///
  /// **Relative, and that is the whole of why this is not a [seek] with a
  /// flag on it.** A keyframe seek to an absolute target lands on the
  /// keyframe *before* it, so a forward step shorter than the distance
  /// between keyframes lands behind where it started: x264's default
  /// `keyint` of 250 frames is 10.4 s at 23.976 fps, against a
  /// `seekTimeDuration` of 10 s, and a viewer pressing forward would
  /// watch the film sit still. Asked as a relative move, mpv rounds the
  /// other way -- to the first keyframe at or past the target, and back
  /// past it going backwards -- so a press always moves at least what it
  /// asked for, in the direction it asked for.
  Future<void> scanBy(Duration delta);

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

  /// Where the cue on screen starts on the **subtitle file's own
  /// timeline**, in seconds: its raw time in the file, before
  /// [setSubtitleSpeed] multiplied it and [setSubtitleDelay] moved it.
  /// Null when there is no cue on screen, and on every backend but
  /// libmpv.
  ///
  /// This is half of a mark -- the other half is the video position the
  /// viewer says that line belongs at -- and which timeline the number
  /// is on decides every one of them: two marks read off different
  /// timelines are points on two different lines, and
  /// `SubtitleCalibration` fits a line. Which of the two libmpv answers
  /// with was settled by measurement rather than by documentation; the
  /// measurement is written down at [MediaKitEngine.subtitleCueStart],
  /// which is the one place that would change if a build of libmpv ever
  /// answered the other one.
  Future<double?> subtitleCueStart();

  /// Applies to the subtitles drawn over the video from the next build.
  Future<void> setSubtitleStyle(SubtitleStyle style);

  /// The video surface, without any built-in controls. Subtitles are drawn
  /// [subtitleBottomPadding] above the bottom edge, so the screen can lift
  /// them clear of its own controls.
  Widget buildVideo(BuildContext context, {double subtitleBottomPadding = 24});

  /// Stops the playback and releases everything the backend holds for it,
  /// the video texture and the audio device among them.
  ///
  /// It can be slow and it can fail -- `Player.stop()` waits on the mpv
  /// core thread, which is the thread that has to answer for whatever the
  /// playback was doing -- so [quit] goes first. That is what gets the
  /// core thread out of whatever the playback had it doing and on to the
  /// stop, and with it sent this comes back in a fraction of a second.
  ///
  /// **Awaited with the sinks still attached, because the release of them
  /// happens inside here.** There is no separate sink to let go of
  /// afterwards and none to withhold: media_kit tears the native video
  /// output down from `Player.dispose`, after its `stop()`, which is
  /// exactly the order wanted. What the caller owes is to keep drawing the
  /// video and to keep the audio device open until this returns.
  Future<void> dispose();

  /// Ends the playback outright -- libmpv's own `quit` -- freeing the
  /// demuxer and the connection it is reading through, and leaves this
  /// engine unusable.
  ///
  /// **This is the kill, and it is sent the moment the player is left**,
  /// ahead of [dispose] rather than behind it on a deadline. There is
  /// nothing stronger to escalate to: `mpv_terminate_destroy` deadlocks
  /// against an attached event loop, which is why media_kit schedules its
  /// own five seconds after the teardown it belongs to (the whole of that
  /// is at [MediaKitEngine.quit]). So withholding the only kill there is
  /// until the slow path has failed buys nothing, and costs the demuxer,
  /// the socket and the server engine that socket keeps live for as long
  /// as the slow path takes. That is what this used to be for, and what it
  /// is no longer.
  ///
  /// **It does not spoil the teardown behind it, which was measured before
  /// it was relied on.** `quit` does not end mpv's core thread: the
  /// shutdown broadcasts and then loops, draining the core's dispatch
  /// queue until the last client is destroyed, and media_kit destroys its
  /// client five seconds late. So the `stop` inside [dispose] is
  /// dispatched and answered exactly as it would be on a live core.
  /// Against real libmpv, three seconds after a quit -- demuxer gone,
  /// socket returned -- `dispose` still came back in single-digit
  /// milliseconds, and nothing threw in any run.
  ///
  /// **What it covers, and what it does not.** It returns at once, so a
  /// caller is never blocked by it -- but "the call returns" and "the
  /// player dies" are two different claims, and only the first one is
  /// unconditional. [MediaKitEngine.quit] enqueues on the mpv core's own
  /// dispatch queue, and the core thread is the only thread that can act
  /// on it. A core thread that is genuinely stuck swallows this along with
  /// everything else, and nothing in this process can reach that thread.
  /// What bounds that case is that a player with no disk cache costs
  /// memory and a socket rather than a volume.
  ///
  /// Throws when the backend refused to accept the command, so a caller
  /// that logs a kill is logging one that was at least asked for.
  ///
  /// Calling it twice, or on a player that has already gone, does nothing
  /// -- a caller may well have lost track of what the player is doing, so
  /// the implementation and not the caller is what has to be sure.
  Future<void> quit();
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
/// overlay polls the embedded server with (absent, the FFI one),
/// [displayFrameRate] (absent, the `xtremio/device` channel) and
/// [dhtStatus] (absent, `ServerClient().dhtStatus`) and [proxyStreams], the
/// way a player ends the streams it is reading on its way out (absent, the
/// FFI one). The subtitle style is not here: the screen derives it from the
/// profile's settings in the `ctx` field.
class PlaybackScope extends InheritedWidget {
  const PlaybackScope({
    super.key,
    required this.createEngine,
    this.fullscreen,
    this.torrentStats,
    this.subtitleMatch,
    this.displayFrameRate,
    this.dhtStatus,
    this.proxyStreams,
    required super.child,
  });

  final PlaybackEngineFactory createEngine;
  final FullscreenController? fullscreen;
  final TorrentStatsClient? torrentStats;

  /// What the film's own frame rate is asked of the display through, on a
  /// television and nowhere else.
  final DisplayFrameRate? displayFrameRate;

  /// What "Match to another subtitle" asks for a ratio and an offset.
  final SubtitleMatchClient? subtitleMatch;

  /// What the start-up card's one DHT explanation reads
  /// (`ServerHandle::dht_status`). A plain function rather than a client
  /// interface, because it is the only thing about the DHT the player ever
  /// asks: cheap and synchronous, read once when torrent polling starts,
  /// never on a timer of its own.
  final DhtStatus Function()? dhtStatus;

  /// How the screen ends the proxied streams its player is reading when it
  /// goes -- the other half of the token it puts in the URL. An interface
  /// rather than a function because a test wants to see which token was
  /// closed, and because every player test would otherwise reach FFI on
  /// its way out.
  final ProxyStreamControl? proxyStreams;

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

  static DisplayFrameRate displayFrameRateOf(BuildContext context) =>
      _maybeOf(context)?.displayFrameRate ?? const ChannelDisplayFrameRate();

  static DhtStatus Function() dhtStatusOf(BuildContext context) =>
      _maybeOf(context)?.dhtStatus ?? (() => const ServerClient().dhtStatus);

  static ProxyStreamControl proxyStreamsOf(BuildContext context) =>
      _maybeOf(context)?.proxyStreams ?? const ServerClient();

  @override
  bool updateShouldNotify(PlaybackScope oldWidget) =>
      createEngine != oldWidget.createEngine ||
      fullscreen != oldWidget.fullscreen ||
      torrentStats != oldWidget.torrentStats ||
      subtitleMatch != oldWidget.subtitleMatch ||
      displayFrameRate != oldWidget.displayFrameRate ||
      dhtStatus != oldWidget.dhtStatus ||
      proxyStreams != oldWidget.proxyStreams;
}

/// [PlaybackEngine] over `media_kit` (libmpv). Direct play only: whatever
/// the URL serves is decoded on this device; the server never transcodes.
///
/// [hardwareDecoding] (`profile.settings.hardwareDecoding`) is fixed at
/// creation: media_kit takes it as the video controller's configuration
/// (`hwdec=auto` vs `no`), and a controller cannot be reconfigured.
class MediaKitEngine implements PlaybackEngine {
  MediaKitEngine({bool hardwareDecoding = true})
    : _player = Player(configuration: playerConfiguration) {
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
      _observeFrameRate(native).ignore();
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
  ///
  /// **`cache-on-disk=no` is the whole of the player's disk policy.**
  /// media_kit 1.2.6 starts libmpv with `cache-on-disk=yes`
  /// (`player/native/player/real.dart`), and what that buys is a cache file
  /// mpv unlinks the moment it creates it: no name in the directory, so no
  /// `du`, no `dumpsys diskstats` and no walk the server's own cleaner
  /// performs can see it, and the blocks come back only when the fd closes.
  /// On the owner's Chromecast one 90-second title held 928 MB that way
  /// while three separate instruments reported the app was using 46 MB.
  ///
  /// There is one cache on this device now and it is the server's: named
  /// files, a configured limit, a free-space floor, a cleaner that evicts,
  /// and survival across a crash. Every stream reaches the player through
  /// it ([proxiedThroughServer]), so a second copy in a file nobody can see
  /// buys nothing that the first one does not already do better. It is set
  /// here, once per player and never again, because it is a property of
  /// this app rather than of any one media -- there is no condition under
  /// which it comes back on, and nothing left that would turn it off.
  ///
  /// `force-seekable` is not here: it is a claim about the stream being
  /// opened rather than about the player, so [forcesSeekable] decides it
  /// per `open`.
  ///
  /// **`video-sync=display-resample` is not here because it is not a
  /// property of this player.** It is set per playback, against the rate
  /// the display turned out to be on, and taken off again the moment
  /// nothing is being presented -- [displaySyncProperties] and
  /// [setDisplayRefreshRate] are where it lives. What belongs here is why
  /// it is set at all, because that is a fact about this VO rather than
  /// about any one film.
  ///
  /// A 23.976 fps film on a 59.94 Hz output is laid on a 2.5:1 cadence --
  /// two refreshes for one frame, three for the next -- and mpv's own
  /// answer to a mismatched rate is to lock the video to the display and
  /// resample the audio by the difference. Every display-sync mode needs
  /// the display's refresh rate, and mpv cannot *measure* it here:
  /// media_kit runs it with `vo=gpu` and `gpu-context=android`
  /// (`android_video_controller/real.dart`), and in the build it ships for
  /// Android (`mpv v0.36.0-549-g78d43740f5`) that context answers
  /// `VO_NOTIMPL` to every request, `VOCTRL_GET_DISPLAY_FPS` included
  /// (`video/out/opengl/context_android.c`), with `vo_gpu` handing the
  /// request straight to it. So the reported rate stays 0,
  /// `vo_get_vsync_interval` answers -1 (`video/out/vo.c`) and
  /// `handle_display_sync_frame` returns before it sets
  /// `display-sync-active` (`player/video.c`). mpv's own estimate cannot
  /// start it either -- vsync samples are collected only from frames that
  /// are already display-synced, so there is nothing to bootstrap from.
  ///
  /// **The measurement this comment used to say was missing has been
  /// taken, and it is worse than it feared.** What this file argued for
  /// instead was the other road -- ask the panel for the film's own rate
  /// (`DisplayFrameRate`, ANDROID.md) and there is no cadence left to
  /// resample around -- and that ask was *not* refused. On the owner's
  /// Chromecast the projector arrived at 23.976 Hz for a 23.976 fps H.264
  /// film and stayed there (`mActiveSfDisplayMode` id 1418,
  /// `mActiveRenderFrameRate=23.976025`, SurfaceFlinger
  /// `activeMode=23.98 Hz`), and the stats OSD read `23.98 out / 23.98
  /// container` with **2779 frames dropped at the video output and 0 at
  /// the decoder**: roughly one frame in five, decoded on time and thrown
  /// away at presentation. Matching the rate is what exposed it -- at
  /// 59.94 the 3:2 cadence had somewhere to hide the misses. Removing the
  /// cadence was necessary and is not sufficient; mpv is still timing
  /// every frame against the audio clock with no idea when the screen
  /// refreshes, and that is what the option fixes.
  ///
  /// So the pair is set now, on the rate the display is measured to be on
  /// rather than the one it was asked for, and only on Android. The
  /// standard it is kept on is the same one that would have refused it:
  /// `display-sync-active` and the vo drop count are both on the stats
  /// OSD, and if display sync does not start, or the count is no better
  /// than 2779, this comes out again rather than being defended on the
  /// theory.
  static const Map<String, String> mpvOverrides = {
    'network-timeout': '300',
    'cache-on-disk': 'no',
    // The window behind the play head, set apart from the one ahead of it:
    // media_kit puts [memoryCacheBytes] on both, and [backCacheBytes] says
    // why the two are not the same number.
    'demuxer-max-back-bytes': '$backCacheBytes',
  };

  /// What starts mpv's display sync on a display refreshing at [hz]
  /// frames a second, and an empty map where there is nothing to say.
  ///
  /// **Two properties, and neither is any use alone.**
  /// `override-display-fps` is what `update_display_fps` takes *ahead* of
  /// the rate the VO reports (`video/out/vo.c`), and a non-zero value
  /// there is the only display-rate gate in `handle_display_sync_frame`;
  /// `video-sync` is what asks for display sync at all, and its default
  /// (`audio`) times every frame against the audio clock however well the
  /// display has been described. Both names were read out of the very
  /// `libmpv.so` media_kit ships for Android
  /// (`mpv v0.36.0-549-g78d43740f5`), along with `display-sync-active` and
  /// `display-fps`, which are how the stats OSD says whether this took
  /// ([PlaybackStats]). The rate goes on first: display-resample asked for
  /// while the override is still 0 is display sync with no display rate,
  /// which is the state this whole thing exists to leave.
  ///
  /// **[hz] is a measurement, never the rate that was asked for.** The ask
  /// (`DisplayFrameRate`) is a vote on the surface on Android 12 and up
  /// and a window attribute below it; neither reports back, both are
  /// asynchronous, and a set can land on a neighbouring mode or move the
  /// display nowhere at all. A rate we asked for and did not get is
  /// exactly the wrong number to hand mpv -- it swaps one wrong cadence
  /// for another and hides it behind a `display-sync-active` reading yes
  /// -- so the number comes from the display itself, afterwards
  /// (`DisplayFrameRate.refreshRate`, `MainActivity.DisplayRefreshRates`),
  /// and again whenever it changes.
  ///
  /// **Android only, and that is not a hedge.** Everywhere else mpv's VO
  /// measures the rate itself and is right about it, so an override there
  /// replaces a true number with one of ours -- which is the whole of what
  /// this does. The Android VO is the one that answers `VO_NOTIMPL` (see
  /// [mpvOverrides]) and so the one with nothing to lose.
  ///
  /// Empty rather than [displaySyncOff] for a rate that is not a rate:
  /// with nothing measured there is nothing to claim, and a player that
  /// never turned display sync on has nothing to give back either.
  static Map<String, String> displaySyncProperties(
    double? hz, {
    TargetPlatform? platform,
  }) {
    if ((platform ?? defaultTargetPlatform) != TargetPlatform.android) {
      return const {};
    }
    if (hz == null || !hz.isFinite || hz <= 0) return const {};
    return {'override-display-fps': '$hz', 'video-sync': 'display-resample'};
  }

  /// What gives display sync back, written by whichever player turned it
  /// on once it stops presenting.
  ///
  /// A zero `override-display-fps` is what mpv reads as "no display rate",
  /// which is where this started, and `audio` is mpv's own `video-sync`
  /// default. Both come off, and that matters more than the setting did:
  /// an override describes the mode one film was shown in, and one left
  /// standing over the next film -- or over a display the viewer has since
  /// changed, or one the platform put back when the ask was cleared -- is
  /// a worse lie than no override at all, because it looks measured.
  static const Map<String, String> displaySyncOff = {
    'override-display-fps': '0',
    'video-sync': 'audio',
  };

  /// Whether to tell mpv that [url] can be seeked in whatever the demuxer
  /// concluded (`force-seekable`), which is decided per stream because it
  /// is a claim about *this* server and not about seeking in general.
  ///
  /// mpv refuses a seek the demuxer says it cannot make -- it restores the
  /// position rather than waiting -- and a demuxer decides that from what
  /// it could read when the file opened, not from what the stream can
  /// serve. A Matroska file keeps its index at the end, which on a torrent
  /// is the last thing to arrive, so the demuxer concludes the file is
  /// unseekable and every seek past the buffered part puts the position
  /// straight back. The option exists for exactly the case where the
  /// caller knows better than the demuxer, and for our own stream we do:
  /// `server/src/routes/stream.rs` answers any byte range with
  /// `Accept-Ranges: bytes`, seeks the torrent reader to the offset --
  /// which re-prioritises the swarm around it -- and streams from there.
  /// A cold offset waits; it is never refused. So the honest thing to tell
  /// mpv is that the stream is seekable, and let a seek into a part nobody
  /// has yet be the wait it really is -- a wait `network-timeout` above
  /// already covers, and one longer than that arrives as the false end of
  /// file the player re-opens from.
  ///
  /// **That claim is about the embedded server and nothing else**, so it
  /// is made only for the loopback address the server binds
  /// (`http://127.0.0.1:<port>/`). An addon can answer with a URL on its
  /// own host, and the player opens that untouched: a live HLS playlist,
  /// or a host that ignores `Range`, really cannot be seeked in, and
  /// forcing it there does not make a seek work -- it turns a refusal the
  /// viewer sees into a bar sitting at a position no packets will ever
  /// arrive for. A refusal is the better failure. An offline `file://` is
  /// left alone too: it is seekable and the demuxer knows it.
  ///
  /// What forcing cannot do is invent an index. A demuxer with no index at
  /// all may still refuse the seek itself, which is a different fault with
  /// a different fix (fetching the tail of the file at open, on the server
  /// side), and the stats OSD's `partially` and `ranges` rows are what
  /// tell the two apart -- `seekable` is our own answer here, not the
  /// demuxer's.
  ///
  /// **A `/proxy` URL is on the server and is still not the server's
  /// stream.** Every remote stream now arrives at the loopback address
  /// ([proxiedThroughServer]), which is exactly the address this method
  /// used to read as "our torrent reader, which waits rather than refuses".
  /// It is not: the route relays a host we know nothing about, so the claim
  /// that could be made about the addon's own URL is the claim to make
  /// about the proxy of it -- and that claim was no.
  static bool forcesSeekable(Uri url) {
    if (!url.isScheme('http') && !url.isScheme('https')) return false;
    if (isProxiedByServer(url)) return false;
    return isLoopbackHost(url.host);
  }

  /// Sets [mpvOverrides] on the native backend. Only libmpv has
  /// properties; any other backend keeps its own behaviour, and a player
  /// torn down before it initialised is not an error worth surfacing.
  static Future<void> _applyOverrides(PlatformPlayer? platform) async {
    if (platform is! NativePlayer) return;
    for (final MapEntry(:key, :value) in mpvOverrides.entries) {
      await _write(platform, key, value);
    }
  }

  /// One mpv property on this player's backend, if it has one.
  Future<void> _setProperty(String name, String value) =>
      _write(_player.platform, name, value);

  static Future<void> _write(
    PlatformPlayer? platform,
    String name,
    String value,
  ) async {
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty(name, value);
    } catch (_) {
      // Gone, or a build of libmpv without the property. Playback is
      // still playback.
    }
  }

  /// What mpv keeps in memory ahead of the play head: 32 MiB of packets,
  /// media_kit's own default written out rather than inherited.
  ///
  /// `PlayerConfiguration.bufferSize` is set on both `demuxer-max-bytes`
  /// and `demuxer-max-back-bytes` (media_kit 1.2.6,
  /// `player/native/player/real.dart`), so on its own this number is per
  /// side and the player's ceiling is twice it. It is not on its own any
  /// more: [backCacheBytes] takes the back side down through
  /// [mpvOverrides], and the ceiling is the sum of the two, 48 MiB.
  ///
  /// **The forward side was reconsidered when the disk cache went, and
  /// deliberately left where it is.** With `cache-on-disk=no` this is the
  /// whole of what the player holds ahead: about two minutes of a 2.3 Mbps
  /// film and nine seconds of a 30 Mbps remux, and everything past that
  /// comes from the server on demand. Raising it is the obvious answer and
  /// the wrong one here, for three reasons that all point the same way.
  ///
  /// The room is not there. The owner's television has 2 GB of RAM for the
  /// whole system, this app measured 245 MB PSS with a player up, and the
  /// embedded server and its torrent engine live in that same process --
  /// so a doubling is another 64 MiB of resident memory on the device with
  /// the least of it, taken from the engine that is feeding the playback.
  ///
  /// The cushion is not supposed to be here. This is the design that moved
  /// the read-ahead into the server's cache, where it is bounded, named,
  /// swept and survives a crash. Growing the player's memory instead is the
  /// two-cache thinking that was just removed, one storey up: it would buy
  /// the same window at a worse price, in the one place nothing can reclaim
  /// it from.
  ///
  /// And the number is not the bottleneck yet. `/proxy` relays without
  /// caching today (`server/tests/proxy.rs`), so the honest next move if
  /// two minutes proves too thin is to make the server's side of the hop
  /// keep what it fetched -- which helps a re-watch, a backward seek and a
  /// second player, none of which a bigger heap here helps at all.
  ///
  /// It is written out rather than inherited because it is now the player's
  /// only buffer, and the only buffer should not be somebody else's
  /// default: a media_kit release that changed `bufferSize` would change
  /// what a television holds, silently. mpv's own default for the forward
  /// side is 150 MiB and for the back side 50 MiB, so what media_kit hands
  /// out is already a sixth of that; what is written here is smaller
  /// still, and on purpose.
  static const int memoryCacheBytes = 32 * 1024 * 1024;

  /// What mpv keeps in memory *behind* the play head: 16 MiB, half of what
  /// it keeps ahead, where media_kit would have made the two the same.
  ///
  /// The two sides are not worth the same. The window ahead is what
  /// playback is about to need and what a thin swarm is racing to fill;
  /// the window behind is what a backward seek lands in without going to
  /// the server, and nothing else. Every stream reaches this player
  /// through the embedded server's own cache ([proxiedThroughServer]), so
  /// a seek that falls out of this window is a range request answered from
  /// the server's disk, not a re-download -- a stall of a second or so
  /// while the demuxer re-opens, rather than a re-fetch from the swarm.
  ///
  /// What 16 MiB is in seconds, at the bitrates this app plays: about
  /// 90 s of a 1.5 Mbps SD encode, 45 s of a 3 Mbps 720p encode, 27 s of a
  /// 5 Mbps 1080p encode and 17 s of an 8 Mbps one. The remote's seek step
  /// is ten seconds (`SeekBar.defaultSeekStep`), so one press back stays in
  /// memory at anything up to about 13 Mbps, and a 30 Mbps remux gets
  /// 4.5 s, where the old 32 MiB gave it 9 -- both less than a press, so
  /// nothing changes for the file that was already going to the server.
  /// At 8 MiB, the other number considered, a press back at 8 Mbps would
  /// have missed the window too.
  ///
  /// The reason is the same television as above: 32 + 32 MiB was 64 MiB
  /// standing for every open player on a device where the low-memory
  /// killer took the app at 311-379 MB resident, and halving the back side
  /// is 16 MiB of that for a cost nobody watching forwards ever pays.
  static const int backCacheBytes = 16 * 1024 * 1024;

  /// media_kit's own defaults with [memoryCacheBytes] named.
  static const PlayerConfiguration playerConfiguration = PlayerConfiguration(
    bufferSize: memoryCacheBytes,
  );

  /// The controller configuration for a `hardwareDecoding` setting.
  ///
  /// media_kit's own default is `hwdec=auto-safe`, and in the libmpv it
  /// ships the direct `mediacodec` hwdec is deliberately not on that
  /// whitelist, so on Android auto-safe can only ever pick
  /// `mediacodec-copy`: the codec decodes into its own buffer, ffmpeg copies
  /// every frame out of it into CPU memory, and mpv uploads that to GL. On a
  /// Chromecast with Google TV that copy is 10-30 ms of a 41 ms frame on the
  /// one core the player shares with everything else, and the stats OSD
  /// showed it as `hwdec mediacodec-copy` with thousands of `vo` drops and
  /// none at the decoder -- frames decoded fine and arrived late. ffmpeg
  /// announces the mode at every decoder init with "Both surface and
  /// native_window are NULL".
  ///
  /// So name the list mpv-android uses: direct `mediacodec` first -- mpv's
  /// AImageReader interop renders the codec's output as an external texture
  /// with no CPU copy -- and `mediacodec-copy` as the fallback, which is
  /// exactly today's behaviour if the direct path fails to initialise. The
  /// OSD's hwdec row says which one took.
  static VideoControllerConfiguration configurationFor({
    required bool hardwareDecoding,
  }) => VideoControllerConfiguration(
    enableHardwareAcceleration: hardwareDecoding,
    hwdec: hardwareDecoding ? 'mediacodec,mediacodec-copy' : 'no',
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

  final StreamController<double> _videoFrameRate =
      StreamController<double>.broadcast();

  /// The last rate emitted, so an observation that repeats itself (mpv
  /// answers the first one immediately, and a re-open of the same file
  /// answers with the same number) does not ask the display twice.
  double? _lastVideoFrameRate;

  /// Whether display sync is on for this player, so the reset is written
  /// only by a player that turned it on. Without it a television whose
  /// display never reported a rate -- and every desktop, where nothing is
  /// ever set -- would write [displaySyncOff] over mpv's own defaults on
  /// the way out, which is a claim about a player nobody measured.
  bool _displaySynced = false;

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

  @override
  Stream<double> get videoFrameRate => _videoFrameRate.stream;

  /// Follows mpv's `container-fps` so the display can be asked to present
  /// the film at its own rate. Only the native (libmpv) backend exposes
  /// properties.
  ///
  /// An observation is what this needs rather than a read: the rate is not
  /// known when the player is built, and by the time it is, nobody is
  /// looking. mpv answers a newly observed property with its current value
  /// straight away, so registering after the file loaded still reports it,
  /// and the same event carries the next file's rate when there is one.
  Future<void> _observeFrameRate(NativePlayer native) async {
    try {
      await native.observeProperty('container-fps', (value) async {
        final fps = double.tryParse(value.trim());
        // A container that declares nothing answers with an empty string
        // or a zero, and either is worse than not asking at all.
        if (fps == null || !fps.isFinite || fps <= 0) return;
        if (fps == _lastVideoFrameRate) return;
        _lastVideoFrameRate = fps;
        if (!_disposed && !_videoFrameRate.isClosed) _videoFrameRate.add(fps);
      });
    } catch (_) {
      // Torn down before the player initialised, or a build of libmpv
      // without the property: the display keeps whatever rate it is on.
    }
  }

  /// Puts [displaySyncProperties] on the player, or [displaySyncOff] back
  /// when there is no rate left to sync to.
  ///
  /// Whoever holds a rate on the display owns this: `PlayerScreen` sets it
  /// as the display reports what it settled on and clears it on every path
  /// that gives the rate back, which is the same list that clears the ask
  /// itself. Nothing here reads the film's own rate -- what mpv is being
  /// told is what the *screen* is doing.
  @override
  Future<void> setDisplayRefreshRate(double? hz) async {
    final start = displaySyncProperties(hz);
    if (start.isEmpty && !_displaySynced) return;
    _displaySynced = start.isNotEmpty;
    for (final MapEntry(:key, :value)
        in (start.isEmpty ? displaySyncOff : start).entries) {
      await _setProperty(key, value);
    }
  }

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
    // `cache-on-disk=no` is already in force and stays in force: it is set
    // once per player ([mpvOverrides]) and nothing here or anywhere else
    // writes it again. Awaiting [_overrides] is what puts it in front of
    // the first `loadfile` rather than a moment after it.
    await _overrides;
    // Before the `loadfile`, and before every one of them: mpv reads
    // `force-seekable` once, when it builds the demuxer, so it has to be
    // set for the stream about to be opened and not for the last one.
    await _setProperty('force-seekable', forcesSeekable(url) ? 'yes' : 'no');
    await _player.open(Media(url.toString(), start: start));
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  /// The mpv command a [scanBy] of [delta] is.
  ///
  /// Written out here because media_kit has no relative seek and throws
  /// `mpv_command`'s return code away (it logs it and returns), so a
  /// misspelled flag would be a press that seeks nowhere, in silence.
  /// Measured against the libmpv this host has (0.41.0): `relative` and
  /// `keyframes` answer `success`, and a `relative+keyframe` a letter
  /// short answers `MPV_ERROR_INVALID_PARAMETER`. Both words are in the
  /// build media_kit ships for Android
  /// (`mpv v0.36.0-549-g78d43740f5`) as well.
  ///
  /// Seconds with four decimals, which is how media_kit writes its own
  /// absolute seek.
  static List<String> scanCommand(Duration delta) => [
    'seek',
    (delta.inMilliseconds / 1000).toStringAsFixed(4),
    'relative+keyframes',
  ];

  /// The `keyframes` flag is what makes this a scan, and it has to be on
  /// the command: media_kit starts libmpv with `hr-seek=yes`
  /// (`player/native/player/real.dart`, the properties it sets for every
  /// platform), which asks mpv for a precise seek wherever one is
  /// possible -- relative seeks included, where mpv's own default would
  /// have taken the keyframe. An explicit flag overrides the option, and
  /// that was measured rather than read: with `hr-seek=yes` set first, a
  /// bare `seek 10 relative` took 18.7 ms and landed on 315.000 of a
  /// 10 s-keyframe file, and `seek 10 relative+keyframes` took 3.7 ms and
  /// landed on 320.
  ///
  /// A burst of these is mpv's own business and not ours: 20 relative
  /// seeks handed to libmpv back to back were merged into 3 actual seeks
  /// landing at the sum of all 20 (`queue_seek` adds a relative seek to
  /// the one already queued), so a held key already scans as fast as the
  /// core can serve it without this having to coalesce anything.
  ///
  /// Off libmpv there is nothing to flag, and a scan is an ordinary seek
  /// from where playback is. So it is once media_kit has decided the
  /// media is over: `Player.play` seeks back to zero when its own
  /// `completed` is still set, and only its `seek` clears that, so a
  /// viewer scanning back from the end of a film and pressing play would
  /// otherwise be taken to the beginning of it.
  @override
  Future<void> scanBy(Duration delta) {
    final native = _player.platform;
    if (native is! NativePlayer || _player.state.completed) {
      return _player.seek(_player.state.position + delta);
    }
    return native.command(scanCommand(delta));
  }

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

  /// The mpv property holding the start time of the subtitle event being
  /// drawn, in seconds.
  static const String subtitleCueStartProperty = 'sub-start';

  /// What that property answers, and how we know.
  ///
  /// mpv's own documentation leaves it open whether `sub-start` is the
  /// cue's raw time in the file or one already moved by `sub-delay` and
  /// `sub-speed`, and a mark is only worth making if the answer is the
  /// raw one: mixing the two frames of reference gives two marks two
  /// different lines to sit on, and the solve is then confidently wrong.
  /// The sign of `sub-speed` was taken from the manual once and had to be
  /// confirmed on the owner's television, so this one was measured first.
  ///
  /// **The probe.** libmpv 0.41.0 -- on Linux this is the very library
  /// media_kit loads, `libmpv.so` from the system -- with a 60-second
  /// video, a subtitle whose one cue is `20.000 --> 25.000`, and
  /// `sub-speed=2.0` with `sub-delay=5.0` set before `loadfile`. The cue
  /// is drawn from 45 s to 55 s of video: 46 and 54 have it on screen, 43
  /// and 56 do not. That is `speed * cue + delay` at both ends, which is
  /// the line `SubtitleCalibration` fits and the sign the panel shows.
  /// At every position inside that window `sub-start` answered **20.000**
  /// and `sub-end` 25.000 -- the times written in the file, moved by
  /// neither property. The transform had to be a real one for the reading
  /// to mean anything: at speed 1.0 and delay 0.0 the raw and the drawn
  /// time are the same number and the probe proves nothing.
  ///
  /// So the value is passed on as it stands. What was *not* probed is the
  /// libmpv media_kit ships for Android (mpv v0.36.0-549-g78d43740f5),
  /// which a desktop cannot load; if a build ever answers the drawn time
  /// instead, this is the one line to change -- `(value - delay) / speed`
  /// for the two properties in force.
  @override
  Future<double?> subtitleCueStart() async {
    final native = _player.platform;
    // Only the native (libmpv) backend has properties, and only it draws
    // subtitles we can be asked about.
    if (native is! NativePlayer || _disposed) return null;
    try {
      return double.parse(await native.getProperty(subtitleCueStartProperty));
    } catch (_) {
      // No cue on screen: mpv answers an unavailable property with
      // nothing at all, which media_kit hands back as an empty string, so
      // that arrives here as a parse failure rather than as an error. A
      // build without the property and a player torn down mid-read come
      // out the same way, and all three mean the same thing -- there is
      // nothing to mark.
      return null;
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
  /// no more frames to the video texture, so the texture is idle by the
  /// time `Player.dispose` unregisters it.
  ///
  /// **Nothing here disposes [_controller], and that is deliberate.**
  /// media_kit tears the native `VideoOutput` down from inside
  /// `Player.dispose`: the `VideoController` constructor adds its own
  /// release callback to the player, and `NativePlayer.dispose` runs those
  /// callbacks out of `super.dispose()` -- after `stop()`, before the
  /// event loop is detached. So "stop, wait for it, then let the texture
  /// and the audio device go" is an order media_kit already enforces, and
  /// the only ways to break it from this side are to release the
  /// controller ourselves or to call this twice, which throws.
  @override
  Future<void> dispose() async {
    _disposed = true;
    _stopStats();
    for (final subscription in _trackSubscriptions) {
      await subscription.cancel();
    }
    await _tracks.close();
    await _stats.close();
    await _videoFrameRate.close();
    try {
      await _player.stop();
    } finally {
      await _player.dispose();
    }
  }

  /// Whether the quit has already gone out. Once per engine: what follows
  /// it is mpv's own shutdown, and asking twice adds nothing to that.
  bool _quitAsked = false;

  /// The `reply_userdata` the quit is sent under, so that the reply mpv
  /// sends back for it belongs to nobody else.
  ///
  /// It used to be zero, and zero is a live id on the other side of the
  /// handle: media_kit's `_asyncRequestNumber` starts there and hands it
  /// to the first async call an engine makes, so the reply to our quit
  /// carried an id media_kit was keeping a completer under. Nothing ever
  /// came of it -- request zero is always a `set_property` during
  /// `_create`, and those replies wait in a different map from the command
  /// replies -- but which map an id ends up in is not this side's to
  /// choose, and an engine whose first async call was a command instead
  /// would have had our quit's reply complete *that* command's completer,
  /// with the quit's error code. The counter only ever steps by one per
  /// async call, so a number past anything a session of them could reach
  /// belongs to us alone. This one also reads as itself in a libmpv log.
  ///
  /// **What it does not do is quiet the log, and no id could.** media_kit's
  /// event loop looks every `MPV_EVENT_COMMAND_REPLY` up in
  /// `_commandRequests` and prints `Received MPV_EVENT_COMMAND_REPLY with
  /// unregistered ID` and the number, for every one it does not find there
  /// -- which is every reply to a command it did not send itself. It cannot
  /// find this one: the map is private, and the command deliberately goes
  /// past media_kit rather than through it. Through it is not the answer either, since
  /// `_command` awaits the reply from the core thread, and a core thread
  /// that answers is exactly what a teardown worth quitting does not have.
  /// So the line is still printed on every exit that sends a quit. What
  /// changed is the number in it, and the collision that number used to be.
  static const int _quitReplyId = 0xD1E00000000;

  /// libmpv's `quit`, sent asynchronously on the live handle -- and not
  /// `mpv_terminate_destroy`, which was the obvious thing to reach for and
  /// is the thing that hangs. Both halves of that were measured.
  ///
  /// **Why not the destroy.** `mpv_terminate_destroy` is
  /// `mp_destroy_client`, which takes the client out of the core's list
  /// and then destroys the condition variable and the mutexes the handle
  /// is made of (`player/client.c`). Any other thread inside an `mpv_*`
  /// call on that handle is parked on that very condvar, and there is no
  /// longer anybody who can wake it: with a thread in `mpv_wait_event` --
  /// which is exactly where media_kit's event loop sits -- the destroy
  /// never returned at all, both threads on one condvar, glibc's
  /// `pthread_cond_destroy` waiting out a waiter that cannot be woken.
  /// The deadlock is the lucky outcome; the same race an instant later is
  /// that waiter reading a freed `ctx`, which is the "causes direct crash"
  /// in media_kit's own comment beside the `quit` it sends instead.
  /// libmpv states the contract itself: since `mpv_destroy` is called on
  /// the way, it is not safe to call other functions concurrently on the
  /// same context.
  ///
  /// What has to be gone first is that event loop, and
  /// `Initializer(mpv).dispose(ctx)` is what detaches it -- clearing the
  /// wakeup callback before closing the `NativeCallable` libmpv would
  /// otherwise call into, or waking the mainloop isolate and killing it
  /// two seconds later. media_kit runs precisely that immediately before
  /// scheduling its own `mpv_terminate_destroy` five seconds on, which is
  /// why `dispose()` may destroy and its hot-restart sweeper may not. But
  /// it runs it *after* `stop()`, and this goes out *before* the stop
  /// does: the one path where destroying is prepared for is the path that
  /// has not begun yet.
  ///
  /// **Why the quit.** `mpv_command_async` is `reserve_reply` plus
  /// `mp_dispatch_enqueue` and nothing else -- no core lock, no waiter,
  /// nothing freed -- so it is safe with the event loop still attached and
  /// it returns immediately, which is what something sent on the way out
  /// of a screen has to do. It parses the arguments into the core's own copy before
  /// enqueueing, so the buffers below can go back at once. And what it
  /// sets off inside mpv is the shutdown, which is where mpv's own
  /// forceful abort lives: `abort_async` after two seconds of waiting on
  /// outstanding work. That bound is the thing this was after, and `quit`
  /// is the way to it that does not require the preparation nobody has
  /// done. Measured with the event loop attached throughout and
  /// the handle never destroyed: the call returned in microseconds, the
  /// demuxer was gone within the second, and the cache directory emptied
  /// -- the blocks back on the volume, which was the whole complaint.
  ///
  /// **What it is not: a way past a stuck core thread.** This comment used
  /// to claim that whatever a teardown is blocked on, the quit is not
  /// blocked on it too, and that is false. `mp_dispatch_enqueue` puts the
  /// command on `mpctx->dispatch` -- the core's own queue, drained by the
  /// core thread -- and the wedged `stop` is on that same queue: media_kit
  /// 1.2.6 with `async: true` issues `stop` through `mpv_command_async`
  /// as well and awaits the reply event (`_command` in
  /// `player/native/player/real.dart`), which only the core thread can
  /// send. Sending this *first* is what turns that queue from a hazard
  /// into an ordering: a core thread that reaches the queue at all reaches
  /// the quit before the stop, and the stop it then reaches is one against
  /// a demuxer that has already been cancelled. What is left over is a
  /// core thread stuck somewhere else entirely, and everything queued
  /// behind that waits forever. The measured recovery above is the first
  /// case; nothing in this process can do anything about the second.
  ///
  /// That is the strongest single argument for the player keeping no disk
  /// cache: a stuck core thread now costs 64 MiB of packet memory, a
  /// socket, and the server engine that socket keeps live, instead of a
  /// gigabyte of a 4 GB television that only a force-stop returns.
  ///
  /// **The return code is not thrown away.** `run_async` answers
  /// `MPV_ERROR_INVALID_PARAMETER` for a command it could not parse,
  /// `MPV_ERROR_UNINITIALIZED` for a core that never came up, and
  /// `MPV_ERROR_EVENT_QUEUE_FULL` when `reserve_reply` has no room -- and
  /// in every one of those the command was never enqueued at all. A
  /// caller that logged "destroying it" and heard nothing further would be
  /// reporting a kill that did not happen, so a refusal is thrown and the
  /// caller's own error path says so.
  ///
  /// What this does not do is free the `mpv_handle` and the core object
  /// behind it: they leak until the process ends. That is bounded, it is
  /// invisible on the volume, and it leaves media_kit's `dispose()` -- the
  /// one place the preparation above is actually done -- as the only thing
  /// that ever destroys the handle, so a teardown that lands late still
  /// lands correctly rather than onto a pointer this method freed.
  ///
  /// The handle is read here and not captured when the fallback was armed,
  /// and `NativePlayer.disposed` is asked with it. media_kit sets that flag
  /// before it schedules its destroy, so a teardown that finished while
  /// this was on its way sends nothing at all -- a `quit` on freed memory
  /// is the same crash by the other road.
  @override
  Future<void> quit() async {
    if (_quitAsked) return;
    _quitAsked = true;
    // Nothing this player reports is worth anything now.
    _disposed = true;
    _stopStats();
    final native = _player.platform;
    if (native is! NativePlayer || native.disposed) return;
    final ctx = native.ctx;
    if (ctx == nullptr) return;
    final command = 'quit'.toNativeUtf8();
    // Two: the command and the NULL that ends the list.
    final args = calloc<Pointer<Int8>>(2);
    final int sent;
    try {
      args[0] = command.cast();
      args[1] = nullptr;
      sent = native.mpv.mpv_command_async(ctx, _quitReplyId, args);
    } catch (error) {
      // A libmpv without the symbol, or a handle that went between the
      // checks above and here. There is nothing further to try -- but the
      // caller is about to write a line about a player it believes it
      // killed, so it hears this rather than not.
      throw StateError('the player could not be sent a quit: $error');
    } finally {
      calloc.free(command);
      calloc.free(args);
    }
    // Freed first, thrown second: the buffers are ours whatever libmpv
    // said, and the answer is about the command rather than about them.
    if (sent < 0) {
      throw StateError(
        'libmpv refused the quit (mpv error $sent); the player is still '
        'running',
      );
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
