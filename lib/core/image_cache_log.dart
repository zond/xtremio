import 'dart:async';

import 'package:flutter/widgets.dart';

import 'diagnostics_log.dart';
import 'image_cache_usage.dart';
import 'state/download.dart';

/// The image cache's figures in the log, where they can be read over adb
/// while somebody drives the app.
///
/// [ImageCacheUsage] has answered what the cache holds since the day
/// before this, but only on the Diagnostics *screen*: reading it meant
/// somebody navigating a television by hand and saying numbers out loud,
/// which is how the one measurement anybody has was taken -- 33 MB of a
/// 33 MB ceiling over 80 images, four fifths of the process's settled
/// native heap, and 410 kB per picture that nothing in this app can
/// explain. The engine writes its own figures to the log continuously
/// (`stream progress`, the retention passes), a Chromecast with Google TV
/// is reachable over `adb logcat -s xtremio` and nothing else, and the
/// image cache belongs in that company.
///
/// Two lines, and they answer different questions:
///
/// - [start] writes [ImageCacheUsage.logLine] every [period]: the totals,
///   on their own, cheap enough to leave on in a shipping build.
/// - [noteDecoded] writes one line per image as it resolves, with the size
///   it actually decoded to. That one is behind [perImage], which follows
///   the "Verbose logging" preference (`DiagnosticsTraceSync`), because a
///   line per picture is a hundred lines for one screen of posters: far
///   too much for normal running and exactly what one measured session
///   needs.
///
/// Both read and neither touches: nothing here decodes, evicts, resizes or
/// walks the cache. [ImageCacheUsage.read] is five stored counters, and
/// the per-image line is taken from the [ImageInfo] a resolve was going to
/// produce anyway.
class ImageCacheLog {
  ImageCacheLog({this.period = defaultPeriod});

  /// How often the totals go out.
  ///
  /// Thirty seconds: two lines a minute is twenty over the ten minutes a
  /// session of this kind lasts, which is five per cent of the four
  /// hundred lines the ring keeps and nothing at all beside the engine's
  /// own traffic -- and it is short enough to *follow* somebody, so a row
  /// of posters filling the cache reads as a climb rather than as a jump
  /// between the only two readings anybody took. A minute would have
  /// covered browsing two titles in three samples.
  ///
  /// Identical consecutive lines are counted rather than written
  /// (`DiagnosticsLog.write`), so an app left standing still says
  /// `last line repeated 12 times` instead of filling the ring.
  static const Duration defaultPeriod = Duration(seconds: 30);

  /// The `target` both lines carry: `images`, beside the app's `player`,
  /// `boot` and `flutter`. In logcat that reads as
  /// `xtremio_core::app: images: …`.
  static const String target = 'images';

  final Duration period;

  Timer? _timer;
  bool _stopped = false;

  /// Starts writing, beginning with a line for this instant: the first
  /// reading of a session is the one a report is read against, and waiting
  /// a period for it would lose the state the app came up in.
  ///
  /// Safe to call after [dispose], and safe to call twice; neither starts
  /// a second timer.
  void start() {
    if (_stopped || _timer != null) return;
    _write();
    _timer = Timer.periodic(period, (_) => _write());
  }

  /// Stops writing. The figures are the framework's, so there is nothing
  /// to put back.
  void dispose() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  static void _write() =>
      DiagnosticsLog.info(target, ImageCacheUsage.read().logLine);

  /// Whether a resolved image writes what it decoded to.
  ///
  /// Off by default and set from the viewer's "Verbose logging" choice by
  /// `DiagnosticsTraceSync`, the one thing in the app that follows that
  /// preference. A static because what reads it -- [ObservingImageCache]
  /// -- is created with the binding, before there are preferences to hand
  /// it, and it is the same shape as `DiagnosticsLog.unredacted`, which
  /// the same switch sets and which is what keeps the URL in these lines
  /// whole.
  ///
  /// It is read as an image is *submitted* to the cache, so turning it on
  /// says nothing about pictures that are already decoded. Backgrounding
  /// the app empties the cache (`XtremioApp`), which is the cheap way to
  /// make a television decode a screen again with this on.
  static bool perImage = false;

  /// One image, as it resolved: what it decoded to, what that costs, and
  /// what it came from.
  ///
  /// This is the line that answers the 410 kB. A decoded picture is
  /// `width × height × 4` bytes resident whatever box it is drawn in, so
  /// the two numbers *are* the memory; and [ImageInfo.debugLabel] carries
  /// the URL with the bound that was asked for appended by `ResizeImage`
  /// (`… - Resized(312×null)`), so a picture that decoded larger than the
  /// box it is drawn in says so on its own line, and a mix that is not
  /// what anybody assumed is visible by reading down the URLs.
  ///
  /// [info] is only read from; disposing the clone is the caller's, as it
  /// is for every image listener.
  static void noteDecoded(ImageInfo info) {
    if (!perImage) return;
    DiagnosticsLog.info(target, decodedLine(info));
  }

  /// The line [noteDecoded] writes, apart from writing it.
  @visibleForTesting
  static String decodedLine(ImageInfo info) =>
      'image decoded: ${info.image.width}×${info.image.height} px, '
      '${DownloadView.humanSize(info.sizeBytes)} resident · '
      '${info.debugLabel ?? 'from an image that names no source'}';
}

/// The framework's image cache, with every image that is submitted to it
/// observed on its way through ([ImageCacheLog.noteDecoded]).
///
/// **Where a resolve can be watched from.** Flutter offers exactly one
/// debug hook for this -- `debugOnPaintImage`, which is inside an `assert`
/// and so does not exist in a release build, the only build the device
/// this app is measured on runs. What is left is the cache itself:
/// `putIfAbsent` is where every provider in the app, and every provider
/// anybody adds later, hands over a stream to be decoded, and it is the
/// only such place. Watching from here means the image widgets are not
/// touched at all -- no provider, no widget, no loading path -- which is
/// also what keeps this out of the way of work going on in them.
///
/// **It observes and does not participate.** The loader is wrapped rather
/// than replaced, so the listener goes on only when the cache is about to
/// decode something new: a cache hit, a pending image and a live one all
/// return before the loader is called, and none of them is a decode to
/// report. The listener comes off again as soon as the image (or the
/// failure) arrives, so nothing is held alive by being watched, and it is
/// only ever attached at all while [ImageCacheLog.perImage] is on.
class ObservingImageCache extends ImageCache {
  @override
  ImageStreamCompleter? putIfAbsent(
    Object key,
    ImageStreamCompleter Function() loader, {
    ImageErrorListener? onError,
  }) {
    if (!ImageCacheLog.perImage) {
      return super.putIfAbsent(key, loader, onError: onError);
    }
    return super.putIfAbsent(key, () => _watched(loader()), onError: onError);
  }

  /// [completer] with a listener on it that writes the one line and then
  /// leaves.
  ///
  /// The removal is a microtask and never synchronous, and that is not a
  /// nicety: a completer that is already complete answers a listener the
  /// instant it goes on, which here is *inside* `loader()`, before the
  /// cache has taken the keep-alive handle that owns it -- and a completer
  /// whose last listener leaves with no handle on it disposes itself and
  /// the picture with it. A microtask later the cache is holding it, the
  /// widget that asked for it is listening, and letting go changes
  /// nothing.
  static ImageStreamCompleter _watched(ImageStreamCompleter completer) {
    late final ImageStreamListener listener;
    void detach() =>
        scheduleMicrotask(() => completer.removeListener(listener));
    listener = ImageStreamListener(
      (info, _) {
        ImageCacheLog.noteDecoded(info);
        // Every listener is handed its own clone to dispose of. The cache
        // disposes the one it takes and this disposes this one: a handle
        // kept open by the thing that counts the memory would be a leak in
        // the measuring tool.
        info.dispose();
        detach();
      },
      onError: (exception, _) {
        detach();
        // Rethrown exactly as it arrived, which is what `reportError`
        // reads as "nobody handled this": an error listener that answers
        // an image that failed is one that silences the framework's own
        // report of it, and a picture that 404s must go on being reported
        // the way it was before anything here existed.
        throw exception;
      },
    );
    completer.addListener(listener);
    return completer;
  }
}

/// The app's binding, which exists for one reason: it is the only place
/// the framework lets an [ImageCache] be replaced ([createImageCache]).
///
/// [ensureInitialized] must be the first thing `main` does -- before
/// anything that might bring a binding up itself, which every plugin's own
/// `ensureInitialized` will -- because whichever binding is created first
/// is the one the process gets.
///
/// Nothing else here is ours; everything is `WidgetsFlutterBinding`'s.
class XtremioBinding extends WidgetsFlutterBinding {
  static XtremioBinding? _instance;

  /// Brings this binding up, and answers it.
  static WidgetsBinding ensureInitialized() {
    if (_instance == null) XtremioBinding();
    return WidgetsBinding.instance;
  }

  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
  }

  @override
  ImageCache createImageCache() => ObservingImageCache();
}
