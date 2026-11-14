import 'package:flutter/foundation.dart';

import '../../shell/video_decoders.dart';

/// Where a film's picture goes.
///
/// **[texture]** is media_kit's way: mpv draws each frame with OpenGL into a
/// texture, and Flutter draws that texture into the app's own picture. It
/// works for every codec and every platform, and costs two passes over every
/// pixel of every frame on the GPU. On Android it also means HDR is converted
/// to SDR, since Flutter's picture is SDR.
///
/// **[surface]** is Android only, and what VLC and Kodi do: MediaCodec decodes
/// straight into a `SurfaceView` of its own (`VideoSurface.kt`, mpv's
/// `vo=mediacodec_embed`), and the display hardware shows it. The GPU does no
/// work per frame, the film is shown at the panel's own resolution, and an
/// HDR10 or HLG film reaches the display as HDR. Measured on a Galaxy Tab S9
/// FE with a 4K HDR10 film: GPU 59-62% busy on [texture], 0% on [surface],
/// with the layer tagged `BT2020_ITU_PQ`. Flutter's controls and subtitles are
/// drawn over it as before.
///
/// The surface shows only what MediaCodec decodes. A film mpv decodes in
/// software has no picture there, so it goes to [texture] instead. That is
/// decided before decoding from the codec and the picture's size, against
/// the device's own hardware decoders ([videoOutputForCodec],
/// [HardwareDecoders]). It is corrected after it if the decoder still fell
/// back to software ([surfaceDecodingFellBack]), or if mpv gave up on the
/// picture ([surfaceLostPicture]).
enum VideoOutput { texture, surface }

/// The codecs mpv may send to Android's MediaCodec when the device could not
/// be asked which it decodes in hardware ([HardwareDecoders.assumed]).
/// Everything else is decoded in software, which the surface cannot show.
const Set<String> surfaceCodecs = {'h264', 'hevc', 'vp8', 'vp9', 'av1'};

/// Whether a player may use [VideoOutput.surface] at all: on Android, with
/// hardware decoding on. Anything else is [VideoOutput.texture] for the
/// player's whole life.
bool surfaceAllowed({
  required bool hardwareDecoding,
  TargetPlatform? platform,
}) =>
    (platform ?? defaultTargetPlatform) == TargetPlatform.android &&
    hardwareDecoding;

/// The output for a film whose video codec mpv names [codec] (its
/// `current-tracks/video/codec`), in a player where the surface is
/// [allowed]. Null while mpv has not said: nothing is decided, and nothing
/// is drawn, until it has.
///
/// The surface takes the film only when one of [decoders] takes the codec
/// at the track's [width] by [height] (mpv's `demux-w`/`demux-h`). An
/// unknown size is decided by the codec alone.
VideoOutput? videoOutputForCodec({
  required bool allowed,
  required String? codec,
  required HardwareDecoders decoders,
  int? width,
  int? height,
}) {
  if (!allowed) return VideoOutput.texture;
  final name = codec?.trim().toLowerCase();
  if (name == null || name.isEmpty) return null;
  return decoders.decodes(name, width: width, height: height)
      ? VideoOutput.surface
      : VideoOutput.texture;
}

/// Whether a film on the surface ended up decoded in software after all, from
/// mpv's `hwdec-current` once the decoder is open. MediaCodec can refuse a
/// stream whose codec it claims (10-bit H.264, say), and mpv then decodes in
/// software, which the surface cannot show. An empty answer is "not decided
/// yet", not a fall-back.
bool surfaceDecodingFellBack(String? hwdecCurrent) {
  final value = hwdecCurrent?.trim();
  if (value == null || value.isEmpty) return false;
  return value == 'no';
}

/// Whether an mpv log line says the film on the surface has no picture.
///
/// On the surface every decoder but MediaCodec is no picture at all. When
/// MediaCodec will not open, mpv logs `vd: Could not open codec.` and falls
/// back to a software decoder. Its first frame cannot be handed to the
/// surface, so mpv gives up on the picture with two fatal lines and plays
/// the sound on. By then `hwdec-current` has no value, so
/// [surfaceDecodingFellBack] never hears of it.
bool surfaceLostPicture({
  required String prefix,
  required String level,
  required String text,
}) {
  final line = text.trim();
  if (prefix == 'vd' && line == 'Could not open codec.') return true;
  if (level != 'fatal') return false;
  return line.startsWith('Cannot convert decoder/filter output') ||
      line == 'Could not initialize video chain.';
}

/// The most pixels a picture decoded in software may have on a device with
/// less than [softwareDecodeMemoryFloor] of memory: 1080p.
const int softwareDecodePixelCeiling = 1920 * 1088;

/// Below this much memory, a picture larger than 1080p is not decoded in
/// software at all.
const int softwareDecodeMemoryFloor = 3 * 1024 * 1024 * 1024;

/// Whether a [width] by [height] picture is too large to decode in software
/// on a device with [memoryBytes] of memory.
///
/// Measured on a Chromecast with Google TV (2 GB): a 2160p 10-bit AV1 film
/// decoded in software took the app to 855 MB, and Android killed it while
/// it was on screen. The decoder holds several 4K frames of about 25 MB
/// each, and the texture holds its own copies. An unknown size or memory
/// decides nothing.
bool softwareDecodeTooLarge({
  required int? width,
  required int? height,
  required int? memoryBytes,
}) {
  if (width == null || height == null || memoryBytes == null) return false;
  if (width <= 0 || height <= 0 || memoryBytes <= 0) return false;
  return memoryBytes < softwareDecodeMemoryFloor &&
      width * height > softwareDecodePixelCeiling;
}

/// The name a viewer knows mpv's [codec] by, as the stream list shows it,
/// or null for one without a familiar name.
String? codecLabel(String? codec) => switch (codec?.trim().toLowerCase()) {
  'av1' => 'AV1',
  'hevc' => 'HEVC',
  'h264' => 'H.264',
  'vp9' => 'VP9',
  'vp8' => 'VP8',
  'mpeg4' => 'MPEG-4',
  'mpeg2video' => 'MPEG-2',
  'vc1' => 'VC-1',
  _ => null,
};
