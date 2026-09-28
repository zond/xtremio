/// Where the viewer was on each title's details screen when they last left
/// it, so the next visit opens on the same season and episode.
///
/// One row per title: the season the episode list showed and the episode
/// whose sources were up. The details screen writes it as the viewer moves
/// and reads it once, when it opens (`MetaDetailsScreen`).
///
/// **The library can be newer.** A visit is where the viewer *looked*; the
/// library's `video_id` is what they last *watched*, and the player moves
/// that on by itself -- the next episode plays, and the next. So a visit
/// carries the time it was made, and a screen that finds the library's
/// `lastWatched` later than it opens on the library's episode instead. A
/// title never visited here opens on the library's episode as it always
/// did.
library;

import 'package:flutter/foundation.dart';

/// One title's last visit.
@immutable
final class DetailsVisit {
  const DetailsVisit({
    required this.meta,
    required this.at,
    this.season,
    this.videoId,
  });

  /// The meta item's id: the show, never one of its episodes.
  final String meta;

  /// The season the episode list showed. Null for a title with no seasons.
  final int? season;

  /// The episode whose sources were up, null when none had been chosen.
  /// It need not be in [season]: walking the season pills changes the list
  /// without choosing an episode from it.
  final String? videoId;

  /// When the visit was made, in UTC -- what is compared with the
  /// library's `lastWatched`.
  final DateTime at;

  Map<String, Object> toJson() => {
    'meta': meta,
    'season': ?season,
    'videoId': ?videoId,
    'at': at.toUtc().millisecondsSinceEpoch,
  };

  /// One stored row, or null when it is not one this build can use.
  /// Preferences are forgiving: an unreadable row is dropped, never a
  /// failure to load.
  static DetailsVisit? fromJson(Object? json) {
    if (json is! Map) return null;
    final meta = _token(json['meta']);
    final at = json['at'];
    if (meta == null || at is! int) return null;
    final season = json['season'];
    return DetailsVisit(
      meta: meta,
      season: season is int && season >= 0 ? season : null,
      videoId: _token(json['videoId']),
      at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
    );
  }

  static String? _token(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  @override
  bool operator ==(Object other) =>
      other is DetailsVisit &&
      other.meta == meta &&
      other.season == season &&
      other.videoId == videoId &&
      other.at == at;

  @override
  int get hashCode => Object.hash(meta, season, videoId, at);
}

/// Every title whose last visit is still remembered, most recent first.
@immutable
final class DetailsVisitMemory {
  const DetailsVisitMemory(this.visits);

  /// Nothing visited yet: a fresh install, and what an unreadable stored
  /// value reads as.
  static const DetailsVisitMemory empty = DetailsVisitMemory(<DetailsVisit>[]);

  /// Most recent first. The order is the recency; [DetailsVisit.at] is
  /// there for the comparison with the library, not for sorting.
  final List<DetailsVisit> visits;

  /// How many titles are remembered. What falls off is the title visited
  /// longest ago, and a title in the library still opens on its last
  /// watched episode without a row here.
  static const int limit = 200;

  /// [meta]'s last visit, or null when it has none.
  DetailsVisit? forMeta(String meta) {
    for (final visit in visits) {
      if (visit.meta == meta) return visit;
    }
    return null;
  }

  /// This memory with [visit] as the most recent, replacing the title's
  /// earlier row and dropping the oldest past [limit].
  DetailsVisitMemory withVisit(DetailsVisit visit) => DetailsVisitMemory([
    visit,
    ...visits.where((row) => row.meta != visit.meta).take(limit - 1),
  ]);

  Map<String, Object> toJson() => {
    'visits': [for (final visit in visits) visit.toJson()],
  };

  static DetailsVisitMemory fromJson(Object? json) {
    if (json is! Map) return empty;
    final rows = json['visits'];
    final visits = <DetailsVisit>[];
    final seen = <String>{};
    for (final row in rows is List ? rows : const []) {
      final visit = DetailsVisit.fromJson(row);
      // One row per title: a hand-edited file naming one twice would
      // otherwise leave a row nothing can ever reach.
      if (visit != null && seen.add(visit.meta)) visits.add(visit);
      if (visits.length == limit) break;
    }
    return visits.isEmpty ? empty : DetailsVisitMemory(visits);
  }

  @override
  bool operator ==(Object other) =>
      other is DetailsVisitMemory && listEquals(other.visits, visits);

  @override
  int get hashCode => Object.hashAll(visits);
}
