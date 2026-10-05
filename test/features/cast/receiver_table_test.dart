import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/cast/receiver_table.dart';

/// Every model Google's table lists.
const modelRows = [
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
    test('the announced name, compared without case', () {
      for (final announced in ['Chromecast', ' chromecast ', 'CHROMECAST']) {
        final row = ReceiverTable.of(announced: announced);
        expect(row, same(ReceiverTable.byAnnouncedName['chromecast']));
        expect(row.decodes('H.264'), isTrue, reason: announced);
        expect(row.decodes('HEVC'), isFalse, reason: announced);
        expect(row.decodes('VP9'), isFalse, reason: announced);
      }
      final ultra = ReceiverTable.of(announced: 'chromecast ultra');
      expect(ultra.video, ReceiverTable.ultra.video);
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
      for (final row in modelRows) {
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

    test('at best, a name is the best model announcing it', () {
      final byName = ReceiverTable.byAnnouncedName['chromecast']!;
      for (final row in [
        ReceiverTable.firstGeneration,
        ReceiverTable.thirdGeneration,
        ReceiverTable.googleTv4k,
        ReceiverTable.googleTvHd,
      ]) {
        expect(coveredBy(row, byName.atBest!), isTrue, reason: row.subject);
      }
      expect(byName.atBest!.decodes('AV1'), isFalse);
      for (final row in modelRows) {
        expect(
          coveredBy(row, ReceiverTable.unknown.atBest!),
          isTrue,
          reason: row.subject,
        );
      }
      // A name that names one model has nothing better to try.
      expect(ReceiverTable.of(announced: 'Chromecast Ultra').atBest, isNull);
      for (final row in modelRows) {
        expect(row.atBest, isNull, reason: row.subject);
      }
    });

    test('a model\'s row is labelled by the model alone: no receiver is '
        'identified as one', () {
      expect(modelRows.map((row) => row.subject), [
        'A 1st or 2nd generation Chromecast',
        'A 3rd generation Chromecast',
        'A Chromecast Ultra',
        'A Chromecast with Google TV (4K)',
        'A Chromecast with Google TV (HD)',
        'A Google TV Streamer',
        'A Nest Hub',
        'A Nest Hub Max',
      ]);
    });

    test('a row known by its name covers what that model decodes', () {
      for (final row in ReceiverTable.byAnnouncedName.values) {
        expect(
          modelRows.any((model) => coveredBy(row, model)),
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
