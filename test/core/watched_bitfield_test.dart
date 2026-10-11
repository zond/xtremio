import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

/// The port of stremio-core's `WatchedBitField` reads, held to the fields
/// stremio-core's own tests write (`stremio-watched-bitfield`,
/// `watched_bitfield.rs`, in the pinned stremio-core).
void main() {
  List<String> episodes(String show, int seasons, int each) => [
    for (var s = 1; s <= seasons; s++)
      for (var e = 1; e <= each; e++) '$show:$s:$e',
  ];

  test("stremio-core's parse_and_modify field: the first five", () {
    final videos = episodes('tt2934286', 1, 9);
    expect(watchedVideoIds('tt2934286:1:5:5:eJyTZwAAAEAAIA==', videos), {
      for (var e = 1; e <= 5; e++) 'tt2934286:1:$e',
    });
  });

  test("stremio-core's de/serialize field: three whole seasons of eight", () {
    final videos = episodes('tt7767422', 4, 8);
    final watched = watchedVideoIds(
      'tt7767422:3:8:24:eJz7//8/AAX9Av4=',
      videos,
    );
    expect(watched, hasLength(24));
    expect(watched, containsAll(episodes('tt7767422', 3, 8)));
    expect(watched, isNot(contains('tt7767422:4:1')));
  });

  test('a list that grew in front is read shifted by where the anchor '
      'moved', () {
    // A special listed ahead of season 1 since the field was written: the
    // bits move one along, as `construct_with_videos` moves them.
    final videos = ['tt7767422:0:1', ...episodes('tt7767422', 4, 8)];
    final watched = watchedVideoIds(
      'tt7767422:3:8:24:eJz7//8/AAX9Av4=',
      videos,
    );
    expect(watched, hasLength(24));
    expect(watched, isNot(contains('tt7767422:0:1')));
    expect(watched, contains('tt7767422:3:8'));
  });

  test('an anchor the list no longer has, or a field that is not one, is '
      'nothing watched', () {
    final videos = episodes('tt1', 1, 3);
    expect(watchedVideoIds('tt9:1:1:1:eJyTZwAAAEAAIA==', videos), isEmpty);
    expect(watchedVideoIds('undefined:1:eJwDAAAAAAE=', videos), isEmpty);
    expect(watchedVideoIds('tt1:1:1:x:eJyTZwAAAEAAIA==', videos), isEmpty);
    expect(watchedVideoIds('tt1:1:1:1:not base64!', videos), isEmpty);
    expect(watchedVideoIds(null, videos), isEmpty);
  });

  test('videos are ordered as stremio-core orders them: season, episode, '
      'release, missing first', () {
    MetaVideo v(String id, int? s, int? e, [String? at]) => (
      id: id,
      season: s,
      episode: e,
      released: at == null ? null : DateTime.parse(at),
    );
    final sorted = sortedVideos([
      v('b', 1, 2),
      v('a', 1, 1),
      v('special', 0, 1),
      v('none', null, null),
      v('later', 2, 1, '2021-01-01'),
      v('earlier', 2, 1, '2020-01-01'),
    ]);
    expect(
      [for (final video in sorted) video.id],
      ['none', 'special', 'a', 'b', 'earlier', 'later'],
    );
  });

  test('a Cinemeta meta answer is its videos in that order, with seasons', () {
    final episodes = episodesInMeta({
      'meta': {
        'videos': [
          {'id': 'tt1:1:2', 'season': 1, 'episode': 2},
          {'id': 'tt1:1:1', 'season': 1, 'number': 1},
          {'id': 'tt1:0:1', 'season': 0, 'episode': 1},
          {'no': 'id'},
        ],
      },
    });
    expect(episodes, [
      (id: 'tt1:0:1', season: 0),
      (id: 'tt1:1:1', season: 1),
      (id: 'tt1:1:2', season: 1),
    ]);
    expect(episodesInMeta({'meta': {}}), isNull);
    final memory = ShowEpisodesMemory.empty.remembering('tt1', episodes!);
    expect(ShowEpisodesMemory.fromJson(memory.toJson()).of('tt1'), episodes);
  });
}
