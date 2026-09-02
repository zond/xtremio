import '../resource.dart';
import 'loadable.dart';
import 'meta_item.dart';
import 'stream.dart';

/// The streams one addon returned for the selected video.
final class StreamGroup extends ResourceLoadable<List<StreamInfo>> {
  const StreamGroup({required super.request, required super.content});

  factory StreamGroup.fromJson(Map<String, dynamic> json) {
    final loadable = ResourceLoadable.fromJson(json, StreamInfo.listFromJson);
    return StreamGroup(request: loadable.request, content: loadable.content);
  }

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
    required this.streamGroups,
    required this.watchedVideoIds,
  });

  /// What was loaded; null when the model is unloaded.
  final ResourcePath? metaPath;

  /// The video whose streams are shown (set by the engine for movies and
  /// guessed for series when `guessStream` is on).
  final ResourcePath? streamPath;

  /// One per meta addon asked; usually only one is `Ready`.
  final List<ResourceLoadable<MetaItem>> metaItems;

  /// One per stream addon asked, in addon order.
  final List<StreamGroup> streamGroups;

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
      streamGroups: [
        for (final group in (json['streams'] as List<dynamic>? ?? const []))
          StreamGroup.fromJson(group as Map<String, dynamic>),
      ],
      watchedVideoIds: [
        ...?(json['watchedVideoIds'] as List<dynamic>?)?.whereType<String>(),
      ],
    );
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

  bool get isLoadingStreams => streamGroups.any((g) => g.isLoading);

  /// Every playable stream with the addon request it came from.
  List<(StreamGroup, StreamInfo)> get playableStreams => [
    for (final group in streamGroups)
      for (final stream in group.streams)
        if (stream.isPlayable) (group, stream),
  ];
}
