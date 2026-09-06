import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

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
/// overlay polls the embedded server with (absent, the FFI one),
/// [displayFrameRate] (absent, the `xtremio/device` channel) and
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
    this.displayFrameRate,
    this.dhtStatus,
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

  @override
  bool updateShouldNotify(PlaybackScope oldWidget) =>
      createEngine != oldWidget.createEngine ||
      fullscreen != oldWidget.fullscreen ||
      torrentStats != oldWidget.torrentStats ||
      subtitleMatch != oldWidget.subtitleMatch ||
      displayFrameRate != oldWidget.displayFrameRate ||
      dhtStatus != oldWidget.dhtStatus;
}

/// The folder mpv writes its cache file into, inside the app's own cache
/// directory -- the same root the embedded server's cache lives under, one
/// folder along.
const String mpvCacheFolderName = 'mpv';

/// Where mpv may write, `null` when the platform will not say.
typedef MpvCacheDirectory = Future<String?> Function();

/// `<app cache>/mpv`, which is what [MediaKitEngine] asks for unless a test
/// hands in something else.
///
/// Android gives an app no writable temp path of its own, so mpv's default
/// (its user cache directory) does not exist there and the demuxer's file
/// cache cannot be created at all -- `Failed to create file cache` on every
/// open, in the owner's own log. The app is already handed a cache
/// directory by the platform (`main.dart` passes it to the core and to the
/// embedded server); mpv gets a folder of its own beside theirs.
///
/// The folder itself is not created here: mpv `mp_mkdirp`s the path it is
/// given before opening the cache file (`demux/cache.c`), which was
/// confirmed by handing a running libmpv a directory two levels below
/// anything that existed and finding both levels afterwards.
Future<String?> platformMpvCacheDirectory() async {
  try {
    final cache = await getApplicationCacheDirectory();
    return '${cache.path}/$mpvCacheFolderName';
  } catch (_) {
    // No cache directory from the platform: mpv keeps its own default,
    // which is right on a desktop and missing on Android.
    return null;
  }
}

/// [PlaybackEngine] over `media_kit` (libmpv). Direct play only: whatever
/// the URL serves is decoded on this device; the server never transcodes.
///
/// [hardwareDecoding] (`profile.settings.hardwareDecoding`) is fixed at
/// creation: media_kit takes it as the video controller's configuration
/// (`hwdec=auto` vs `no`), and a controller cannot be reconfigured.
class MediaKitEngine implements PlaybackEngine {
  MediaKitEngine({
    bool hardwareDecoding = true,
    MpvCacheDirectory cacheDirectory = platformMpvCacheDirectory,
  }) : _player = Player() {
    _overrides = _applyOverrides(_player.platform, cacheDirectory);
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
  /// `force-seekable` is not here: it is a claim about the stream being
  /// opened rather than about the player, so [forcesSeekable] decides it
  /// per `open`; nor is `cache-on-disk`, which [open] sets because
  /// [MpvDiskCacheLimit] can have turned it off for the media before this
  /// one.
  ///
  /// **`video-sync=display-resample` is not here, and it would do nothing
  /// if it were.** A 23.976 fps film on a 59.94 Hz output is laid on a
  /// 2.5:1 cadence -- two refreshes for one frame, three for the next --
  /// and mpv's own answer to a mismatched rate is to lock the video to the
  /// display and resample the audio by the difference. Every display-sync
  /// mode needs to know what the display's refresh rate is, and on Android
  /// nothing tells libmpv: media_kit runs it with `vo=gpu` and
  /// `gpu-context=android` (`android_video_controller/real.dart`), and in
  /// the build it ships for Android (`mpv v0.36.0-549-g78d43740f5`) that
  /// context answers `VO_NOTIMPL` to every request,
  /// `VOCTRL_GET_DISPLAY_FPS` included
  /// (`video/out/opengl/context_android.c`), with `vo_gpu` handing the
  /// request straight to it. So the reported rate stays 0,
  /// `vo_get_vsync_interval` answers -1 (`video/out/vo.c`) and
  /// `handle_display_sync_frame` returns before it sets
  /// `display-sync-active` (`player/video.c`): playback stays on the
  /// default `video-sync=audio` whatever this map says. mpv's own estimate
  /// cannot start it either -- vsync samples are collected only from
  /// frames that are already display-synced, so there is nothing to
  /// bootstrap from. That was read out of mpv's source at the commit this
  /// build names rather than off the manual, and the option would leave
  /// something that reads like the fix standing beside a drop count it did
  /// not move. **The cadence is the display's to fix here**: the player
  /// asks the panel for the film's own rate instead (`DisplayFrameRate`,
  /// ANDROID.md).
  static const Map<String, String> mpvOverrides = {'network-timeout': '300'};

  /// [mpvOverrides] plus what the demuxer's file cache needs, for a
  /// [cacheDirectory] of `null` (nothing is added) or a directory mpv may
  /// write in.
  ///
  /// `demuxer-cache-dir` is where mpv puts that file. Without it the cache
  /// cannot be created on Android at all, and the seekable window is
  /// whatever fits in the memory cache -- media_kit starts libmpv with
  /// `demuxer-max-bytes` and `demuxer-max-back-bytes` at 32 MiB each
  /// (`PlayerConfiguration.bufferSize`), which on the owner's 2.3 Mbps film
  /// was the two islands, 1465-1601s and 516-551s, that he could not scan
  /// between. With the file cache those byte limits apply to packet
  /// *metadata* instead of to the payload: two minutes of a test stream
  /// weighed 818 KB of metadata against 21 MB of payload on a running
  /// libmpv, and mpv's own manual puts the metadata at some 50 MB an hour,
  /// so the same 32 MiB holds half an hour of film rather than ninety
  /// seconds of it.
  ///
  /// `demuxer-cache-unlink-files=immediate` is mpv's own default and is set
  /// here because it is what answers for the file afterwards: mpv unlinks
  /// the cache file as soon as it has created it, so it never has a name in
  /// the directory, and the space goes back to the filesystem when the fd
  /// closes -- at the next `loadfile`, when the player is disposed, and
  /// when the app is killed or crashes. Nothing of ours has to sweep up,
  /// and a default that changed under us would leave files behind.
  ///
  /// Both were measured against a running libmpv (0.41.0 on Linux) rather
  /// than read off the manual, and both names were checked against the
  /// build media_kit ships for Android, `mpv v0.36.0-549-g78d43740f5`,
  /// where `demuxer-cache-dir` is the option and the older `cache-dir` is
  /// only a deprecated alias.
  static Map<String, String> overridesFor(String? cacheDirectory) => {
    ...mpvOverrides,
    if (cacheDirectory != null) ...{
      'demuxer-cache-dir': cacheDirectory,
      'demuxer-cache-unlink-files': 'immediate',
    },
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
  static bool forcesSeekable(Uri url) {
    if (!url.isScheme('http') && !url.isScheme('https')) return false;
    final host = url.host;
    if (host == 'localhost') return true;
    return InternetAddress.tryParse(host)?.isLoopback ?? false;
  }

  /// Sets [overridesFor] on the native backend. Only libmpv has
  /// properties; any other backend keeps its own behaviour, and a player
  /// torn down before it initialised is not an error worth surfacing.
  ///
  /// The directory is asked for only once there is a backend to give it to,
  /// so a fake engine never reaches the platform channel.
  static Future<void> _applyOverrides(
    PlatformPlayer? platform,
    MpvCacheDirectory cacheDirectory,
  ) async {
    if (platform is! NativePlayer) return;
    for (final MapEntry(:key, :value) in overridesFor(
      await cacheDirectory(),
    ).entries) {
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

  /// The timer that keeps mpv's cache file to
  /// [MpvDiskCacheLimit.defaultLimitBytes], and the limiter it drives. One
  /// pair per `open`, because the file is one per `loadfile`.
  Timer? _diskCacheTimer;
  MpvDiskCacheLimit? _diskCacheLimit;

  final StreamController<PlaybackTracks> _tracks =
      StreamController<PlaybackTracks>.broadcast();

  final StreamController<double> _videoFrameRate =
      StreamController<double>.broadcast();

  /// The last rate emitted, so an observation that repeats itself (mpv
  /// answers the first one immediately, and a re-open of the same file
  /// answers with the same number) does not ask the display twice.
  double? _lastVideoFrameRate;

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

  /// Starts watching the size of mpv's cache file for the media just
  /// opened. The previous media's file is already gone -- mpv deletes it
  /// with the demuxer that made it -- so each `open` starts a fresh count.
  void _watchDiskCache() {
    _stopWatchingDiskCache();
    if (_player.platform is! NativePlayer || _disposed) return;
    final limit = MpvDiskCacheLimit(
      cacheState: () => _property('demuxer-cache-state'),
      stopWritingToDisk: () => _setProperty('cache-on-disk', 'no'),
    );
    _diskCacheLimit = limit;
    _diskCacheTimer = Timer.periodic(MpvDiskCacheLimit.interval, (_) {
      if (!_disposed) limit.check().ignore();
    });
  }

  void _stopWatchingDiskCache() {
    _diskCacheTimer?.cancel();
    _diskCacheTimer = null;
    // The timer is not the whole of it: a reading already awaiting libmpv
    // outlives its cancellation, so the limiter is told it no longer
    // speaks for the playback ([MpvDiskCacheLimit.stop]).
    _diskCacheLimit?.stop();
    _diskCacheLimit = null;
  }

  /// One mpv property as a string, `null` off libmpv or when the player
  /// cannot answer.
  Future<String?> _property(String name) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return null;
    try {
      return await platform.getProperty(name);
    } catch (_) {
      return null;
    }
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
    // First, before anything here writes `cache-on-disk`: the limiter
    // belongs to the media being replaced, and one of its readings landing
    // after the write below would turn the disk cache off for the media
    // this call is opening.
    _stopWatchingDiskCache();
    await _overrides;
    // Before the `loadfile`, and before every one of them: mpv reads
    // `force-seekable` once, when it builds the demuxer, so it has to be
    // set for the stream about to be opened and not for the last one.
    await _setProperty('force-seekable', forcesSeekable(url) ? 'yes' : 'no');
    // The same holds for the file cache, and awaiting [_overrides] above is
    // what puts `demuxer-cache-dir` in front of the first `loadfile`. mpv
    // creates the cache while it builds the demuxer and reads the directory
    // then; the demuxer's own option cache does not watch that option, so a
    // directory arriving later is not picked up at all. Handing a running
    // libmpv the directory a second after `loadfile` reproduced the owner's
    // `Failed to create file cache` and left `file-cache-bytes` absent for
    // the rest of the stream. `cache-on-disk` is media_kit's own default
    // (1.2.6 sets it once at start-up) but mpv reads it per demuxer, and
    // [MpvDiskCacheLimit] turns it off when the file grows too large, so
    // this is where the next media gets its file cache back.
    await _setProperty('cache-on-disk', 'yes');
    await _player.open(Media(url.toString(), start: start));
    _watchDiskCache();
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
  /// no more frames to the video texture, so the texture is idle by the time
  /// `Player.dispose` unregisters it (media_kit tears the native
  /// `VideoOutput` down from `Player.dispose`, so there is nothing separate
  /// to dispose on the `VideoController`).
  @override
  Future<void> dispose() async {
    _disposed = true;
    _stopStats();
    _stopWatchingDiskCache();
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
}

/// Keeps what mpv writes to disk for one media under a size a television
/// can spare.
///
/// mpv's cache file is append-only and nothing in mpv bounds it: the byte
/// limits (`demuxer-max-bytes`, `demuxer-max-back-bytes`) apply to packet
/// metadata once the payload is on disk, and space the player prunes is
/// never reused, so the file grows with every byte demuxed until the media
/// is closed. Measured against a running libmpv 0.41.0 with both limits at
/// media_kit's 32 MiB: playing a 139 MiB stream through left a 139 MiB
/// cache file, four times the whole memory budget. Left alone, the owner's
/// two-hour 2.3 Mbps film would put about 2 GB in the cache of a 2 GB
/// television that also stores torrent data, and a 4K remux would put tens
/// of gigabytes there. That is how you fill someone's device.
///
/// So the bound is ours to keep. [check] asks mpv what the file weighs and
/// turns `cache-on-disk` off once it is over [limitBytes]; from there the
/// media plays on out of the memory cache, which is what every playback
/// does today. What is already in the file stays seekable -- mpv reads
/// those packets back through the fd it still holds -- until the metadata
/// budget prunes them. The switch was measured the same way: a file capped
/// at 16 MiB stopped growing on the tick it crossed, stayed at that size
/// through the next four minutes of media, and playback did not falter.
///
/// **Nothing removes the file, because nothing has to.**
/// `demuxer-cache-unlink-files=immediate` (`MediaKitEngine.overridesFor`)
/// has mpv unlink it the moment it is created, so it never has a name in
/// the directory and the space returns to the filesystem when the fd
/// closes: at the next `loadfile`, when the player is disposed, and when
/// the app is killed or crashes. Confirmed by listing the directory during
/// playback while mpv reported 145 MB in the file, and finding it empty.
class MpvDiskCacheLimit {
  MpvDiskCacheLimit({
    required this.cacheState,
    required this.stopWritingToDisk,
    this.limitBytes = defaultLimitBytes,
  });

  /// 512 MiB, on a device whose whole storage is 8 GB and whose torrent
  /// data shares it. It is 512 MiB of *bytes demuxed*, and that is not the
  /// same clock as playback.
  ///
  /// With the file cache carrying the payload, media_kit's 32 MiB
  /// `demuxer-max-bytes` bounds packet metadata instead -- some 26 bytes of
  /// budget per megabyte of film, on the pair of readings in
  /// `player_cache_test.dart` -- so mpv reads tens of minutes ahead, and it
  /// reads at whatever rate the link delivers rather than at the film's
  /// 2.3 Mbps. On a link that keeps up, 512 MiB of a 2.3 Mbps film is
  /// therefore demuxed within the first few minutes of a two-hour one, not
  /// half way through it. What that costs is the far end of the film: from
  /// the cap on, new packets are held in memory at full payload size again
  /// and the window ahead shortens back towards the ninety seconds the
  /// readings started at. The `file` row on the stats panel is what says
  /// which side of that a reading was taken on -- a number that has stopped
  /// climbing.
  ///
  /// **What this number does not know is how much room there actually is.**
  /// It is a constant, and the player has no way to ask: free space per
  /// volume exists in the app (`server_storage_report`) but only as a
  /// question for the embedded server, and this stream need never have gone
  /// near the server. On a volume with less than this free, mpv fills it
  /// and its writes start failing; `demux_cache_write` then leaves the
  /// packet in memory and puts `file_size` back where it was, so the
  /// reading freezes below the cap, this limiter never fires, and mpv
  /// retries on every packet for the rest of the film. Nothing is left
  /// behind afterwards -- the file is unlinked at creation -- but the
  /// volume is full while it plays. The honest bound would be the smaller
  /// of this and what the volume has; giving the player a free-space
  /// reading of its own is the change that would buy it.
  static const int defaultLimitBytes = 512 * 1024 * 1024;

  /// How often [MediaKitEngine] asks. The file grows at the bitrate of the
  /// media, so five seconds overshoots by a couple of megabytes on a
  /// television stream and by forty on a 60 Mbps remux -- both small
  /// against the limit, and one property read is cheap.
  static const Duration interval = Duration(seconds: 5);

  /// mpv's `demuxer-cache-state`, as [MediaKitEngine] reads it.
  final Future<String?> Function() cacheState;

  /// Sets `cache-on-disk` to `no`.
  final Future<void> Function() stopWritingToDisk;

  /// The most the cache file may weigh.
  final int limitBytes;

  bool _reached = false;
  bool _checking = false;
  bool _stopped = false;

  /// Whether the limit has been hit for this media, after which nothing is
  /// asked again: the file cannot shrink, so the answer cannot change.
  bool get reached => _reached;

  /// Ends this limiter for good: it belongs to one media, and the media it
  /// was measuring is gone.
  ///
  /// Cancelling the timer that drives it is not enough on its own. [check]
  /// awaits an `mpv_get_property_string` in the middle, so a reading that
  /// began before the next `loadfile` can come back after it -- carrying
  /// the *previous* file's size -- and write `cache-on-disk=no` onto the
  /// media that has just been opened. That media then plays its whole
  /// length with no disk cache and its own limiter, seeing no file at all,
  /// never turns one back on: the fix silently does not apply to the next
  /// episode. So [check] asks again after every await whether this limiter
  /// still speaks for the playback.
  void stop() => _stopped = true;

  /// One reading. Turns the disk cache off if the file is over
  /// [limitBytes].
  Future<void> check() async {
    // One at a time: `getProperty` awaits the player's own initialisation,
    // so a slow start must not pile readings up.
    if (_stopped || _reached || _checking) return;
    _checking = true;
    try {
      final bytes = PlaybackStats.fileCacheBytesOf(await cacheState());
      if (_stopped || bytes == null || bytes <= limitBytes) return;
      _reached = true;
      await stopWritingToDisk();
    } catch (_) {
      // A player torn down mid-reading is not an error worth surfacing;
      // the next tick, if there is one, asks again.
    } finally {
      _checking = false;
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
