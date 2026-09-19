import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/dev/dev_streams.dart';
import 'package:xtremio/features/player/archive_sniff.dart';

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

    testWidgets('asks nothing of a stream that had loaded', (tester) async {
      final harness = PlayerHarness(stream: DevStreams.bigBuckBunnyHttp)
        ..archiveKind = ArchiveKind.rar;
      await harness.pump(tester);
      harness.engine.emitDuration(const Duration(minutes: 90));
      await tester.pump();

      harness.engine.emitError('demuxer error');
      await tester.pump();
      await tester.pump();
      expect(harness.archiveSniffs, isEmpty);
      expect(find.text('Playback failed: demuxer error'), findsOneWidget);
    });
  });
}
