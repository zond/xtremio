/// The image cache's figures in the log.
///
/// Everything anybody knows about this app's image memory was read off the
/// Diagnostics screen of a television, out loud, once. These lines are the
/// same figures where `adb logcat -s xtremio` can follow them: the totals
/// on a period, and -- behind "Verbose logging" -- what each picture
/// actually decoded to, which is the half that can explain 80 images at
/// 410 kB each.
///
/// The cache these run against is the framework's own, and the observing
/// one is compared against a plain [ImageCache] doing the same work,
/// because a log that moved what it measures would be worse than no log at
/// all.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/diagnostics_capture.dart';

/// A decoded picture and the completer that hands it out, the way the
/// framework hands one to the cache: [width] x [height] physical pixels,
/// four bytes each.
Future<ImageStreamCompleter> decoded(
  WidgetTester tester, {
  int width = 100,
  int height = 100,
  String? label,
}) async {
  final image = (await tester.runAsync(
    () => createTestImage(width: width, height: height),
  ))!;
  return OneFrameImageStreamCompleter(
    SynchronousFuture(ImageInfo(image: image, debugLabel: label)),
  );
}

/// [decoded], put into the framework's cache and kept *live* -- the state
/// a poster is in while the screen showing it is still on the stack.
///
/// The listener is what does that: while one is on the completer the entry
/// stays in the live half, which no eviction and no `clear` reaches.
/// Answers how to let go of it again, and what it is worth.
Future<({VoidCallback release, int bytes})> shown(
  WidgetTester tester,
  Object key, {
  int width = 100,
  int height = 100,
}) async {
  final completer = await decoded(tester, width: width, height: height);
  final listener = ImageStreamListener((info, _) => info.dispose());
  completer.addListener(listener);
  imageCache.putIfAbsent(key, () => completer);
  return (
    release: () => completer.removeListener(listener),
    bytes: width * height * 4,
  );
}

/// "Verbose logging" on, both halves of it, the way one press of the
/// switch in Settings leaves the app (`DiagnosticsTraceSync`): the line
/// per image, and URLs written whole rather than reduced to their host.
/// The second matters here -- the URL is half of what the line is for, and
/// with the switch off the redaction would take exactly the part being
/// chased.
void verboseLogging() {
  final unredacted = DiagnosticsLog.unredacted;
  addTearDown(() {
    ImageCacheLog.perImage = false;
    DiagnosticsLog.unredacted = unredacted;
  });
  ImageCacheLog.perImage = true;
  DiagnosticsLog.unredacted = true;
}

/// One picture through [cache], and what is still holding on to it after:
/// how many handles are open on the image, and what the cache took it to
/// be worth.
Future<({int handles, int bytes})> withOpenHandles(
  WidgetTester tester,
  ImageCache cache, {
  required int size,
}) async {
  // A size of its own per call: `createTestImage` hands out clones of one
  // picture per size, so two caches given "the same" 10x10 would be given
  // handles on one image and counted together.
  final image = (await tester.runAsync(
    () => createTestImage(width: size, height: size),
  ))!;
  cache.putIfAbsent(
    'poster',
    () => OneFrameImageStreamCompleter(
      SynchronousFuture(ImageInfo(image: image)),
    ),
  );
  // A microtask on, which is when the observer lets go.
  await tester.pump();
  return (
    handles: image.debugGetOpenHandleStackTraces()!.length,
    bytes: cache.currentSizeBytes,
  );
}

void main() {
  group('the periodic line', () {
    setUp(() {
      final ceiling = imageCache.maximumSizeBytes;
      addTearDown(() {
        imageCache.clear();
        imageCache.clearLiveImages();
        imageCache.maximumSizeBytes = ceiling;
      });
      imageCache.clear();
      imageCache.clearLiveImages();
    });

    testWidgets('goes out at once and then on the period, and says what '
        'the cache holds', (tester) async {
      final lines = captureDiagnostics();
      final log = ImageCacheLog(period: const Duration(seconds: 5));
      addTearDown(log.dispose);

      log.start();
      // The first reading is the state the app came up in; waiting a
      // period for it would lose it.
      expect(lines, hasLength(1));
      expect(
        lines.single,
        'info images image cache: 0 B of '
        '${DownloadView.humanSize(imageCache.maximumSizeBytes)} ceiling '
        '· 0 images · 0 held live by a widget, which no eviction frees '
        '· 0 decoding',
      );

      final one = await shown(tester, 'poster');
      addTearDown(one.release);
      await tester.pump(const Duration(seconds: 5));

      // And it moves with the cache, which is the whole point: the figure
      // is read at the moment the line is written, not at start-up.
      expect(lines, hasLength(2));
      expect(
        lines.last,
        'info images image cache: 40.0 kB of '
        '${DownloadView.humanSize(imageCache.maximumSizeBytes)} ceiling '
        '· 1 images, 40.0 kB each on average '
        '· 1 held live by a widget, which no eviction frees '
        '· 0 decoding',
      );
      expect(one.bytes, 40000);
      // Inside the body, not in a tear-down: a timer still ticking when a
      // test body ends is a test failure, which is the framework holding
      // the app to the same rule -- `XtremioApp` stops this one in
      // `dispose`.
      log.dispose();
    });

    testWidgets('carries the average, which is the figure the question was '
        'about', (tester) async {
      final lines = captureDiagnostics();
      final log = ImageCacheLog(period: const Duration(seconds: 5));
      addTearDown(log.dispose);

      // Two pictures of different sizes: a reading of "33 MB over 80
      // images" only says 410 kB each once somebody divides, and a person
      // reading a log at three in the morning is not that somebody.
      final big = await shown(tester, 'backdrop', width: 200, height: 200);
      addTearDown(big.release);
      final small = await shown(tester, 'thumb', width: 100, height: 100);
      addTearDown(small.release);
      log.start();

      expect((big.bytes + small.bytes) ~/ 2, 100000);
      expect(lines.single, contains('· 2 images, 100 kB each on average'));
      log.dispose();
    });

    testWidgets('stops when the app does', (tester) async {
      final lines = captureDiagnostics();
      final log = ImageCacheLog(period: const Duration(seconds: 5));
      log.start();
      expect(lines, hasLength(1));

      log.dispose();
      await tester.pump(const Duration(seconds: 30));

      expect(lines, hasLength(1), reason: 'a disposed log writes nothing');
    });

    testWidgets('leaves the cache exactly as it found it', (tester) async {
      captureDiagnostics();
      final one = await shown(tester, 'poster');
      addTearDown(one.release);
      final before = ImageCacheUsage.read();
      final log = ImageCacheLog(period: const Duration(seconds: 1));
      addTearDown(log.dispose);

      // Ten readings, which is five minutes of the real period. A log that
      // evicted, decoded or resized anything would be a memory bug in the
      // thing that exists to find memory bugs.
      log.start();
      await tester.pump(const Duration(seconds: 10));

      final after = ImageCacheUsage.read();
      expect(after.cachedBytes, before.cachedBytes);
      expect(after.cachedBytes, one.bytes);
      expect(after.cachedImages, before.cachedImages);
      expect(after.liveImages, before.liveImages);
      expect(after.ceilingBytes, before.ceilingBytes);
      expect(after.decodingImages, before.decodingImages);
      expect(imageCache.containsKey('poster'), isTrue);
      log.dispose();
    });
  });

  group('the line per image', () {
    testWidgets('is not written while verbose logging is off', (tester) async {
      final lines = captureDiagnostics();
      final cache = ObservingImageCache();
      final completer = await decoded(tester, label: 'https://addon/p.jpg');

      cache.putIfAbsent('poster', () => completer);
      await tester.pump();

      expect(
        lines,
        isEmpty,
        reason:
            'a line per picture is not for a '
            'shipping build',
      );
      expect(cache.currentSize, 1);
    });

    testWidgets('is refused by the writer itself while it is off', (
      tester,
    ) async {
      // The gate is on the cache *and* here. The cache's is what makes it
      // cost nothing -- with it off no listener is ever attached -- and
      // this one is what makes the rule true of the call rather than of
      // one caller, which is what a public static has to be.
      final lines = captureDiagnostics();
      final image = (await tester.runAsync(
        () => createTestImage(width: 10, height: 10),
      ))!;
      final info = ImageInfo(image: image, debugLabel: 'https://addon/p.jpg');
      addTearDown(info.dispose);

      ImageCacheLog.noteDecoded(info);
      expect(lines, isEmpty);

      verboseLogging();
      ImageCacheLog.noteDecoded(info);
      expect(lines, hasLength(1));
      expect(lines.single, contains('image decoded: 10×10 px'));
    });

    testWidgets('carries what it decoded to, what that costs and where it '
        'came from', (tester) async {
      final lines = captureDiagnostics();
      verboseLogging();
      final cache = ObservingImageCache();
      // What `Image.network` with a `cacheWidth` produces: the URL, and
      // the bound that was asked for appended by `ResizeImage`.
      final completer = await decoded(
        tester,
        width: 312,
        height: 468,
        label:
            'https://images.metahub.space/poster/medium/tt0063350/img'
            ' - Resized(312×null)',
      );

      cache.putIfAbsent('poster', () => completer);
      await tester.pump();

      expect(lines, hasLength(1));
      expect(
        lines.single,
        'info images image decoded: 312×468 px, 584 kB resident · '
        'https://images.metahub.space/poster/medium/tt0063350/img'
        ' - Resized(312×null)',
      );
      // Which is the arithmetic the answer turns on: a decoded picture is
      // width x height x 4 bytes resident whatever box it is drawn in.
      expect(312 * 468 * 4, 584064);
    });

    testWidgets('says so when there is no source to name', (tester) async {
      final lines = captureDiagnostics();
      verboseLogging();
      final cache = ObservingImageCache();
      final completer = await decoded(tester);

      cache.putIfAbsent('poster', () => completer);
      await tester.pump();

      expect(
        lines.single,
        contains(
          'image decoded: 100×100 px, 40.0 kB resident · from an '
          'image that names no source',
        ),
      );
    });

    testWidgets('is written once per decode, not once per resolve', (
      tester,
    ) async {
      final lines = captureDiagnostics();
      verboseLogging();
      final cache = ObservingImageCache();
      final completer = await decoded(tester);

      cache.putIfAbsent('poster', () => completer);
      // Every later resolve of the same picture is a cache hit: the loader
      // is never called, so there is nothing to observe and nothing new to
      // say. A board scrolled back and forth would otherwise write a line
      // per tile per pass.
      cache.putIfAbsent('poster', () => completer);
      cache.putIfAbsent('poster', () => completer);
      await tester.pump();

      expect(lines, hasLength(1));
    });

    testWidgets('and an image that fails is still the framework\'s to '
        'report', (tester) async {
      captureDiagnostics();
      verboseLogging();
      final cache = ObservingImageCache();
      final completer = _FailingCompleter();
      final reported = <Object>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) => reported.add(details.exception);
      addTearDown(() => FlutterError.onError = previous);

      cache.putIfAbsent('poster', () => completer);
      completer.fail('the addon sent a 404');
      await tester.pump();
      // Back before the expectation, which the test framework insists on
      // and which a failure here would otherwise report as its own fault.
      FlutterError.onError = previous;

      // The observer takes an error listener to know when to let go, and
      // an error listener that *answered* would silence the report the
      // framework makes when nothing else is listening.
      expect(reported, ['the addon sent a 404']);
    });
  });

  group('observing the cache', () {
    testWidgets('accounts for an image exactly as a plain cache does', (
      tester,
    ) async {
      captureDiagnostics();
      verboseLogging();
      final plain = ImageCache();
      final observing = ObservingImageCache();
      final onePicture = await decoded(tester);
      final another = await decoded(tester);

      plain.putIfAbsent('plain', () => onePicture);
      observing.putIfAbsent('watched', () => another);
      // A microtask on, which is when the observer lets go.
      await tester.pump();

      expect(observing.currentSize, plain.currentSize);
      expect(observing.currentSizeBytes, plain.currentSizeBytes);
      expect(observing.liveImageCount, plain.liveImageCount);
      expect(observing.pendingImageCount, plain.pendingImageCount);
      expect(observing.containsKey('watched'), plain.containsKey('plain'));
      expect(observing.currentSizeBytes, 40000);
    });

    testWidgets('holds on to none of the picture it looked at', (tester) async {
      captureDiagnostics();
      verboseLogging();
      // Every listener is handed its own handle on the picture and has to
      // dispose of it. One kept open by the thing that exists to *count*
      // the memory would be a leak in the measuring tool, so the handles
      // open on a watched picture are counted against the handles open on
      // one a plain cache took: the same, or the observer is holding a
      // picture.
      final watched = await withOpenHandles(
        tester,
        ObservingImageCache(),
        size: 10,
      );
      final plain = await withOpenHandles(tester, ImageCache(), size: 11);

      expect(watched.handles, plain.handles);
      expect(watched.handles, 2, reason: 'the picture and the test\'s own');
      expect(watched.bytes, 10 * 10 * 4);
      expect(plain.bytes, 11 * 11 * 4);
    });

    testWidgets('leaves the picture usable after it has watched it', (
      tester,
    ) async {
      captureDiagnostics();
      verboseLogging();
      final cache = ObservingImageCache();
      final completer = await decoded(tester);

      // The observer is a listener, and a completer whose last listener
      // leaves with no keep-alive handle on it disposes itself -- taking
      // the picture with it. This is why it lets go a microtask later,
      // once the cache is holding it.
      cache.putIfAbsent('poster', () => completer);
      await tester.pump();

      final seen = <ImageInfo>[];
      final listener = ImageStreamListener((info, _) => seen.add(info));
      completer.addListener(listener);
      addTearDown(() => completer.removeListener(listener));
      expect(seen, hasLength(1), reason: 'the picture is still there');
      expect(seen.single.image.width, 100);
      for (final info in seen) {
        info.dispose();
      }
    });
  });

  test('the app boots its own binding, which is what installs that cache', () {
    // The wiring, read as text: `createImageCache` is the only place the
    // framework lets an image cache be replaced, a binding is the only
    // thing that has one, and a test process is already running a binding
    // of its own before any of this could be exercised. So what is checked
    // here is that `main` still brings ours up, and first.
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('XtremioBinding.ensureInitialized();'));
    expect(
      main,
      isNot(contains('WidgetsFlutterBinding.ensureInitialized();')),
      reason: 'whichever binding comes up first is the process\'s',
    );
  });
}

/// A completer that never gets a picture, so the failure path can be run.
class _FailingCompleter extends ImageStreamCompleter {
  void fail(Object exception) => reportError(exception: exception);
}
