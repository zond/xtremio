import '../resource.dart';
import '../well_formed_text.dart';
import 'meta_item_preview.dart';
import 'stream.dart';

/// View over stremio-core's full `MetaItem` JSON (the preview fields
/// flattened in, plus `videos` and the details a title page shows).
final class MetaItem extends MetaItemPreview {
  const MetaItem(super.json);

  /// Link category Cinemeta uses for genres (`GENRES_LINK_CATEGORY`).
  static const String genresCategory = 'Genres';

  /// Link category carrying the IMDb rating as its name
  /// (`IMDB_LINK_CATEGORY`).
  static const String imdbCategory = 'imdb';

  String? get logo => json['logo'] as String?;
  String? get runtime => json['runtime'] as String?;

  /// The video the engine plays without asking (`behaviorHints.defaultVideoId`);
  /// null for a series, where an episode has to be picked.
  String? get defaultVideoId =>
      (json['behaviorHints'] as Map<String, dynamic>?)?['defaultVideoId']
          as String?;

  List<MetaLink> get links => [
    for (final link in (json['links'] as List<dynamic>? ?? const []))
      MetaLink(link as Map<String, dynamic>),
  ];

  /// Genre names, in the addon's order.
  List<MetaLink> get genres => [
    for (final link in links)
      if (link.category == genresCategory) link,
  ];

  /// `7.8`-style IMDb rating, when the addon sends one.
  String? get imdbRating {
    for (final link in links) {
      if (link.category == imdbCategory) return link.name;
    }
    return null;
  }

  /// Sorted by (season, episode) with season 0 (specials) last, as the
  /// engine serializes them.
  List<VideoInfo> get videos => [
    for (final video in (json['videos'] as List<dynamic>? ?? const []))
      VideoInfo(video as Map<String, dynamic>),
  ];

  /// Distinct seasons ascending, specials (season 0) last; empty for a
  /// movie or a series whose videos carry no season.
  List<int> get seasons {
    final seasons = <int>{};
    for (final video in videos) {
      final season = video.season;
      if (season != null) seasons.add(season);
    }
    final sorted = seasons.toList()..sort();
    if (sorted.isNotEmpty && sorted.first == 0) {
      sorted
        ..removeAt(0)
        ..add(0);
    }
    return sorted;
  }

  /// The videos of one season in the engine's order.
  List<VideoInfo> videosOfSeason(int season) => [
    for (final video in videos)
      if (video.season == season) video,
  ];

  VideoInfo? videoById(String id) {
    for (final video in videos) {
      if (video.id == id) return video;
    }
    return null;
  }
}

/// One `links[]` entry of a meta item: IMDb rating, genres, cast, ... The
/// `url` is either a web URL or a `stremio:///` deep link.
final class MetaLink {
  const MetaLink(this.json);

  final Map<String, dynamic> json;

  String get name => wellFormedText(json['name'] as String?) ?? '';
  String get category => json['category'] as String? ?? '';
  String? get url => json['url'] as String?;

  /// The catalog request a
  /// `stremio:///discover/<manifest url>/<type>/<id>?<extra>` link points
  /// at; null for any other URL. Extras come from the query, as the official
  /// clients read them.
  ResourceRequest? get discoverRequest {
    final uri = Uri.tryParse(url ?? '');
    if (uri == null || uri.scheme != 'stremio') return null;
    final segments = uri.pathSegments;
    if (segments.length != 4 || segments.first != 'discover') return null;
    final base = Uri.tryParse(segments[1]);
    if (base == null || !base.hasScheme) return null;
    return ResourceRequest(
      base: segments[1],
      path: ResourcePath(
        resource: 'catalog',
        type: segments[2],
        id: segments[3],
        extra: [
          for (final entry in uri.queryParameters.entries)
            ExtraValue(entry.key, entry.value),
        ],
      ),
    );
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

  /// [released] parsed, in UTC; null when absent or malformed.
  DateTime? get releasedAt {
    final released = this.released;
    return released == null ? null : DateTime.tryParse(released)?.toUtc();
  }

  /// Whether the video has aired by [now]. Videos without a date count as
  /// released, as `MetaItem::next_video` treats them.
  bool isReleased(DateTime now) {
    final released = releasedAt;
    return released == null || !released.isAfter(now);
  }

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
