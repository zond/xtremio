import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'local_media.dart';

/// A frame of a video on this device, as its card's picture: what the
/// source's [LocalMediaSource.thumbnail] answers, decoded.
///
/// **Asked for, not stored.** Android keeps a thumbnail of every video it
/// indexes, so a card asks for it each time it is decoded and the image
/// cache holds it while it is on screen; nothing of it is written by this
/// app. A source with no thumbnails (a desktop, today) answers null, and
/// the card falls back to its icon as it would for a missing poster.
@immutable
class LocalThumbnail extends ImageProvider<LocalThumbnail> {
  const LocalThumbnail(this.uri, {required this.source});

  final String uri;

  /// Not part of the key: there is one source in an app, and a key that
  /// held it would miss the cache whenever a screen was handed a new one.
  final LocalMediaSource source;

  /// The longest side asked for, in pixels: a grid card's width on a
  /// phone, with room for the crop a frame wider than a poster takes.
  static const int size = 480;

  @override
  Future<LocalThumbnail> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    LocalThumbnail key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(_load(decode));

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    final bytes = await source.thumbnail(uri, size: size);
    if (bytes == null || bytes.isEmpty) {
      throw StateError('no thumbnail');
    }
    final codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    final frame = await codec.getNextFrame();
    return ImageInfo(image: frame.image);
  }

  @override
  bool operator ==(Object other) => other is LocalThumbnail && other.uri == uri;

  @override
  int get hashCode => uri.hashCode;
}
