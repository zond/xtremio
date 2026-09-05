import 'dart:convert';

import 'package:flutter/foundation.dart';

/// One range of the open media the demuxer says it can seek within, as
/// `demuxer-cache-state`'s `seekable-ranges` reports it.
///
/// For a network stream that is the cache, not the file: what has been
/// read and is still held. It is what says whether a seek the viewer just
/// asked for was inside what mpv thought it could reach.
@immutable
class SeekableRange {
  const SeekableRange(this.start, this.end);

  final Duration start;
  final Duration end;

  @override
  bool operator ==(Object other) =>
      other is SeekableRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'SeekableRange($start, $end)';
}

/// One sample of playback performance, as the stats OSD shows it.
///
/// Every field is nullable: before the first frame (and for audio-only
/// media) most of them are simply unavailable. [fromMpv] builds one from
/// raw mpv property strings; other engines can fill the fields directly.
class PlaybackStats {
  const PlaybackStats({
    this.outputFps,
    this.containerFps,
    this.droppedFrames,
    this.decoderDroppedFrames,
    this.hwdec,
    this.videoCodec,
    this.audioCodec,
    this.width,
    this.height,
    this.videoBitrate,
    this.cacheDuration,
    this.pausedForCache,
    this.cacheBufferingState,
    this.seekable,
    this.partiallySeekable,
    this.seekableForced,
    this.seekableRanges,
  });

  /// The mpv properties [fromMpv] reads, in one place so the engine polls
  /// exactly this set.
  static const List<String> mpvProperties = [
    'estimated-vf-fps',
    'container-fps',
    'frame-drop-count',
    'decoder-frame-drop-count',
    'hwdec-current',
    'video-codec',
    'audio-codec-name',
    'video-params/w',
    'video-params/h',
    'video-bitrate',
    'demuxer-cache-duration',
    'paused-for-cache',
    'cache-buffering-state',
    'seekable',
    'partially-seekable',
    'force-seekable',
    'demuxer-cache-state',
  ];

  /// Parses mpv property strings (as `mpv_get_property_string` returns
  /// them). Missing, empty or unparsable values become `null`.
  factory PlaybackStats.fromMpv(Map<String, String> properties) {
    String? text(String name) {
      final value = properties[name]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    double? number(String name) {
      final value = text(name);
      return value == null ? null : double.tryParse(value);
    }

    int? integer(String name) {
      final value = text(name);
      if (value == null) return null;
      return int.tryParse(value) ?? double.tryParse(value)?.round();
    }

    bool? flag(String name) => switch (text(name)) {
      'yes' => true,
      'no' => false,
      _ => null,
    };

    final cache = number('demuxer-cache-duration');
    return PlaybackStats(
      outputFps: number('estimated-vf-fps'),
      containerFps: number('container-fps'),
      droppedFrames: integer('frame-drop-count'),
      decoderDroppedFrames: integer('decoder-frame-drop-count'),
      hwdec: text('hwdec-current'),
      videoCodec: text('video-codec'),
      audioCodec: text('audio-codec-name'),
      width: integer('video-params/w'),
      height: integer('video-params/h'),
      videoBitrate: integer('video-bitrate'),
      cacheDuration: cache == null
          ? null
          : Duration(milliseconds: (cache * 1000).round()),
      pausedForCache: flag('paused-for-cache'),
      cacheBufferingState: integer('cache-buffering-state'),
      seekable: flag('seekable'),
      partiallySeekable: flag('partially-seekable'),
      seekableForced: flag('force-seekable'),
      seekableRanges: _ranges(text('demuxer-cache-state')),
    );
  }

  /// Frames per second actually leaving the video filter chain
  /// (`estimated-vf-fps`).
  final double? outputFps;

  /// Frame rate the container declares (`container-fps`).
  final double? containerFps;

  /// Frames the video output dropped (`frame-drop-count`).
  final int? droppedFrames;

  /// Frames the decoder dropped (`decoder-frame-drop-count`).
  final int? decoderDroppedFrames;

  /// The hardware decoder in use (`hwdec-current`): an API name such as
  /// `vaapi`, or `no` when decoding in software; `null` when unknown.
  final String? hwdec;

  /// `video-codec`, e.g. `h264 (High)`.
  final String? videoCodec;

  /// `audio-codec-name`: the bare codec, e.g. `aac`, `eac3`, `dts`. Not
  /// shown anywhere -- it is what the cast compatibility check asks mpv
  /// about the audio, the one place the file itself can be believed over
  /// what a release name claims.
  final String? audioCodec;

  /// Decoded picture size (`video-params/w`, `video-params/h`).
  final int? width;
  final int? height;

  /// Video bitrate estimate in bits per second (`video-bitrate`).
  final int? videoBitrate;

  /// How much media the demuxer has buffered ahead
  /// (`demuxer-cache-duration`).
  final Duration? cacheDuration;

  /// Playback is stalled waiting for the cache (`paused-for-cache`).
  final bool? pausedForCache;

  /// Cache fill while stalled, 0-100 (`cache-buffering-state`).
  final int? cacheBufferingState;

  /// Whether mpv says the open media can be seeked in at all (`seekable`),
  /// whether it can only be seeked within what it has cached
  /// (`partially-seekable`), and whether we are the reason it says yes
  /// (`force-seekable`, `MediaKitEngine.forcesSeekable`).
  ///
  /// `seekable` is what mpv refuses a seek on: a no there does not wait
  /// for the seek, it restores the position, and from the sofa that looks
  /// exactly like the film jumping back. But for a stream the embedded
  /// server is serving we force it true, because the server answers any
  /// byte range and the demuxer cannot know that -- so on our own stream
  /// `seekable` is our answer and not a reading, which is what
  /// [seekableForced] is on the panel to say.
  ///
  /// **`partially-seekable` is then the row that carries the demuxer's own
  /// conclusion**: mpv sets it alongside the forced `seekable`, so a yes
  /// there on a forced stream is the demuxer having said it could not seek
  /// (a Matroska file whose index sits at the end and had not arrived when
  /// it opened) and our claim overruling it. A stream nothing was forced
  /// on reads both rows straight.
  final bool? seekable;
  final bool? partiallySeekable;
  final bool? seekableForced;

  /// What the demuxer says it can currently seek within
  /// (`demuxer-cache-state`'s `seekable-ranges`). Null when mpv did not
  /// answer at all; empty when it answered with no ranges, which is not
  /// the same thing and is exactly the reading this is here for.
  final List<SeekableRange>? seekableRanges;

  /// The seekable ranges out of `demuxer-cache-state`, which mpv answers
  /// as JSON (a node property converted to a string). Anything that does
  /// not parse, or an answer without the key, is no answer at all: the
  /// panel then omits the row rather than claiming there are none.
  static List<SeekableRange>? _ranges(String? state) {
    if (state == null) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(state);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final ranges = decoded['seekable-ranges'];
    if (ranges is! List) return null;
    final parsed = <SeekableRange>[];
    for (final range in ranges) {
      if (range is! Map) continue;
      final start = _seconds(range['start']);
      final end = _seconds(range['end']);
      if (start == null || end == null) continue;
      parsed.add(SeekableRange(start, end));
    }
    return parsed;
  }

  static Duration? _seconds(Object? value) {
    final number = value is num ? value.toDouble() : null;
    if (number == null || !number.isFinite) return null;
    return Duration(milliseconds: (number * 1000).round());
  }

  /// True when mpv reports it is decoding without a hardware decoder. Null
  /// while [hwdec] is unknown (no video yet).
  bool? get isSoftwareDecoding => switch (hwdec) {
    null => null,
    'no' || 'none' || '' => true,
    _ => false,
  };

  @override
  bool operator ==(Object other) =>
      other is PlaybackStats &&
      other.outputFps == outputFps &&
      other.containerFps == containerFps &&
      other.droppedFrames == droppedFrames &&
      other.decoderDroppedFrames == decoderDroppedFrames &&
      other.hwdec == hwdec &&
      other.videoCodec == videoCodec &&
      other.audioCodec == audioCodec &&
      other.width == width &&
      other.height == height &&
      other.videoBitrate == videoBitrate &&
      other.cacheDuration == cacheDuration &&
      other.pausedForCache == pausedForCache &&
      other.cacheBufferingState == cacheBufferingState &&
      other.seekable == seekable &&
      other.partiallySeekable == partiallySeekable &&
      other.seekableForced == seekableForced &&
      listEquals(other.seekableRanges, seekableRanges);

  @override
  int get hashCode => Object.hash(
    outputFps,
    containerFps,
    droppedFrames,
    decoderDroppedFrames,
    hwdec,
    videoCodec,
    audioCodec,
    width,
    height,
    videoBitrate,
    cacheDuration,
    pausedForCache,
    cacheBufferingState,
    seekable,
    partiallySeekable,
    seekableForced,
    seekableRanges == null ? null : Object.hashAll(seekableRanges!),
  );

  @override
  String toString() =>
      'PlaybackStats(fps: $outputFps/$containerFps, dropped: $droppedFrames'
      '/$decoderDroppedFrames, hwdec: $hwdec, codec: $videoCodec'
      '/$audioCodec, '
      '${width}x$height, bitrate: $videoBitrate, cache: $cacheDuration, '
      'pausedForCache: $pausedForCache, buffering: $cacheBufferingState, '
      'seekable: $seekable, partiallySeekable: $partiallySeekable, '
      'ranges: $seekableRanges)';
}
