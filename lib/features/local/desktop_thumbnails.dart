import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

/// Takes one frame of the video file at [path], at most [size] pixels wide,
/// encoded as JPEG; null when there is none to take.
typedef FrameGrabber = Future<Uint8List?> Function(String path, int size);

/// A desktop's video thumbnails: a frame taken with libmpv and kept on
/// disk, since a desktop has no system thumbnailer the app can ask the way
/// Android's media index is asked.
///
/// **One at a time.** A frame costs a file opened and a frame decoded -- a
/// second or so for a large film -- so a grid of cards asks in turn, and a
/// card scrolled past has usually been answered by the time it comes back.
///
/// **Kept by what the file is.** The cache name is the path, the file's
/// modification time and its length, hashed: a file replaced under the same
/// name is a new frame, and nothing needs clearing when one is deleted
/// beyond what the cache directory's owner clears.
class DesktopThumbnails {
  DesktopThumbnails({
    FrameGrabber? grab,
    Future<Directory> Function()? cacheDir,
  }) : _grab = grab ?? MpvFrameGrabber().grab,
       _cacheDir = cacheDir ?? _defaultCacheDir;

  final FrameGrabber _grab;
  final Future<Directory> Function() _cacheDir;
  Future<void> _queue = Future.value();

  static Future<Directory> _defaultCacheDir() async => Directory(
    '${(await getApplicationCacheDirectory()).path}'
    '${Platform.pathSeparator}local-thumbnails',
  );

  /// The frame of the `file://` video [uri], from the cache or taken now.
  Future<Uint8List?> thumbnail(String uri, {required int size}) async {
    final File file;
    try {
      file = File.fromUri(Uri.parse(uri));
    } on Object {
      return null;
    }
    final FileStat stat;
    try {
      stat = await file.stat();
    } on FileSystemException {
      return null;
    }
    if (stat.type != FileSystemEntityType.file) return null;
    final key = sha1
        .convert(
          utf8.encode(
            '${file.path}|${stat.modified.microsecondsSinceEpoch}|'
            '${stat.size}|$size',
          ),
        )
        .toString();
    final dir = await _cacheDir();
    final cached = File('${dir.path}${Platform.pathSeparator}$key.jpg');
    try {
      if (await cached.exists()) return await cached.readAsBytes();
    } on FileSystemException {
      // Unreadable cache: take the frame again below.
    }
    final taken = Completer<Uint8List?>();
    _queue = _queue.then((_) async {
      try {
        taken.complete(await _grab(file.path, size));
      } on Object {
        taken.complete(null);
      }
    });
    final bytes = await taken.future;
    if (bytes == null || bytes.isEmpty) return null;
    try {
      await dir.create(recursive: true);
      await cached.writeAsBytes(bytes, flush: true);
    } on FileSystemException {
      // Not kept: the next card that asks takes it again.
    }
    return bytes;
  }
}

/// [FrameGrabber] over a hidden, muted libmpv player, made on first use and
/// let go after [idle] with nothing asked.
///
/// A player with no video view has video decoding off (media_kit's
/// `vid=no`), which is why it is turned on here; the frame is scaled inside
/// mpv, so what comes back is already card-sized. The start is a tenth of
/// the way in: past the logos and the black of a film's opening.
class MpvFrameGrabber {
  MpvFrameGrabber({this.idle = const Duration(seconds: 20)});

  final Duration idle;
  Player? _player;
  Timer? _idleTimer;

  /// How long one frame is waited for before the file is given up on.
  static const Duration patience = Duration(seconds: 8);

  /// How long a file may go without showing any video at all.
  static const Duration noVideoAfter = Duration(seconds: 3);

  Future<Uint8List?> grab(String path, int size) async {
    _idleTimer?.cancel();
    try {
      final player = await _playerNow();
      final native = player.platform! as NativePlayer;
      await native.setProperty('vf', 'scale=$size:-2');
      // Reset by media_kit after every file, so set before every file.
      await native.setProperty('start', '10%');
      await player.open(Media(Uri.file(path).toString()), play: false);
      final started = DateTime.now();
      final deadline = started.add(patience);
      while (DateTime.now().isBefore(deadline)) {
        // No picture at all by now: not a video mpv can read, and the
        // cards queued behind it should not wait out the rest.
        if (player.state.width == null &&
            DateTime.now().difference(started) > noVideoAfter) {
          return null;
        }
        final shot = await player.screenshot(format: 'image/jpeg');
        if (shot != null && shot.isNotEmpty) return shot;
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      return null;
    } finally {
      await _player?.stop();
      _idleTimer = Timer(idle, _release);
    }
  }

  Future<Player> _playerNow() async {
    final existing = _player;
    if (existing != null) return existing;
    final player = Player(
      configuration: const PlayerConfiguration(
        title: 'thumbnails',
        muted: true,
        bufferSize: 4 * 1024 * 1024,
      ),
    );
    final native = player.platform! as NativePlayer;
    await native.setProperty('vid', 'auto');
    await native.setProperty('ao', 'null');
    await native.setProperty('hwdec', 'no');
    await native.setProperty('sub', 'no');
    await native.setProperty('screenshot-jpeg-quality', '80');
    return _player = player;
  }

  void _release() {
    final player = _player;
    _player = null;
    unawaited(player?.dispose());
  }
}
