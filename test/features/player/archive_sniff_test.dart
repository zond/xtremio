import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/dev/dev_streams.dart';
import 'package:xtremio/features/player/archive_route.dart';
import 'package:xtremio/features/player/archive_sniff.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/torrent_stats.dart';

import '../../support/player_harness.dart';

/// A source that serves an archive instead of a film.
///
/// mpv answers one with "Failed to recognize file format", which says
/// nothing about what to do. The player reads the start of the stream and
/// names the container instead (a stored RAR of a cinema package, from a
/// debrid link, is where this came from).
void main() {
  List<int> startingWith(List<int> bytes, {int length = 64}) => [
    ...bytes,
    ...List.filled(length - bytes.length, 0),
  ];

  group('archiveKindOf', () {
    test('names each container by its signature', () {
      expect(
        archiveKindOf(startingWith([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00])),
        ArchiveKind.rar,
        reason: 'RAR 4',
      );
      expect(
        archiveKindOf(
          startingWith([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]),
        ),
        ArchiveKind.rar,
        reason: 'RAR 5',
      );
      for (final tail in const [
        [0x03, 0x04],
        [0x05, 0x06],
        [0x07, 0x08],
      ]) {
        expect(
          archiveKindOf(startingWith([0x50, 0x4B, ...tail])),
          ArchiveKind.zip,
          reason: 'PK $tail',
        );
      }
      expect(
        archiveKindOf(startingWith([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])),
        ArchiveKind.sevenZip,
      );
      final iso = List.filled(archiveSniffBytes, 0);
      iso.setAll(0x8001, 'CD001'.codeUnits);
      expect(archiveKindOf(iso), ArchiveKind.iso);
    });

    test('a film is not an archive', () {
      // Matroska's EBML header, an MP4's `ftyp` box, an MPEG-TS sync byte.
      expect(archiveKindOf(startingWith([0x1A, 0x45, 0xDF, 0xA3])), isNull);
      expect(
        archiveKindOf(startingWith([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70])),
        isNull,
      );
      expect(archiveKindOf(startingWith([0x47])), isNull);
      expect(archiveKindOf(const []), isNull);
      // `PK` alone is not a ZIP, and a signature cut short is nothing.
      expect(archiveKindOf(startingWith([0x50, 0x4B, 0x00, 0x00])), isNull);
      expect(archiveKindOf(const [0x52, 0x61, 0x72, 0x21]), isNull);
    });
  });

  group('sniffArchive', () {
    late HttpServer server;
    late List<String?> ranges;
    late int status;
    late bool honourRange;
    late Uint8List body;
    HttpOverrides? overrides;

    setUp(() async {
      // The test binding answers every request with a 400 of its own; these
      // talk to a real server on the loopback.
      overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      ranges = [];
      status = HttpStatus.ok;
      honourRange = true;
      body = Uint8List(1 << 20);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        ranges.add(range);
        final response = request.response;
        if (status != HttpStatus.ok) {
          response.statusCode = status;
        } else if (honourRange && range != null) {
          final end = int.parse(range.split('-').last);
          response.statusCode = HttpStatus.partialContent;
          response.add(body.sublist(0, end + 1));
        } else {
          response.add(body);
        }
        await response.close();
      });
    });
    tearDown(() async {
      HttpOverrides.global = overrides;
      await server.close(force: true);
    });

    Uri url() => Uri.parse('http://127.0.0.1:${server.port}/film.mkv');

    test('asks for no more than it needs, and names what it finds', () async {
      body.setAll(0, const [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]);
      expect(await sniffArchive(url()), ArchiveKind.rar);
      expect(ranges, ['bytes=0-${archiveSniffBytes - 1}']);

      body.setAll(0, List.filled(8, 0));
      body.setAll(0x8001, 'CD001'.codeUnits);
      expect(await sniffArchive(url()), ArchiveKind.iso);
    });

    test('a server that ignores the range is still read', () async {
      honourRange = false;
      body.setAll(0, const [0x50, 0x4B, 0x03, 0x04]);
      expect(await sniffArchive(url()), ArchiveKind.zip);
    });

    test('a film, an error or a dead server is null', () async {
      body.setAll(0, const [0x1A, 0x45, 0xDF, 0xA3]);
      expect(await sniffArchive(url()), isNull);

      body.setAll(0, const [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]);
      status = HttpStatus.notFound;
      expect(await sniffArchive(url()), isNull);

      final dead = url();
      await server.close(force: true);
      expect(
        await sniffArchive(dead, timeout: const Duration(seconds: 2)),
        isNull,
      );
      expect(await sniffArchive(Uri.parse('file:///film.rar')), isNull);
    });
  });

  group('the player', () {
    PlayerHarness failing(String error) => PlayerHarness(
      player: {
        'selected': {'stream': DevStreams.bigBuckBunnyHttp},
        'stream': {
          'type': 'Ready',
          'content': [
            {'streaming_url': DevStreams.bigBuckBunnyHttp['url']},
            DevStreams.bigBuckBunnyHttp,
          ],
        },
      },
      stream: DevStreams.bigBuckBunnyHttp,
      configureEngine: (engine) => engine.openError = error,
    );

    const unrecognized = 'Failed to recognize file format.';

    testWidgets('says the source is an archive instead of mpv\'s words', (
      tester,
    ) async {
      // With no server to send it to -- [PlayerHarness.archiveRouting] is
      // null, which is a server that could not be asked -- naming the
      // container is still all there is to say.
      final harness = failing(unrecognized)..archiveKind = ArchiveKind.rar;
      await harness.pump(tester);

      expect(harness.archiveSniffs, [harness.engine.opened.single.$1]);
      expect(
        find.text(
          'Playback failed: this source is a RAR archive, which can\'t be '
          'played. Try another source.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining(unrecognized), findsNothing);
    });

    testWidgets('keeps mpv\'s words when the source is no archive', (
      tester,
    ) async {
      final harness = failing(unrecognized);
      await harness.pump(tester);

      expect(harness.archiveSniffs, hasLength(1));
      expect(find.text('Playback failed: $unrecognized'), findsOneWidget);
    });

    testWidgets('an answer that comes back after the stream changed is '
        'dropped', (tester) async {
      // Reading the start of the stream is a request over the network, and
      // by the time it answers the screen may be playing something else:
      // the core resolved another stream, and its failure -- or its
      // playing -- is not this answer's to overwrite.
      final gate = Completer<void>();
      final harness = failing(unrecognized)
        ..archiveKind = ArchiveKind.rar
        ..archiveSniffPending = gate.future;
      await harness.pump(tester);
      expect(harness.archiveSniffs, hasLength(1));
      expect(find.text('Playback failed: $unrecognized'), findsOneWidget);

      // Another stream, resolved by the core while the check was out, and
      // this one plays.
      harness.engine.openError = null;
      final next = Map<String, dynamic>.from(harness.fixture);
      next['stream'] = {
        'type': 'Ready',
        'content': [
          {'streaming_url': 'https://example.org/another.mkv'},
          DevStreams.bigBuckBunnyHttp,
        ],
      };
      harness.core.setState(CoreField.player, next);
      await pumpEvents(tester);
      expect(find.textContaining('Playback failed'), findsNothing);

      gate.complete();
      await pumpEvents(tester);
      expect(find.textContaining('RAR archive'), findsNothing);
    });

    testWidgets('asks nothing of a stream that had loaded', (tester) async {
      // Nor fails it: once the film is in, an engine error is one of mpv's
      // log lines (a dead subtitle link, a damaged frame), and the film
      // goes on playing under it.
      final harness = PlayerHarness(stream: DevStreams.bigBuckBunnyHttp)
        ..archiveKind = ArchiveKind.rar;
      await harness.pump(tester);
      harness.engine.emitDuration(const Duration(minutes: 90));
      await tester.pump();

      harness.engine.emitError('demuxer error');
      await tester.pump();
      await tester.pump();
      expect(harness.archiveSniffs, isEmpty);
      expect(find.textContaining('Playback failed'), findsNothing);
    });
  });

  group('the player sends the container to the server', () {
    // The server reads an archive or a disc image as ranges of itself, so
    // the film inside one is played rather than given up on
    // (`docs/translated-sources.md`, step 7). What the screen has to get
    // right is *what it names* -- the URL the engine was handed, or the
    // torrent and the file inside it -- and what it does with each of the
    // three answers.
    PlayerHarness failingLink(String error) => PlayerHarness(
      player: {
        'selected': {'stream': DevStreams.bigBuckBunnyHttp},
        'stream': {
          'type': 'Ready',
          'content': [
            {'streaming_url': DevStreams.bigBuckBunnyHttp['url']},
            DevStreams.bigBuckBunnyHttp,
          ],
        },
      },
      stream: DevStreams.bigBuckBunnyHttp,
      configureEngine: (engine) => engine.openError = error,
    );

    const unrecognized = 'Failed to recognize file format.';
    final member = Uri.parse(
      '${PlayerHarness.recordedServerBaseUrl}/zip/stream/abc/Film.mkv',
    );

    testWidgets('a link is named by the URL the engine was handed, and the '
        'member is what plays', (tester) async {
      // The engine refuses the container and would refuse anything else
      // handed to it, so the ask is held open while the failure is taken
      // off it: what opens next is the member, and it plays.
      final asked = Completer<void>();
      final harness = failingLink(unrecognized)
        ..archiveKind = ArchiveKind.zip
        ..archiveRouting = ArchiveMember(member)
        ..archiveRoutePending = asked.future;
      await harness.pump(tester);
      harness.engine.openError = null;
      asked.complete();
      await pumpEvents(tester);

      // The URL that reaches the server is the one the player would have
      // fetched -- this stream's own host wrapped in `/proxy`, credentials
      // and all -- and not the addon's bare one.
      final played = harness.engine.opened.first.$1;
      expect(played.pathSegments.first, 'proxy');
      expect(harness.archiveRoutes, hasLength(1));
      final request = harness.archiveRoutes.single;
      expect(request.url, played);
      expect(request.kind, ArchiveKind.zip);
      expect(request.torrentKey, isNull);
      expect(request.serverBase, PlayerHarness.recordedServerBaseUrl);

      // And what mpv is opened on is the member, on this server, with the
      // failure card gone.
      expect(harness.engine.opened.map((open) => open.$1), [played, member]);
      expect(find.textContaining('Playback failed'), findsNothing);
      expect(find.textContaining('ZIP archive'), findsNothing);

      // A different stream is a different film: what the last one turned
      // out to hold is not what the next one opens.
      final next = Map<String, dynamic>.from(harness.fixture);
      next['stream'] = {
        'type': 'Ready',
        'content': [
          {'streaming_url': 'https://example.org/another.mkv'},
          DevStreams.bigBuckBunnyHttp,
        ],
      };
      harness.core.setState(CoreField.player, next);
      await pumpEvents(tester);
      expect(harness.engine.opened.last.$1.toString(), contains('another.mkv'));
    });

    testWidgets('a member that fails in its turn is not sent round again', (
      tester,
    ) async {
      // One translation per stream. The sniff would answer the same thing
      // about the member, the route would answer the same member, and the
      // screen would re-open it for ever; what a failure here is, is the
      // member's failure, said in mpv's own words.
      final harness = failingLink(unrecognized)
        ..archiveKind = ArchiveKind.zip
        ..archiveRouting = ArchiveMember(member);
      await harness.pump(tester);

      expect(harness.engine.opened.map((open) => open.$1).last, member);
      expect(harness.archiveRoutes, hasLength(1));
      expect(harness.archiveSniffs, hasLength(1));
      expect(find.text('Playback failed: $unrecognized'), findsOneWidget);
    });

    testWidgets('a refusal is said in the viewer\'s terms, not the server\'s', (
      tester,
    ) async {
      final harness = failingLink(unrecognized)
        ..archiveKind = ArchiveKind.rar
        ..archiveRouting = const ArchiveRefused(
          kind: 'compressed',
          message:
              'this file is compressed inside the rar (Normal), and playing '
              'it would mean unpacking the whole archive first',
        );
      await harness.pump(tester);

      expect(
        find.text(
          'Playback failed: this RAR archive has the film packed inside it '
          'rather than just wrapped, so playing it would mean unpacking the '
          'whole archive first. Try another source.',
        ),
        findsOneWidget,
      );
      // Nothing is re-opened on a refusal: there is nothing to open.
      expect(harness.engine.opened, hasLength(1));
    });

    testWidgets('a refusal the app has nothing better for keeps the '
        'server\'s sentence', (tester) async {
      // `unsupported` names one concrete structure -- the UDF metadata
      // partition map a Blu-ray image hits first -- that no message written
      // in this app could know.
      const said =
          'this UDF image uses a type 2 partition map (metadata), which '
          'remaps logical blocks; that is not supported yet';
      final harness = failingLink(unrecognized)
        ..archiveKind = ArchiveKind.iso
        ..archiveRouting = const ArchiveRefused(
          kind: 'unsupported',
          message: said,
        );
      await harness.pump(tester);

      expect(
        find.text('Playback failed: $said. Try another source.'),
        findsOneWidget,
      );
    });

    testWidgets('a torrent names the torrent and the file the server opened, '
        'and never creates a session', (tester) async {
      // The `torrent:` form has no create call: the key is the info hash
      // and the file's own name as the *server* states it (`streamName`),
      // which is the string the route matches on.
      final inside = Uri.parse(
        '${PlayerHarness.recordedServerBaseUrl}/rar/stream/'
        'torrent%3Ah%2FRelease%2Ffilm.part1.rar/Release/film.mkv',
      );
      final harness =
          PlayerHarness(
              configureEngine: (engine) => engine.openError = unrecognized,
            )
            ..archiveKind = ArchiveKind.rar
            ..archiveRouting = ArchiveMember(inside);
      harness.torrentStats.response = const TorrentStats(
        phase: TorrentPhase.ready,
        streamName: 'Release/film.part1.rar',
      );
      await tester.pumpWidget(harness.build());
      await pumpEvents(tester);
      // A torrent's first refusals are tried again; the check is made only
      // once the failure is final.
      for (var i = 0; i < PlayerScreen.torrentOpenRetries + 2; i++) {
        await tester.pump(const Duration(seconds: 5));
        await pumpEvents(tester);
      }

      final infoHash =
          (harness.selected['stream'] as Map<String, dynamic>)['infoHash']
              as String;
      expect(harness.archiveRoutes, hasLength(1));
      final request = harness.archiveRoutes.single;
      expect(request.url, isNull);
      expect(request.infoHash, infoHash);
      expect(request.pathInTorrent, 'Release/film.part1.rar');
      expect(request.torrentKey, 'torrent:$infoHash/Release/film.part1.rar');
      expect(request.kind, ArchiveKind.rar);

      // And the member is opened exactly as it was named: a torrent's own
      // URL always carries `buffer=`, and the member's never does. The
      // archive routes read no such query, and the read-ahead is the one
      // the translator's source opens on the torrent underneath.
      expect(
        harness.engine.opened.first.$1.queryParameters,
        contains('buffer'),
      );
      expect(harness.engine.opened.last.$1, inside);
    });
  });
}
