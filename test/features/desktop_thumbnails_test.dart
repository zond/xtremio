import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/local/desktop_thumbnails.dart';

/// A desktop's video frames: taken once per file as it is, kept on disk,
/// one at a time. The taking itself (libmpv) is checked by hand; CI has no
/// libmpv to take a frame with.
void main() {
  late Directory root;
  late Directory cache;
  setUp(() {
    root = Directory.systemTemp.createTempSync('thumbs');
    cache = Directory('${root.path}/cache');
  });
  tearDown(() => root.deleteSync(recursive: true));

  File video(String name, [String content = 'x']) =>
      File('${root.path}/$name')..writeAsStringSync(content);

  test('a frame is taken once and read from disk after, even by a new '
      'instance', () async {
    final asked = <String>[];
    Future<Uint8List?> grab(String path, int size) async {
      asked.add('$path@$size');
      return Uint8List.fromList([1, 2, 3]);
    }

    final film = video('film.mkv');
    final first = DesktopThumbnails(grab: grab, cacheDir: () async => cache);
    expect(await first.thumbnail(film.uri.toString(), size: 480), [1, 2, 3]);
    expect(await first.thumbnail(film.uri.toString(), size: 480), [1, 2, 3]);
    final again = DesktopThumbnails(grab: grab, cacheDir: () async => cache);
    expect(await again.thumbnail(film.uri.toString(), size: 480), [1, 2, 3]);
    expect(asked, ['${film.path}@480']);
  });

  test('a file changed under the same name is a new frame', () async {
    var taken = 0;
    final thumbs = DesktopThumbnails(
      grab: (path, size) async => Uint8List.fromList([++taken]),
      cacheDir: () async => cache,
    );
    final film = video('film.mkv');
    expect(await thumbs.thumbnail(film.uri.toString(), size: 480), [1]);
    film.writeAsStringSync('a longer file now');
    expect(await thumbs.thumbnail(film.uri.toString(), size: 480), [2]);
  });

  test('frames are taken one at a time', () async {
    var running = 0;
    var most = 0;
    final thumbs = DesktopThumbnails(
      grab: (path, size) async {
        most = ++running > most ? running : most;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        running--;
        return Uint8List.fromList([1]);
      },
      cacheDir: () async => cache,
    );
    await Future.wait([
      for (var i = 0; i < 4; i++)
        thumbs.thumbnail(video('e$i.mkv').uri.toString(), size: 480),
    ]);
    expect(most, 1);
  });

  test('none for a file that is gone, a frame that failed, or a grab that '
      'threw -- and a failure is asked again next time', () async {
    var fail = true;
    final thumbs = DesktopThumbnails(
      grab: (path, size) async {
        if (path.endsWith('throws.mkv')) throw StateError('mpv');
        return fail ? null : Uint8List.fromList([7]);
      },
      cacheDir: () async => cache,
    );
    expect(
      await thumbs.thumbnail(
        Uri.file('${root.path}/gone.mkv').toString(),
        size: 480,
      ),
      isNull,
    );
    final film = video('film.mkv');
    expect(await thumbs.thumbnail(film.uri.toString(), size: 480), isNull);
    expect(
      await thumbs.thumbnail(video('throws.mkv').uri.toString(), size: 480),
      isNull,
    );
    fail = false;
    expect(await thumbs.thumbnail(film.uri.toString(), size: 480), [7]);
  });
}
