import 'package:flutter/foundation.dart';

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
/// software has no picture there, so it goes to [texture] instead: decided
/// before decoding from the codec ([videoOutputForCodec]), and corrected
/// after it if the decoder still fell back to software
/// ([surfaceDecodingFellBack]).
enum VideoOutput { texture, surface }

/// The codecs mpv sends to Android's MediaCodec (`hwdec-codecs`). Everything
/// else is decoded in software, which the surface cannot show.
const Set<String> surfaceCodecs = {'h264', 'hevc', 'vp8', 'vp9', 'av1'};

/// Whether a player may use [VideoOutput.surface] at all: on Android, with
/// hardware decoding on, and with the viewer's "Direct video" on
/// (`AppPrefs.directVideo`). Anything else is [VideoOutput.texture] for the
/// player's whole life.
bool surfaceAllowed({
  required bool hardwareDecoding,
  required bool directVideo,
  TargetPlatform? platform,
}) =>
    (platform ?? defaultTargetPlatform) == TargetPlatform.android &&
    hardwareDecoding &&
    directVideo;

/// The output for a film whose video codec mpv names [codec] (its
/// `current-tracks/video/codec`), in a player where the surface is
/// [allowed]. Null while mpv has not said: nothing is decided, and nothing
/// is drawn, until it has.
VideoOutput? videoOutputForCodec({
  required bool allowed,
  required String? codec,
}) {
  if (!allowed) return VideoOutput.texture;
  final name = codec?.trim().toLowerCase();
  if (name == null || name.isEmpty) return null;
  return surfaceCodecs.contains(name)
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
