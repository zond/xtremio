/// The disk cache under the network images, and the provider over it.
///
/// What is being tested is a claim about cost, not about pixels: a picture
/// the app has drawn once is drawn again without a round trip, and the
/// bytes that make that true are bounded and expire. The pixels are
/// `test/features/image_decode_test.dart`'s and the screens' own tests --
/// nothing here should be able to change what is drawn, and the provider
/// tests say why.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

/// A real 1x1 PNG, so that the decode on the far side of the cache is the
/// engine's own and not a stub: bytes that come back off the disk have to
/// decode exactly as the ones that came off the wire did.
final Uint8List onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQ'
  'DJ/pLvAAAAAElFTkSuQmCC',
);

void main() {
  late Directory dir;

  /// The store's clock, so an age is a line in a test rather than a wait.
  late DateTime clock;

  Future<ImageDiskCache> open({
    int ceilingBytes = 4000,
    Duration maxAge = const Duration(days: 30),
  }) async => (await ImageDiskCache.openIn(
    dir,
    ceilingBytes: ceilingBytes,
    maxAge: maxAge,
    now: () => clock,
  ))!;

  Uint8List filling(int bytes) => Uint8List(bytes)..fillRange(0, bytes, 7);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xtremio-images');
    clock = DateTime.utc(2026, 9, 24, 12);
  });

  tearDown(() {
    DiskCachedImage.debugFetch = null;
    ImageDiskCache.install(null);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('the store', () {
    test('keeps what it was given and reads it back', () async {
      final store = await open();
      const url = 'https://images.metahub.space/poster/medium/tt0063350/img';
      expect(store.has(url), isFalse);
      expect(await store.read(url), isNull);

      await store.write(url, filling(300));

      expect(store.has(url), isTrue);
      expect(await store.read(url), filling(300));
      expect(store.bytes, 300);
      expect(store.files, 1);
      expect(dir.listSync().whereType<File>().length, 1);
    });

    test('answers a miss from its index, without asking the filesystem '
        'anything', () async {
      final store = await open();
      const kept = 'https://addon.example/logo.png';
      await store.write(kept, filling(200));

      // The directory goes out from under the running store, which is what
      // Android reclaiming `getCacheDir()` looks like. [has] still answers
      // from the index -- that is the proof it is a map lookup and not a
      // `stat`, and it is the reason a cold board costs no syscall per
      // poster on the way to the network.
      dir.deleteSync(recursive: true);
      expect(store.has(kept), isTrue);
      expect(store.has('https://addon.example/other.png'), isFalse);

      // And the read is where the truth comes out: a file the index
      // promised and the disk has not is forgotten, not retried.
      expect(await store.read(kept), isNull);
      expect(store.has(kept), isFalse);
      expect(store.bytes, 0);
    });

    test(
      'is bounded: more goes in than fits, and the oldest goes out',
      () async {
        final store = await open(ceilingBytes: 3000);
        for (final name in ['a', 'b', 'c']) {
          await store.write('https://posters.example/$name.jpg', filling(1000));
          clock = clock.add(const Duration(minutes: 1));
        }
        expect(store.bytes, 3000, reason: 'exactly full is not over');
        expect(store.files, 3);

        await store.write('https://posters.example/d.jpg', filling(1000));

        expect(store.bytes, lessThanOrEqualTo(3000));
        expect(store.files, 3);
        expect(dir.listSync().whereType<File>().length, 3);
        expect(store.has('https://posters.example/a.jpg'), isFalse);
        expect(store.has('https://posters.example/d.jpg'), isTrue);
        expect(
          await store.read('https://posters.example/d.jpg'),
          filling(1000),
        );
      },
    );

    test('will not keep a picture bigger than the whole store', () async {
      final store = await open(ceilingBytes: 3000);
      await store.write('https://posters.example/small.jpg', filling(1000));

      await store.write('https://posters.example/huge.jpg', filling(4000));

      // Refused rather than admitted and then swept: a store one answer
      // can empty is not a cache.
      expect(store.has('https://posters.example/huge.jpg'), isFalse);
      expect(store.has('https://posters.example/small.jpg'), isTrue);
      expect(store.bytes, 1000);
    });

    test('a second open finds what the first wrote', () async {
      final first = await open();
      await first.write('https://posters.example/one.jpg', filling(500));
      await first.write('https://posters.example/two.jpg', filling(700));

      // The restart. Nothing is handed over in memory: the index is what
      // the directory says, which is the whole claim about surviving a
      // kill by the low-memory killer.
      clock = clock.add(const Duration(days: 2));
      final second = await open();

      expect(second.bytes, 1200);
      expect(second.files, 2);
      expect(
        await second.read('https://posters.example/one.jpg'),
        filling(500),
      );
      expect(
        await second.read('https://posters.example/two.jpg'),
        filling(700),
      );
    });

    test('and comes up under a ceiling a new build lowered', () async {
      final first = await open(ceilingBytes: 100000);
      for (final name in ['a', 'b', 'c', 'd']) {
        await first.write('https://posters.example/$name.jpg', filling(1000));
        clock = clock.add(const Duration(minutes: 1));
      }
      expect(first.bytes, 4000);

      final second = await open(ceilingBytes: 2500);

      expect(second.bytes, lessThanOrEqualTo(2500));
      expect(dir.listSync().whereType<File>().length, 2);
      expect(second.has('https://posters.example/a.jpg'), isFalse);
      expect(second.has('https://posters.example/d.jpg'), isTrue);
    });

    test('a picture past its age is not answered with, and is gone at the '
        'next open', () async {
      final store = await open(maxAge: const Duration(days: 30));
      const logo = 'https://addon.example/logo.png';
      await store.write(logo, filling(400));

      // An addon updated its logo a month later. The URL has not changed --
      // nothing about it could tell the app -- so the clock is what does.
      clock = clock.add(const Duration(days: 31));
      expect(await store.read(logo), isNull);
      expect(store.has(logo), isFalse, reason: 'and it is dropped, not kept');
      expect(store.bytes, 0);

      // Within the window it is still believed, which is the other half:
      // thirty days of posters that never change cost nothing.
      final fresh = await open(maxAge: const Duration(days: 30));
      await fresh.write(logo, filling(400));
      clock = clock.add(const Duration(days: 29));
      final next = await open(maxAge: const Duration(days: 30));
      expect(next.files, 1);
      expect(await next.read(logo), filling(400));

      clock = clock.add(const Duration(days: 2));
      final later = await open(maxAge: const Duration(days: 30));
      expect(later.files, 0, reason: 'the open sweeps what has aged out');
      expect(dir.listSync().whereType<File>(), isEmpty);
    });

    test('a directory it cannot have is no store, not a crash', () async {
      final file = File('${dir.path}${Platform.pathSeparator}in-the-way')
        ..writeAsStringSync('not a directory');

      expect(await ImageDiskCache.openIn(Directory(file.path)), isNull);
    });
  });

  group('the provider', () {
    /// Resolves [provider] the way an `Image` does, and answers when the
    /// picture is decoded.
    Future<ImageInfo> draw(ImageProvider<Object> provider) {
      final done = Completer<ImageInfo>();
      final stream = provider.resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener(
        (info, _) {
          if (!done.isCompleted) done.complete(info);
        },
        onError: (error, stack) {
          if (!done.isCompleted) done.completeError(error, stack);
        },
      );
      stream.addListener(listener);
      return done.future.whenComplete(() => stream.removeListener(listener));
    }

    /// Waits for the write that happens *after* the decode -- see
    /// [ImageDiskCache.write]; nothing a viewer waits for waits for it, so
    /// a test has to.
    Future<void> stored(ImageDiskCache store, int files) async {
      for (var i = 0; i < 500 && store.files < files; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(store.files, files);
    }

    /// What the ceiling does when it is crossed and what `XtremioApp` does
    /// when the app is backgrounded: everything decoded goes.
    void dropEveryDecodedImage() {
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    }

    testWidgets('fetches once, and draws the second time off the disk', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final store = await open(ceilingBytes: 1 << 20);
        ImageDiskCache.install(store);
        var fetches = 0;
        DiskCachedImage.debugFetch = (url) async {
          fetches++;
          return onePixelPng;
        };
        const provider = DiskCachedImage('https://posters.example/one.jpg');

        final first = await draw(provider);
        expect(fetches, 1);
        expect(first.image.width, 1);
        await stored(store, 1);

        dropEveryDecodedImage();
        final second = await draw(provider);

        expect(
          fetches,
          1,
          reason: 'the second draw cost a local read, not a round trip',
        );
        expect(second.image.width, 1, reason: 'and decoded the same picture');
      });
    });

    testWidgets('and goes out again every time when there is no store', (
      tester,
    ) async {
      await tester.runAsync(() async {
        // The build before this one, and every test that never boots the
        // app: the provider still draws, and every eviction is a fetch.
        ImageDiskCache.install(null);
        var fetches = 0;
        DiskCachedImage.debugFetch = (url) async {
          fetches++;
          return onePixelPng;
        };
        const provider = DiskCachedImage('https://posters.example/two.jpg');

        await draw(provider);
        dropEveryDecodedImage();
        await draw(provider);

        expect(fetches, 2);
      });
    });

    testWidgets('a picture that will not load is not stored', (tester) async {
      await tester.runAsync(() async {
        final store = await open();
        ImageDiskCache.install(store);
        DiskCachedImage.debugFetch = (url) async =>
            throw const SocketException('no route to host');

        await expectLater(
          draw(const DiskCachedImage('https://posters.example/gone.jpg')),
          throwsA(isA<SocketException>()),
        );

        expect(store.files, 0);
        expect(dir.listSync().whereType<File>(), isEmpty);
      });
    });

    test('bounded() is the wrapper `Image.network` used to build', () {
      const url = 'https://images.metahub.space/logo/medium/tt0063350/img';

      expect(
        DiskCachedImage.bounded(url, cacheWidth: 120),
        isA<ResizeImage>()
            .having((image) => image.width, 'width', 120)
            .having((image) => image.height, 'height', isNull)
            .having(
              (image) => (image.imageProvider as DiskCachedImage).url,
              'url',
              url,
            ),
      );
      expect(
        DiskCachedImage.bounded(url, cacheHeight: 60),
        isA<ResizeImage>()
            .having((image) => image.width, 'width', isNull)
            .having((image) => image.height, 'height', 60),
      );
      // Unbounded is the bare provider, exactly as `Image.network` with no
      // `cacheWidth` was -- which is what the guard in
      // `test/features/image_decode_test.dart` exists to keep out of `lib/`.
      expect(DiskCachedImage.bounded(url), isA<DiskCachedImage>());
    });

    test('keys on the url, so the framework cache is keyed as it was', () {
      const a = DiskCachedImage('https://posters.example/one.jpg');
      const b = DiskCachedImage('https://posters.example/one.jpg');
      const c = DiskCachedImage('https://posters.example/two.jpg');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a.obtainKey(ImageConfiguration.empty), isA<SynchronousFuture>());
    });
  });
}
