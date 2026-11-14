import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../features/player/video_output.dart' show surfaceCodecs;
import 'device_profile.dart';

/// The largest picture a hardware decoder takes.
@immutable
class DecoderSize {
  const DecoderSize(this.width, this.height);

  final int width;
  final int height;

  /// Whether a [w] by [h] picture fits, either way round. A decoder that
  /// takes 4096x2304 also takes a portrait 2160x3840.
  bool fits(int w, int h) =>
      (w <= width && h <= height) || (h <= width && w <= height);

  @override
  bool operator ==(Object other) =>
      other is DecoderSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

/// The video codecs this device decodes in hardware, by mpv's names, with
/// the largest picture each takes.
///
/// The player's surface shows only what a hardware decoder draws, and mpv
/// sends to the hardware only the codecs in `hwdec-codecs`. Both come from
/// this one set ([codecs], [hwdecCodecs]). On Android it is Android's own
/// answer ([probe]). Everywhere else, and when Android could not be asked,
/// it is [assumed].
@immutable
class HardwareDecoders {
  const HardwareDecoders(this.sizes);

  /// mpv's codec name to the largest picture its decoder takes, or null
  /// where only the codec is known.
  final Map<String, DecoderSize?> sizes;

  /// What the player assumes with nobody to ask: [surfaceCodecs], at any
  /// size.
  static final HardwareDecoders assumed = HardwareDecoders({
    for (final codec in surfaceCodecs) codec: null,
  });

  /// mpv's codec names for the Android types the channel answers with, in
  /// the order `hwdec-codecs` lists them.
  ///
  /// **MPEG-4 Part 2 and MPEG-2 are deliberately not here.** media_kit's
  /// Android controller sets
  /// `hwdec-codecs=h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1`
  /// (`android_video_controller/real.dart`), and with the direct
  /// `mediacodec` hwdec (`MediaKitEngine.configurationFor`) an MPEG-4 file
  /// fails at decoder init:
  ///
  ///     mpeg4_mediacodec: Both surface and native_window are NULL
  ///     mpeg4_mediacodec: MediaCodec 0x0 failed to start
  ///     vd: Could not open codec.
  ///
  /// It then plays, after about three seconds of stalling with an error on
  /// screen. Software decodes those old formats comfortably on the weakest
  /// device this runs on, and the codecs the hardware is needed for are all
  /// still here.
  static const Map<String, String> mimeOf = {
    'h264': 'video/avc',
    'hevc': 'video/hevc',
    'vp8': 'video/x-vnd.on2.vp8',
    'vp9': 'video/x-vnd.on2.vp9',
    'av1': 'video/av01',
  };

  /// The codecs a hardware decoder takes.
  Set<String> get codecs => sizes.keys.toSet();

  /// mpv's `hwdec-codecs` for this set. Empty when no codec has a hardware
  /// decoder, which mpv reads as "none".
  String get hwdecCodecs => [
    ...mimeOf.keys.where(sizes.containsKey),
    ...sizes.keys.where((codec) => !mimeOf.containsKey(codec)),
  ].join(',');

  /// Whether a hardware decoder takes [codec] (mpv's name) at a [width] by
  /// [height] picture. An unknown size is decided by the codec alone.
  bool decodes(String codec, {int? width, int? height}) {
    final name = codec.trim().toLowerCase();
    if (!sizes.containsKey(name)) return false;
    final size = sizes[name];
    if (size == null || width == null || height == null) return true;
    if (width <= 0 || height <= 0) return true;
    return size.fits(width, height);
  }

  /// [reply] from the `hwVideoDecoders` call: Android type to
  /// `{maxWidth, maxHeight}`. A type the player does not know is ignored,
  /// and a size that is missing or not positive is unknown.
  static HardwareDecoders fromReply(Map<Object?, Object?> reply) {
    final sizes = <String, DecoderSize?>{};
    for (final MapEntry(key: codec, value: mime) in mimeOf.entries) {
      if (!reply.containsKey(mime)) continue;
      final limits = reply[mime];
      final w = limits is Map ? limits['maxWidth'] : null;
      final h = limits is Map ? limits['maxHeight'] : null;
      sizes[codec] = w is int && h is int && w > 0 && h > 0
          ? DecoderSize(w, h)
          : null;
    }
    return HardwareDecoders(sizes);
  }

  /// Asks Android which video codecs it decodes in hardware
  /// (`MainActivity`'s `hwVideoDecoders`, `HwVideoDecoders.kt`). Every other
  /// platform, and a channel that is missing or throws, yields [assumed].
  static Future<HardwareDecoders> probe({
    MethodChannel channel = DeviceProfile.channel,
    TargetPlatform? platform,
  }) async {
    if ((platform ?? defaultTargetPlatform) != TargetPlatform.android) {
      return assumed;
    }
    try {
      final reply = await channel.invokeMapMethod<Object?, Object?>(
        'hwVideoDecoders',
      );
      if (reply == null) return assumed;
      return fromReply(reply);
    } on PlatformException catch (error) {
      if (kDebugMode) debugPrint('hardware decoders unavailable: $error');
      return assumed;
    } on MissingPluginException catch (error) {
      if (kDebugMode) debugPrint('hardware decoders unavailable: $error');
      return assumed;
    }
  }

  static Future<HardwareDecoders>? _onThisDevice;

  /// [probe], asked once per process. The decoders do not change while the
  /// app runs.
  static Future<HardwareDecoders> onThisDevice() => _onThisDevice ??= probe();

  @override
  String toString() => 'HardwareDecoders($sizes)';
}
