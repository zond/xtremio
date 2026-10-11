/// The rules of the For you row, as functions of what the library and the
/// faces say: which titles are sources, how much each weighs, and how the
/// titles their "More like this" answers name are ranked.
///
/// Nothing here asks anybody anything. The asking -- the suggestions, the
/// episode lists, the catalogue -- is `ForYouController`'s, and this is what
/// it does with the answers, so a test can hold every rule with a list.
library;

import '../../core/core.dart';
import '../similar/similar_resolver.dart';

/// Why a source is one, and so what its reason line says. The order is
/// which wins for a title that is more than one: liking it is the most
/// the viewer has said.
enum ForYouReason {
  liked('Because you liked'),
  watched('Because you watched'),
  saved('Because you saved');

  const ForYouReason(this.phrase);

  final String phrase;

  /// The tile's reason line for a suggestion from [name].
  String line(String name) => '$phrase $name';

  static ForYouReason? parse(Object? value) => switch (value) {
    'liked' => ForYouReason.liked,
    'watched' => ForYouReason.watched,
    'saved' => ForYouReason.saved,
    _ => null,
  };
}

/// One title whose "More like this" answer feeds the row.
final class ForYouSource {
  const ForYouSource({
    required this.id,
    required this.type,
    required this.name,
    required this.weight,
    required this.reason,
    required this.recency,
  });

  final String id;

  /// `movie` or `series`: which `/similar` it is asked as.
  final String type;
  final String name;

  /// One per listing it is in -- watched through, added by hand -- and one
  /// more for a happy face.
  final int weight;
  final ForYouReason reason;

  /// When it was last watched or added, whichever is later; what orders
  /// the sources, and what breaks a tie between two suggestions.
  final DateTime recency;

  /// The part of the source that changes what the row would be.
  String get signature => '$type/$id:$weight:${reason.name}';

  @override
  String toString() => 'ForYouSource($id, $weight, ${reason.name})';
}

/// A series is "watched through" once one whole season is -- every episode
/// the meta lists for a season numbered one or more -- or, for a show with
/// no such seasons, every episode it has. Specials (season 0) are never a
/// season of their own. A season still airing is not whole until its last
/// listed episode is watched: [videos] lists what is announced, and an
/// episode not out yet cannot have been watched.
bool seriesWatchedThrough(
  List<({String id, int? season})> videos,
  Set<String> watched,
) {
  if (videos.isEmpty) return false;
  final seasons = <int, List<String>>{};
  for (final video in videos) {
    final season = video.season;
    if (season != null && season > 0) {
      (seasons[season] ??= []).add(video.id);
    }
  }
  if (seasons.isEmpty) return videos.every((v) => watched.contains(v.id));
  return seasons.values.any((ids) => ids.every(watched.contains));
}

/// [episodes] (in stremio-core's order) watched through, per
/// [seriesWatchedThrough], as [item]'s `state.watched` says.
bool libraryItemWatchedThrough(
  LibraryItemView item,
  List<({String id, int? season})> episodes,
) => seriesWatchedThrough(
  episodes,
  watchedVideoIds(item.watchedField, [for (final e in episodes) e.id]),
);

/// The sources among [library], heaviest-and-latest first:
///
/// * a **movie watched** (`timesWatched > 0` or `flaggedWatched`), or a
///   **series watched through** ([watchedThrough] answers for one);
/// * a title **added by hand** (`temp == false`, `removed == false`).
///
/// A title that is both counts twice. A happy face adds one; a sad face
/// takes the title out whatever else it is. Only `movie` and `series` are
/// sources, since only those have a `/similar`.
List<ForYouSource> forYouSources(
  Iterable<LibraryItemView> library,
  Faces faces, {
  required bool Function(LibraryItemView series) watchedThrough,
}) {
  final sources = <ForYouSource>[];
  final seen = <String>{};
  for (final item in library) {
    if (item.type != 'movie' && item.type != 'series') continue;
    if (!seen.add(item.id)) continue;
    final face = faces.of(item.id);
    if (face == Face.dislike) continue;
    final watched = item.type == 'movie'
        ? item.timesWatched > 0 || item.flaggedWatched
        : watchedThrough(item);
    final saved = !item.temp && !item.removed;
    if (!watched && !saved) continue;
    final liked = face == Face.like;
    final weight = (watched ? 1 : 0) + (saved ? 1 : 0) + (liked ? 1 : 0);
    final times = [?item.lastWatched, if (saved) ?item.addedAt];
    sources.add(
      ForYouSource(
        id: item.id,
        type: item.type,
        name: item.name,
        weight: weight,
        reason: liked
            ? ForYouReason.liked
            : watched
            ? ForYouReason.watched
            : ForYouReason.saved,
        recency: times.isEmpty
            ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
            : times.reduce((a, b) => a.isAfter(b) ? a : b),
      ),
    );
  }
  sources.sort(_heavierThenLater);
  return sources;
}

int _heavierThenLater(ForYouSource a, ForYouSource b) {
  final byWeight = b.weight.compareTo(a.weight);
  if (byWeight != 0) return byWeight;
  final byTime = b.recency.compareTo(a.recency);
  return byTime != 0 ? byTime : a.id.compareTo(b.id);
}

/// A title named in one or more sources' answers, before the catalogue has
/// confirmed it.
final class ForYouCandidate {
  ForYouCandidate(this.suggestion);

  /// The first naming of it, by the heaviest source: what is resolved.
  final SuggestedTitle suggestion;

  /// The sum of the weights of every source that named it.
  int score = 0;

  /// Its best place in any one answer, 0 first.
  int bestRank = 1 << 30;

  /// The latest of the sources that named it.
  DateTime latest = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  /// The heaviest source that named it (the latest of equals): whose name
  /// is on the reason line.
  late ForYouSource because;

  /// The key two namings of one title share: the title as matching reads
  /// it, and the year.
  String get key => keyOf(suggestion);

  static String keyOf(SuggestedTitle suggestion) =>
      '${similarTitleKey(suggestion.title)}|${suggestion.year}';

  @override
  String toString() => 'ForYouCandidate(${suggestion.title}, $score)';
}

/// Every title [answers] name, ranked: by the summed weight of the sources
/// that named it, then by its best place in an answer (the first named is
/// the best), then by the latest of those sources, then by title.
///
/// [answers] is each source's suggestions in the model's own order.
List<ForYouCandidate> rankForYou(
  List<ForYouSource> sources,
  Map<String, List<SuggestedTitle>> answers,
) {
  final byKey = <String, ForYouCandidate>{};
  for (final source in sources) {
    final answer = answers[source.id];
    if (answer == null) continue;
    final counted = <String>{};
    for (final (rank, suggestion) in answer.indexed) {
      final key = ForYouCandidate.keyOf(suggestion);
      // A model that names one title twice is one vote from that source.
      if (!counted.add(key)) continue;
      final candidate = byKey[key] ??= (ForYouCandidate(suggestion)
        ..because = source);
      candidate.score += source.weight;
      if (rank < candidate.bestRank) candidate.bestRank = rank;
      if (source.recency.isAfter(candidate.latest)) {
        candidate.latest = source.recency;
      }
      if (_heavierThenLater(source, candidate.because) < 0) {
        candidate.because = source;
      }
    }
  }
  final ranked = byKey.values.toList()
    ..sort((a, b) {
      var order = b.score.compareTo(a.score);
      if (order == 0) order = a.bestRank.compareTo(b.bestRank);
      if (order == 0) order = b.latest.compareTo(a.latest);
      if (order == 0) {
        order = a.suggestion.title.compareTo(b.suggestion.title);
      }
      return order;
    });
  return ranked;
}

/// A title the row shows: the catalogue's item, and why.
final class ForYouTitle {
  const ForYouTitle({
    required this.item,
    required this.reason,
    required this.because,
  });

  final MetaItemPreview item;
  final ForYouReason reason;

  /// The source's name.
  final String because;

  String get reasonLine => reason.line(because);

  /// What the row's cache keeps: the item's own fields a tile draws, and
  /// the reason.
  Map<String, Object?> toJson() => {
    'item': {
      for (final key in const [
        'id',
        'type',
        'name',
        'poster',
        'posterShape',
        'releaseInfo',
      ])
        if (item.json[key] != null) key: item.json[key],
    },
    'reason': reason.name,
    'because': because,
  };

  static ForYouTitle? fromJson(Object? json) {
    if (json is! Map) return null;
    final item = json['item'];
    final reason = ForYouReason.parse(json['reason']);
    final because = json['because'];
    if (item is! Map || reason == null || because is! String) return null;
    if (item['id'] is! String || item['type'] is! String) return null;
    return ForYouTitle(
      item: MetaItemPreview(Map<String, dynamic>.from(item)),
      reason: reason,
      because: because,
    );
  }

  @override
  String toString() => 'ForYouTitle(${item.id}, $reasonLine)';
}
