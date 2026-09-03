import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/stream_facts.dart';

import '../support/fixtures.dart';

/// One row of the parser table: a stream as an addon would send it, and
/// what should be read out of it.
typedef Row = ({
  String why,
  Map<String, dynamic> stream,
  StreamResolution? resolution,
  int? size,
  int? seeders,
  List<String> tags,
});

Row row(
  String why, {
  required Map<String, dynamic> stream,
  StreamResolution? resolution,
  int? size,
  int? seeders,
  List<String> tags = const [],
}) => (
  why: why,
  stream: stream,
  resolution: resolution,
  size: size,
  seeders: seeders,
  tags: tags,
);

const int kb = 1024;
const int mb = 1024 * 1024;
const int gb = 1024 * 1024 * 1024;

StreamFacts facts({
  StreamResolution? resolution,
  int? sizeBytes,
  int? seeders,
}) =>
    StreamFacts(resolution: resolution, sizeBytes: sizeBytes, seeders: seeders);

void main() {
  group('parses', () {
    final rows = <Row>[
      row(
        'the recorded public-domain fixture: a name that is only the '
        'resolution, and the 💾 convention in the description',
        stream: {
          'infoHash': '11ea02584fa6351956f35671962ab46354d99060',
          'fileIdx': 0,
          'name': '1080p',
          'description': '💾 1.51 GB',
        },
        resolution: StreamResolution.fhd1080,
        size: 1621350154,
      ),
      row(
        'a Torrentio-shaped answer: seeders and size in one description '
        'line, the release in the filename',
        stream: {
          'infoHash': 'a' * 40,
          'name': 'Torrentio\n1080p',
          'description':
              'Breaking.Bad.S01E01.1080p.WEB-DL.x265.mkv\n'
              '👤 42 💾 1.51 GB ⚙️ ThePirateBay',
          'behaviorHints': {
            'filename': 'Breaking.Bad.S01E01.1080p.WEB-DL.x265.mkv',
          },
        },
        resolution: StreamResolution.fhd1080,
        size: 1621350154,
        seeders: 42,
        tags: ['WEB-DL', 'HEVC'],
      ),
      row(
        'videoSize beats the text, because it is the structured field',
        stream: {
          'infoHash': 'b' * 40,
          'name': '2160p',
          'description': '💾 1.51 GB',
          'behaviorHints': {'videoSize': 25000000000},
        },
        resolution: StreamResolution.uhd2160,
        size: 25000000000,
      ),
      row(
        'a videoSize of zero is not a size: nothing is known, and the text '
        'has nothing either',
        stream: {
          'infoHash': 'c' * 40,
          'name': 'Some release',
          'behaviorHints': {'videoSize': 0},
        },
      ),
      row(
        '4K and UHD are the 2160p rung',
        stream: {'infoHash': 'd' * 40, 'name': 'Torrentio\n4k HDR DV'},
        resolution: StreamResolution.uhd2160,
        tags: ['HDR', 'DV'],
      ),
      row(
        'the binge group carries the resolution when nothing else does',
        stream: {
          'infoHash': 'e' * 40,
          'name': 'Public Domain Movies',
          'behaviorHints': {'bingeGroup': 'pdm-1080p'},
        },
        resolution: StreamResolution.fhd1080,
      ),
      row(
        'a filename with dimensions instead of a rung name',
        stream: {
          'url': 'https://example.test/a.mkv',
          'name': 'Direct',
          'behaviorHints': {'filename': 'movie.1920x1080.BluRay.REMUX.mkv'},
        },
        resolution: StreamResolution.fhd1080,
        tags: ['REMUX', 'BluRay'],
      ),
      row(
        'a spelled-out seeder count, and a size written without a space',
        stream: {
          'infoHash': 'f' * 40,
          'name': '720p',
          'description': 'Seeders: 7 | 700MB | HDTV',
        },
        resolution: StreamResolution.hd720,
        size: 700 * mb,
        seeders: 7,
        tags: ['HDTV'],
      ),
      row(
        'a comma decimal and a binary unit',
        stream: {
          'infoHash': '1' * 40,
          'name': '480p DVDRip',
          'description': '1,5 GiB · 3 seeders',
        },
        resolution: StreamResolution.sd480,
        size: 1610612736,
        seeders: 3,
        tags: ['DVDRip'],
      ),
      row(
        'a stream with none of it: everything stays unknown rather than '
        'becoming zero',
        stream: {
          'url': 'https://example.test/stream.m3u8',
          'name': 'Some channel',
          'description': 'Live now',
        },
      ),
      row(
        'a bare number with no unit is not a size, and a resolution '
        'without its p is not a resolution',
        stream: {
          'infoHash': '2' * 40,
          'name': 'Release 2160 of 4400',
          'description': 'Season 1 · 5.1 audio',
        },
      ),
      row(
        'the whole tag table, canonically spelled and in table order '
        'whatever order the addon wrote them in',
        stream: {
          'infoHash': '3' * 40,
          'name': 'x264 ATMOS proper 10bit',
          'description': 'WEBRip DTS-HD BDRip CAM AV1 REMUX',
        },
        tags: [
          'REMUX',
          'BDRip',
          'WEBRip',
          'CAM',
          'AVC',
          'AV1',
          '10bit',
          'Atmos',
          'DTS',
          'PROPER',
        ],
      ),
    ];

    for (final row in rows) {
      test(row.why, () {
        final parsed = StreamFacts.of(StreamInfo(row.stream));
        expect(parsed.resolution, row.resolution, reason: 'resolution');
        expect(parsed.sizeBytes, row.size, reason: 'size');
        expect(parsed.seeders, row.seeders, reason: 'seeders');
        expect(parsed.tags, row.tags, reason: 'tags');
      });
    }

    test('the source kind and the addon name come from outside the text', () {
      final torrent = StreamFacts.of(
        StreamInfo({'infoHash': 'a' * 40}),
        addonName: 'Torrentio',
      );
      expect(torrent.sourceKind, StreamKind.torrent);
      expect(torrent.addonName, 'Torrentio');

      // A source the engine cannot place is a null kind, not a
      // `StreamKind.unknown` badge.
      final nothing = StreamFacts.of(StreamInfo(const {'name': 'x'}));
      expect(nothing.sourceKind, isNull);
      expect(nothing.addonName, isNull);
    });

    test('every stream of the recorded fixture parses without throwing', () {
      final state = MetaDetailsState.fromJson(loadMetaDetailsFixture());
      final all = [
        for (final group in state.allStreamGroups)
          for (final stream in group.streams)
            StreamFacts.of(stream, addonName: group.addonLabel),
      ];
      expect(all, isNotEmpty);
      // The public-domain torrent is the one thing in there with facts.
      final known = all.where((f) => f.resolution != null).toList();
      expect(known, hasLength(1));
      expect(known.single.resolution, StreamResolution.fhd1080);
      expect(known.single.sizeBytes, 1621350154);
      expect(known.single.seeders, isNull, reason: 'that addon says none');
    });
  });

  group('badges', () {
    test('name only what is known, in display order', () {
      expect(
        facts(
          resolution: StreamResolution.uhd2160,
          sizeBytes: 3 * gb,
          seeders: 42,
        ).badges,
        ['2160p', '3 GB', '42 seeders'],
      );
      expect(facts(sizeBytes: 700 * mb).badges, ['700 MB']);
      expect(facts().badges, isEmpty);
      expect(facts(seeders: 1).badges, ['1 seeder']);
      expect(facts(seeders: 0).badges, ['0 seeders']);
    });

    test('sizes read the way the addons write them', () {
      expect(StreamFacts.formatSize(null), isNull);
      expect(StreamFacts.formatSize(512), '512 B');
      expect(StreamFacts.formatSize(4 * kb), '4 KB');
      expect(StreamFacts.formatSize(1621350154), '1.51 GB');
      expect(StreamFacts.formatSize(700 * gb), '700 GB');
      // A fraction that is all zeros is dropped rather than padded.
      expect(StreamFacts.formatSize(20 * gb), '20 GB');
      expect(StreamFacts.formatSize((1.5 * gb).round()), '1.5 GB');
    });
  });

  group('the order inside a section', () {
    /// The three orders over the same five streams, by their labels.
    List<String> ordered(
      List<(String, StreamFacts)> streams,
      StreamOrder order,
    ) => [
      for (final entry in sortedByStreamOrder(streams, (e) => e.$2, order))
        entry.$1,
    ];

    test('peers per megabyte is the smallest size ÷ peers first', () {
      final streams = [
        ('2 GB, 10 peers', facts(sizeBytes: 2 * gb, seeders: 10)),
        ('8 GB, 200 peers', facts(sizeBytes: 8 * gb, seeders: 200)),
        ('700 MB, 2 peers', facts(sizeBytes: 700 * mb, seeders: 2)),
      ];
      // 8 GB ÷ 200 is 41 MB a peer, 2 GB ÷ 10 is 205, 700 MB ÷ 2 is 350:
      // the biggest file wins because it also has the deepest swarm, which
      // is the whole point of the ratio.
      expect(ordered(streams, StreamOrder.peersPerSize), [
        '8 GB, 200 peers',
        '2 GB, 10 peers',
        '700 MB, 2 peers',
      ]);
      // And the other two orders disagree with it, each in its own way.
      expect(ordered(streams, StreamOrder.largest).first, '8 GB, 200 peers');
      expect(ordered(streams, StreamOrder.mostPeers), [
        '8 GB, 200 peers',
        '2 GB, 10 peers',
        '700 MB, 2 peers',
      ]);
    });

    test('the biggest file does not win on size alone', () {
      final streams = [
        ('20 GB, 3 peers', facts(sizeBytes: 20 * gb, seeders: 3)),
        ('2 GB, 100 peers', facts(sizeBytes: 2 * gb, seeders: 100)),
      ];
      expect(
        ordered(streams, StreamOrder.peersPerSize).first,
        '2 GB, 100 peers',
      );
      expect(ordered(streams, StreamOrder.largest).first, '20 GB, 3 peers');
    });

    test('a stream missing either number sorts after every ranked one, and '
        'is never read as a zero', () {
      final noSize = facts(seeders: 500);
      final noPeers = facts(sizeBytes: 700 * mb);
      final neither = facts();
      // The worst ranked stream there is -- 20 GB for a single peer -- is
      // still ahead of all three, which a zero size or a zero peer count
      // would not be.
      final ranked = facts(sizeBytes: 20 * gb, seeders: 1);
      for (final unranked in [noSize, noPeers, neither]) {
        expect(
          compareStreamOrder(ranked, unranked, StreamOrder.peersPerSize),
          lessThan(0),
        );
        expect(
          compareStreamOrder(unranked, ranked, StreamOrder.peersPerSize),
          greaterThan(0),
        );
      }
      // Nor is an unranked one *best*: it does not lead the list either.
      expect(
        ordered([
          ('unknown', neither),
          ('known', ranked),
        ], StreamOrder.peersPerSize),
        ['known', 'unknown'],
      );
      // Two unranked streams are equal, so they keep the addons' order.
      expect(compareStreamOrder(noSize, noPeers, StreamOrder.peersPerSize), 0);
    });

    test('a known-empty swarm is ranked, and ranked last', () {
      // Zero peers is measured, not missing: size ÷ 0 is the worst ratio
      // there is, which puts it behind every stream anyone is seeding and
      // still ahead of the ones nobody described.
      final empty = facts(sizeBytes: 700 * mb, seeders: 0);
      final seeded = facts(sizeBytes: 20 * gb, seeders: 1);
      final unknown = facts(sizeBytes: 700 * mb);
      expect(
        compareStreamOrder(seeded, empty, StreamOrder.peersPerSize),
        lessThan(0),
      );
      expect(
        compareStreamOrder(empty, unknown, StreamOrder.peersPerSize),
        lessThan(0),
      );
    });

    test('largest and most peers put their own unknown last', () {
      final big = facts(sizeBytes: 8 * gb);
      final small = facts(sizeBytes: 1 * gb, seeders: 900);
      expect(compareStreamOrder(big, small, StreamOrder.largest), lessThan(0));
      // Size unknown: after both, even with the deepest swarm on the list.
      final noSize = facts(seeders: 9000);
      expect(
        compareStreamOrder(noSize, small, StreamOrder.largest),
        greaterThan(0),
      );
      expect(
        compareStreamOrder(noSize, small, StreamOrder.mostPeers),
        lessThan(0),
      );
      // Peers unknown: after both under most peers, ranked under largest.
      expect(
        compareStreamOrder(big, small, StreamOrder.mostPeers),
        greaterThan(0),
      );
    });

    test('a tie falls through to the order the addons gave', () {
      // The same ratio, differently spelled: 2 GB for 10 peers and 1 GB
      // for 5 is 205 MB a peer either way.
      final tied = [
        ('first', facts(sizeBytes: 2 * gb, seeders: 10)),
        ('second', facts(sizeBytes: 1 * gb, seeders: 5)),
      ];
      expect(ordered(tied, StreamOrder.peersPerSize), ['first', 'second']);
      expect(ordered(tied.reversed.toList(), StreamOrder.peersPerSize), [
        'second',
        'first',
      ]);
      // And streams the order cannot tell apart at all keep their places.
      final items = [for (var i = 0; i < 6; i++) i];
      for (final order in StreamOrder.values) {
        expect(sortedByStreamOrder(items, (_) => facts(), order), items);
      }
    });

    test('is reflexive and symmetric on every pair, in every order', () {
      final all = [
        facts(),
        facts(sizeBytes: 1 * gb),
        facts(seeders: 7),
        facts(sizeBytes: 1 * gb, seeders: 0),
        facts(sizeBytes: 20 * gb, seeders: 3),
        facts(sizeBytes: 2 * gb, seeders: 100),
      ];
      for (final order in StreamOrder.values) {
        for (final a in all) {
          expect(compareStreamOrder(a, a, order), 0);
          for (final b in all) {
            expect(
              compareStreamOrder(a, b, order).sign,
              -compareStreamOrder(b, a, order).sign,
              reason: '$a vs $b in $order',
            );
          }
        }
      }
    });

    test('sorting an empty or single list is the list', () {
      expect(
        sortedByStreamOrder(<int>[], (_) => facts(), StreamOrder.largest),
        isEmpty,
      );
      expect(sortedByStreamOrder([1], (_) => facts(), StreamOrder.largest), [
        1,
      ]);
    });
  });

  group('the sections', () {
    test('are one per resolution, highest first, unknown last', () {
      final rows = [
        ('a', facts(resolution: StreamResolution.hd720)),
        ('b', facts()),
        ('c', facts(resolution: StreamResolution.uhd2160)),
        ('d', facts(resolution: StreamResolution.hd720)),
        ('e', facts(resolution: StreamResolution.fhd1080)),
      ];
      final sections = sectionsByResolution(rows, (row) => row.$2);
      expect(sections.map((s) => s.label), [
        '2160p',
        '1080p',
        '720p',
        'Unknown resolution',
      ]);
      // Within a section the rows keep the order they arrived in, which is
      // the order the chosen sort left them in.
      expect(sections[2].rows.map((row) => row.$1), ['a', 'd']);
      // A resolution nobody offered is not an empty section.
      expect(
        sections.map((s) => s.resolution),
        isNot(contains(StreamResolution.sd480)),
      );
    });

    test('a collapsed header can still say how many and how healthy', () {
      final sections = sectionsByResolution([
        facts(resolution: StreamResolution.uhd2160, seeders: 3),
        facts(resolution: StreamResolution.uhd2160, seeders: 137),
        facts(resolution: StreamResolution.uhd2160),
        facts(resolution: StreamResolution.fhd1080, seeders: 1),
        facts(resolution: StreamResolution.hd720),
      ], (f) => f);
      expect(sections[0].summary, '3 streams · best 137 seeders');
      expect(sections[1].summary, '1 stream · best 1 seeder');
      // Nobody said, which is not the same as nobody being there.
      expect(sections[2].bestSeeders, isNull);
      expect(sections[2].summary, '1 stream · seeders unknown');
    });

    test('no rows are no sections', () {
      expect(sectionsByResolution(<StreamFacts>[], (f) => f), isEmpty);
    });
  });
}
