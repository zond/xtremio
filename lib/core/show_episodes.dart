/// A series' episode list, as much of it as "watched through" needs, and
/// where it is kept.
///
/// A library item's watched marks are bits by position in the meta's
/// video list (`watched_bitfield.dart`), so telling whether a season is
/// watched needs that list. It is asked of Cinemeta -- the meta addon
/// everybody has, which "More like this" already asks -- once per show,
/// and kept: what is stored is the ids in stremio-core's order with their
/// season numbers, nothing else.
library;

import 'package:flutter/foundation.dart';

import 'watched_bitfield.dart';

/// One episode, as the rule reads it.
typedef ShowEpisode = ({String id, int? season});

/// The videos of a `{"meta": {"videos": [...]}}` answer, in stremio-core's
/// order; null when it is not one.
List<ShowEpisode>? episodesInMeta(Object? json) {
  final meta = json is Map ? json['meta'] : null;
  final videos = meta is Map ? meta['videos'] : null;
  if (videos is! List) return null;
  int? number(Object? value) =>
      value is int ? value : (value is num ? value.toInt() : null);
  return [
    for (final video in sortedVideos([
      for (final video in videos)
        if (video is Map && video['id'] is String)
          (
            id: video['id'] as String,
            season: number(video['season']),
            episode: number(video['episode'] ?? video['number']),
            released: DateTime.tryParse('${video['released'] ?? ''}'),
          ),
    ]))
      (id: video.id, season: video.season),
  ];
}

/// Every show's list this device has asked for, most recent first.
@immutable
final class ShowEpisodesMemory {
  const ShowEpisodesMemory(this.shows);

  static const ShowEpisodesMemory empty = ShowEpisodesMemory({});

  /// How many shows are kept. The library's watched-through series are
  /// what is asked about, and a show past this is asked again once.
  static const int limit = 256;

  final Map<String, List<ShowEpisode>> shows;

  List<ShowEpisode>? of(String id) => shows[id];

  ShowEpisodesMemory remembering(String id, List<ShowEpisode> episodes) {
    final next = <String, List<ShowEpisode>>{id: episodes};
    for (final MapEntry(:key, :value) in shows.entries) {
      if (next.length >= limit) break;
      next.putIfAbsent(key, () => value);
    }
    return ShowEpisodesMemory(next);
  }

  /// `{id: [[videoId, season], ...]}`, a season of null written as 0 -- a
  /// special, which is what the rule takes it for either way.
  Map<String, Object> toJson() => {
    for (final MapEntry(:key, :value) in shows.entries)
      key: [
        for (final episode in value) [episode.id, episode.season ?? 0],
      ],
  };

  static ShowEpisodesMemory fromJson(Object? json) {
    if (json is! Map) return empty;
    final shows = <String, List<ShowEpisode>>{};
    for (final MapEntry(:key, :value) in json.entries) {
      if (key is! String || value is! List) continue;
      shows[key] = [
        for (final row in value)
          if (row is List && row.length == 2 && row[0] is String)
            (id: row[0] as String, season: row[1] is int ? row[1] as int : 0),
      ];
    }
    return ShowEpisodesMemory(shows);
  }
}
