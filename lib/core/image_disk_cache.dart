import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'diagnostics_log.dart';

/// The encoded bytes of every network picture the app has drawn, kept on
/// disk, so that dropping a decoded one costs a local read rather than a
/// download.
///
/// **There was no such cache, and the ceiling was chosen as if there
/// were.** `dart:io`'s `HttpClient` implements no HTTP cache of any kind,
/// and Flutter's `NetworkImage` gives it none: it fetches into memory,
/// hands the bytes to the decoder and forgets them. So every eviction
/// `XtremioBootstrap.imageCacheCeilingBytes` caused, and every one of the
/// wholesale `ImageCache.clear`s `XtremioApp` does when the app is
/// backgrounded, was paid for the next time the picture was drawn with a
/// DNS lookup, a TLS handshake and a round trip to metahub -- on a
/// television, over whatever the house wifi is doing. A ceiling that is
/// cheap to cross is what lets it be lowered, and until this existed
/// crossing it was the most expensive thing the app could do.
///
/// On the owner's Chromecast with Google TV, browsing two titles and
/// returning to the board leaves Flutter's cache at 33 MB of its 33 MB
/// ceiling in 80 images, against a settled native heap of 42 MB for the
/// whole process: about four fifths of everything the app retains after
/// browsing is decoded artwork, and the low-memory killer has taken this
/// app at 203 MB and at 147 MB resident.
///
/// **What is stored is the file the addon served, not the decode.** A
/// poster is twenty to forty kilobytes of JPEG and about four hundred
/// kilobytes of texture, so the bytes here are an order of magnitude
/// smaller than the ones they refill, and they are the ones a re-decode
/// needs. Nothing here decides how a picture is decoded: the bound stays
/// where it was, on the `ResizeImage` round the provider (see
/// [DiskCachedImage.bounded]), so what is drawn is what was drawn before.
///
/// **The index is the whole point of the cold path.** Whether a URL is
/// here is answered by [has] from a map built once at [openIn], never by
/// asking the filesystem -- a `stat` in front of every fetch would put a
/// syscall on the one path a viewer notices, the first draw of a board
/// whose artwork is not here yet, and would buy nothing at all on a cold
/// cache. A miss is a hash and a map lookup. A write happens after the
/// codec has been handed back, so nothing a viewer is waiting for waits
/// for a file.
class ImageDiskCache {
  ImageDiskCache._(
    this._dir,
    this.ceilingBytes,
    this.maxAge,
    this._now,
    this._entries,
    this._bytes,
  );

  /// What the store may hold: 64 MiB.
  ///
  /// The ceiling exists because a television is not a workstation -- an
  /// unbounded artwork directory on a box with eight gigabytes of storage
  /// that is mostly film is a second bug, not a fix for the first. What
  /// makes 64 MiB the number is the ratio to what it refills: at the
  /// twenty to forty kilobytes metahub serves a poster at, this holds
  /// well over a thousand pictures, where Flutter's 32 MiB of decoded
  /// images holds eighty. Everything a browsing session touches, and most
  /// of a library, therefore survives every eviction and every
  /// backgrounding, which is what the ceiling above it was costing.
  ///
  /// It is deliberately *not* taken out of the server's `cacheSize`
  /// budget (`rust/src/storage.rs`, reported on the `cache:` line). That
  /// budget has one owner, the Rust side, over one root, the torrent
  /// data; two owners spending one number is how a limit stops being
  /// enforced by either. What the two do share is the report: the
  /// `image files:` line sits under `cache:` and `disk:` so the three are
  /// read at once (see `ImageCacheUsage`).
  static const int defaultCeilingBytes = 64 * 1024 * 1024;

  /// How long a stored picture is believed: thirty days.
  ///
  /// Nothing served here carries a useful validator -- metahub answers a
  /// poster with no `ETag` worth a conditional request -- so the choice is
  /// between believing a URL forever and re-fetching on a clock. A poster
  /// or a backdrop for a title that exists never changes; what does change
  /// is an addon's logo, when the addon is updated, and a profile picture.
  /// Thirty days is the shortest age that still costs nothing in practice
  /// (artwork is drawn far more often than monthly, so a re-fetch is one
  /// picture in a screenful, once) and the longest a wrong logo can
  /// survive. Not honouring staleness at all would leave a replaced logo
  /// on screen until the store filled, which on 64 MiB is never.
  static const Duration defaultMaxAge = Duration(days: 30);

  static ImageDiskCache? _instance;

  /// The store [DiskCachedImage] reads and writes, or null when none was
  /// opened.
  ///
  /// Null is the honest state and not a failure: a test that never boots
  /// the app has no store, and neither has a device whose cache directory
  /// could not be made. Both draw exactly what they drew before -- every
  /// fetch goes to the network, which is what the app did until now.
  static ImageDiskCache? get instance => _instance;

  /// Puts [cache] in place for the life of the process (null takes one
  /// away, which is what a test tears down to).
  static void install(ImageDiskCache? cache) => _instance = cache;

  /// Opens the store in [dir], reading what a previous run left there.
  ///
  /// The listing is where the index comes from, and it is the only time
  /// the filesystem is walked: one `stat` per stored picture, a few
  /// milliseconds for a full store, and it happens inside the boot that is
  /// already waiting on the Rust core rather than in front of a frame.
  /// Anything already too old ([maxAge]) is deleted here rather than
  /// indexed, and anything over [ceilingBytes] is swept, so a build that
  /// lowered the ceiling comes up under it.
  ///
  /// Answers null when the directory cannot be made or listed at all. A
  /// device that will not give the app a cache directory still draws
  /// pictures.
  static Future<ImageDiskCache?> openIn(
    Directory dir, {
    int ceilingBytes = defaultCeilingBytes,
    Duration maxAge = defaultMaxAge,
    DateTime Function() now = DateTime.now,
  }) async {
    try {
      await dir.create(recursive: true);
      final entries = <String, _Stored>{};
      final stale = <File>[];
      var bytes = 0;
      await for (final item in dir.list(followLinks: false)) {
        if (item is! File) continue;
        final FileStat stat = await item.stat();
        if (now().difference(stat.modified) > maxAge) {
          stale.add(item);
          continue;
        }
        entries[item.uri.pathSegments.last] = _Stored(stat.size, stat.modified);
        bytes += stat.size;
      }
      final cache = ImageDiskCache._(
        dir,
        ceilingBytes,
        maxAge,
        now,
        entries,
        bytes,
      );
      for (final file in stale) {
        await cache._delete(file);
      }
      await cache._sweep();
      return cache;
    } on IOException catch (error) {
      DiagnosticsLog.warn('images', 'no disk cache for images: $error');
      return null;
    }
  }

  final Directory _dir;
  final DateTime Function() _now;

  /// Name to size and write time, for everything in [_dir]. The index the
  /// class doc is about: [has] is this map and nothing else.
  final Map<String, _Stored> _entries;

  int _bytes;

  /// What the store may hold before the oldest pictures are dropped.
  final int ceilingBytes;

  /// How old a stored picture may be before it is fetched again.
  final Duration maxAge;

  /// What is stored right now, for the diagnostics report.
  int get bytes => _bytes;

  /// How many pictures that is.
  int get files => _entries.length;

  /// Whether [url] is here, from the index: a hash and a map lookup, with
  /// no syscall and nothing awaited. See the class doc.
  bool has(String url) => _entries.containsKey(_nameFor(url));

  /// The stored bytes for [url], or null when there are none, they have
  /// aged out, or the file the index named could not be read.
  ///
  /// A file the index promised and the disk does not have is forgotten
  /// rather than retried: the directory is the system's to reclaim (it is
  /// `getCacheDir()` on Android), so half a store disappearing under a
  /// running app is expected, and the answer to it is a download.
  Future<Uint8List?> read(String url) async {
    final name = _nameFor(url);
    final stored = _entries[name];
    if (stored == null) return null;
    if (_now().difference(stored.written) > maxAge) {
      await _delete(_fileNamed(name));
      return null;
    }
    try {
      return await _fileNamed(name).readAsBytes();
    } on IOException {
      _forget(name);
      return null;
    }
  }

  /// Stores [bytes] as what [url] serves, and sweeps the store back under
  /// its ceiling if that put it over.
  ///
  /// Nothing waits for this: [DiskCachedImage] starts it after the codec
  /// is on its way to the widget. A picture larger than the whole store is
  /// not kept at all rather than emptying it -- there is no such artwork,
  /// and a store that can be cleared by one answer is not a cache.
  Future<void> write(String url, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > ceilingBytes) return;
    final name = _nameFor(url);
    final at = _now();
    try {
      final file = _fileNamed(name);
      await file.writeAsBytes(bytes, flush: false);
      // The store's own clock decides ages, not the filesystem's: the two
      // agree on a device and a test can move only one of them.
      await file.setLastModified(at);
    } on IOException {
      _forget(name);
      return;
    }
    _bytes += bytes.length - (_entries[name]?.bytes ?? 0);
    _entries[name] = _Stored(bytes.length, at);
    await _sweep();
  }

  /// Drops the oldest pictures until the store is under its ceiling.
  ///
  /// Oldest *written*, not least recently used. An LRU would have to
  /// touch a file on every hit, which is a write on the read path and on
  /// a television's flash the read path is where this is meant to be
  /// free; and with a store that holds ten times a browsing session the
  /// two orders pick the same victims anyway.
  Future<void> _sweep() async {
    if (_bytes <= ceilingBytes) return;
    final oldest = _entries.entries.toList()
      ..sort((a, b) => a.value.written.compareTo(b.value.written));
    for (final entry in oldest) {
      if (_bytes <= ceilingBytes) return;
      await _delete(_fileNamed(entry.key));
    }
  }

  Future<void> _delete(File file) async {
    try {
      await file.delete();
    } on IOException {
      // Gone, or never ours to delete. Either way it is not in the index
      // any more, which is what the index is for.
    }
    _forget(file.uri.pathSegments.last);
  }

  void _forget(String name) {
    final stored = _entries.remove(name);
    if (stored != null) _bytes -= stored.bytes;
  }

  File _fileNamed(String name) =>
      File('${_dir.path}${Platform.pathSeparator}$name');

  /// The file a URL is stored under: its SHA-256, hex.
  ///
  /// A URL is not a filename -- it carries slashes, a query and more
  /// characters than Windows will accept -- and a hash is the one mapping
  /// that is the same length, the same everywhere and needs no escaping
  /// rules to be got right twice.
  static String _nameFor(String url) =>
      sha256.convert(utf8.encode(url)).toString();
}

/// One stored picture, as the index has it.
class _Stored {
  const _Stored(this.bytes, this.written);

  final int bytes;
  final DateTime written;
}

/// A network image that keeps what it fetched in [ImageDiskCache].
///
/// Everything else about it is Flutter's `NetworkImage`, deliberately: the
/// same shared `HttpClient` and so the same connection reuse across a
/// board full of posters, the same chunk events, the same
/// `NetworkImageLoadException` on a bad status, the same eviction of a key
/// whose fetch threw, and the same equality -- the URL -- so the framework
/// cache keys images exactly as it did. What is added is two lines: the
/// stored bytes are used when they are there, and what was fetched is
/// stored afterwards.
///
/// The provider is never built directly outside this file; call sites
/// build it through [bounded], which is what keeps a decode bounded (the
/// guard in `test/features/image_decode_test.dart` enforces both halves).
@immutable
class DiskCachedImage extends ImageProvider<DiskCachedImage> {
  const DiskCachedImage(this.url, {this.scale = 1.0});

  /// The provider for [url], decoded at [cacheWidth] x [cacheHeight]
  /// physical pixels.
  ///
  /// This is exactly what `Image.network` builds round Flutter's own
  /// provider, down to the call -- `ResizeImage.resizeIfNeeded` -- so a
  /// call site that moved from `Image.network(url, cacheWidth: w)` to
  /// `Image(image: DiskCachedImage.bounded(url, cacheWidth: w))` draws the
  /// same picture at the same decode, and a test that reads the bound off
  /// the `ResizeImage` still finds it.
  static ImageProvider<Object> bounded(
    String url, {
    int? cacheWidth,
    int? cacheHeight,
  }) =>
      ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, DiskCachedImage(url));

  /// The URL fetched, and the key both caches use.
  final String url;

  final double scale;

  /// Stands in for the network in a test, so that "did this go out again?"
  /// is a counted question. Debug-only, like Flutter's own
  /// `debugNetworkImageHttpClientProvider`.
  @visibleForTesting
  static Future<Uint8List> Function(Uri url)? debugFetch;

  @override
  Future<DiskCachedImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<DiskCachedImage>(this);

  @override
  ImageStreamCompleter loadImage(
    DiskCachedImage key,
    ImageDecoderCallback decode,
  ) {
    // Handed to [_load], which closes it however it ends.
    final chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _load(key, chunkEvents, decode),
      chunkEvents: chunkEvents.stream,
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider<Object>>('Image provider', this),
        DiagnosticsProperty<DiskCachedImage>('Image key', key),
      ],
    );
  }

  Future<ui.Codec> _load(
    DiskCachedImage key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
  ) async {
    try {
      final Uri resolved = Uri.base.resolve(key.url);
      final store = ImageDiskCache.instance;
      // The index, not the disk: a miss here costs no syscall, which is
      // what keeps a cold board as fast as it was.
      if (store != null && store.has(key.url)) {
        final Uint8List? kept = await store.read(key.url);
        if (kept != null && kept.isNotEmpty) {
          return await decode(await ui.ImmutableBuffer.fromUint8List(kept));
        }
      }
      final Uint8List bytes = await _fetch(resolved, chunkEvents);
      if (bytes.isEmpty) {
        throw Exception('a network image is an empty file: $resolved');
      }
      final ui.Codec codec = await decode(
        await ui.ImmutableBuffer.fromUint8List(bytes),
      );
      // After the decode, and not awaited: the picture is already on its
      // way to the widget, and a file write may not be in front of it.
      if (store != null) unawaited(store.write(key.url, bytes));
      return codec;
    } catch (_) {
      // Flutter's own comment, and its reason: the cache may not have had
      // a chance to track the key yet, so give it one before evicting.
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    } finally {
      unawaited(
        chunkEvents.close().catchError((Object error, StackTrace stack) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stack,
              library: 'xtremio',
              context: ErrorDescription(
                'while closing the chunk events of $url',
              ),
            ),
          );
        }),
      );
    }
  }

  Future<Uint8List> _fetch(
    Uri resolved,
    StreamController<ImageChunkEvent> chunkEvents,
  ) async {
    Future<Uint8List> Function(Uri url)? instead;
    assert(() {
      instead = debugFetch;
      return true;
    }());
    if (instead != null) return instead!(resolved);
    final HttpClientRequest request = await _client.getUrl(resolved);
    final HttpClientResponse response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      // Drained rather than dropped, so the connection goes back to the
      // pool instead of being torn down.
      await response.drain<List<int>>(<int>[]);
      throw NetworkImageLoadException(
        statusCode: response.statusCode,
        uri: resolved,
      );
    }
    return consolidateHttpClientResponseBytes(
      response,
      onBytesReceived: (int cumulative, int? total) => chunkEvents.add(
        ImageChunkEvent(
          cumulativeBytesLoaded: cumulative,
          expectedTotalBytes: total,
        ),
      ),
    );
  }

  /// One client for the whole process, as Flutter's provider keeps: a
  /// board draws a few dozen posters off one host, and a client per
  /// fetch would be a handshake per poster. `autoUncompress` is off for
  /// the same reason it is off there -- it makes `Content-Length`
  /// trustworthy, and [consolidateHttpClientResponseBytes] does the
  /// uncompressing.
  static final HttpClient _client = HttpClient()..autoUncompress = false;

  @override
  bool operator ==(Object other) =>
      other is DiskCachedImage &&
      other.runtimeType == runtimeType &&
      other.url == url &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(url, scale);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'DiskCachedImage')}("$url", '
      'scale: ${scale.toStringAsFixed(1)})';
}
