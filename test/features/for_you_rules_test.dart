import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/for_you/for_you_rules.dart';

import '../support/library_items.dart';

/// The For you row's rules as functions: which titles are sources and how
/// much each weighs, when a series counts as watched through, and how what
/// the sources' answers name is ranked.
void main() {
  /// Three seasons of four, `tt9:s:e`.
  final show = [
    for (var s = 1; s <= 3; s++)
      for (var e = 1; e <= 4; e++) (id: 'tt9:$s:$e', season: s),
  ];

  group('a series is watched through', () {
    test('once one whole season is, whichever', () {
      expect(
        seriesWatchedThrough(show, {for (var e = 1; e <= 4; e++) 'tt9:2:$e'}),
        isTrue,
      );
      expect(
        seriesWatchedThrough(show, {'tt9:1:1', 'tt9:1:2', 'tt9:1:3'}),
        isFalse,
        reason: 'three of four is not a season',
      );
      expect(
        seriesWatchedThrough(show, {'tt9:1:4', 'tt9:2:4', 'tt9:3:4'}),
        isFalse,
        reason: 'a finale of each is not a season either',
      );
    });

    test('specials are never a season of their own', () {
      final withSpecials = [(id: 'tt9:0:1', season: 0), ...show];
      expect(seriesWatchedThrough(withSpecials, {'tt9:0:1'}), isFalse);
    });

    test('a show with no numbered seasons counts when all of it is', () {
      final miniseries = [(id: 'm:1', season: null), (id: 'm:2', season: null)];
      expect(seriesWatchedThrough(miniseries, {'m:1', 'm:2'}), isTrue);
      expect(seriesWatchedThrough(miniseries, {'m:1'}), isFalse);
      final specialsOnly = [(id: 's:0:1', season: 0)];
      expect(seriesWatchedThrough(specialsOnly, {'s:0:1'}), isTrue);
      expect(seriesWatchedThrough(const [], const {}), isFalse);
    });

    test('read off the item\'s own watched field', () {
      // Season 2 whole: bits 4..7, anchored on its last episode.
      final whole = LibraryItemView(
        libraryItemJson(
          'tt9',
          type: 'series',
          watched: 'tt9:2:4:8:eJz7wAAAAeIA8Q==',
        ),
      );
      final partial = LibraryItemView(
        libraryItemJson(
          'tt9',
          type: 'series',
          watched: 'tt9:2:3:7:eJwrYAAAAOIAcQ==',
        ),
      );
      expect(libraryItemWatchedThrough(whole, show), isTrue);
      expect(libraryItemWatchedThrough(partial, show), isFalse);
    });
  });

  group('sources', () {
    List<ForYouSource> sourcesOf(
      List<Map<String, dynamic>> items, {
      Faces faces = Faces.empty,
      Set<String> watchedThrough = const {},
    }) => forYouSources(
      [for (final item in items) LibraryItemView(item)],
      faces,
      watchedThrough: (series) => watchedThrough.contains(series.id),
    );

    test('a watched film, a watched-through series and a title added by '
        'hand are sources; a title in both counts twice', () {
      final sources = sourcesOf(
        [
          libraryItemJson(
            'tt-played',
            temp: true,
            removed: true,
            timesWatched: 1,
          ),
          libraryItemJson(
            'tt-flagged',
            temp: true,
            removed: true,
            flaggedWatched: 1,
          ),
          libraryItemJson('tt-saved'),
          libraryItemJson('tt-both', timesWatched: 2),
          libraryItemJson('tt-show', type: 'series', temp: true, removed: true),
          libraryItemJson(
            'tt-started',
            temp: true,
            removed: true,
            timeOffset: 5,
          ),
          libraryItemJson('tt-removed', removed: true),
          libraryItemJson('tt-other', type: 'tv', timesWatched: 1),
        ],
        watchedThrough: {'tt-show'},
      );
      expect(
        {for (final s in sources) s.id: s.weight},
        {
          'tt-both': 2,
          'tt-played': 1,
          'tt-flagged': 1,
          'tt-saved': 1,
          'tt-show': 1,
        },
      );
      final byId = {for (final s in sources) s.id: s};
      expect(byId['tt-both']!.reason, ForYouReason.watched);
      expect(byId['tt-saved']!.reason, ForYouReason.saved);
      expect(byId['tt-show']!.type, 'series');
    });

    test('a happy face adds one and names the reason; a sad face takes the '
        'title out whatever it is', () {
      final faces = Faces.empty
          .marking('tt-liked', Face.like, DateTime.utc(2026))
          .marking('tt-hated', Face.dislike, DateTime.utc(2026))
          .marking('tt-dismissed', Face.dismissed, DateTime.utc(2026));
      final sources = sourcesOf([
        libraryItemJson('tt-liked', timesWatched: 1),
        libraryItemJson('tt-hated', timesWatched: 3),
        libraryItemJson('tt-dismissed'),
        libraryItemJson('tt-liked-only', temp: true, removed: true),
      ], faces: faces);
      expect(
        {for (final s in sources) s.id: s.weight},
        {'tt-liked': 3, 'tt-dismissed': 1},
      );
      expect(sources.first.reason, ForYouReason.liked);
    });

    test('heavier first, then the latest watched or added', () {
      final sources = sourcesOf([
        libraryItemJson('old', added: '2026-01-01T00:00:00Z'),
        libraryItemJson(
          'new',
          temp: true,
          removed: true,
          timesWatched: 1,
          lastWatched: '2026-06-01T00:00:00Z',
        ),
        libraryItemJson('heavy', timesWatched: 1),
      ]);
      expect([for (final s in sources) s.id], ['heavy', 'new', 'old']);
    });
  });

  group('ranking', () {
    ForYouSource source(String id, int weight, String at) => ForYouSource(
      id: id,
      type: 'movie',
      name: 'Name $id',
      weight: weight,
      reason: ForYouReason.watched,
      recency: DateTime.parse(at),
    );
    SuggestedTitle t(String title, [int year = 2000]) =>
        SuggestedTitle(title: title, year: year, why: '');

    test('by the summed weight of the sources that named it, then its best '
        'place, then the latest source', () {
      final a = source('a', 2, '2026-01-01');
      final b = source('b', 1, '2026-05-01');
      final c = source('c', 1, '2026-03-01');
      final ranked = rankForYou(
        [a, b, c],
        {
          'a': [t('Alpha'), t('Shared'), t('Tie A')],
          'b': [t('Shared'), t('Zed'), t('Late')],
          'c': [t('The Shared'), t('Ant')],
        },
      );
      final order = [for (final c in ranked) c.suggestion.title];
      // Shared: 2 + 1 + 1 (the article is not part of the key) = 4.
      expect(order.first, 'Shared');
      expect(ranked.first.score, 4);
      // Alpha and Tie A weigh 2; Alpha is named first.
      expect(order.sublist(1, 3), ['Alpha', 'Tie A']);
      // Weight 1, place 1: Zed's source is the latest, whatever the
      // alphabet says.
      expect(order.sublist(3, 5), ['Zed', 'Ant']);
      expect(order.last, 'Late');
      // The reason is the heaviest source that named it.
      expect(ranked.first.because.id, 'a');
    });

    test('a title named twice in one answer is one vote', () {
      final ranked = rankForYou(
        [source('a', 1, '2026-01-01')],
        {
          'a': [t('Twice'), t('Twice')],
        },
      );
      expect(ranked.single.score, 1);
    });

    test('a different year is a different title', () {
      final ranked = rankForYou(
        [source('a', 1, '2026-01-01'), source('b', 1, '2026-02-01')],
        {
          'a': [t('Heat', 1995)],
          'b': [t('Heat', 2013)],
        },
      );
      expect(ranked, hasLength(2));
    });
  });

  test('the reason line', () {
    expect(ForYouReason.watched.line('Alien'), 'Because you watched Alien');
    expect(ForYouReason.saved.line('Alien'), 'Because you saved Alien');
    expect(ForYouReason.liked.line('Alien'), 'Because you liked Alien');
  });

  test('a source line says in words what it counted for', () {
    ForYouContribution c(bool w, bool s, bool l) => (
      id: 'tt0113277',
      type: 'movie',
      name: 'Heat',
      watched: w,
      saved: s,
      liked: l,
      weight: [w, s, l].where((x) => x).length,
    );
    expect(forYouContributionLine(c(true, false, false)), 'Watched: Heat');
    expect(forYouContributionLine(c(false, true, false)), 'Saved: Heat');
    expect(
      forYouContributionLine(c(true, true, false)),
      'Watched and saved: Heat (×2)',
    );
    expect(
      forYouContributionLine(c(true, true, true)),
      'Watched, saved and liked: Heat (×3)',
    );
    expect(forYouPoints(1), '1 point');
    expect(forYouPoints(5), '5 points');
  });

  test('a candidate keeps every source that named it, strongest first, '
      'and a kept title reads them back', () {
    ForYouSource source(String id, int weight, String at) => ForYouSource(
      id: id,
      type: 'movie',
      name: 'Name $id',
      weight: weight,
      reason: ForYouReason.watched,
      recency: DateTime.parse(at),
      watched: true,
      saved: weight > 1,
      liked: weight > 2,
    );
    const pick = SuggestedTitle(title: 'Pick', year: 2000, why: '');
    final ranked = rankForYou(
      [
        source('one', 1, '2026-01-01'),
        source('three', 3, '2026-01-01'),
        source('two', 2, '2026-02-01'),
      ],
      {
        'one': [pick],
        'three': [pick],
        'two': [pick],
      },
    );
    expect(
      [for (final s in ranked.single.sources) s.id],
      ['three', 'two', 'one'],
    );
    final title = ForYouTitle(
      item: const MetaItemPreview({'id': 'tt1', 'type': 'movie', 'name': 'P'}),
      reason: ForYouReason.liked,
      because: 'Name three',
      sources: [for (final s in ranked.single.sources) s.contribution],
    );
    final back = ForYouTitle.fromJson(title.toJson())!;
    expect(back.sources, title.sources);
    expect(back.points, 6);
  });

  test('a source saved and liked is another source than one watched and '
      'liked, so the kept row is worked out again', () {
    ForYouSource source({required bool watched, required bool saved}) =>
        ForYouSource(
          id: 'tt1',
          type: 'movie',
          name: 'Heat',
          weight: 2,
          reason: ForYouReason.liked,
          recency: DateTime.utc(2026),
          watched: watched,
          saved: saved,
          liked: true,
        );
    expect(
      source(watched: true, saved: false).signature,
      isNot(source(watched: false, saved: true).signature),
    );
  });
}
