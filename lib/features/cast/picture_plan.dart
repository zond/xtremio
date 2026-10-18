import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/core.dart';
import 'receiver_table.dart';

/// **What a film's picture is converted to for a receiver, and at what
/// bitrate** (stream-server `docs/design/renditions.md`, step F4): the
/// choice behind [PicturePlan], made where `CastCompatibility.of` finds a
/// picture the receiver cannot take as it is or as a copy.
///
/// The receiver is judged the way a copy is: by what the best model
/// announcing its name decodes ([ReceiverRow.atBest], else the row itself).
/// A target only that best model decodes is a trial ([PictureChosen.tentative]),
/// and the receiver's own report of its picture decides.
///
/// - **HDR** (mpv's transfer is PQ or HLG) goes only to 10-bit HEVC, which
///   keeps its colours and transfer. That needs a row that decodes HEVC at
///   the film's size and rate, and a phone whose HEVC encoder makes 10-bit
///   pictures ([PictureSupport.tenBit]). Nothing here turns HDR into SDR.
/// - **10-bit ordinary video** goes to 10-bit HEVC on such a phone, and
///   otherwise as 8-bit video does.
/// - **8-bit video** goes to HEVC where the row decodes it at the film's size
///   and the phone encodes it, and to H.264 otherwise.
/// - **A codec the receiver showed no picture for** this session (`noPicture`)
///   is passed over for the next one. When every target that fits is one, the
///   first is chosen anyway: the player refuses it with the sentence that
///   says the receiver showed no picture for it.
/// - **The picture keeps its size.** A film bigger or faster than any target
///   the row decodes is refused ([PictureShortfall.size]).
///
/// Null when conversion is no answer at all: the phone encodes nothing the
/// row decodes, so the refusal a copy would get stands.
PictureChoice? choosePicture({
  required ReceiverRow receiver,
  required PictureSupport support,
  int? width,
  int? height,
  double? fps,
  bool hdr = false,
  int? depth,
  Set<String> noPicture = const {},
}) {
  final row = receiver.atBest ?? receiver;
  bool fits(String codec) =>
      row.fits(codec, width: width, height: height, fps: fps);
  bool makes(String codec) => support.encodes.contains(codec);
  final hevc = makes('HEVC') && fits('HEVC');
  final tenBit = hevc && support.tenBit;
  final targets = <PictureTarget>[
    if (hdr) ...[
      if (tenBit) PictureTarget.hevcMain10,
    ] else ...[
      if (tenBit && depth == 10) PictureTarget.hevcMain10,
      if (hevc) PictureTarget.hevcMain,
      if (makes('H.264') && fits('H.264')) PictureTarget.h264High,
    ],
  ];
  if (targets.isEmpty) {
    if (hdr) {
      if (!row.decodes('HEVC')) {
        return const PictureRefused(PictureShortfall.hdrReceiver);
      }
      if (!fits('HEVC')) {
        return const PictureRefused(PictureShortfall.size, codec: 'HEVC');
      }
      return const PictureRefused(PictureShortfall.hdrPhone);
    }
    // The first codec the phone makes and the row decodes at some size: the
    // one whose limit the size refusal names.
    for (final codec in const ['HEVC', 'H.264']) {
      if (makes(codec) && row.decodes(codec)) {
        return PictureRefused(PictureShortfall.size, codec: codec);
      }
    }
    return null;
  }
  final target = targets.firstWhere(
    (target) => !noPicture.contains(target.codec),
    orElse: () => targets.first,
  );
  return PictureChosen(
    PicturePlan(target, pictureBitrate(target, height: height, fps: fps)),
    tentative: !receiver.fits(
      target.codec,
      width: width,
      height: height,
      fps: fps,
    ),
  );
}

/// What [choosePicture] answered.
sealed class PictureChoice {
  const PictureChoice();
}

/// The picture is converted as [plan]. [tentative] when only the best model
/// announcing the receiver's name decodes it.
@immutable
final class PictureChosen extends PictureChoice {
  const PictureChosen(this.plan, {required this.tentative});

  final PicturePlan plan;
  final bool tentative;
}

/// The picture cannot be converted for this receiver, and why. [codec] is the
/// one whose limit a [PictureShortfall.size] refusal names.
@immutable
final class PictureRefused extends PictureChoice {
  const PictureRefused(this.shortfall, {this.codec});

  final PictureShortfall shortfall;
  final String? codec;
}

/// Why a picture is not converted.
enum PictureShortfall {
  /// HDR, and the receiver decodes no HEVC, the only HDR picture made.
  hdrReceiver,

  /// HDR, and this phone makes no 10-bit HEVC.
  hdrPhone,

  /// Bigger or faster than anything the receiver decodes that the phone
  /// makes. Pictures are never made smaller.
  size,
}

/// **The bitrate a converted picture is made at**, in bits per second, by the
/// film's height (its first row at or above it), from this table:
///
/// | height up to | HEVC Main / Main 10 | H.264 High |
/// |---|---|---|
/// | 576 | 2.5 M | 3.5 M |
/// | 720 | 4 M | 6 M |
/// | 1080 | 8 M | 12 M |
/// | 1440 | 12 M | 18 M |
/// | 2160 | 16 M | 24 M |
///
/// A film faster than 30 frames a second gets 1.4 times as much, never more
/// than [maxPictureBitrate]. A height mpv has not reported is taken as 1080.
const List<({int height, int hevc, int h264})> pictureBitrates = [
  (height: 576, hevc: 2500000, h264: 3500000),
  (height: 720, hevc: 4000000, h264: 6000000),
  (height: 1080, hevc: 8000000, h264: 12000000),
  (height: 1440, hevc: 12000000, h264: 18000000),
  (height: 2160, hevc: 16000000, h264: 24000000),
];

/// The most any converted picture is made at. The server's ring holds about
/// 30 seconds of film at this rate.
const int maxPictureBitrate = 24000000;

/// [pictureBitrates] for [target] at [height] and [fps].
int pictureBitrate(PictureTarget target, {int? height, double? fps}) {
  final at = height ?? 1080;
  final row = pictureBitrates.firstWhere(
    (row) => at <= row.height,
    orElse: () => pictureBitrates.last,
  );
  final base = target.codec == 'HEVC' ? row.hevc : row.h264;
  // Half a frame a second either way is the same rate, as the receiver
  // table reads one: mpv reports "30" as 30.000030 as often as not.
  final fast = fps != null && fps > 30.5;
  return min(fast ? base * 14 ~/ 10 : base, maxPictureBitrate);
}
