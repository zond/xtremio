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
import 'archive_route.dart';
import 'archive_sniff.dart';
import 'playback_stats.dart';
import 'playback_tracks.dart';
import 'subtitle_match.dart';
import 'torrent_stats.dart';

export 'playback_stats.dart';
export 'playback_tracks.dart';
export 'torrent_stats.dart';

/// The URL of the external subtitle file [error] says mpv could not load,
/// or null when it says something else.
///
/// mpv logs `Can not open external file <url>.` at error level, so it
/// arrives as a [PlaybackEngine.errors] event, and that is the only signal:
/// media_kit drops `sub-add`'s return code, so the call completes as if the
/// file had been added.
String? externalSubtitleFailure(String error) {
  const prefix = 'Can not open external file ';
  if (!error.startsWith(prefix)) return null;
  var url = error.substring(prefix.length).trim();
  if (url.endsWith('.')) url = url.substring(0, url.length - 1);
  return url.isEmpty ? null : url;
}

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

  /// What the backend says went wrong. media_kit makes these out of mpv's
  /// error-level log lines from a handful of subsystems (`cplayer`, `vd`,
  /// `ad`, `stream`, `file`, and ffmpeg's `tcp:` lines), so one says
  /// something failed and not that the playback did: a dead external
  /// subtitle URL arrives here too ([externalSubtitleFailure]), over a
  /// film that plays on.
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

  /// The frame rate the open video declares (`container-fps`), emitted once
  /// per file as it loads; nothing for media that declares none, or on a
  /// backend without the property.
  ///
  /// Its one consumer is the display: a 23.976 fps film on a 59.94 Hz
  /// output lands on a 3:2 cadence, so the player asks the television for a
  /// matching mode (`DisplayFrameRate`). Nothing about subtitle timing may
  /// read this (AGENTS.md, "Nothing re-times a subtitle but the viewer").
  Stream<double> get videoFrameRate;

  /// Tells the engine what the display is **really** refreshing at, in
  /// hertz, so it can time frames against the screen instead of the audio
  /// clock; `null` withdraws the claim.
  ///
  /// On Android mpv cannot measure the rate itself (see
  /// [MediaKitEngine.displayRateProperties]). The caller sets it while it
  /// holds a rate on the display and clears it the moment it gives the rate
  /// back: an override outliving the mode it described is worse than none.
  /// Only libmpv has the property; other backends do nothing.
  Future<void> setDisplayRefreshRate(double? hz);

  /// Opens [url] and starts playing from [start].
  Future<void> open(Uri url, {Duration start = Duration.zero});

  /// Seeks to [position] exactly, decoding forward from the keyframe
  /// before it if that is what landing there takes.
  Future<void> seek(Duration position);

  /// Moves [delta] from wherever playback is, landing on a keyframe: the
  /// step a viewer scanning through the film asks for.
  ///
  /// An exact [seek] decodes forward from the keyframe before the target,
  /// and on a 32-bit Amlogic box with `hwdec=mediacodec-copy` that decode is
  /// what a press of the seek key costs. A scan takes the keyframe and lands
  /// at once.
  ///
  /// **Relative, which is why this is not [seek] with a flag.** A keyframe
  /// seek to an absolute target lands on the keyframe *before* it, so a
  /// forward step shorter than the keyframe interval lands behind where it
  /// started (x264's default `keyint` of 250 frames is 10.4 s at 23.976 fps,
  /// against a 10 s `seekTimeDuration`). A relative keyframe seek rounds
  /// away from the start, so a press always moves at least what it asked
  /// for, in the direction it asked for.
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
  /// A file cut for a release of another frame rate drifts linearly, so one
  /// multiplier puts it back in step. Only the viewer asks for one (AGENTS.md,
  /// "Nothing re-times a subtitle but the viewer"), and every path that
  /// changes what is on screen sets it, 1.0 included: it is a property of
  /// the player, not of the file. Only libmpv has the property; other
  /// backends do nothing.
  Future<void> setSubtitleSpeed(double speed);

  /// Shifts the subtitle events being drawn by [seconds]: positive makes a
  /// line appear later than the file asks for, negative earlier.
  ///
  /// The other half of putting a file back in step: an offset fixes a file
  /// cut for a release that starts elsewhere (a distributor logo this video
  /// does not have). Like the multiplier it is set only by the viewer, and
  /// every path that changes what is on screen sets it, `0.0` included.
  /// libmpv's `sub-delay`; other backends do nothing.
  Future<void> setSubtitleDelay(double seconds);

  /// Where the cue on screen starts on the **subtitle file's own
  /// timeline**, in seconds: its raw time, before [setSubtitleSpeed] and
  /// [setSubtitleDelay] moved it. Null when no cue is on screen, and on
  /// every backend but libmpv.
  ///
  /// This is half of a mark (the other half is the video position the
  /// viewer says the line belongs at), and `SubtitleCalibration` fits one
  /// line through the marks, so every mark has to be on the same timeline.
  /// The measurement that settled which one libmpv answers on is at
  /// [MediaKitEngine.subtitleCueStart].
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
  /// It can be slow and it can fail (`Player.stop()` waits on the mpv core
  /// thread), so [quit] goes first; with it sent this returns in a fraction
  /// of a second. The sinks are released inside this call (media_kit tears
  /// the video output down from `Player.dispose`, after `stop()`), so the
  /// caller keeps drawing the video and keeps the audio device open until
  /// it returns. See docs/ARCHITECTURE.md, "Leaving the player".
  Future<void> dispose();

  /// Ends the playback outright -- libmpv's own `quit` -- freeing the
  /// demuxer and the connection it reads through, and leaves this engine
  /// unusable.
  ///
  /// **This is the kill, sent the moment the player is left, ahead of
  /// [dispose].** There is nothing stronger: `mpv_terminate_destroy`
  /// deadlocks against an attached event loop (see [MediaKitEngine.quit]).
  /// It does not spoil the teardown behind it: `quit` leaves mpv's core
  /// thread draining its dispatch queue, so the `stop` inside [dispose] is
  /// answered as on a live core -- measured against real libmpv, `dispose`
  /// returned in single-digit milliseconds three seconds after a quit.
  ///
  /// It returns at once, but a core thread that is genuinely stuck swallows
  /// it along with everything else; nothing in this process can reach that
  /// thread.
  ///
  /// Throws when the backend refused the command, so a caller that logs a
  /// kill logs one that was at least asked for. Calling it twice, or on a
  /// player that has gone, does nothing.
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
    this.streamNumbers,
    this.hints,
    this.archiveSniff,
    this.archiveRoute,
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

  /// What the stats panel asks for the cache and sharing rows: what this
  /// server holds of the stream on screen. An interface rather than a
  /// function because a test wants to see which URL was asked about, and
  /// because every player test would otherwise reach FFI while a panel is
  /// up.
  final StreamNumbersReader? streamNumbers;

  /// What the server is told about the playback that it cannot work out
  /// from the reads: the film's length, and a player opening on or
  /// stalling on a torrent. Injectable so a test can see what was reported
  /// without reaching FFI.
  final PlaybackHints? hints;

  /// What a stream that failed to open is asked, to say whether it is an
  /// archive rather than a film (absent, [sniffArchive], which reads the
  /// start of it over HTTP). A function so a test can answer without a
  /// server.
  final Future<ArchiveKind?> Function(Uri url)? archiveSniff;

  /// How a container the sniff named is sent to the streaming server, which
  /// reads the film inside it as ranges of the container itself (absent,
  /// [routeArchive]). A function for the same reason as [archiveSniff]: a
  /// test answers what the server would without one running.
  final ArchiveRouter? archiveRoute;

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

  static StreamNumbersReader streamNumbersOf(BuildContext context) =>
      _maybeOf(context)?.streamNumbers ?? const ServerClient();

  static PlaybackHints hintsOf(BuildContext context) =>
      _maybeOf(context)?.hints ?? const ServerClient();

  static Future<ArchiveKind?> Function(Uri url) archiveSniffOf(
    BuildContext context,
  ) => _maybeOf(context)?.archiveSniff ?? sniffArchive;

  static ArchiveRouter archiveRouteOf(BuildContext context) =>
      _maybeOf(context)?.archiveRoute ?? routeArchive;

  @override
  bool updateShouldNotify(PlaybackScope oldWidget) =>
      createEngine != oldWidget.createEngine ||
      fullscreen != oldWidget.fullscreen ||
      torrentStats != oldWidget.torrentStats ||
      subtitleMatch != oldWidget.subtitleMatch ||
      displayFrameRate != oldWidget.displayFrameRate ||
      dhtStatus != oldWidget.dhtStatus ||
      proxyStreams != oldWidget.proxyStreams ||
      streamNumbers != oldWidget.streamNumbers ||
      hints != oldWidget.hints ||
      archiveSniff != oldWidget.archiveSniff ||
      archiveRoute != oldWidget.archiveRoute;
}

/// [PlaybackEngine] over `media_kit` (libmpv). Direct play only: whatever
/// the URL serves is decoded on this device; the server never transcodes.
///
/// [hardwareDecoding] (`profile.settings.hardwareDecoding`) is fixed at
/// creation: media_kit takes it as the video controller's configuration
/// (`hwdec=auto` vs `no`), and a controller cannot be reconfigured.
class MediaKitEngine implements PlaybackEngine {
  MediaKitEngine({bool hardwareDecoding = true, bool verboseLog = false})
    : _verboseLog = verboseLog,
      _player = Player(
        configuration: playerConfigurationFor(verboseLog: verboseLog),
      ) {
    _overrides = _applyOverrides(
      _player.platform,
      overridesFor(verboseLog: verboseLog),
    );
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

  /// "Verbose diagnostics" as it stood when this player opened
  /// ([AppPrefs.verboseDiagnostics]): whether mpv's demuxer, stream and
  /// cache lines reach [engineLog], and whether mpv is asked to produce
  /// them at all ([playerConfigurationFor], [verboseMpvOverrides]). Fixed
  /// at creation like `hardwareDecoding`: the log level is the player's
  /// configuration, and a player cannot be reconfigured.
  final bool _verboseLog;

  late final VideoController _controller;
  bool _disposed = false;

  /// The mpv properties in [mpvOverrides], on their way to the backend.
  /// [open] waits for it: a property mpv reads when it opens a stream is
  /// worth nothing if it lands after the stream is open.
  late final Future<void> _overrides;

  /// mpv properties this app sets differently from media_kit's defaults,
  /// applied once per player.
  ///
  /// `network-timeout`: media_kit starts libmpv with `network-timeout=5`,
  /// five seconds for a read to make progress. On a thin swarm the embedded
  /// server legitimately takes minutes to hand over the next piece, and with
  /// `keep-open=yes` the timeout arrives as a false end of file on which
  /// media_kit's `play()` seeks back to 0 ("it plays ten seconds and starts
  /// over"). Five minutes is long enough that no swarm trips it and short
  /// enough that a dead connection still ends in an error.
  ///
  /// **`cache-on-disk=no` is the whole of the player's disk policy.**
  /// media_kit's default `yes` makes a cache file mpv unlinks as it creates
  /// it, invisible to `du`, `dumpsys diskstats` and the server until the fd
  /// closes: one 90-second title on a Chromecast held 928 MB that way while
  /// the app reported 46 MB. The one cache on the device is the server's,
  /// which every stream reaches the player through ([proxiedThroughServer]).
  ///
  /// Not here: `force-seekable` is a claim about one stream
  /// ([forcesSeekable], per `open`); `override-display-fps` is set per
  /// playback against the rate the display settled on
  /// ([displayRateProperties]); `video-sync` is deliberately left at mpv's
  /// default (see [displayRateProperties]).
  ///
  /// mpv cannot measure the display's refresh rate on Android: media_kit runs
  /// `vo=gpu` with `gpu-context=android`, which in the build it ships
  /// (`mpv v0.36.0-549-g78d43740f5`) answers `VO_NOTIMPL` to
  /// `VOCTRL_GET_DISPLAY_FPS` (`video/out/opengl/context_android.c`), so the
  /// reported rate stays 0. That is why the rate is supplied from outside.
  static const Map<String, String> mpvOverrides = {
    'network-timeout': '300',
    'cache-on-disk': 'no',
    // The window behind the play head, set apart from the one ahead of it:
    // media_kit puts [memoryCacheBytes] on both, and [backCacheBytes] says
    // why the two are not the same number.
    'demuxer-max-back-bytes': '$backCacheBytes',
  };

  /// The overrides "Verbose diagnostics" adds, with the `logLevel` of
  /// [playerConfigurationFor]: mpv saying which of its parts wanted a read.
  ///
  /// The server logs which byte range was asked for (stream-server's
  /// `stage="stream_request"` line) but cannot know which part of the player
  /// asked, because a player sends a range and nothing else. This is that
  /// half, on while somebody is about to read a report.
  static const Map<String, String> verboseMpvOverrides = {
    'msg-level': 'all=info,demux=v,stream=v,cache=v',
  };

  /// [mpvOverrides], with [verboseMpvOverrides] on top under
  /// "Verbose diagnostics".
  static Map<String, String> overridesFor({required bool verboseLog}) =>
      verboseLog ? {...mpvOverrides, ...verboseMpvOverrides} : mpvOverrides;

  /// What tells mpv the rate a display is refreshing at, in hertz, and an
  /// empty map where there is nothing to say.
  ///
  /// **`override-display-fps` is the whole of it; `video-sync` stays at
  /// mpv's default (`audio`).** The override is what `update_display_fps`
  /// takes ahead of the VO's rate (`video/out/vo.c`), and on Android the
  /// only way mpv learns the rate at all. `video-sync=display-resample` is
  /// not used: on a Chromecast `display-sync-active` never engaged, and it
  /// put the audio on a correction loop against a rate mpv cannot verify,
  /// so the picture drifted audibly behind the sound over a few minutes.
  /// The frame drops it was tried against were the copying decoder's (see
  /// [configurationFor]); with this map a 23.976 fps film on a panel asked
  /// for 23.976 Hz plays at `1 vo / 0 decoder` drops.
  ///
  /// **[hz] is a measurement, never the rate that was asked for.** The ask
  /// (`DisplayFrameRate`) is asynchronous, reports nothing back and can land
  /// on a neighbouring mode, so the number comes from the display itself
  /// afterwards (`DisplayFrameRate.refreshRate`,
  /// `MainActivity.DisplayRefreshRates`).
  ///
  /// **Android only.** Everywhere else mpv's VO measures the rate itself and
  /// is right, so an override would replace a true number with ours.
  ///
  /// Empty rather than [displayRateOff] for a rate that is not a rate: with
  /// nothing measured there is nothing to claim.
  static Map<String, String> displayRateProperties(
    double? hz, {
    TargetPlatform? platform,
  }) {
    if ((platform ?? defaultTargetPlatform) != TargetPlatform.android) {
      return const {};
    }
    if (hz == null || !hz.isFinite || hz <= 0) return const {};
    return {'override-display-fps': '$hz'};
  }

  /// What takes the rate back, written by whichever player claimed one once
  /// it stops presenting: a zero `override-display-fps` is mpv's "no display
  /// rate". An override left standing over the next film, or over a mode
  /// the platform has since changed, is worse than none, because it looks
  /// measured.
  static const Map<String, String> displayRateOff = {
    'override-display-fps': '0',
  };

  /// Whether to tell mpv that [url] can be seeked in whatever the demuxer
  /// concluded (`force-seekable`) -- a claim about this server, decided per
  /// stream.
  ///
  /// mpv refuses a seek the demuxer says it cannot make, and a demuxer
  /// decides that from what it could read at open. A Matroska index is at
  /// the end of the file, the last thing a torrent delivers, so without this
  /// every seek past the buffered part is refused. The embedded server's
  /// stream route answers any byte range and re-prioritises the swarm around
  /// it: a cold offset waits (covered by `network-timeout`, and past that by
  /// the false-end re-open), it is never refused.
  ///
  /// **Only for the embedded server's own streams on the loopback address.**
  /// An addon's own host (a live HLS playlist, a host that ignores `Range`)
  /// really cannot be seeked in, and forcing it turns a visible refusal into
  /// a bar sitting where no packets will arrive. A `/proxy` URL is on the
  /// loopback address but fronts such a host, so it is not forced either. A
  /// kept download is forced like any other torrent.
  ///
  /// Forcing cannot invent an index; a demuxer with none may still refuse,
  /// which the stats OSD's `partially` and `ranges` rows tell apart.
  static bool forcesSeekable(Uri url) {
    if (!url.isScheme('http') && !url.isScheme('https')) return false;
    if (isProxiedByServer(url)) return false;
    return isLoopbackHost(url.host);
  }

  /// Sets [overrides] ([overridesFor]) on the native backend. Only libmpv
  /// has properties; any other backend keeps its own behaviour, and a
  /// player torn down before it initialised is not an error worth
  /// surfacing.
  static Future<void> _applyOverrides(
    PlatformPlayer? platform,
    Map<String, String> overrides,
  ) async {
    if (platform is! NativePlayer) return;
    for (final MapEntry(:key, :value) in overrides.entries) {
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

  /// What mpv keeps in memory ahead of the play head: 32 MiB of packets.
  ///
  /// media_kit sets `PlayerConfiguration.bufferSize` on both
  /// `demuxer-max-bytes` and `demuxer-max-back-bytes`; [backCacheBytes]
  /// takes the back side down through [mpvOverrides], so the player's
  /// ceiling is 40 MiB.
  ///
  /// This is the buffer that absorbs a swarm going quiet. The heaviest
  /// torrent this television has played reads at about 4 MB/s (32 Mbps),
  /// where 32 MiB is 8.4 s of read-ahead and 16 MiB would be 4.2. It is not
  /// raised because a 2 GB television has no room; the cushion belongs in
  /// the server's cache, which is bounded and reclaimable.
  ///
  /// Written out rather than inherited, so a media_kit release that changed
  /// `bufferSize` cannot silently change what a television holds (mpv's own
  /// defaults are 150 MiB ahead and 50 MiB behind).
  static const int memoryCacheBytes = 32 * 1024 * 1024;

  /// What mpv keeps in memory *behind* the play head: 8 MiB, where media_kit
  /// would make it the same as the window ahead.
  ///
  /// The window behind only serves a backward seek; one that falls out of it
  /// is a range request answered from the server's disk (a second or so of
  /// demuxer re-open), not a re-fetch from the swarm.
  ///
  /// **Sized by one press of the remote.** The seek step is ten seconds
  /// (`SeekBar.defaultSeekStep`), and 8 MiB covers one press back up to
  /// about 6.7 Mbps. Above that no affordable size covers a press (at
  /// 32 Mbps, 16 MiB is 4.2 s), so a larger window buys nothing. 4 MiB would
  /// cover only 3.3 Mbps and start missing on ordinary 1080p.
  static const int backCacheBytes = 8 * 1024 * 1024;

  /// media_kit's own defaults with [memoryCacheBytes] named, and the log
  /// level "Verbose diagnostics" asks for.
  ///
  /// media_kit gates mpv's log at `error` by default, so nothing below that
  /// reaches [engineLog] whatever `msg-level` says. `info` is the level
  /// mpv's demuxer announces seeks, stream opens and cache state at;
  /// `debug` and `trace` log per packet and would evict the whole
  /// diagnostics ring in seconds, taking the server's own lines -- the
  /// ones a report is read by -- with them. So verbose is `info`, and off
  /// is media_kit's own `error`.
  static PlayerConfiguration playerConfigurationFor({
    required bool verboseLog,
  }) => PlayerConfiguration(
    bufferSize: memoryCacheBytes,
    logLevel: verboseLog ? MPVLogLevel.info : MPVLogLevel.error,
  );

  /// The controller configuration for a `hardwareDecoding` setting.
  ///
  /// media_kit's default `hwdec=auto-safe` excludes the direct `mediacodec`
  /// hwdec, so on Android it can only pick `mediacodec-copy`, which copies
  /// every frame into CPU memory: on a Chromecast with Google TV that is
  /// 10-30 ms of a 41 ms frame, seen on the stats OSD as thousands of `vo`
  /// drops and none at the decoder. So this names the list mpv-android uses:
  /// direct `mediacodec` first (no CPU copy), `mediacodec-copy` as the
  /// fallback. The OSD's hwdec row says which one took; ffmpeg's "Both
  /// surface and native_window are NULL" at init is logged by both and
  /// proves nothing.
  static VideoControllerConfiguration configurationFor({
    required bool hardwareDecoding,
  }) => VideoControllerConfiguration(
    enableHardwareAcceleration: hardwareDecoding,
    hwdec: hardwareDecoding ? 'mediacodec,mediacodec-copy' : 'no',
  );

  /// Which codecs may go to the hardware decoder.
  ///
  /// **MPEG-4 Part 2 and MPEG-2 are deliberately not on it.** media_kit's
  /// Android controller sets
  /// `hwdec-codecs=h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1`
  /// (`android_video_controller/real.dart`), and with the direct
  /// `mediacodec` hwdec ([configurationFor]) an MPEG-4 file fails at decoder
  /// init:
  ///
  ///     mpeg4_mediacodec: Both surface and native_window are NULL
  ///     mpeg4_mediacodec: MediaCodec 0x0 failed to start
  ///     vd: Could not open codec.
  ///
  /// It then plays, after about three seconds of stalling with an error on
  /// screen. Software decodes those old formats comfortably on the weakest
  /// device this runs on, and the codecs the hardware is needed for are all
  /// still on the list.
  static const String hwdecCodecs = 'h264,hevc,vp8,vp9,av1';

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

  /// Whether a rate has been claimed for this player, so only a player that
  /// claimed one writes [displayRateOff] back over mpv's defaults.
  bool _displayRateSet = false;

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
      .where(
        (entry) => engineLogCarries(
          prefix: entry.prefix,
          level: entry.level,
          verboseLog: _verboseLog,
        ),
      )
      .map((entry) => '${entry.prefix}: ${entry.text}');

  /// Whether an mpv log line reaches [engineLog]: every error, and under
  /// "Verbose diagnostics" the subsystems that say why a read happened --
  /// demuxer, stream and cache -- and only those. Everything else at that
  /// level is noise that would evict the diagnostics ring.
  static bool engineLogCarries({
    required String prefix,
    required String level,
    required bool verboseLog,
  }) =>
      level == 'error' ||
      (verboseLog && const {'demux', 'stream', 'cache'}.contains(prefix));

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

  /// Puts [displayRateProperties] on the player, or [displayRateOff] back
  /// when there is no rate left to describe.
  ///
  /// Whoever holds a rate on the display owns this: `PlayerScreen` sets it
  /// as the display reports what it settled on and clears it on every path
  /// that gives the rate back, which is the same list that clears the ask
  /// itself. Nothing here reads the film's own rate -- what mpv is being
  /// told is what the *screen* is doing.
  @override
  Future<void> setDisplayRefreshRate(double? hz) async {
    final start = displayRateProperties(hz);
    if (start.isEmpty && !_displayRateSet) return;
    _displayRateSet = start.isNotEmpty;
    for (final MapEntry(:key, :value)
        in (start.isEmpty ? displayRateOff : start).entries) {
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
    // [_overrides] (`cache-on-disk=no` among them) must be in force before
    // the first `loadfile`.
    await _overrides;
    // Before the `loadfile`, and before every one of them: mpv reads
    // `force-seekable` once, when it builds the demuxer, so it has to be
    // set for the stream about to be opened and not for the last one.
    await _setProperty('force-seekable', forcesSeekable(url) ? 'yes' : 'no');
    // And which codecs the hardware is allowed to have. Here rather than in
    // [mpvOverrides] for two reasons: mpv reads it when it picks a decoder,
    // which is at the `loadfile` below, and media_kit's Android controller
    // writes its own value while *it* initialises -- so a value set once at
    // construction is racing something that has not run yet.
    await _setProperty('hwdec-codecs', hwdecCodecs);
    await _player.open(Media(url.toString(), start: start));
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  /// The mpv command a [scanBy] of [delta] is.
  ///
  /// Written out because media_kit has no relative seek and discards
  /// `mpv_command`'s return code, so a misspelled flag would seek nowhere in
  /// silence. `relative+keyframes` answers `success` on libmpv 0.41.0, and
  /// both words are in the Android build (`mpv v0.36.0-549-g78d43740f5`).
  /// Seconds with four decimals, as media_kit writes its own absolute seek.
  static List<String> scanCommand(Duration delta) => [
    'seek',
    (delta.inMilliseconds / 1000).toStringAsFixed(4),
    'relative+keyframes',
  ];

  /// The `keyframes` flag has to be on the command: media_kit starts libmpv
  /// with `hr-seek=yes`, which makes even relative seeks precise, and an
  /// explicit flag overrides it (measured: a bare `seek 10 relative` took
  /// 18.7 ms and landed on 315.000 of a 10 s-keyframe file; with
  /// `+keyframes`, 3.7 ms and 320). mpv merges a burst of relative seeks
  /// itself (`queue_seek`), so a held key needs no coalescing here.
  ///
  /// Off libmpv, or once media_kit has marked the media completed, this is
  /// an ordinary seek from where playback is: `Player.play` seeks back to
  /// zero while its `completed` is set, and only its `seek` clears it.
  @override
  Future<void> scanBy(Duration delta) {
    final native = _player.platform;
    if (native is! NativePlayer || _player.state.completed) {
      return _player.seek(scanFallbackTarget(_player.state.position, delta));
    }
    return native.command(scanCommand(delta));
  }

  /// Where the fallback above seeks to: [position] moved by [delta], never
  /// before the start of the file.
  ///
  /// media_kit's absolute seek hands mpv whatever number it is given, and
  /// mpv reports a seek's raw target on `time-pos` until the first frame
  /// after it lands -- so a step back from the first seconds of a film
  /// puts a negative position on the stream the player forwards to the
  /// core, where a time is unsigned. There is no upper clamp because the
  /// duration is not this call's to know: past the end is an ending,
  /// which mpv answers with EOF, and no number reaches the core.
  static Duration scanFallbackTarget(Duration position, Duration delta) {
    final target = position + delta;
    return target < Duration.zero ? Duration.zero : target;
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
      // A player torn down mid-write, or a libmpv without the property
      // (which never re-timed anything either). media_kit discards
      // `mpv_set_property_string`'s return code, so an out-of-range value is
      // refused silently; the range is enforced where the number is computed
      // (`minSubtitleSpeed` in `subtitle_groups.dart`).
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
      // A player torn down mid-write, or a libmpv without the property,
      // which never shifted anything either.
    }
  }

  /// The mpv property holding the start time of the subtitle event being
  /// drawn, in seconds.
  static const String subtitleCueStartProperty = 'sub-start';

  /// What that property answers, and how we know.
  ///
  /// mpv's documentation leaves open whether `sub-start` is the raw cue time
  /// or one moved by `sub-delay` and `sub-speed`; a mark needs the raw one
  /// (see [PlaybackEngine.subtitleCueStart]), so it was measured. libmpv
  /// 0.41.0 (the library media_kit loads on Linux), a subtitle whose one cue
  /// is `20.000 --> 25.000`, `sub-speed=2.0` and `sub-delay=5.0`: the cue is
  /// drawn from 45 s to 55 s of video (`speed * cue + delay`, the line
  /// `SubtitleCalibration` fits), and throughout it `sub-start` answered
  /// **20.000** -- the raw time.
  ///
  /// Not probed: the Android build (mpv v0.36.0-549-g78d43740f5), which a
  /// desktop cannot load. If a build ever answers the drawn time, this is
  /// the one line to change: `(value - delay) / speed`.
  @override
  Future<double?> subtitleCueStart() async {
    final native = _player.platform;
    // Only the native (libmpv) backend has properties, and only it draws
    // subtitles we can be asked about.
    if (native is! NativePlayer || _disposed) return null;
    try {
      return double.parse(await native.getProperty(subtitleCueStartProperty));
    } catch (_) {
      // No cue on screen: media_kit hands mpv's unavailable property back as
      // an empty string, which fails the parse. A build without the
      // property and a player torn down mid-read land here too; all three
      // mean there is nothing to mark.
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

  /// Stops playback, then releases the player. Once stopped, libmpv posts no
  /// more frames to the texture, so it is idle when `Player.dispose`
  /// unregisters it.
  ///
  /// **[_controller] is deliberately not disposed here.** media_kit releases
  /// the native video output from inside `Player.dispose` (after `stop()`,
  /// before the event loop is detached), which is the order wanted;
  /// releasing the controller ourselves, or calling this twice, breaks it.
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

  /// The `reply_userdata` the quit is sent under, chosen so its reply belongs
  /// to nobody else: media_kit numbers its own async requests upwards from
  /// zero, one per call, so a small id could complete one of its completers
  /// with the quit's error code. It also reads as itself in a libmpv log.
  ///
  /// media_kit still logs `Received MPV_EVENT_COMMAND_REPLY with
  /// unregistered ID` for it on every exit: it logs every reply to a command
  /// it did not send, and the quit bypasses it on purpose (its `_command`
  /// awaits a reply from the core thread, which a teardown worth quitting
  /// may never get).
  static const int _quitReplyId = 0xD1E00000000;

  /// libmpv's `quit`, sent asynchronously on the live handle, and not
  /// `mpv_terminate_destroy`. Both halves were measured.
  ///
  /// **Why not the destroy.** `mpv_terminate_destroy` destroys the condition
  /// variable and mutexes the handle is made of (`player/client.c`) while
  /// media_kit's event loop is parked on that condvar in `mpv_wait_event`:
  /// the destroy never returned, and the same race a moment later is a
  /// use-after-free. libmpv's own contract forbids concurrent calls during
  /// it. media_kit detaches its event loop (`Initializer(mpv).dispose(ctx)`)
  /// before its own destroy, but only after `stop()`, and this goes out
  /// before the stop.
  ///
  /// **Why the quit.** `mpv_command_async` only reserves a reply and
  /// enqueues on the core's dispatch queue -- no lock, no waiter, nothing
  /// freed -- so it is safe with the event loop attached and returns at
  /// once; the arguments are copied before it returns. The shutdown it
  /// starts carries mpv's own forceful abort after two seconds. Measured
  /// with the loop attached: the call returned in microseconds and the
  /// demuxer was gone within the second.
  ///
  /// **Not a way past a stuck core thread.** The queue is drained by the
  /// core thread, and media_kit's own `stop` goes through the same queue
  /// (`_command` in `player/native/player/real.dart`). Sending the quit
  /// first means a core thread that reaches the queue at all reaches the
  /// quit before the stop; one stuck elsewhere swallows both. With no disk
  /// cache that costs 40 MiB of packet memory and a socket, not a gigabyte
  /// of the volume.
  ///
  /// **A refusal is thrown.** `run_async` answers
  /// `MPV_ERROR_INVALID_PARAMETER`, `MPV_ERROR_UNINITIALIZED` or
  /// `MPV_ERROR_EVENT_QUEUE_FULL` when the command was never enqueued, and a
  /// caller must not log a kill that did not happen.
  ///
  /// The `mpv_handle` is not freed here; it leaks until the process ends,
  /// which leaves media_kit's `dispose()` the only thing that destroys it.
  /// The handle is read when the quit is sent and `NativePlayer.disposed` is
  /// asked with it: media_kit sets that flag before scheduling its destroy,
  /// so a teardown that already finished sends nothing to freed memory.
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
