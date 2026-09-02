import 'meta_item_preview.dart';
import 'stream.dart';

/// View over stremio-core's full `MetaItem` JSON (the preview fields
/// flattened in, plus `videos` and the details a title page shows).
final class MetaItem extends MetaItemPreview {
  const MetaItem(super.json);

  String? get logo => json['logo'] as String?;
  String? get runtime => json['runtime'] as String?;

  List<VideoInfo> get videos => [
    for (final video in (json['videos'] as List<dynamic>? ?? const []))
      VideoInfo(video as Map<String, dynamic>),
  ];

  VideoInfo? videoById(String id) {
    for (final video in videos) {
      if (video.id == id) return video;
    }
    return null;
  }
}

/// One `Video` of a meta item (an episode, or the movie itself).
final class VideoInfo {
  const VideoInfo(this.json);

  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get title => json['title'] as String? ?? '';
  String? get thumbnail => json['thumbnail'] as String?;
  String? get overview => json['overview'] as String?;

  /// ISO-8601, when the addon knows the air date.
  String? get released => json['released'] as String?;

  int? get season => json['season'] as int?;
  int? get episode => json['episode'] as int?;

  /// `S1E3`-style label; empty for a movie.
  String get seasonEpisodeLabel {
    final (season, episode) = (this.season, this.episode);
    if (season == null || episode == null) return '';
    return 'S${season}E$episode';
  }

  /// Streams the meta addon attached directly to the video, if any.
  List<StreamInfo> get streams => StreamInfo.listFromJson(json['streams']);
}
