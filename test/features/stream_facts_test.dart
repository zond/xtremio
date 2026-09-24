import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/stream_facts.dart';
import 'package:xtremio/features/details/tv_source_row.dart';

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
  List<String> languages = const [],
  String? tracker,
}) => StreamFacts(
  resolution: resolution,
  sizeBytes: sizeBytes,
  seeders: seeders,
  languages: languages,
  tracker: tracker,
);

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

  group('pills', () {
    test('name only what is known, in display order', () {
      expect(
        facts(
          resolution: StreamResolution.uhd2160,
          sizeBytes: 3 * gb,
          seeders: 42,
          languages: const ['\u{1F1EC}\u{1F1E7}', '\u{1F1F8}\u{1F1EA}'],
          tracker: 'RARBG',
        ).pills,
        [
          '2160p',
          '3 GB',
          '42 seeders',
          '\u{1F1EC}\u{1F1E7} \u{1F1F8}\u{1F1EA}',
          'RARBG',
        ],
      );
      expect(facts(sizeBytes: 700 * mb).pills, ['700 MB']);
      expect(facts().pills, isEmpty);
      expect(facts(seeders: 1).pills, ['1 seeder']);
      expect(facts(seeders: 0).pills, ['0 seeders']);
      // The two the sort and the sections never had a pill for. An addon
      // that says nothing about either draws neither, which is a
      // different thing from saying "English" or "no indexer".
      expect(facts(languages: const ['\u{1F1F8}\u{1F1EA}']).pills, [
        '\u{1F1F8}\u{1F1EA}',
      ]);
      expect(facts(tracker: '1337x').pills, ['1337x']);
      // Every flag in one pill, not a pill each: seventeen of them is
      // what recorded row 2 carries, and seventeen boxes wrap to six rows
      // on a television card 260 wide.
      expect(
        facts(languages: const ['\u{1F1EC}\u{1F1E7}', '\u{1F1F7}\u{1F1FA}'])
            .pills,
        hasLength(1),
      );
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

  releaseNameTests();
  leadSubtractionTests();
  recordedAddonAnswers();
}

/// The rule that decides what a line under the lead still has to say.
///
/// The recorded rows are the specification and [recordedAddonAnswers] walks
/// every one of them; this group is the rule stated on its own, with the
/// two ways it can go wrong -- taking words out of a line that is not the
/// lead, and leaving the lead's own words in one that is -- written as
/// cases rather than inferred from a table.
void leadSubtractionTests() {
  StreamInfo torrent(String description, {String? filename}) =>
      StreamInfo(<String, dynamic>{
        'infoHash': 'a',
        'name': 'Torrentio\n4k',
        'description': description,
        if (filename != null)
          'behaviorHints': <String, dynamic>{'filename': filename},
      });

  List<String> restOf(StreamInfo stream) =>
      StreamPresentation.of(stream, addonName: 'Torrentio').rest;

  group('a line that is the lead again, more fully spelled', () {
    test("keeps only what it adds, in the addon's own separators", () {
      expect(
        restOf(
          torrent(
            'Movie.Name.2019.2160p.BluRay.x265.10bit.HDR.TrueHD.7.1'
            '.Atmos-GROUP',
            filename: 'Movie.Name.2019.2160p.BluRay.X265-GROUP.mkv',
          ),
        ),
        ['10bit.HDR.TrueHD.7.1.Atmos'],
      );
    });

    test('and goes entirely when it adds nothing, which is what it always '
        'did', () {
      expect(
        restOf(
          torrent(
            'Movie Name 2019 2160p BluRay x265-GROUP',
            filename: 'Movie.Name.2019.2160p.BluRay.x265-GROUP.mkv',
          ),
        ),
        isEmpty,
      );
    });

    test('a word the line has twice and the lead has once is the line saying '
        'something the second time', () {
      // The lead's `PROPER` is accounted for by the line's first one; the
      // second is not the lead's and stays.
      expect(
        restOf(
          torrent(
            'Movie.Name.2019.PROPER.1080p.PROPER.WEB-DL-GROUP',
            filename: 'Movie.Name.2019.PROPER.1080p.WEB-DL-GROUP.mkv',
          ),
        ),
        ['PROPER'],
      );
    });
  });

  group('and the lines that are not', () {
    test('a pack is not its own files, however much of them it spells', () {
      // Recorded row 4 without the `[PACK]` in front of it, to show what
      // keeps the line whole is what it names and not the word: the head
      // of the lead is `Movie Name 2019` and the head of the line is
      // `Movie Name Collection 2019 2021`.
      expect(
        restOf(
          torrent(
            'Movie Name Collection (2019-2021) (2160p HDR BDRip x265 DTS) '
            '[GROUP]',
            filename:
                'Movie Name (2019) (2160p HDR BDRip x265 DTS) '
                '[GROUP].mkv',
          ),
        ),
        [
          'Movie Name Collection (2019-2021) (2160p HDR BDRip x265 DTS) '
              '[GROUP]',
        ],
      );
    });

    test('and neither is the season a file came out of', () {
      expect(
        restOf(
          torrent(
            'Series Name (2008) S01 (2160p AMZN WEB-DL H265 - GROUP)',
            filename:
                'Series Name (2008) S01E01 (2160p AMZN WEB-DL H265 - '
                'GROUP).mkv',
          ),
        ),
        ['Series Name (2008) S01 (2160p AMZN WEB-DL H265 - GROUP)'],
      );
    });

    test('a line that shares a word or two is left alone: half a line is '
        'worse than a repeated one', () {
      // The same film at another resolution, which is a different release
      // and not this one spelled out. More of it is its own than is the
      // lead's, and that is where this stops.
      expect(
        restOf(
          torrent(
            'Movie.Name.2019.720p.HDTV.XviD.AC3-OTHER',
            filename: 'Movie.Name.2019.2160p.BluRay.x265.TrueHD-GROUP.mkv',
          ),
        ),
        ['Movie.Name.2019.720p.HDTV.XviD.AC3-OTHER'],
      );
    });

    test("a line with no title in it at all is nobody's release", () {
      // The public-domain addon: the whole stream name is `1080p`, so
      // there is no title in front of the resolution to agree about. No
      // head, no claim that two lines are one release.
      final stream = StreamInfo(const {
        'infoHash': 'a',
        'name': '1080p',
        'description': '💾 1.51 GB',
      });
      expect(
        StreamPresentation.of(stream, addonName: 'caching.stremio.net').rest,
        ['💾 1.51 GB'],
      );
    });
  });
}

/// The four shapes real addons send, and what a card leads with for each.
///
/// None of them is a field called "the release": every one of these is a
/// convention, and the differences between them are the whole reason
/// [releaseNameOf] exists rather than a card reading `stream.name`.
void releaseNameTests() {
  group('the release a card leads with', () {
    test("Torrentio's: the name is the addon and the quality, the release "
        'is the first line of the description', () {
      final stream = StreamInfo(const {
        'infoHash': 'a',
        'name': 'Torrentio\n4k',
        'description':
            'Movie.Name.2019.2160p.BluRay.x265-GROUP\n'
            '👤 716 💾 10.69 GB ⚙️ ThePirateBay',
      });
      expect(
        releaseNameOf(stream, addonName: 'Torrentio'),
        'Movie.Name.2019.2160p.BluRay.x265-GROUP',
      );
    });

    test('an addon that sets behaviorHints.filename is believed over its '
        'own free text, minus the container', () {
      final stream = StreamInfo(const {
        'infoHash': 'a',
        'name': 'Some Addon',
        'description': 'Movie.Name.2019.1080p.WEB-DL-OTHER',
        'behaviorHints': {'filename': 'Movie.Name.2019.2160p.BluRay.mkv'},
      });
      expect(
        releaseNameOf(stream, addonName: 'Some Addon'),
        'Movie.Name.2019.2160p.BluRay',
      );
    });

    test('a one-line description with no release in it is prose, and the '
        'name is what is left', () {
      // WatchHub, as it is in our own recorded fixture: `Subscription` is
      // not a release, and a card headed with it would say nothing.
      final stream = StreamInfo(const {
        'externalUrl': 'https://example/watch',
        'name': 'Amazon Prime Video',
        'description': 'Subscription',
      });
      expect(
        releaseNameOf(stream, addonName: 'watchhub.strem.io'),
        'Amazon Prime Video',
      );
    });

    test('an addon with nothing but a name leads with it, on one line', () {
      final stream = StreamInfo(const {
        'infoHash': 'a',
        'name': 'Torrentio\n4k',
      });
      expect(releaseNameOf(stream, addonName: 'Torrentio'), 'Torrentio 4k');
    });

    test('a description that is only the numbers leaves nothing behind, and '
        'the name is what is left', () {
      // The public-domain addon in the recorded fixture.
      final stream = StreamInfo(const {
        'infoHash': 'a',
        'name': '1080p',
        'description': '💾 1.51 GB',
      });
      expect(releaseNameOf(stream, addonName: 'caching.stremio.net'), '1080p');
    });

    test('a candidate that is the addon over again is skipped, so the card '
        'does not say one name twice', () {
      final stream = StreamInfo(const {
        'infoHash': 'a',
        'name': 'Comet',
        'description': 'Movie.Name.2019.1080p-GROUP',
        'behaviorHints': {'filename': 'comet.mkv'},
      });
      expect(
        releaseNameOf(stream, addonName: 'Comet'),
        'Movie.Name.2019.1080p-GROUP',
      );
    });

    test('a stream that says nothing at all falls back to what kind it is', () {
      final stream = StreamInfo(const {'infoHash': 'a'});
      expect(releaseNameOf(stream), StreamKind.torrent.label);
    });
  });

  group('a codec is not a container', () {
    // `.x265` is a dot and four characters, which is exactly what an
    // extension looks like, so the shape that recognised `.mkv`
    // recognised it too and took it off the title.
    test('so a filename ending in one keeps it', () {
      final stream = StreamInfo(const {
        'infoHash': 'a',
        'name': 'Torrentio\n1080p',
        'behaviorHints': {'filename': 'Movie.2019.1080p.WEB-DL.x265'},
      });
      expect(
        releaseNameOf(stream, addonName: 'Torrentio'),
        'Movie.2019.1080p.WEB-DL.x265',
      );
    });
  });

  group('breaking a release for a card two lines tall', () {
    test('gives the layout somewhere to break at every separator', () {
      expect(
        breakableRelease('Avalon.2001.1080p.x264-CiNEFiLE'),
        'Avalon.​2001.​1080p.​x264-​CiNEFiLE',
      );
    });

    test('and adds nothing to a name that already has spaces in it', () {
      expect(breakableRelease('Alpha 1080p'), 'Alpha 1080p');
    });
  });
}

/// One recorded addon answer and every value the app reads out of it.
///
/// Written out, never computed: an expectation derived by running the
/// parser would agree with the parser whatever the parser did. These were
/// read off the addons' own text by hand, and where the answer is a
/// judgement rather than a reading the row says so in [why].
typedef Recorded = ({
  /// The `addon` key of the fixture row, asserted so an inserted row shows
  /// up as a misalignment here rather than silently shifting the table.
  String addon,

  /// What this row is in the fixture, and what it is evidence of.
  String why,

  StreamResolution? resolution,
  int? size,
  int? seeders,
  List<String> tags,
  List<String> languages,
  String? audioTracks,

  /// The `⚙️` indexer of the stats line.
  String? tracker,

  /// How many announce URLs the stream carries ([StreamInfo.trackers]) -- a
  /// different field from [tracker] and, on all but one row, a different
  /// answer.
  int announce,

  /// The line that names what a press would start.
  String lead,

  /// The rest of what the addon wrote, in its order, with what [lead]
  /// already said taken out of it.
  List<String> rest,
});

Recorded recorded(
  String addon,
  String why, {
  required String lead,
  List<String> rest = const [],
  StreamResolution? resolution,
  int? size,
  int? seeders,
  List<String> tags = const [],
  List<String> languages = const [],
  String? audioTracks,
  String? tracker,
  int announce = 0,
}) => (
  addon: addon,
  why: why,
  resolution: resolution,
  size: size,
  seeders: seeders,
  tags: tags,
  languages: languages,
  audioTracks: audioTracks,
  tracker: tracker,
  announce: announce,
  lead: lead,
  rest: rest,
);

/// The parser over every stream in `addon_streams_recorded.json`, which is
/// what the live addons actually answered rather than what a shape we
/// invented would look like.
///
/// The fixture is trimmed from 122 real streams to one row per field-shape
/// and it is the specification: where it and the parser disagree, the
/// parser is what changes. The table below is index-aligned with it, and
/// the first test in the group is what stops a newly recorded addon
/// slipping in unchecked.
void recordedAddonAnswers() {
  const gb = 1024 * 1024 * 1024;

  final table = <Recorded>[
    recorded(
      'torrentio',
      'a single-file torrent -- the release on line one, the stats on line '
          'two, no languages. Line one is the same release as the filename '
          'spelled more fully, so what is left of it is the five words the '
          'filename does not have: the bit depth, the dynamic range and the '
          'audio',
      resolution: StreamResolution.uhd2160,
      size: 37677600604,
      seeders: 99,
      tags: const ['BluRay', 'HDR', 'HEVC', '10bit', 'Atmos'],
      tracker: 'RARBG',
      lead: 'The.Matrix.1999.RERIP.2160p.UHD.BluRay.X265-IAMABLE',
      rest: const [
        // Was `The.Matrix.1999.RERIP.2160p.UHD.BluRay.x265.10bit.HDR
        // .TrueHD.7.1.Atmos-IAMABLE`, four fifths of it the lead over
        // again, in the addon's own dots.
        '10bit.HDR.TrueHD.7.1.Atmos',
        '👤 99 💾 35.09 GB ⚙️ RARBG',
      ],
    ),
    recorded(
      'torrentio',
      'seventeen flags on a line of their own with no audio phrase in '
          'front of them; the filename and line one are the same string, so '
          'the lead is not repeated underneath',
      resolution: StreamResolution.uhd2160,
      size: 20905753313,
      seeders: 96,
      tags: const ['WEB-DL', 'HDR'],
      languages: const [
        '🇬🇧',
        '🇷🇺',
        '🇮🇹',
        '🇵🇹',
        '🇪🇸',
        '🇰🇷',
        '🇨🇳',
        '🇫🇷',
        '🇩🇪',
        '🇳🇱',
        '🇭🇺',
        '🇩🇰',
        '🇸🇪',
        '🇳🇴',
        '🇹🇷',
        '🇸🇦',
        '🇮🇩',
      ],
      tracker: 'ThePirateBay',
      lead:
          'The.Matrix.1999.2160p.YouTubeMovies.WEB-DL.DDP5.1.HDR'
          '.VP9-SomniWare',
      rest: const [
        '👤 96 💾 19.47 GB ⚙️ ThePirateBay',
        '🇬🇧 / 🇷🇺 / 🇮🇹 / 🇵🇹 / 🇪🇸 / 🇰🇷 / 🇨🇳 / 🇫🇷 / 🇩🇪 / 🇳🇱 / 🇭🇺 / 🇩🇰 / '
            '🇸🇪 / 🇳🇴 / 🇹🇷 / 🇸🇦 / 🇮🇩',
      ],
    ),
    recorded(
      'torrentio',
      'the one recorded stream with no behaviorHints.filename at all, so '
          'the lead has to come out of the text -- and line one is a release, '
          'so it does. Also the first `Multi Audio /` line',
      resolution: StreamResolution.uhd2160,
      size: 55082955571,
      seeders: 83,
      tags: const ['REMUX', 'BluRay', 'HDR', 'Atmos'],
      languages: const [
        '🇬🇧',
        '🇮🇹',
        '🇵🇹',
        '🇰🇷',
        '🇨🇳',
        '🇫🇷',
        '🇩🇪',
        '🇸🇦',
      ],
      audioTracks: 'Multi Audio',
      tracker: '1337x',
      lead: 'The Matrix 1999 UHD Blu-ray 2160p HDR Remux Multi Atmos 7.1-DTOne',
      rest: const [
        '👤 83 💾 51.3 GB ⚙️ 1337x',
        'Multi Audio / 🇬🇧 / 🇮🇹 / 🇵🇹 / 🇰🇷 / 🇨🇳 / 🇫🇷 / 🇩🇪 / 🇸🇦',
      ],
    ),
    recorded(
      'torrentio',
      'THE PACK ROW -- line one is `[PACK] The Matrix 4K UHD Collection '
          '(1999-2003) ...`, a box set and not a film and not what a press '
          'would start. The lead is the film, off behaviorHints.filename; the '
          'collection stays underneath *whole* -- it shares ten of its '
          'fifteen words with the lead and is still not the lead, because it '
          'names the box set and not the film, which is worth knowing -- and '
          'the duplicate file line goes',
      resolution: StreamResolution.uhd2160,
      size: 5347234284,
      seeders: 80,
      tags: const ['BDRip', 'HDR', 'HEVC', '10bit', 'DTS'],
      tracker: '1337x',
      lead: 'The Matrix (1999) (2160p HDR BDRip x265 10bit DTS) [4KLiGHT]',
      rest: const [
        '[PACK] The Matrix 4K UHD Collection (1999-2003) '
            '(2160p HDR BDRip x265 10bit DTS) [4KLiGHT]',
        '👤 80 💾 4.98 GB ⚙️ 1337x',
      ],
    ),
    recorded(
      'torrentio',
      'the same release spelled two ways -- spaces in the text, dots in '
          'the filename -- so only the stats survive underneath; a card that '
          'drew both would be drawing its own headline again',
      resolution: StreamResolution.uhd2160,
      size: 56811679908,
      seeders: 43,
      tags: const ['REMUX', 'BluRay', 'DV', 'HEVC', 'Atmos'],
      tracker: '1337x',
      lead:
          'The.Matrix.1999.UHD.BluRay.2160p.TrueHD.Atmos.7.1.DV.HEVC'
          '.REMUX-FraMeSToR',
      rest: const ['👤 43 💾 52.91 GB ⚙️ 1337x'],
    ),
    recorded(
      'torrentio',
      'the filename spells every dub out (ENG LATINO CASTELLANO ...) where '
          'the text says only MULTi. The lead is the long one because it is '
          'the file that plays, and the whole of what the short one adds is '
          'the word MULTi -- which is what is left of it',
      resolution: StreamResolution.uhd2160,
      size: 26252987597,
      seeders: 11,
      tags: const ['WEB-DL', 'HDR', 'DV', 'HEVC', 'Atmos'],
      languages: const ['🇬🇧', '🇮🇹', '🇵🇹', '🇪🇸', '🇲🇽', '🇫🇷', '🇮🇳'],
      audioTracks: 'Multi Audio',
      tracker: 'ThePirateBay',
      lead:
          'The.Matrix.1999.2160p.MAX.WEB-DL.DV.HDR.ENG.LATINO.CASTELLANO'
          '.ITA.FRE.HINDI.PORTUGUESE.DDP5.1.Atmos.H265.MP4-BEN.THE.MEN',
      rest: const [
        // Was `The.Matrix.1999.2160p.MAX.WEB-DL.DV.HDR.MULTi.DDP5.1.Atmos
        // .H265.MP4-BEN.THE.MEN`: seventeen words of the lead and one of
        // its own.
        'MULTi',
        '👤 11 💾 24.45 GB ⚙️ ThePirateBay',
        'Multi Audio / 🇬🇧 / 🇮🇹 / 🇵🇹 / 🇪🇸 / 🇲🇽 / 🇫🇷 / 🇮🇳',
      ],
    ),
    recorded(
      'torrentio',
      'line one is not a title at all -- `Imdb top 263 movies hindi '
          'english gdrive`, somebody\'s drive dump. Two thousand seeders hang '
          'off it, so it is a row a viewer would pick, and heading it with '
          'that line would say nothing about the film',
      resolution: StreamResolution.fhd1080,
      size: 1997159793,
      seeders: 2081,
      tags: const ['BDRip', 'AVC'],
      languages: const ['🇬🇧', '🇮🇳'],
      tracker: '1337x',
      lead: 'The.Matrix.1999.1080p.BrRip.x264.YIFY',
      rest: const [
        'Imdb top 263 movies hindi english gdrive',
        '👤 2081 💾 1.86 GB ⚙️ 1337x',
        '🇬🇧 / 🇮🇳',
      ],
    ),
    recorded(
      'torrentio',
      'the file line carries a directory in front of it that the filename '
          'does not, and the two are still one file. `Dual Audio` as the '
          'phrase leading the flags',
      resolution: StreamResolution.fhd1080,
      size: 2576980378,
      seeders: 1202,
      tags: const ['BluRay', 'AVC'],
      languages: const ['🇬🇧', '🇯🇵'],
      audioTracks: 'Dual Audio',
      tracker: '1337x',
      lead: 'The.Matrix.1999.Bluray.1080p.BluRay.x264 (DUAL En5.1-Ja)',
      rest: const [
        'Dual Japanese dubbed English movies super pack',
        '👤 1202 💾 2.4 GB ⚙️ 1337x',
        'Dual Audio / 🇬🇧 / 🇯🇵',
      ],
    ),
    recorded(
      'torrentio',
      'a trilogy pack, and `Multi Audio / 🇬🇧` -- six audio tracks under '
          'one flag, which is why the phrase is a fact of its own and not '
          'something counted off the flags',
      resolution: StreamResolution.hd720,
      size: 1191853425,
      seeders: 6,
      tags: const ['BluRay', 'HEVC', '10bit'],
      languages: const ['🇬🇧'],
      audioTracks: 'Multi Audio',
      tracker: '1337x',
      lead:
          'The Matrix (1999) Remastered RiffTrax sextuple audio 720p.10bit'
          '.BluRay.x265-budgetbits',
      rest: const [
        'The Matrix Trilogy (1999-2003) Remastered RiffTrax multi audio '
            '720p.10bit.BluRay.x265-budgetbits',
        '👤 6 💾 1.11 GB ⚙️ 1337x',
        'Multi Audio / 🇬🇧',
      ],
    ),
    recorded(
      'torrentio',
      'a season pack -- S01 on line one, S01E01 in the filename. One '
          'character apart, and it is the difference between naming the '
          'episode and naming the season',
      resolution: StreamResolution.uhd2160,
      size: 6732361236,
      seeders: 83,
      tags: const ['WEB-DL', 'HEVC'],
      tracker: 'ThePirateBay',
      lead:
          'Breaking Bad (2008) S01E01 '
          '(2160p AMZN WEB-DL H265 SDR DDP 5.1 English - HONE)',
      rest: const [
        'Breaking Bad (2008) S01 '
            '(2160p AMZN WEB-DL H265 SDR DDP 5.1 English - HONE)',
        '👤 83 💾 6.27 GB ⚙️ ThePirateBay',
      ],
    ),
    recorded(
      'torrentio',
      'the filename is a plain episode title with double spaces in it, '
          'kept exactly as the addon wrote them',
      resolution: StreamResolution.uhd2160,
      size: 10232759583,
      seeders: 63,
      tags: const ['BluRay', 'HEVC'],
      tracker: 'ThePirateBay',
      lead: 'Breaking Bad  S01E01  Pilot',
      rest: const [
        'Breaking Bad. S01. 2008 2160P.Ai Upscaled.BluRay.60FPS.H265.SDR'
            '.AC3.5.1_Marjenbo',
        '👤 63 💾 9.53 GB ⚙️ ThePirateBay',
      ],
    ),
    recorded(
      'torrentio',
      'a complete-series pack whose own line says WEB-DL and whose files '
          'say WEBRip: both are tags, because the addon said both',
      resolution: StreamResolution.uhd2160,
      size: 54556822077,
      seeders: 49,
      tags: const ['WEB-DL', 'WEBRip', 'AVC', 'DTS'],
      languages: const ['🇬🇧', '🇷🇺', '🇺🇦'],
      tracker: '1337x',
      lead: 'Breaking.Bad.S01E01.2160p.WEBRip.DTS-HD.MA5.1.x264-TrollUHD',
      rest: const [
        'Breaking Bad COMPLETE S01-S05 2160p WEB-DL Rus Ukr Eng DTS-HD '
            'MA5.1 x264-TrollUHD [RiCK]',
        '👤 49 💾 50.81 GB ⚙️ 1337x',
        '🇬🇧 / 🇷🇺 / 🇺🇦',
      ],
    ),
    recorded(
      'torrentio',
      'the only row carrying announce URLs, twenty-six of them, next to a '
          '`⚙️ Rutracker` that is not one of them. Line one is Russian prose '
          'about the season and stays: the flags do not say there is a '
          'LostFilm dub on it and that line does',
      resolution: StreamResolution.uhd2160,
      size: 13335873454,
      seeders: 35,
      tags: const ['WEB-DL', 'HEVC', 'DTS'],
      languages: const ['🇬🇧', '🇷🇺'],
      tracker: 'Rutracker',
      announce: 26,
      lead:
          'Breaking.Bad.S01E01.Pilot.2160p.AMZN.WEB-DL.DTS-HD.MA.5.1.SDR'
          '.HEVC',
      rest: const [
        'Во все тяжкие / Breaking Bad / Сезон: 1 / Серии: 1-7 из 7 '
            '[2008 WEB-DL 2160p 4k] MVO (LostFilm FoxCrime) + DVO '
            '(Кубик в Кубе) + Original + Sub (Rus Eng)',
        '👤 35 💾 12.42 GB ⚙️ Rutracker',
        '🇬🇧 / 🇷🇺',
      ],
    ),
    recorded(
      'torrentio',
      'text and filename agree exactly, so nothing is left but the stats',
      resolution: StreamResolution.uhd2160,
      size: 7322919240,
      seeders: 17,
      tags: const ['WEB-DL'],
      tracker: 'ThePirateBay',
      lead: 'Breaking Bad S01E01 Pilot 2160p NF WEB-DL DDP5 1 H 265-XEBEC',
      rest: const ['👤 17 💾 6.82 GB ⚙️ ThePirateBay'],
    ),
    recorded(
      'torrentio',
      'the same at 1080p: the plainest shape Torrentio sends',
      resolution: StreamResolution.fhd1080,
      size: 1170378588,
      seeders: 33,
      tags: const ['HEVC'],
      tracker: 'ThePirateBay',
      lead: 'Breaking.Bad.S01E01.Pilot.1080p.HEVC.x265-MeGusta',
      rest: const ['👤 33 💾 1.09 GB ⚙️ ThePirateBay'],
    ),
    recorded(
      'torrentio',
      'a release name that is itself the pack -- `iNTEGRALE` where the '
          'file says S01E01 -- and `Multi Audio / 🇫🇷` on one flag, off a '
          'French indexer: between them the two facts say what the dub is',
      resolution: StreamResolution.fhd1080,
      size: 2888365507,
      seeders: 6,
      tags: const ['AVC'],
      languages: const ['🇫🇷'],
      audioTracks: 'Multi Audio',
      tracker: 'Torrent9',
      lead: 'Breaking.Bad.S01E01.MULTi.1080p.WEB.DDP5.1.x264-TFA',
      rest: const [
        'Breaking.Bad.iNTEGRALE.MULTi.1080p.WEB.DDP5.1.x264-TFA',
        '👤 6 💾 2.69 GB ⚙️ Torrent9',
        'Multi Audio / 🇫🇷',
      ],
    ),
    recorded(
      'watchhub',
      'no filename, no bingeGroup, one line of text, twelve platform URL '
          'keys. The lead is the service -- `Amazon Prime Video` -- and not '
          '`Subscription, Rent, Buy`, which is an availability phrase and here '
          'carries three of them at once',
      lead: 'Amazon Prime Video',
      rest: const ['Subscription, Rent, Buy'],
    ),
    recorded(
      'watchhub',
      'the same with half the platform keys null: the field set varies per '
          'row and nothing may read a fixed shape out of it',
      lead: 'Rakuten TV',
      rest: const ['Rent, Buy'],
    ),
    recorded(
      'publicdomainmovies',
      'a name that is only a resolution and a description that is only a '
          'size. Seeders stay null -- that addon never says -- which is not a '
          'swarm of zero and draws no badge',
      resolution: StreamResolution.fhd1080,
      size: 1621350154,
      lead: '1080p',
      rest: const ['💾 1.51 GB'],
    ),
    recorded(
      'watchhub',
      'recorded through the engine rather than off the wire, so this one '
          'really does have a `description` key -- the alias already applied. '
          'Four platform URL keys, not twelve',
      lead: 'Amazon Prime Video',
      rest: const ['Subscription'],
    ),
    recorded(
      'watchhub',
      'a rental-only service',
      lead: 'Google Play Movies',
      rest: const ['Rent, Buy'],
    ),
    recorded(
      'watchhub',
      '`ADS` as the whole text: a third availability beside Subscription '
          'and Rent, Buy, and the plainest proof that the field is a phrase '
          'and not a release. Also the only row with no webosUrl',
      lead: 'Plex',
      rest: const ['ADS'],
    ),
    recorded(
      'watchhub',
      'a channel sold through another service -- the name says both, and '
          'it is still the name that leads',
      lead: 'MUBI Amazon Channel',
      rest: const ['Subscription'],
    ),
    recorded(
      'watchhub',
      'and the same service direct',
      lead: 'MUBI',
      rest: const ['Subscription'],
    ),
    recorded(
      'publicdomainmovies',
      'the same torrent again, carrying an empty `announce` array. An '
          'empty tracker list and no tracker list read alike, and neither has '
          'anything to do with the `⚙️` field, which this addon never writes',
      resolution: StreamResolution.fhd1080,
      size: 1621350154,
      lead: '1080p',
      rest: const ['💾 1.51 GB'],
    ),
  ];

  group('the recorded addon answers', () {
    final streams = loadRecordedStreams();

    test('every recorded row has an expectation written for it', () {
      // Recording a new addon must not slip through unchecked: add the row
      // to the table above, by hand, from what the addon actually said.
      expect(
        table,
        hasLength(streams.length),
        reason:
            'addon_streams_recorded.json holds ${streams.length} streams and '
            'the table holds ${table.length} -- write the missing '
            'expectation rather than widening this check',
      );
    });

    for (final (index, expected) in table.indexed) {
      test('row ${index + 1}: ${expected.why}', () {
        final row = streams[index];
        // A fixture row inserted above this one shifts every expectation
        // after it; the addon name is the cheapest thing that notices.
        expect(row['addon'], expected.addon, reason: 'the table is misaligned');
        final stream = StreamInfo(row['stream'] as Map<String, dynamic>);
        final facts = StreamFacts.of(stream, addonName: expected.addon);

        expect(facts.resolution, expected.resolution, reason: 'resolution');
        expect(facts.sizeBytes, expected.size, reason: 'size');
        expect(facts.seeders, expected.seeders, reason: 'seeders');
        expect(facts.tags, expected.tags, reason: 'tags');
        expect(facts.languages, expected.languages, reason: 'languages');
        expect(facts.audioTracks, expected.audioTracks, reason: 'audio');
        expect(facts.tracker, expected.tracker, reason: 'the ⚙️ indexer');
        expect(
          stream.trackers,
          hasLength(expected.announce),
          reason: 'announce URLs, which are not the ⚙️ indexer',
        );

        final shown = StreamPresentation.of(stream, addonName: expected.addon);
        expect(shown.lead, expected.lead, reason: 'the lead line');
        expect(shown.rest, expected.rest, reason: 'the rest, in order');
        // The two halves are one read: whatever the lead turned out to be,
        // it is not also sitting in the lines under it.
        expect(shown.rest, isNot(contains(shown.lead)));
        expect(releaseNameOf(stream, addonName: expected.addon), shown.lead);
      });
    }

    test('no addon sets `description`: they all write `title`', () {
      // The serde alias in stremio-core is what makes the app see a
      // description at all, and it is invisible from Dart. Only the rows
      // re-recorded through the engine carry the normalized key.
      final live = [
        for (final row in streams)
          if (!row.containsKey('from')) row['stream'] as Map<String, dynamic>,
      ];
      expect(live, isNotEmpty);
      for (final stream in live) {
        expect(stream.containsKey('description'), isFalse);
        expect(stream.containsKey('title'), isTrue);
        expect(StreamInfo(stream).description, stream['title']);
      }
    });

    test('an unknown is null and never zero, on every row that has one', () {
      // The distinction the sort and the badges both hang on. Nine of the
      // recorded rows say nothing about seeders, and none of them is a
      // swarm of zero.
      final silent = [
        for (final row in streams)
          if (StreamFacts.of(StreamInfo(row['stream'] as Map<String, dynamic>))
                  .seeders ==
              null)
            row['addon'],
      ];
      expect(silent, hasLength(9));
      expect(silent, everyElement(isNot('torrentio')));
      for (final row in streams) {
        final facts = StreamFacts.of(
          StreamInfo(row['stream'] as Map<String, dynamic>),
        );
        expect(facts.sizeBytes, isNot(0));
        expect(facts.seeders, isNot(0));
      }
    });

    test('the facts the list sorts and sections by come out usable', () {
      final all = [
        for (final row in streams)
          StreamFacts.of(
            StreamInfo(row['stream'] as Map<String, dynamic>),
            addonName: row['addon'] as String,
          ),
      ];
      // Every resolution a recorded stream has, highest first, with the
      // nine that have none in a section of their own at the end.
      final sections = sectionsByResolution(all, (f) => f);
      expect(sections.map((s) => s.label), [
        '2160p',
        '1080p',
        '720p',
        'Unknown resolution',
      ]);
      expect(sections.last.rows, hasLength(7));
      expect(sections.last.bestSeeders, isNull);
      expect(sections.first.summary, '11 streams · best 99 seeders');
      // The deepest swarm leads the most-peers order, without the streams
      // nobody counted getting in front of it.
      final ranked = sortedByStreamOrder(all, (f) => f, StreamOrder.mostPeers);
      expect(ranked.first.seeders, 2081);
      expect(ranked.last.seeders, isNull);
      // A size sort is the same shape: the 52.91 GB remux first.
      expect(
        sortedByStreamOrder(all, (f) => f, StreamOrder.largest).first.sizeBytes,
        greaterThan(52 * gb),
      );
    });

    test('the languages are the pill a Swedish viewer is looking for', () {
      final withSwedish = [
        for (final row in streams)
          if (StreamFacts.of(StreamInfo(row['stream'] as Map<String, dynamic>))
              .languages
              .contains('🇸🇪'))
            row['addon'],
      ];
      // Exactly one recorded stream offers it, which is the point: before
      // this parser nothing in the app could have said so.
      expect(withSwedish, ['torrentio']);
    });
  });
}
