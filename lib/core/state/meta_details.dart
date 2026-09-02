import '../resource.dart';
import 'loadable.dart';
import 'meta_item.dart';
import 'stream.dart';

/// The streams one addon returned for the selected video.
final class StreamGroup extends ResourceLoadable<List<StreamInfo>> {
  const StreamGroup({
    required super.request,
    required super.content,
    this.isFromMeta = false,
  });

  factory StreamGroup.fromJson(
    Map<String, dynamic> json, {
    bool isFromMeta = false,
  }) {
    final loadable = ResourceLoadable.fromJson(json, StreamInfo.listFromJson);
    return StreamGroup(
      request: loadable.request,
      content: loadable.content,
      isFromMeta: isFromMeta,
    );
  }

  /// Whether this is a `metaStreams` group: streams the meta addon attached
  /// to the video itself (or the YouTube stream of a `yt:` id).
  final bool isFromMeta;

  /// The addon, as its manifest host (the model has no addon names).
  String get addonLabel => Uri.tryParse(request.base)?.host ?? request.base;

  List<StreamInfo> get streams => contentOrNull ?? const [];
}

/// View over the `meta_details` field (`MetaDetails` + `watchedVideoIds`).
final class MetaDetailsState {
  const MetaDetailsState({
    required this.metaPath,
    required this.streamPath,
    required this.metaItems,
    required this.metaStreamGroups,
    required this.streamGroups,
    required this.lastUsedStream,
    required this.libraryVideoId,
    required this.watchedVideoIds,
  });

  /// What was loaded; null when the model is unloaded.
  final ResourcePath? metaPath;

  /// The video whose streams are shown (set by the engine for movies and
  /// guessed for series when `guessStream` is on).
  final ResourcePath? streamPath;

  /// One per meta addon asked; usually only one is `Ready`.
  final List<ResourceLoadable<MetaItem>> metaItems;

  /// Streams the meta addon attached to the selected video (at most one
  /// group, `isFromMeta`).
  final List<StreamGroup> metaStreamGroups;

  /// One per stream addon asked, in addon order.
  final List<StreamGroup> streamGroups;

  /// The stream (and the addon group it was found in) this title was last
  /// played with, when one of the loaded groups still offers it or a
  /// binge-group sibling; null otherwise.
  final (StreamGroup, StreamInfo)? lastUsedStream;

  /// `libraryItem.state.video_id`: the video the library is on (an episode
  /// id for series), null before anything was played.
  final String? libraryVideoId;

  final List<String> watchedVideoIds;

  factory MetaDetailsState.fromJson(Map<String, dynamic> json) {
    final selected = json['selected'] as Map<String, dynamic>?;
    final metaPath = selected?['metaPath'] as Map<String, dynamic>?;
    final streamPath = selected?['streamPath'] as Map<String, dynamic>?;
    return MetaDetailsState(
      metaPath: metaPath == null ? null : ResourcePath.fromJson(metaPath),
      streamPath: streamPath == null ? null : ResourcePath.fromJson(streamPath),
      metaItems: [
        for (final item in (json['metaItems'] as List<dynamic>? ?? const []))
          ResourceLoadable.fromJson(
            item as Map<String, dynamic>,
            (content) => MetaItem(content as Map<String, dynamic>),
          ),
      ],
      metaStreamGroups: [
        for (final group in (json['metaStreams'] as List<dynamic>? ?? const []))
          StreamGroup.fromJson(group as Map<String, dynamic>, isFromMeta: true),
      ],
      streamGroups: [
        for (final group in (json['streams'] as List<dynamic>? ?? const []))
          StreamGroup.fromJson(group as Map<String, dynamic>),
      ],
      lastUsedStream: _lastUsedStream(
        json['lastUsedStream'] as Map<String, dynamic>?,
      ),
      libraryVideoId:
          ((json['libraryItem'] as Map<String, dynamic>?)?['state']
                  as Map<String, dynamic>?)?['video_id']
              as String?,
      watchedVideoIds: [
        ...?(json['watchedVideoIds'] as List<dynamic>?)?.whereType<String>(),
      ],
    );
  }

  /// `lastUsedStream` is `ResourceLoadable<Option<Stream>>`: the request is
  /// the stream addon's when a stream matched, the meta request otherwise.
  static (StreamGroup, StreamInfo)? _lastUsedStream(
    Map<String, dynamic>? json,
  ) {
    if (json == null) return null;
    final content = json['content'] as Map<String, dynamic>?;
    final stream = content?['content'];
    if (content?['type'] != 'Ready' || stream is! Map<String, dynamic>) {
      return null;
    }
    final group = StreamGroup(
      request: ResourceRequest.fromJson(
        json['request'] as Map<String, dynamic>,
      ),
      content: LoadableReady([StreamInfo(stream)]),
    );
    return (group, StreamInfo(stream));
  }

  /// The first meta addon that answered.
  ResourceLoadable<MetaItem>? get readyMeta {
    for (final item in metaItems) {
      if (item.contentOrNull != null) return item;
    }
    return null;
  }

  MetaItem? get meta => readyMeta?.contentOrNull;

  /// The meta request to hand to `Load Player` (for library/next-video).
  ResourceRequest? get metaRequest => readyMeta?.request;

  bool get isLoadingMeta => meta == null && metaItems.any((m) => m.isLoading);

  /// The error when every meta addon failed.
  LoadableError<MetaItem>? get metaError {
    if (meta != null || metaItems.isEmpty) return null;
    if (metaItems.any((m) => m.isLoading)) return null;
    return metaItems.first.error;
  }

  /// The selected video (episode) of the ready meta item, if resolvable.
  VideoInfo? get selectedVideo {
    final id = streamPath?.id;
    return id == null ? null : meta?.videoById(id);
  }

  /// Whether the meta item has videos to pick from (a series).
  bool get hasVideos => meta?.videos.isNotEmpty ?? false;

  /// Whether the engine will pick a stream path on its own once the meta
  /// settles (`selected_guess_stream_update`): a default video, or no videos
  /// at all. When false and [streamPath] is null the UI has to select one.
  bool get engineWillGuessStream {
    final meta = this.meta;
    if (meta == null) return true;
    return meta.defaultVideoId != null || meta.videos.isEmpty;
  }

  /// The episode to show first: [preferred] (a continue-watching row knows
  /// it), else the library's current video, else the selected stream path,
  /// else the first regular (non-special) episode. Null for a movie or
  /// before the meta arrives.
  VideoInfo? initialVideo({String? preferred}) {
    final meta = this.meta;
    if (meta == null || meta.videos.isEmpty) return null;
    for (final id in [preferred, libraryVideoId, streamPath?.id]) {
      final video = id == null ? null : meta.videoById(id);
      if (video != null) return video;
    }
    final videos = meta.videos;
    for (final video in videos) {
      if (video.season != 0) return video;
    }
    return videos.first;
  }

  bool isWatched(VideoInfo video) => watchedVideoIds.contains(video.id);

  /// Every group with streams to list: the meta addon's own first, then
  /// one per stream addon.
  List<StreamGroup> get allStreamGroups => [
    ...metaStreamGroups,
    ...streamGroups,
  ];

  bool get isLoadingStreams => allStreamGroups.any((g) => g.isLoading);

  /// Every playable stream with the addon request it came from.
  List<(StreamGroup, StreamInfo)> get playableStreams => [
    for (final group in allStreamGroups)
      for (final stream in group.streams)
        if (stream.isPlayable) (group, stream),
  ];
}
