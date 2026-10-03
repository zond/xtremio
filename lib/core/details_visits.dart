/// Where the viewer was on each title's details screen when they last left
/// it, so the next visit opens where they were: the same season and
/// episode, the page scrolled as far, and on a television the remote on
/// the same stop.
///
/// One row per title: the season the episode list showed, the episode
/// whose sources were up, how far the page was scrolled and where the
/// remote stood ([DetailsRemote]). The details screen writes it as the
/// viewer moves and whenever they leave -- a pop, the player pushed over
/// it, the app paused -- and reads it once, when it opens
/// (`MetaDetailsScreen`). **A title with a row has been visited**, which
/// is what decides whether its screen opens at the top or where it was
/// left.
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

/// Where the remote stood on a television's details screen: a stop on
/// its ladder, and which rung and group of sources were open around it.
///
/// The row is a name rather than the ladder's level number, so a
/// renumbering of the ladder does not send a stored row somewhere else.
@immutable
final class DetailsRemote {
  const DetailsRemote({
    required this.row,
    this.index = 0,
    this.id,
    this.rung,
    this.group,
  });

  /// Which row of the ladder: `header`, `episodes`, `sources`, ... --
  /// the screen's names for its levels.
  final String row;

  /// Which stop of the row, in the order the remote walks it.
  final int index;

  /// The stop's own name where it has one (a source's key, a group's
  /// label), which finds it again when the row is drawn in another order.
  final String? id;

  /// The rung that was open, when the viewer had chosen it.
  final String? rung;

  /// The group of sources whose row was out.
  final String? group;

  Map<String, Object> toJson() => {
    'row': row,
    'index': index,
    'id': ?id,
    'rung': ?rung,
    'group': ?group,
  };

  static DetailsRemote? fromJson(Object? json) {
    if (json is! Map) return null;
    final row = DetailsVisit._token(json['row']);
    if (row == null) return null;
    final index = json['index'];
    return DetailsRemote(
      row: row,
      index: index is int && index >= 0 ? index : 0,
      id: DetailsVisit._token(json['id']),
      rung: DetailsVisit._token(json['rung']),
      group: DetailsVisit._token(json['group']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DetailsRemote &&
      other.row == row &&
      other.index == index &&
      other.id == id &&
      other.rung == rung &&
      other.group == group;

  @override
  int get hashCode => Object.hash(row, index, id, rung, group);
}

/// One title's last visit.
@immutable
final class DetailsVisit {
  const DetailsVisit({
    required this.meta,
    required this.at,
    this.season,
    this.videoId,
    this.offset,
    this.remote,
  });

  /// The meta item's id: the show, never one of its episodes.
  final String meta;

  /// The season the episode list showed. Null for a title with no seasons.
  final int? season;

  /// The episode whose sources were up, null when none had been chosen.
  /// It need not be in [season]: walking the season pills changes the list
  /// without choosing an episode from it.
  final String? videoId;

  /// When the season or episode was chosen, in UTC -- what is compared
  /// with the library's `lastWatched`. Not when the screen was left: the
  /// screen writes the visit again on every leaving, and an episode chosen
  /// before a binge must not look newer than the library for it.
  final DateTime at;

  /// How far down the page was scrolled, in logical pixels; null for the
  /// top.
  final double? offset;

  /// Where the remote stood, on a television; null off one, and on a
  /// screen the remote never reached.
  final DetailsRemote? remote;

  Map<String, Object> toJson() => {
    'meta': meta,
    'season': ?season,
    'videoId': ?videoId,
    'at': at.toUtc().millisecondsSinceEpoch,
    'offset': ?offset,
    'remote': ?remote?.toJson(),
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
    final offset = json['offset'];
    return DetailsVisit(
      meta: meta,
      season: season is int && season >= 0 ? season : null,
      videoId: _token(json['videoId']),
      at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
      offset: offset is num && offset.isFinite && offset > 0
          ? offset.toDouble()
          : null,
      remote: DetailsRemote.fromJson(json['remote']),
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
      other.at == at &&
      other.offset == offset &&
      other.remote == remote;

  @override
  int get hashCode => Object.hash(meta, season, videoId, at, offset, remote);
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
  /// longest ago, which opens at the top again as if never visited -- and
  /// a title in the library still on its last watched episode.
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
