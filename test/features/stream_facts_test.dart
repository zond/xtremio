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

  group('the sort', () {
    test('is resolution first, highest first', () {
      final order = [
        facts(resolution: StreamResolution.sd480),
        facts(resolution: StreamResolution.uhd2160),
        facts(resolution: StreamResolution.hd720),
        facts(resolution: StreamResolution.fhd1080),
      ];
      expect(sortedByStreamFacts(order, (f) => f).map((f) => f.resolution), [
        StreamResolution.uhd2160,
        StreamResolution.fhd1080,
        StreamResolution.hd720,
        StreamResolution.sd480,
      ]);
    });

    test('then seeders, when both are known', () {
      final a = facts(resolution: StreamResolution.fhd1080, seeders: 3);
      final b = facts(resolution: StreamResolution.fhd1080, seeders: 90);
      expect(compareStreamFacts(b, a), lessThan(0));
      expect(compareStreamFacts(a, b), greaterThan(0));
    });

    test('then size, largest first', () {
      final a = facts(resolution: StreamResolution.fhd1080, sizeBytes: 1 * gb);
      final b = facts(resolution: StreamResolution.fhd1080, sizeBytes: 8 * gb);
      expect(compareStreamFacts(b, a), lessThan(0));
    });

    test('seeders outrank size', () {
      final many = facts(seeders: 90, sizeBytes: 1 * gb);
      final big = facts(seeders: 3, sizeBytes: 8 * gb);
      expect(compareStreamFacts(many, big), lessThan(0));
    });

    test('an unknown resolution is a bucket after every known one', () {
      final unknown = facts(seeders: 900, sizeBytes: 20 * gb);
      final lowest = facts(resolution: StreamResolution.sd240);
      expect(compareStreamFacts(lowest, unknown), lessThan(0));
      expect(compareStreamFacts(unknown, lowest), greaterThan(0));
      // Two unknowns are equal to each other, not ordered by accident.
      expect(compareStreamFacts(unknown, facts()), 0);
    });

    test('an unknown seeder count or size never moves a stream: the tie '
        'falls through instead', () {
      final known = facts(resolution: StreamResolution.fhd1080, seeders: 5);
      final noSeeders = facts(resolution: StreamResolution.fhd1080);
      expect(compareStreamFacts(known, noSeeders), 0);
      expect(compareStreamFacts(noSeeders, known), 0);

      // With seeders unknown on one side the size still decides.
      final small = facts(
        resolution: StreamResolution.fhd1080,
        seeders: 500,
        sizeBytes: 1 * gb,
      );
      final large = facts(
        resolution: StreamResolution.fhd1080,
        sizeBytes: 9 * gb,
      );
      expect(compareStreamFacts(large, small), lessThan(0));
    });

    test('is reflexive and symmetric on every pair', () {
      final all = [
        facts(),
        facts(resolution: StreamResolution.uhd2160),
        facts(resolution: StreamResolution.fhd1080, seeders: 1),
        facts(resolution: StreamResolution.fhd1080, sizeBytes: 1),
        facts(seeders: 7, sizeBytes: 2),
      ];
      for (final a in all) {
        expect(compareStreamFacts(a, a), 0);
        for (final b in all) {
          expect(
            compareStreamFacts(a, b).sign,
            -compareStreamFacts(b, a).sign,
            reason: '$a vs $b',
          );
        }
      }
    });

    test('is stable: equal streams keep the order the engine gave them', () {
      // Six streams the comparator cannot tell apart at all.
      final items = [for (var i = 0; i < 6; i++) i];
      expect(sortedByStreamFacts(items, (_) => facts()), items);

      // And equal within a tier, below one that outranks them.
      final tiers = [
        ('a', facts(resolution: StreamResolution.fhd1080)),
        ('b', facts(resolution: StreamResolution.fhd1080)),
        ('top', facts(resolution: StreamResolution.uhd2160)),
        ('c', facts(resolution: StreamResolution.fhd1080)),
      ];
      expect(sortedByStreamFacts(tiers, (e) => e.$2).map((e) => e.$1), [
        'top',
        'a',
        'b',
        'c',
      ]);
    });

    test('sorting an empty or single list is the list', () {
      expect(sortedByStreamFacts(<int>[], (_) => facts()), isEmpty);
      expect(sortedByStreamFacts([1], (_) => facts()), [1]);
    });
  });
}
