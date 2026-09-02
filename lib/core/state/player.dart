import '../resource.dart';
import 'loadable.dart';
import 'meta_item.dart';
import 'stream.dart';

/// The URLs stremio-core derived for the selected stream (`StreamUrls`).
///
/// Note this struct is snake_case on the wire, unlike the rest of the model.
final class StreamUrls {
  const StreamUrls(this.json, {this.convertedStream});

  final Map<String, dynamic> json;

  /// The second half of the engine's `(StreamUrls, Stream)` pair: the
  /// stream after source conversion (torrent hints resolved, ...).
  final StreamInfo? convertedStream;

  /// What to hand to the player: the direct URL for `url` streams, or the
  /// streaming server's `/{infoHash}/{fileIdx}` URL for torrents. Null when
  /// the stream cannot be played by a media player (magnet, external, ...).
  Uri? get streamingUrl => _uri(json['streaming_url']);

  Uri? get downloadUrl => _uri(json['download_url']);
  Uri? get magnetUrl => _uri(json['magnet_url']);

  static Uri? _uri(Object? value) =>
      value is String ? Uri.tryParse(value) : null;
}

/// Where the library says playback last stopped.
final class LibraryProgress {
  const LibraryProgress({required this.timeOffset, required this.duration});

  /// Milliseconds, like the `TimeChanged` action.
  final int timeOffset;
  final int duration;

  /// A resume point worth seeking to (some progress, not at the very end).
  bool get isResumable =>
      timeOffset > 0 && (duration == 0 || timeOffset < duration * 0.95);
}

/// One subtitle file an addon offers (`Subtitles`): a URL to an SRT/VTT
/// file plus its language.
final class SubtitleInfo {
  const SubtitleInfo(this.json);

  final Map<String, dynamic> json;

  String get id => json['id'] as String? ?? url.toString();

  /// Language code as the addon sent it (`eng`, `pob`, ...).
  String get lang => json['lang'] as String? ?? '';
  Uri get url => Uri.parse(json['url'] as String);
  String? get label => json['label'] as String?;

  static List<SubtitleInfo> listFromJson(Object? json) => [
    for (final item in (json as List<dynamic>? ?? const []))
      SubtitleInfo(item as Map<String, dynamic>),
  ];
}

/// Where subtitles for this Player session should come from
/// (`SubtitlePreference`), remembered by the engine across `Load Player`
/// until `Unload`.
final class SubtitlePreference {
  const SubtitlePreference({required this.enabled, this.source, this.language});

  final bool enabled;

  /// `embedded` or `external`; null to keep the client's own ordering.
  final String? source;

  /// Normalized language code; null when unknown.
  final String? language;

  factory SubtitlePreference.fromJson(Map<String, dynamic> json) =>
      SubtitlePreference(
        enabled: json['enabled'] as bool? ?? false,
        source: json['source'] as String?,
        language: json['language'] as String?,
      );
}

/// View over the `player` field (`Player`).
final class PlayerState {
  const PlayerState({
    required this.selectedStream,
    required this.selectedVideoId,
    required this.stream,
    required this.metaItem,
    required this.nextVideo,
    required this.nextStream,
    required this.progress,
    required this.subtitles,
    required this.subtitlePreference,
    this.streamRequest,
    this.metaRequest,
    this.subtitlesPath,
  });

  /// The stream as it was loaded; null when the model is unloaded.
  final StreamInfo? selectedStream;

  /// The video the stream was requested for (`streamRequest.path.id`).
  final String? selectedVideoId;

  /// Null until `Load Player` ran; `Err` when the stream cannot be
  /// converted (e.g. a torrent while no streaming server is configured).
  final Loadable<StreamUrls>? stream;

  final ResourceLoadable<MetaItem>? metaItem;
  final VideoInfo? nextVideo;

  /// The stream the engine picked for [nextVideo] (same addon, matching
  /// binge group); null when it found none, in which case the next episode
  /// has to be chosen from its own stream list.
  final StreamInfo? nextStream;
  final LibraryProgress? progress;

  /// One entry per subtitle addon asked (`Player.subtitles`), each Loading,
  /// Ready with its files, or Err.
  final List<ResourceLoadable<List<SubtitleInfo>>> subtitles;
  final SubtitlePreference? subtitlePreference;

  /// The requests `Load Player` was given, so a follow-up load (the next
  /// episode) can be built from them.
  final ResourceRequest? streamRequest;
  final ResourceRequest? metaRequest;
  final ResourcePath? subtitlesPath;

  factory PlayerState.fromJson(Map<String, dynamic> json) {
    final selected = json['selected'] as Map<String, dynamic>?;
    final selectedStream = selected?['stream'] as Map<String, dynamic>?;
    final stream = json['stream'] as Map<String, dynamic>?;
    final metaItem = json['metaItem'] as Map<String, dynamic>?;
    final nextVideo = json['nextVideo'] as Map<String, dynamic>?;
    final libraryState =
        (json['libraryItem'] as Map<String, dynamic>?)?['state']
            as Map<String, dynamic>?;
    final streamRequest = selected?['streamRequest'] as Map<String, dynamic>?;
    final metaRequest = selected?['metaRequest'] as Map<String, dynamic>?;
    final subtitlesPath = selected?['subtitlesPath'] as Map<String, dynamic>?;
    final nextStream = json['nextStream'] as Map<String, dynamic>?;
    final preference = json['subtitlePreference'] as Map<String, dynamic>?;
    return PlayerState(
      selectedStream: selectedStream == null
          ? null
          : StreamInfo(selectedStream),
      selectedVideoId:
          (streamRequest?['path'] as Map<String, dynamic>?)?['id'] as String?,
      stream: stream == null
          ? null
          : Loadable.fromJson(stream, (content) {
              // `(StreamUrls, Stream<ConvertedStreamSource>)`: a 2-tuple.
              final pair = content as List<dynamic>;
              final converted = pair.length > 1 ? pair[1] : null;
              return StreamUrls(
                pair[0] as Map<String, dynamic>,
                convertedStream: converted is Map<String, dynamic>
                    ? StreamInfo(converted)
                    : null,
              );
            }),
      metaItem: metaItem == null
          ? null
          : ResourceLoadable.fromJson(
              metaItem,
              (content) => MetaItem(content as Map<String, dynamic>),
            ),
      nextVideo: nextVideo == null ? null : VideoInfo(nextVideo),
      nextStream: nextStream == null ? null : StreamInfo(nextStream),
      subtitles: [
        for (final entry in (json['subtitles'] as List<dynamic>? ?? const []))
          ResourceLoadable.fromJson(
            entry as Map<String, dynamic>,
            SubtitleInfo.listFromJson,
          ),
      ],
      subtitlePreference: preference == null
          ? null
          : SubtitlePreference.fromJson(preference),
      streamRequest: streamRequest == null
          ? null
          : ResourceRequest.fromJson(streamRequest),
      metaRequest: metaRequest == null
          ? null
          : ResourceRequest.fromJson(metaRequest),
      subtitlesPath: subtitlesPath == null
          ? null
          : ResourcePath.fromJson(subtitlesPath),
      progress: libraryState == null
          ? null
          : LibraryProgress(
              timeOffset: (libraryState['timeOffset'] as num?)?.toInt() ?? 0,
              duration: (libraryState['duration'] as num?)?.toInt() ?? 0,
            ),
    );
  }

  bool get isLoaded => selectedStream != null;

  /// The URL to open in the player, once the engine has resolved it.
  Uri? get streamingUrl => stream?.contentOrNull?.streamingUrl;

  /// The stream as the engine converted it (`stream.content[1]`), whose
  /// `behaviorHints` may carry the filename subtitle lookups want.
  StreamInfo? get convertedStream {
    final content = stream?.contentOrNull;
    return content?.convertedStream;
  }

  /// Every subtitle file on offer: what the subtitle addons returned, the
  /// stream's own `subtitles`, and the converted stream's, deduplicated by
  /// URL in that order.
  List<SubtitleInfo> get externalSubtitles {
    final seen = <String>{};
    final result = <SubtitleInfo>[];
    void add(Iterable<SubtitleInfo> items) {
      for (final item in items) {
        if (seen.add(item.url.toString())) result.add(item);
      }
    }

    for (final entry in subtitles) {
      add(entry.contentOrNull ?? const []);
    }
    add(selectedStream?.subtitlesJson.map(SubtitleInfo.new) ?? const []);
    add(convertedStream?.subtitlesJson.map(SubtitleInfo.new) ?? const []);
    return result;
  }

  /// Some subtitle addon has not answered yet.
  bool get subtitlesLoading => subtitles.any((entry) => entry.isLoading);

  /// Why nothing can be played: the conversion error, or a stream kind the
  /// engine resolved to no media URL.
  String? get unplayableReason {
    final stream = this.stream;
    if (stream is LoadableError<StreamUrls>) return stream.message;
    if (stream is LoadableReady<StreamUrls> && streamingUrl == null) {
      return 'This ${selectedStream?.kind.label.toLowerCase() ?? 'stream'} '
          'stream has no playable URL';
    }
    return null;
  }

  /// A title for the overlay: the meta item's name (plus the episode label
  /// and title for series), else the stream's own title.
  String get title {
    final meta = metaItem?.contentOrNull;
    if (meta == null) return selectedStream?.title ?? '';
    final videoId = selectedVideoId;
    final video = videoId == null ? null : meta.videoById(videoId);
    if (video == null || video.id == meta.id) return meta.name;
    final label = video.seasonEpisodeLabel;
    return '${meta.name} · ${label.isEmpty ? '' : '$label '}${video.title}';
  }
}
