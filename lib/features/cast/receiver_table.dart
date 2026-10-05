import 'package:flutter/foundation.dart';

/// **What each Cast receiver decodes**: one row per model (stream-server
/// `docs/design/renditions.md`, step F5), from Google's own table
/// (developers.google.com/cast/docs/media, read 2026-10-05). A row is the
/// video codecs the receiver decodes and, per codec, the biggest picture at
/// the fastest rate. Sound is not here: it does not change with the model
/// (the cast check converts anything but stereo AAC or MP3).
///
/// **Which row** is the model name the receiver announces
/// ([ReceiverTable.of]), the one thing the Cast SDK says about its hardware.
/// A name's row holds only **what is common to every model announcing
/// it**: "Chromecast" is announced by the 2013, 2015 and 2018 dongles and by
/// both Chromecasts with Google TV, so it is the 1st generation's H.264
/// alone, with what the best of them decodes as its [ReceiverRow.atBest]. A
/// name the table does not know gets what every receiver in it plays.
@immutable
final class ReceiverRow {
  const ReceiverRow({required this.subject, required this.video, this.atBest});

  /// How a sentence names the receiver, capitalised, as its subject:
  /// 'Every receiver that calls itself "Chromecast"'. A model's own row
  /// names the model; a sentence only ever shows a by-name row's.
  final String subject;

  /// The video codecs it decodes (the names the cast check uses: `H.264`,
  /// `HEVC`, `VP8`, `VP9`, `AV1`), each with the pictures it decodes: any
  /// one of them covering a film's is enough.
  final Map<String, List<VideoLimit>> video;

  /// For a row known only by a name several models announce: what the
  /// best of them decodes. A cast beyond this row and within that one is
  /// tried (zond, 2026-10-05: "we could e.g. try HEVC if we are
  /// uncertain"), the receiver's own report of the picture catching a
  /// model that cannot. Null where the name names one model, whose row
  /// is then held to as it is.
  final ReceiverRow? atBest;

  /// Whether it decodes [codec] at all.
  bool decodes(String codec) => video.containsKey(codec);

  /// Whether it decodes [codec] at [width] x [height] and [fps]; a size or
  /// rate mpv has not reported is not held against the film.
  bool fits(String codec, {int? width, int? height, double? fps}) {
    final limits = video[codec];
    if (limits == null) return false;
    return limits.any(
      (limit) => limit.covers(width: width, height: height, fps: fps),
    );
  }

  /// The codecs it decodes, as a sentence lists them.
  String get codecList => _orList(video.keys);

  /// What it decodes of [codec], as a sentence says it: "HEVC up to
  /// 1920x1080 at 60 frames a second".
  String describeLimit(String codec) {
    final limits = video[codec] ?? const [];
    final described = limits.map((limit) => limit.describe()).join(', or ');
    return '$codec up to $described';
  }

  /// This model's row as the one name it announces, said as [subject].
  ReceiverRow byName(String subject) =>
      ReceiverRow(subject: subject, video: video);
}

/// The biggest picture a receiver decodes at the fastest rate.
@immutable
final class VideoLimit {
  const VideoLimit(this.width, this.height, this.fps);

  final int width;
  final int height;
  final int fps;

  bool covers({int? width, int? height, double? fps}) =>
      (width == null || width <= this.width) &&
      (height == null || height <= this.height) &&
      // A container's rate is a ratio, and mpv reports "30" as 30.000030
      // as often as not: half a frame a second either way is the same rate.
      (fps == null || fps <= this.fps + 0.5);

  String describe() => '${width}x$height at $fps frames a second';
}

const _p720at30 = VideoLimit(1280, 720, 30);
const _p720at60 = VideoLimit(1280, 720, 60);
const _p1080at30 = VideoLimit(1920, 1080, 30);
const _p1080at60 = VideoLimit(1920, 1080, 60);
const _p2160at30 = VideoLimit(3840, 2160, 30);
const _p2160at60 = VideoLimit(3840, 2160, 60);

/// The rows: by model, as Google's table names the limits (where it gives
/// two, "720p/60fps or 1080p/30fps", both are kept), and by announced name,
/// which is what a receiver is judged by. The by-name rows are built from,
/// and tested against, the models'.
abstract final class ReceiverTable {
  /// Chromecast 1st and 2nd generation (2013, 2015): H.264 High up to 4.1,
  /// VP8, each 720p60 or 1080p30.
  static const ReceiverRow firstGeneration = ReceiverRow(
    subject: 'A 1st or 2nd generation Chromecast',
    video: {
      'H.264': [_p720at60, _p1080at30],
      'VP8': [_p720at60, _p1080at30],
    },
  );

  /// Chromecast 3rd generation (2018): H.264 High up to 4.2 at 1080p60.
  static const ReceiverRow thirdGeneration = ReceiverRow(
    subject: 'A 3rd generation Chromecast',
    video: {
      'H.264': [_p1080at60],
      'VP8': [_p720at60, _p1080at30],
    },
  );

  /// Chromecast Ultra: adds HEVC Main/Main 10 and VP9 profiles 0 and 2,
  /// 4K60.
  static const ReceiverRow ultra = ReceiverRow(
    subject: 'A Chromecast Ultra',
    video: {
      'H.264': [_p1080at60],
      'VP8': [_p2160at30],
      'HEVC': [_p2160at60],
      'VP9': [_p2160at60],
    },
  );

  /// Chromecast with Google TV (4K): H.264 High up to level
  /// 5.1, which Google writes as 4K30 and which holds 1080p60 too; HEVC
  /// Main/Main 10 and VP9 profile 2 up to 4K60. Google's table lists no
  /// VP8 for it.
  static const ReceiverRow googleTv4k = ReceiverRow(
    subject: 'A Chromecast with Google TV (4K)',
    video: {
      'H.264': [_p2160at30, _p1080at60],
      'HEVC': [_p2160at60],
      'VP9': [_p2160at60],
    },
  );

  /// Chromecast with Google TV (HD): the 4K model's codecs at
  /// the 1080p its hardware outputs (Google's table does not list the HD
  /// model apart; 1080p is its ceiling).
  static const ReceiverRow googleTvHd = ReceiverRow(
    subject: 'A Chromecast with Google TV (HD)',
    video: {
      'H.264': [_p1080at60],
      'HEVC': [_p1080at60],
      'VP9': [_p1080at60],
    },
  );

  /// Google TV Streamer: the Google TV codecs at 4K60, and AV1.
  static const ReceiverRow streamer = ReceiverRow(
    subject: 'A Google TV Streamer',
    video: {
      'H.264': [_p2160at60],
      'HEVC': [_p2160at60],
      'VP9': [_p2160at60],
      'AV1': [_p2160at60],
    },
  );

  /// Google Nest Hub: H.264 and VP9 at 720p60.
  static const ReceiverRow nestHub = ReceiverRow(
    subject: 'A Nest Hub',
    video: {
      'H.264': [_p720at60],
      'VP9': [_p720at60],
    },
  );

  /// Google Nest Hub Max: H.264 and VP9 at 720p30.
  static const ReceiverRow nestHubMax = ReceiverRow(
    subject: 'A Nest Hub Max',
    video: {
      'H.264': [_p720at30],
      'VP9': [_p720at30],
    },
  );

  /// What every model announcing a name has in common, by that name
  /// (compared without case). "Chromecast": the 1st, 2nd and 3rd
  /// generation dongles and both Chromecasts with Google TV -- the 1st
  /// generation's H.264 (Google lists no VP8 for the Google TV models).
  /// The rest name one model each, as far as is known.
  static final Map<String, ReceiverRow> byAnnouncedName = {
    'chromecast': const ReceiverRow(
      subject: 'Every receiver that calls itself "Chromecast"',
      video: {
        'H.264': [_p720at60, _p1080at30],
      },
      atBest: ReceiverRow(
        subject: 'The best of the receivers that call themselves "Chromecast"',
        video: {
          'H.264': [_p2160at30, _p1080at60],
          'VP8': [_p720at60, _p1080at30],
          'HEVC': [_p2160at60],
          'VP9': [_p2160at60],
        },
      ),
    ),
    'chromecast ultra': ultra.byName(
      'Every receiver that calls itself "Chromecast Ultra"',
    ),
    'google tv streamer': streamer.byName(
      'Every receiver that calls itself "Google TV Streamer"',
    ),
    'google nest hub': nestHub.byName(
      'Every receiver that calls itself "Google Nest Hub"',
    ),
    'nest hub': nestHub.byName('Every receiver that calls itself "Nest Hub"'),
    'google home hub': nestHub.byName(
      'Every receiver that calls itself "Google Home Hub"',
    ),
    'google nest hub max': nestHubMax.byName(
      'Every receiver that calls itself "Google Nest Hub Max"',
    ),
  };

  /// A name the table does not know: what every row above decodes, H.264 at
  /// 720p30 (the Nest Hub Max's ceiling).
  static const ReceiverRow unknown = ReceiverRow(
    subject: 'Every Cast receiver',
    video: {
      'H.264': [_p720at30],
    },
    atBest: ReceiverRow(
      subject: 'The best Cast receiver xtremio knows of',
      video: {
        'H.264': [_p2160at60],
        'VP8': [_p2160at30, _p720at60],
        'HEVC': [_p2160at60],
        'VP9': [_p2160at60],
        'AV1': [_p2160at60],
      },
    ),
  );

  /// **The deepest picture any receiver decodes, by codec**: its bit
  /// depth, always 4:2:0. Google's table lists H.264 as High Profile only --
  /// 8-bit 4:2:0, so High 10 ("Hi10P", common in anime releases), High
  /// 4:2:2 and High 4:4:4 are decoded by no Chromecast; HEVC as Main and
  /// Main 10, so 12 bits, 4:2:2 and 4:4:4 (the range extensions) by none
  /// either; VP9 as profiles 0 and 2 (8 and 10 bits, 4:2:0); AV1 as Main
  /// (8 and 10 bits, 4:2:0); VP8 is 8-bit 4:2:0 by definition. One table
  /// for every row, since a row's limits are size and rate and what no
  /// receiver decodes is refused whatever the receiver: a model whose row
  /// holds less (a Nest Hub's VP9) is left to its own report of the
  /// picture.
  static const Map<String, int> deepestPicture = {
    'H.264': 8,
    'HEVC': 10,
    'VP8': 8,
    'VP9': 10,
    'AV1': 10,
  };

  /// Whether some receiver decodes [codec] in a picture of [depth] bits
  /// with [chroma] subsampling (`4:2:0`, `4:2:2`, `4:4:4`). A codec this
  /// table does not name is not judged here.
  static bool decodesPicture(
    String codec, {
    required int depth,
    required String chroma,
  }) {
    final deepest = deepestPicture[codec];
    if (deepest == null) return true;
    return chroma == '4:2:0' && depth <= deepest;
  }

  /// The row for a receiver that announced [announced] as its model.
  static ReceiverRow of({String? announced}) {
    final name = announced?.trim().toLowerCase();
    return (name == null ? null : byAnnouncedName[name]) ?? unknown;
  }
}

String _orList(Iterable<String> names) {
  final items = names.toList();
  if (items.length < 2) return items.join();
  return '${items.take(items.length - 1).join(', ')} or ${items.last}';
}
