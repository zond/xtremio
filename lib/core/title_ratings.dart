/// A title's scores -- IMDb, TMDB, the Tomatometer and the Popcornmeter --
/// and where this device keeps them.
///
/// The scores come from the xtremio-xervice server's `/ratings`
/// (`xtremio-xervice/functions/ratings.js`), which asks MDBList once a week
/// per title for everybody. This is the device's copy: written down under
/// the title in the preferences file, so a title opened again shows its
/// scores at once and is asked about again only once [TitleRatingsMemory.freshFor]
/// has passed.
library;

import 'package:flutter/foundation.dart';

/// One source's score: [score] on that source's own scale, and how many
/// votes or reviews it rests on when the source says.
@immutable
final class TitleScore {
  const TitleScore(this.score, {this.votes});

  /// Out of ten for IMDb and TMDB, a percentage for the two Rotten
  /// Tomatoes meters.
  final double score;

  final int? votes;

  Map<String, Object> toJson() => {'score': score, 'votes': ?votes};

  /// One source in the server's answer, or null for anything that is not
  /// a positive number -- `null` included, which is how the server says
  /// the source has no score for the title.
  static TitleScore? fromJson(Object? json) {
    if (json is! Map) return null;
    final score = json['score'];
    if (score is! num || !score.isFinite || score <= 0) return null;
    final votes = json['votes'];
    return TitleScore(
      score.toDouble(),
      votes: votes is num && votes > 0 ? votes.toInt() : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TitleScore && other.score == score && other.votes == votes;

  @override
  int get hashCode => Object.hash(score, votes);

  @override
  String toString() => 'TitleScore($score, $votes)';
}

/// What is known about how a title scored. Any of the four may be null:
/// the server had no score from that source.
@immutable
final class TitleRatings {
  const TitleRatings({this.imdb, this.tmdb, this.tomatoes, this.popcorn});

  static const TitleRatings none = TitleRatings();

  /// IMDb's user rating, out of ten.
  final TitleScore? imdb;

  /// TMDB's user score, out of ten.
  final TitleScore? tmdb;

  /// Rotten Tomatoes' critics' Tomatometer, a percentage.
  final TitleScore? tomatoes;

  /// Rotten Tomatoes' audience Popcornmeter, a percentage.
  final TitleScore? popcorn;

  bool get isEmpty =>
      imdb == null && tmdb == null && tomatoes == null && popcorn == null;

  Map<String, Object> toJson() => {
    'imdb': ?imdb?.toJson(),
    'tmdb': ?tmdb?.toJson(),
    'tomatoes': ?tomatoes?.toJson(),
    'popcorn': ?popcorn?.toJson(),
  };

  /// The server's answer, or a stored copy of one. A source that is not
  /// readable is a source with no score, never a failed read.
  static TitleRatings fromJson(Object? json) {
    if (json is! Map) return none;
    return TitleRatings(
      imdb: TitleScore.fromJson(json['imdb']),
      tmdb: TitleScore.fromJson(json['tmdb']),
      tomatoes: TitleScore.fromJson(json['tomatoes']),
      popcorn: TitleScore.fromJson(json['popcorn']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TitleRatings &&
      other.imdb == imdb &&
      other.tmdb == tmdb &&
      other.tomatoes == tomatoes &&
      other.popcorn == popcorn;

  @override
  int get hashCode => Object.hash(imdb, tmdb, tomatoes, popcorn);

  @override
  String toString() => 'TitleRatings(${toJson()})';
}

/// The scores this device has been told, most recently told first.
@immutable
final class TitleRatingsMemory {
  const TitleRatingsMemory(this.entries);

  static const TitleRatingsMemory empty = TitleRatingsMemory(
    <TitleRatingsEntry>[],
  );

  final List<TitleRatingsEntry> entries;

  /// How many titles are remembered. A row is a hundred-odd bytes; what
  /// falls off the end costs one request the next time it is opened.
  static const int limit = 256;

  /// How long a remembered answer is shown without asking again. The
  /// server keeps an answer a week and the edge a day, so asking sooner
  /// than a day would be answered with the same bytes.
  static const Duration freshFor = Duration(days: 1);

  /// What was told about [id] of [type], or null.
  TitleRatingsEntry? forItem({required String type, required String id}) {
    for (final entry in entries) {
      if (entry.type == type && entry.id == id) return entry;
    }
    return null;
  }

  /// This memory with [ratings] written in under [type] and [id] as of
  /// [at], moved to the front, and the oldest dropped past [limit].
  TitleRatingsMemory remembering({
    required String type,
    required String id,
    required TitleRatings ratings,
    required DateTime at,
  }) => TitleRatingsMemory(
    [
      TitleRatingsEntry(type: type, id: id, ratings: ratings, savedAt: at),
      for (final entry in entries)
        if (!(entry.type == type && entry.id == id)) entry,
    ].take(limit).toList(growable: false),
  );

  List<Map<String, Object>> toJson() => [
    for (final entry in entries) entry.toJson(),
  ];

  /// The stored value read back, dropping every row this build cannot
  /// read. A value that is not a list at all is [empty].
  static TitleRatingsMemory fromJson(Object? json) {
    if (json is! List) return empty;
    final entries = [for (final row in json) ?TitleRatingsEntry.fromJson(row)];
    return entries.isEmpty ? empty : TitleRatingsMemory(entries);
  }

  @override
  bool operator ==(Object other) =>
      other is TitleRatingsMemory && listEquals(other.entries, entries);

  @override
  int get hashCode => Object.hashAll(entries);
}

/// What one title was told, and when.
@immutable
final class TitleRatingsEntry {
  const TitleRatingsEntry({
    required this.type,
    required this.id,
    required this.ratings,
    required this.savedAt,
  });

  final String type;
  final String id;
  final TitleRatings ratings;

  /// When the server answered this, by this device's clock.
  final DateTime savedAt;

  /// Whether this is still worth showing without asking again at [now].
  /// A clock that went backwards past [savedAt] makes it stale, not fresh
  /// forever.
  bool isFreshAt(DateTime now) {
    final age = now.difference(savedAt);
    return !age.isNegative && age < TitleRatingsMemory.freshFor;
  }

  Map<String, Object> toJson() => {
    'type': type,
    'id': id,
    'at': savedAt.millisecondsSinceEpoch,
    'ratings': ratings.toJson(),
  };

  static TitleRatingsEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final type = json['type'];
    final id = json['id'];
    final at = json['at'];
    if (type is! String || id is! String || at is! int) return null;
    return TitleRatingsEntry(
      type: type,
      id: id,
      ratings: TitleRatings.fromJson(json['ratings']),
      savedAt: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TitleRatingsEntry &&
      other.type == type &&
      other.id == id &&
      other.ratings == ratings &&
      other.savedAt == savedAt;

  @override
  int get hashCode => Object.hash(type, id, ratings, savedAt);
}
