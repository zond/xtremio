import 'loadable.dart';
import 'meta_item.dart';
import 'stream.dart';

/// The URLs stremio-core derived for the selected stream (`StreamUrls`).
///
/// Note this struct is snake_case on the wire, unlike the rest of the model.
final class StreamUrls {
  const StreamUrls(this.json);

  final Map<String, dynamic> json;

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

/// View over the `player` field (`Player`).
final class PlayerState {
  const PlayerState({
    required this.selectedStream,
    required this.selectedVideoId,
    required this.stream,
    required this.metaItem,
    required this.nextVideo,
    required this.progress,
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
  final LibraryProgress? progress;

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
              return StreamUrls(pair[0] as Map<String, dynamic>);
            }),
      metaItem: metaItem == null
          ? null
          : ResourceLoadable.fromJson(
              metaItem,
              (content) => MetaItem(content as Map<String, dynamic>),
            ),
      nextVideo: nextVideo == null ? null : VideoInfo(nextVideo),
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
