import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/fake_prefs_client.dart';

/// Where each title's details screen was left: one row per title, most
/// recent first, bounded, and forgiving of what it reads back.
void main() {
  DetailsVisit visit(
    String meta, {
    int? season,
    String? videoId,
    int day = 1,
  }) => DetailsVisit(
    meta: meta,
    season: season,
    videoId: videoId,
    at: DateTime.utc(2026, 9, day),
  );

  test('a visit replaces the title\'s last and goes to the front', () {
    final memory = DetailsVisitMemory.empty
        .withVisit(visit('a', season: 1))
        .withVisit(visit('b', season: 2))
        .withVisit(visit('a', season: 3, videoId: 'a:3:1'));
    expect([for (final v in memory.visits) v.meta], ['a', 'b']);
    expect(memory.forMeta('a')?.season, 3);
    expect(memory.forMeta('a')?.videoId, 'a:3:1');
    expect(memory.forMeta('c'), isNull);
  });

  test('the title visited longest ago falls off past the limit', () {
    var memory = DetailsVisitMemory.empty;
    for (var i = 0; i <= DetailsVisitMemory.limit; i++) {
      memory = memory.withVisit(visit('t$i'));
    }
    expect(memory.visits, hasLength(DetailsVisitMemory.limit));
    expect(memory.forMeta('t0'), isNull);
    expect(memory.forMeta('t${DetailsVisitMemory.limit}'), isNotNull);
  });

  test('what is written is what is read back', () {
    final memory = DetailsVisitMemory.empty
        .withVisit(visit('a', season: 0, videoId: 'a:0:2', day: 3))
        .withVisit(visit('b'));
    expect(DetailsVisitMemory.fromJson(memory.toJson()), memory);
  });

  test('a row it cannot use is dropped, never a failure', () {
    final memory = DetailsVisitMemory.fromJson({
      'visits': [
        {'meta': 'a', 'at': 1, 'season': 2, 'videoId': 'a:2:1'},
        {'meta': 'a', 'at': 2},
        {'at': 3},
        {'meta': 'b'},
        {'meta': 'c', 'at': 4, 'season': -1, 'videoId': ' '},
        'nonsense',
      ],
    });
    expect([for (final v in memory.visits) v.meta], ['a', 'c']);
    expect(memory.forMeta('a')?.season, 2, reason: 'the first row of a title');
    expect(memory.forMeta('c')?.season, isNull);
    expect(memory.forMeta('c')?.videoId, isNull);
    expect(DetailsVisitMemory.fromJson('nonsense'), DetailsVisitMemory.empty);
  });

  test('the preferences keep it across a load, and tell no listener', () async {
    final client = FakePrefsClient();
    final prefs = AppPrefs(client: client);
    addTearDown(prefs.dispose);
    await prefs.load();
    var told = 0;
    prefs.addListener(() => told++);

    final memory = DetailsVisitMemory.empty.withVisit(
      visit('a', season: 2, videoId: 'a:2:5'),
    );
    await prefs.setDetailsVisits(memory);
    expect(told, 0, reason: 'nothing is drawn from it');
    expect(client.stored, contains(AppPrefs.detailsVisitsKey));

    final again = AppPrefs(client: client);
    addTearDown(again.dispose);
    await again.load();
    expect(again.detailsVisits, memory);

    await again.setDetailsVisits(DetailsVisitMemory.empty);
    expect(client.stored, isNot(contains(AppPrefs.detailsVisitsKey)));
  });
}
