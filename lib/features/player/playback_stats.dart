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
      other.cacheBufferingState == cacheBufferingState;

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
  );

  @override
  String toString() =>
      'PlaybackStats(fps: $outputFps/$containerFps, dropped: $droppedFrames'
      '/$decoderDroppedFrames, hwdec: $hwdec, codec: $videoCodec'
      '/$audioCodec, '
      '${width}x$height, bitrate: $videoBitrate, cache: $cacheDuration, '
      'pausedForCache: $pausedForCache, buffering: $cacheBufferingState)';
}
