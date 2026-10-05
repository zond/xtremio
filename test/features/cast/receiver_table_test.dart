import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/cast/receiver_table.dart';

/// Every model Google's table lists, exactly identified.
const exactRows = [
  ReceiverTable.firstGeneration,
  ReceiverTable.thirdGeneration,
  ReceiverTable.ultra,
  ReceiverTable.googleTv4k,
  ReceiverTable.googleTvHd,
  ReceiverTable.streamer,
  ReceiverTable.nestHub,
  ReceiverTable.nestHubMax,
];

/// Whether every picture [narrow] decodes, [wide] decodes too.
bool coveredBy(ReceiverRow narrow, ReceiverRow wide) =>
    narrow.video.entries.every(
      (entry) => entry.value.every(
        (limit) => wide.fits(
          entry.key,
          width: limit.width,
          height: limit.height,
          fps: limit.fps.toDouble(),
        ),
      ),
    );

void main() {
  group('which row', () {
    test('a codename names the model, whatever it announces', () {
      for (final (codename, row) in [
        ('sabrina', ReceiverTable.googleTv4k),
        ('boreal', ReceiverTable.googleTvHd),
        ('kirkwood', ReceiverTable.streamer),
        (' Sabrina ', ReceiverTable.googleTv4k),
      ]) {
        final found = ReceiverTable.of(
          codename: codename,
          announced: 'Chromecast',
        );
        expect(found, same(row), reason: codename);
        expect(found.exact, isTrue);
      }
    });

    test('no codename, or one the table does not know: the announced name', () {
      for (final codename in [null, 'chorizo']) {
        final row = ReceiverTable.of(
          codename: codename,
          announced: 'Chromecast',
        );
        expect(row.exact, isFalse);
        expect(row.decodes('H.264'), isTrue);
        expect(row.decodes('HEVC'), isFalse, reason: '$codename');
        expect(row.decodes('VP9'), isFalse);
      }
      final ultra = ReceiverTable.of(announced: 'chromecast ultra');
      expect(ultra.video, ReceiverTable.ultra.video);
      expect(ultra.exact, isFalse);
      expect(
        ReceiverTable.of(announced: 'Google TV Streamer').decodes('AV1'),
        isTrue,
      );
      expect(
        ReceiverTable.of(announced: 'Google Nest Hub').video,
        ReceiverTable.nestHub.video,
      );
    });

    test('a name the table does not know gets the most conservative row', () {
      for (final announced in [null, 'BRAVIA 4K VH2', '']) {
        expect(
          ReceiverTable.of(announced: announced),
          same(ReceiverTable.unknown),
          reason: '$announced',
        );
      }
      // What every model in the table decodes, and nothing more.
      for (final row in exactRows) {
        expect(
          coveredBy(ReceiverTable.unknown, row),
          isTrue,
          reason: row.subject,
        );
      }
      expect(
        ReceiverTable.unknown.fits('H.264', width: 1920, height: 1080),
        isFalse,
      );
    });

    test('"Chromecast" holds only what every model announcing it decodes', () {
      final byName = ReceiverTable.byAnnouncedName['chromecast']!;
      for (final row in [
        ReceiverTable.firstGeneration,
        ReceiverTable.thirdGeneration,
        ReceiverTable.googleTv4k,
        ReceiverTable.googleTvHd,
      ]) {
        expect(coveredBy(byName, row), isTrue, reason: row.subject);
      }
      // And no less than the oldest of them does with H.264.
      expect(
        byName.video['H.264'],
        ReceiverTable.firstGeneration.video['H.264'],
      );
    });

    test('a row known by its name covers what that model decodes', () {
      for (final row in ReceiverTable.byAnnouncedName.values) {
        expect(row.exact, isFalse, reason: row.subject);
        expect(
          exactRows.any((exact) => coveredBy(row, exact)),
          isTrue,
          reason: row.subject,
        );
      }
    });
  });

  group('each row, from Google\'s table', () {
    test('1st and 2nd generation: H.264 and VP8, 720p60 or 1080p30', () {
      const row = ReceiverTable.firstGeneration;
      expect(row.fits('H.264', width: 1920, height: 1080, fps: 29.97), isTrue);
      expect(row.fits('H.264', width: 1280, height: 720, fps: 59.94), isTrue);
      expect(row.fits('H.264', width: 1920, height: 1080, fps: 60), isFalse);
      // A rate as a container writes it, a hair over the round number.
      expect(
        row.fits('H.264', width: 1920, height: 1080, fps: 30.00003),
        isTrue,
      );
      expect(row.fits('VP8', width: 1920, height: 1080, fps: 25), isTrue);
      expect(row.decodes('HEVC'), isFalse);
    });

    test('3rd generation: H.264 at 1080p60', () {
      const row = ReceiverTable.thirdGeneration;
      expect(row.fits('H.264', width: 1920, height: 1080, fps: 60), isTrue);
      expect(row.fits('H.264', width: 3840, height: 2160, fps: 24), isFalse);
      expect(row.decodes('HEVC'), isFalse);
    });

    test('Ultra: HEVC and VP9 at 4K60, H.264 at 1080p60', () {
      const row = ReceiverTable.ultra;
      expect(row.fits('HEVC', width: 3840, height: 2160, fps: 60), isTrue);
      expect(row.fits('VP9', width: 3840, height: 2160, fps: 60), isTrue);
      expect(row.fits('H.264', width: 3840, height: 2160, fps: 24), isFalse);
      expect(row.decodes('AV1'), isFalse);
    });

    test('Chromecast with Google TV (4K): HEVC 4K60, H.264 4K30, no VP8', () {
      const row = ReceiverTable.googleTv4k;
      expect(row.fits('HEVC', width: 3840, height: 2160, fps: 60), isTrue);
      expect(row.fits('H.264', width: 3840, height: 2160, fps: 30), isTrue);
      expect(row.fits('H.264', width: 3840, height: 2160, fps: 60), isFalse);
      expect(row.decodes('VP8'), isFalse);
      expect(row.decodes('AV1'), isFalse);
    });

    test('Chromecast with Google TV (HD): the same codecs at 1080p', () {
      const row = ReceiverTable.googleTvHd;
      expect(row.fits('HEVC', width: 1920, height: 1080, fps: 60), isTrue);
      expect(row.fits('HEVC', width: 3840, height: 2160, fps: 24), isFalse);
    });

    test('Google TV Streamer: AV1 too', () {
      expect(
        ReceiverTable.streamer.fits('AV1', width: 3840, height: 2160, fps: 60),
        isTrue,
      );
    });

    test('Nest Hub and Hub Max: 720p, at 60 and at 30', () {
      expect(
        ReceiverTable.nestHub.fits('VP9', width: 1280, height: 720, fps: 60),
        isTrue,
      );
      expect(
        ReceiverTable.nestHub.fits('H.264', width: 1920, height: 1080),
        isFalse,
      );
      expect(
        ReceiverTable.nestHubMax.fits(
          'H.264',
          width: 1280,
          height: 720,
          fps: 60,
        ),
        isFalse,
      );
    });

    test('a size or rate nobody reported is not held against a film', () {
      expect(ReceiverTable.firstGeneration.fits('H.264'), isTrue);
      expect(
        ReceiverTable.firstGeneration.fits('H.264', width: 1920, height: 1080),
        isTrue,
      );
    });
  });
}
