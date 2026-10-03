/// How a title scored, as the details header draws it: IMDb, TMDB, Rotten
/// Tomatoes' Tomatometer ("RT") and its Popcornmeter ("Popcorn").
///
/// IMDb comes first and comes at once, from what the addon sent with the
/// title ([MetaItem.imdbRating]); the other three come from the
/// xtremio-xervice server ([RatingsService]) a moment later, or from what
/// this device remembers of the last time. Whatever is known is drawn and
/// nothing waits for the rest: a score the server never sends is a score
/// that is not on the screen, never a gap or a dash.
///
/// The labels are words rather than the sources' logos, which are their
/// owners' marks and not this app's to ship.
library;

import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../ratings/xtremio_ratings.dart';
import 'details_header.dart' show ImdbRating;

/// Supplies where the scores are asked, for the details screen: a test
/// answers what the server would without a network. Absent, the screen
/// asks the xtremio-xervice server ([XtremioRatings]).
class RatingsScope extends InheritedWidget {
  const RatingsScope({super.key, required this.provider, required super.child});

  final RatingsProvider provider;

  static RatingsProvider of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RatingsScope>()?.provider ??
      XtremioRatings();

  @override
  bool updateShouldNotify(RatingsScope oldWidget) =>
      provider != oldWidget.provider;
}

/// One score as it is drawn: the number, and the word that says whose.
typedef ShownScore = ({String label, String value, String spoken});

/// What the header shows, in the order it shows it.
///
/// IMDb is the addon's rating while there is one, and MDBList's only when
/// there is not: the addon's arrives with the page, and a number that
/// changed by a tenth a second later would read as a mistake.
List<ShownScore> shownScores(MetaItem meta, TitleRatings? ratings) {
  final imdb = meta.imdbRating ?? _tenths(ratings?.imdb);
  final tmdb = _tenths(ratings?.tmdb);
  final tomatoes = _percent(ratings?.tomatoes);
  final popcorn = _percent(ratings?.popcorn);
  return [
    if (imdb != null) (label: 'IMDb', value: imdb, spoken: 'IMDb $imdb'),
    if (tmdb != null) (label: 'TMDB', value: tmdb, spoken: 'TMDB $tmdb'),
    if (tomatoes != null)
      (
        label: 'RT',
        value: tomatoes,
        spoken: 'Rotten Tomatoes Tomatometer $tomatoes',
      ),
    if (popcorn != null)
      (
        label: 'Popcorn',
        value: popcorn,
        spoken: 'Rotten Tomatoes Popcornmeter $popcorn',
      ),
  ];
}

String? _tenths(TitleScore? score) => score?.score.toStringAsFixed(1);

String? _percent(TitleScore? score) =>
    score == null ? null : '${score.score.round()}%';

/// The scores on a phone or a desktop: the IMDb rating as it has always
/// been drawn -- a link to the title's page when the addon gave one --
/// and the others after it, each its number and then its word.
class DetailsScores extends StatelessWidget {
  const DetailsScores({super.key, required this.meta, this.ratings});

  final MetaItem meta;

  /// What the server answered, or what is remembered; null while neither
  /// is known.
  final TitleRatings? ratings;

  @override
  Widget build(BuildContext context) {
    final scores = shownScores(meta, ratings);
    if (scores.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 14,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final score in scores)
          if (score.label == 'IMDb')
            ImdbRating(
              rating: score.value,
              // The address only with the addon's own rating: it is never
              // built here out of an id ([ImdbRating]).
              url: meta.imdbRating == null ? null : meta.imdbUrl,
            )
          else
            _Score(score),
      ],
    );
  }
}

class _Score extends StatelessWidget {
  const _Score(this.score);

  final ShownScore score;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: score.spoken,
      excludeSemantics: true,
      child: Padding(
        // The IMDb link's own padding, so the four sit on one baseline.
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(score.value, style: theme.textTheme.labelLarge),
            const SizedBox(width: 4),
            Text(
              score.label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The scores on a television: one line of text, the label before the
/// number -- `IMDb 7.8 · TMDB 7.6 · RT 97% · Popcorn 90%` -- or empty when
/// nothing is known.
///
/// Text and nothing else, deliberately: a score is not a stop. The remote
/// walks every stop between the top of the screen and the rows, and a
/// set-top box has nowhere to open a score's page anyway.
String tvScoresLine(MetaItem meta, TitleRatings? ratings) => [
  for (final score in shownScores(meta, ratings))
    '${score.label} ${score.value}',
].join(' · ');
