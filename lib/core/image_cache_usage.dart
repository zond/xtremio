import 'package:flutter/painting.dart';

import 'state/download.dart';

/// What Flutter's own image cache holds at one instant, and the ceiling it
/// is held against.
///
/// `XtremioBootstrap.imageCacheCeilingBytes` caps that cache at 32 MiB in
/// place of the framework's 100 MiB, and `XtremioApp` empties it when the
/// app goes to the background -- but until this existed nothing in the app
/// ever looked at what the cache actually held, so whether the cap was ever
/// reached was a guess. On the owner's Chromecast with Google TV (2 GB for
/// the whole box) browsing two titles and their source lists, with nothing
/// played, took the native heap to 77 MB peak and 35 MB settled, and the
/// low-memory killer has taken the app at 147 MB resident. Which part of
/// that a ceiling could ever reach is the question these figures answer.
///
/// **Two halves, and they are not a sum.** [cachedBytes] is the cache
/// proper: images an LRU bounds, evicted least-recently-used first as the
/// ceiling is crossed and dropped whole when the app is backgrounded.
/// [liveImages] is the other half -- images an on-screen widget, or one on
/// a screen still in the navigator stack, is holding. Eviction and
/// `ImageCache.clear` do not free those; only the widget going away does.
/// Most live images are counted in [cachedBytes] as well, so adding the two
/// means nothing. What they are read for is the share: how much of what the
/// app is holding a ceiling could ever reach.
///
/// The framework counts live images but not their bytes -- there is no
/// getter for them, and walking the cache for a sum would cost more than a
/// diagnostics read is allowed to -- so that half is a count. A count still
/// settles the question it is there for: a settled figure with the cached
/// bytes far under the ceiling and a hundred images live says the memory is
/// in the half no cap touches.
class ImageCacheUsage {
  const ImageCacheUsage({
    required this.cachedBytes,
    required this.cachedImages,
    required this.ceilingBytes,
    required this.liveImages,
    required this.decodingImages,
  });

  /// The process-wide cache as it stands this instant.
  ///
  /// Five reads of stored counters and two map lengths: nothing is
  /// allocated, decoded, walked or evicted. Diagnostics that moved what
  /// they measure would be worse than no diagnostics, and this is read on
  /// the screen that exists for a device already close to being killed.
  factory ImageCacheUsage.read() {
    final cache = PaintingBinding.instance.imageCache;
    return ImageCacheUsage(
      cachedBytes: cache.currentSizeBytes,
      cachedImages: cache.currentSize,
      ceilingBytes: cache.maximumSizeBytes,
      liveImages: cache.liveImageCount,
      decodingImages: cache.pendingImageCount,
    );
  }

  /// Decoded bytes the cache is holding for images nothing has to be
  /// showing: `ImageCache.currentSizeBytes`. The half the ceiling acts on.
  final int cachedBytes;

  /// How many images that is (`currentSize`). Beside [cachedBytes] it
  /// gives the average decoded size, which is what says whether a ceiling
  /// bounds a hundred posters or a dozen.
  final int cachedImages;

  /// The ceiling those are held against: `ImageCache.maximumSizeBytes` as
  /// the cache has it, not `XtremioBootstrap.imageCacheCeilingBytes` as the
  /// app meant it.
  ///
  /// The constant is what [main] asks for before the first frame; this is
  /// what is in force. A report that quoted the constant could not show a
  /// build where the ceiling was never applied, which is one of the things
  /// worth finding out from a device nobody can attach a debugger to.
  final int ceilingBytes;

  /// How many images a live widget is holding (`liveImageCount`): the half
  /// no eviction and no `clear` reaches. A count, not bytes -- see the
  /// class doc.
  final int liveImages;

  /// How many images are being fetched or decoded right now
  /// (`pendingImageCount`): memory on its way in that is in neither figure
  /// yet. A screenful of posters resolving at once is what a browsing peak
  /// looks like from here.
  final int decodingImages;

  /// `18.2 MB of 33.6 MB ceiling`, in the decimal units every other size
  /// in this app is shown in -- so 32 MiB of ceiling reads as 33.6 MB,
  /// the same convention as the `cache:` and `disk:` lines above it.
  String get cachedLabel =>
      '${DownloadView.humanSize(cachedBytes)} of '
      '${DownloadView.humanSize(ceilingBytes)} ceiling';

  /// The two lines the diagnostics header carries, taken the instant the
  /// header's `taken:` stamp was.
  ///
  /// Two lines and not one because the halves answer different questions,
  /// and a reader who only saw a total would draw the wrong conclusion from
  /// it: a cached figure well under the ceiling is not a small image
  /// footprint if a hundred images are live.
  List<String> get reportLines => [
    'image cache: $cachedLabel · $cachedImages images',
    'images in use: $liveImages held by a live widget, which no eviction '
        'frees · $decodingImages decoding',
  ];

  /// What those lines say when the cache could not be read at all -- the
  /// binding not up, which on a running app it always is. The header keeps
  /// its shape either way, the way the storage lines do.
  static const List<String> unknownReportLines = [
    'image cache: unknown',
    'images in use: unknown',
  ];
}
