import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/cast/cast_client.dart';
import 'package:xtremio/features/cast/cast_widgets.dart';
import 'package:xtremio/features/player/cast_stats_overlay.dart';
import 'package:xtremio/features/player/seek_bar.dart';

import '../../support/diagnostics_capture.dart';
import '../../support/fake_cast_client.dart';
import '../../support/fake_playback_engine.dart';
import '../../support/player_harness.dart';

/// The stats panel while a receiver has the film (`CastStatsOverlay`):
/// what its rows say and leave out, the rates it makes from two of the
/// server's answers on the screen's clock, where it sits on a phone, when
/// it asks the server, and the line a cast's end leaves in the log.
void main() {
  group('the rows', () {
    final t0 = DateTime(2026, 10, 5, 20);

    test('a cast from its source says what the receiver does and no more', () {
      expect(
        CastStatsOverlay.describe(
          facts: const CastFacts(
            deviceName: 'Living Room TV',
            model: 'Chromecast',
            video: 'HEVC',
            tentative: true,
            direct: true,
            reportsPicture: true,
          ),
          status: const CastStatus(
            state: CastPlayerState.playing,
            position: Duration(hours: 1, minutes: 2, seconds: 3),
            duration: Duration(hours: 2),
            picture: CastPicture(width: 1920, height: 1040, hdr: 'sdr'),
          ),
          buffering: const CastBuffering(),
          now: t0,
        ),
        [
          'receiver Living Room TV · Chromecast · HEVC tried · playing · '
              '1920x1040 sdr',
          'sending  from its source, not through this device',
          'position 1:02:03 / 2:00:00',
          'buffered never',
        ],
      );
    });

    test('a rendition says what it sends, how fast, and how far ahead', () {
      final rows = CastStatsOverlay.describe(
        facts: rendition,
        status: const CastStatus(
          state: CastPlayerState.playing,
          position: Duration(minutes: 2, seconds: 10),
          duration: Duration(hours: 2),
        ),
        buffering: CastBuffering(
          count: 2,
          total: const Duration(seconds: 3),
          since: t0.subtract(const Duration(seconds: 1)),
          started: true,
        ),
        now: t0.add(const Duration(seconds: 2)),
        samples: [
          (at: t0, numbers: renditionNumbers()),
          (
            at: t0.add(const Duration(seconds: 2)),
            numbers: renditionNumbers(
              requests: 6,
              bytes: 3000000,
              read: 6000000,
              filmMade: const Duration(seconds: 103),
              madeTo: const Duration(seconds: 166),
            ),
          ),
        ],
      );
      expect(rows, [
        'receiver Living Room TV · Chromecast · HEVC sent · playing · '
            'no picture reported',
        'sending  rendition (video/mp4) · video hevc copied · '
            'audio eac3 5.1 → aac 2.0 192 kbps',
        'position 2:10 / 2:00:00',
        // Two stops: the one still going counts up to now.
        'buffered 2 times · 6.0 s',
        'requests 6 · 5 bodies · 1 open',
        're-req.  1 in the last 2 s',
        // 2 MB in two seconds.
        'sent     3.0 MB · 8.0 Mbps',
        // Made to 2:46 with the receiver at 2:10; 3 s of film in 2.
        'made     36 s ahead · 1.5x',
        'runs     at 2:06, 67 slots · 2 started',
        'layout   3363 slots, exact',
        'source   torrent · 16.0 Mbps · 2 opens · 14 seeks',
      ]);
    });

    test('one answer has no rates, and no time between answers none', () {
      const paused = CastStatus(
        state: CastPlayerState.paused,
        position: Duration(minutes: 2, seconds: 10),
      );
      final once = CastStatsOverlay.describe(
        facts: rendition,
        status: paused,
        buffering: const CastBuffering(),
        now: t0,
        samples: [(at: t0, numbers: renditionNumbers())],
      );
      expect(once, contains('sent     1.0 MB'));
      expect(once, contains('made     30 s ahead'));
      expect(once, contains('source   torrent · 2 opens · 14 seeks'));
      expect(once.where((row) => row.startsWith('re-req.')), isEmpty);
      // A run waiting at its lookahead made nothing: no speed rather than
      // a zero, which would read as a run that cannot keep up.
      final idle = CastStatsOverlay.describe(
        facts: rendition,
        status: paused,
        buffering: const CastBuffering(),
        now: t0,
        samples: [
          (at: t0, numbers: renditionNumbers()),
          (at: t0.add(const Duration(seconds: 1)), numbers: renditionNumbers()),
        ],
      );
      expect(idle, contains('made     30 s ahead'));
    });

    test(
      'the re-requests are the last thirty seconds once watched that long',
      () {
        DateTime at(int seconds) => t0.add(Duration(seconds: seconds));
        final rows = CastStatsOverlay.describe(
          facts: rendition,
          status: const CastStatus(state: CastPlayerState.playing),
          buffering: const CastBuffering(),
          now: at(45),
          samples: [
            for (final (seconds, requests) in [
              (0, 2),
              (10, 4),
              (20, 9),
              (45, 12),
            ])
              (at: at(seconds), numbers: renditionNumbers(requests: requests)),
          ],
        );
        // Counted from the answer at 10 s, the newest at or before 15 s.
        expect(rows, contains('re-req.  8 in the last 30 s'));
      },
    );

    test('a plain cast says it goes as it is, and nothing of a rendition', () {
      final rows = CastStatsOverlay.describe(
        facts: const CastFacts(
          deviceName: 'Kitchen Display',
          video: 'H.264',
          sourceAudio: 'aac',
          sourceChannels: 2,
        ),
        status: const CastStatus(state: CastPlayerState.buffering),
        buffering: const CastBuffering(),
        now: t0,
        samples: [
          (
            at: t0,
            numbers: const CastNumbers(
              rendition: false,
              contentType: 'video/mp4',
              delivery: CastDelivery(
                requests: 1,
                bodiesBegun: 1,
                bodiesOpen: 1,
                bytes: 512,
              ),
              source: CastSource(
                kind: 'http',
                bytesRead: 512,
                opens: 1,
                seeks: 0,
              ),
            ),
          ),
        ],
      );
      expect(rows, [
        'receiver Kitchen Display · H.264 sent · buffering',
        'sending  as it is (video/mp4) · video h.264 · audio aac 2.0',
        'position 0:00',
        'buffered never',
        'requests 1 · 1 body · 1 open',
        'sent     512 B',
        'source   http · 1 open · 0 seeks',
      ]);
    });

    test("the server's answer reads as the server writes it", () {
      // The example in stream-server's docs/lan-media.md.
      final numbers = CastNumbers.fromJson({
        'kind': 'rendition',
        'contentType': 'video/mp4',
        'delivery': {
          'requests': 7,
          'bodiesBegun': 6,
          'bodiesEnded': 5,
          'bodiesOpen': 1,
          'bytes': 48213004,
          'lastRequestAt': 1180672,
          'furthestAt': 1311744,
        },
        'source': {
          'kind': 'torrent',
          'bytesRead': 51003392,
          'opens': 2,
          'seeks': 14,
        },
        'rendition': {
          'video': 'copy',
          'audio': {
            'aacStereo': {'bitrate': 192000},
          },
          'videoOut': {
            'codec': 'hevc',
            'width': 1920,
            'height': 1040,
            'channels': null,
            'sampleRate': null,
          },
          'audioOut': {
            'codec': 'aac',
            'width': null,
            'height': null,
            'channels': 2,
            'sampleRate': 48000,
          },
          'layout': {
            'slots': 3363,
            'slotMs': null,
            'exact': true,
            'total': 2471230464,
          },
          'runs': [
            {'from': 63, 'fromMs': 126040, 'produced': 67},
          ],
          'runsStarted': 2,
          'slotsMade': 70,
          'filmMadeMs': 139800,
          'askedSlot': 64,
          'askedMs': 128040,
          'madeTo': 129,
          'madeToMs': 262000,
        },
      })!;
      expect(numbers.rendition, isTrue);
      expect(numbers.delivery.requests, 7);
      expect(numbers.delivery.bodiesOpen, 1);
      expect(numbers.delivery.bytes, 48213004);
      expect(numbers.source.kind, 'torrent');
      expect(numbers.source.seeks, 14);
      final made = numbers.made!;
      expect(made.videoCopied, isTrue);
      expect(made.videoCodec, 'hevc');
      expect(made.soundConverted, isTrue);
      expect(made.soundChannels, 2);
      expect(made.soundBitrate, 192000);
      expect(made.slots, 3363);
      expect(made.slotLength, isNull);
      expect(made.exact, isTrue);
      expect(made.runs.single.from, const Duration(milliseconds: 126040));
      expect(made.runs.single.produced, 67);
      expect(made.runsStarted, 2);
      expect(made.filmMade, const Duration(milliseconds: 139800));
      expect(made.madeTo, const Duration(seconds: 262));
      expect(CastNumbers.fromJson(null), isNull);
      expect(CastNumbers.fromJson({'kind': 'plain'}), isNull);
    });
  });

  group('the buffering count', () {
    final t0 = DateTime(2026, 10, 5, 20);
    DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

    test('leaves the load out and adds up every stop after it', () {
      var buffering = const CastBuffering()
          .note(CastPlayerState.buffering, at(0))
          .note(CastPlayerState.buffering, at(4));
      expect(buffering.count, 0, reason: 'the load is not a stop');
      buffering = buffering
          .note(CastPlayerState.playing, at(5))
          .note(CastPlayerState.buffering, at(60))
          .note(CastPlayerState.buffering, at(61))
          .note(CastPlayerState.playing, at(63))
          .note(CastPlayerState.paused, at(70))
          .note(CastPlayerState.buffering, at(80));
      expect(buffering.count, 2);
      expect(buffering.totalAt(at(80)), const Duration(seconds: 3));
      expect(buffering.totalAt(at(85)), const Duration(seconds: 8));
      buffering = buffering.note(CastPlayerState.idle, at(86));
      expect(buffering.totalAt(at(200)), const Duration(seconds: 9));
    });
  });

  group('on the casting view', () {
    final panel = find.byType(CastStatsOverlay);

    testWidgets('a narrow phone keeps the remote clear of the panel', (
      tester,
    ) async {
      // A phone in portrait, 434 logical pixels wide and short enough that
      // the panel's rows do not all fit above the remote.
      tester.view.physicalSize = const Size(434, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final harness = await casting(tester);
      harness.mediaIds.numbers = renditionNumbers(contentType: 'video/mp4');
      await showStats(tester);
      expect(panel, findsOneWidget);

      final drawn = tester.getRect(panel);
      for (final control in [
        find.descendant(
          of: find.byType(CastRemotePanel),
          matching: find.byIcon(Icons.cast_connected),
        ),
        find.text('Casting to Living Room TV'),
        find.byKey(const ValueKey('cast-play-pause')),
        find.byKey(const ValueKey('cast-rewind')),
        find.byKey(const ValueKey('cast-forward')),
        find.byKey(const ValueKey('cast-stop-button')),
        find.descendant(
          of: find.byType(CastRemotePanel),
          matching: find.byType(SeekBar),
        ),
      ]) {
        expect(control, findsOneWidget);
        final rect = tester.getRect(control);
        expect(
          drawn.overlaps(rect),
          isFalse,
          reason: 'the panel $drawn covers $control at $rect',
        );
        expect(rect.bottom, lessThanOrEqualTo(800), reason: '$control is off');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('asks the server once a second while it is up, and only then', (
      tester,
    ) async {
      useWideViewport(tester);
      final harness = await casting(tester);
      final asked = harness.mediaIds.numbersAsked;
      harness.mediaIds.numbers = renditionNumbers(contentType: 'video/mp4');
      await tester.pump(const Duration(seconds: 5));
      expect(asked, isEmpty, reason: 'nothing asked with the panel off');

      await showStats(tester);
      expect(asked, ['t1'], reason: 'asked at once');
      await tester.pump(CastStatsOverlay.pollInterval * 3);
      expect(asked, hasLength(4));

      // Hidden: nobody can see it.
      await sendApp(tester, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
      ]);
      await tester.pump(CastStatsOverlay.pollInterval * 3);
      expect(asked, hasLength(4));
      await sendApp(tester, [
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      expect(
        asked,
        hasLength(5),
        reason: 'asked again at once on the way back',
      );

      // Off with Shift+I, which works while casting as the button does.
      await pressShiftI(tester);
      expect(panel, findsNothing);
      await tester.pump(CastStatsOverlay.pollInterval * 3);
      expect(asked, hasLength(5));
      await pressShiftI(tester);
      expect(panel, findsOneWidget);
      expect(asked, hasLength(6));

      // The cast ends: so does the asking. One more ask is the end's
      // own, for the log line.
      await tester.tap(find.byKey(const ValueKey('cast-stop-button')));
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      final atTheEnd = asked.length;
      await tester.pump(CastStatsOverlay.pollInterval * 3);
      expect(asked, hasLength(atTheEnd));
    });

    testWidgets("rates are two answers over the screen's clock between them", (
      tester,
    ) async {
      useWideViewport(tester);
      var now = DateTime(2026, 10, 5, 20);
      final harness = await casting(tester, now: () => now);
      harness.mediaIds.numbers = renditionNumbers(contentType: 'video/mp4');
      await showStats(tester);
      expect(row('sent     1.0 MB'), findsOneWidget);
      // What was decided at the hand-over, beside what the server says.
      expect(
        row('receiver Living Room TV · Chromecast · H.264 sent · buffering'),
        findsOneWidget,
      );
      expect(
        row(
          'sending  rendition (video/mp4) · video hevc copied · '
          'audio aac → aac 2.0 192 kbps',
        ),
        findsOneWidget,
      );

      // The pump is a second of the test's time; the screen's clock says
      // four went by, and the rate is over those.
      now = now.add(const Duration(seconds: 4));
      harness.mediaIds.numbers = renditionNumbers(
        contentType: 'video/mp4',
        bytes: 5000000,
      );
      await tester.pump(CastStatsOverlay.pollInterval);
      expect(row('sent     5.0 MB · 8.0 Mbps'), findsOneWidget);
    });

    testWidgets('its rows are on the semantics tree, as the screen is', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      useWideViewport(tester);
      final harness = await casting(tester);
      harness.mediaIds.numbers = renditionNumbers(contentType: 'video/mp4');
      await showStats(tester);
      expect(
        find.bySemanticsLabel('requests 5 · 4 bodies · 1 open'),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('the end of a cast is one line in the log, with its numbers', (
      tester,
    ) async {
      useWideViewport(tester);
      final lines = captureDiagnostics();
      var now = DateTime(2026, 10, 5, 20);
      final cast = FakeCastClient(devices: const [livingRoom]);
      final harness = await casting(tester, now: () => now, cast: cast);
      harness.mediaIds.numbers = renditionNumbers(
        contentType: 'video/mp4',
        bytes: 1200000000,
      );
      Future<void> report(CastPlayerState state, int seconds) async {
        now = DateTime(2026, 10, 5, 20).add(Duration(seconds: seconds));
        cast.emitStatus(
          CastStatus(
            state: state,
            position: Duration(seconds: seconds),
          ),
        );
        await tester.pump();
      }

      await report(CastPlayerState.playing, 2);
      await report(CastPlayerState.buffering, 300);
      await report(CastPlayerState.playing, 341);
      now = DateTime(2026, 10, 5, 20, 12);
      await tester.tap(find.byKey(const ValueKey('cast-stop-button')));
      await tester.pumpAndSettle();

      final ended = lines.where((line) => line.contains('the cast ended'));
      expect(ended, [
        'info player the cast ended after 12 min: the receiver buffered 1 '
            'time, 41 s in all; 5 requests, 1.2 GB sent',
      ]);
      expect(ended.single, isNot(contains('t1')), reason: 'never the token');
    });

    testWidgets('leaving the player mid-cast ends it in the log too', (
      tester,
    ) async {
      useWideViewport(tester);
      final lines = captureDiagnostics();
      await casting(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(
        lines.where((line) => line.contains('the cast ended')),
        hasLength(1),
      );
    });

    testWidgets('another receiver picked ends the cast before it in the log', (
      tester,
    ) async {
      useWideViewport(tester);
      final lines = captureDiagnostics();
      final cast = FakeCastClient(devices: const [livingRoom, kitchen]);
      final harness = await casting(tester, cast: cast);
      harness.mediaIds.numbers = renditionNumbers(contentType: 'video/mp4');
      Iterable<String> ended() =>
          lines.where((line) => line.contains('the cast ended'));

      await tester.tap(find.byKey(const ValueKey('cast')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('cast-device-${kitchen.id}')));
      await tester.pumpAndSettle();
      expect(ended(), hasLength(1), reason: 'the first cast, as it ended');
      expect(ended().single, contains('5 requests, 1.0 MB sent'));

      await tester.tap(find.byKey(const ValueKey('cast-stop-button')));
      await tester.pumpAndSettle();
      expect(ended(), hasLength(2), reason: 'and then the second');
    });
  });
}

const livingRoom = CastDevice(
  id: 'device-1',
  name: 'Living Room TV',
  model: 'Chromecast',
);

const kitchen = CastDevice(
  id: 'device-2',
  name: 'Kitchen Display',
  model: 'Nest Hub',
);

/// A rendition of an HEVC film whose 5.1 E-AC-3 is converted.
const rendition = CastFacts(
  deviceName: 'Living Room TV',
  model: 'Chromecast',
  video: 'HEVC',
  rendition: true,
  convertsSound: true,
  sourceAudio: 'eac3',
  sourceChannels: 6,
  reportsPicture: true,
);

/// What the server answers for a rendition a minute or two in.
CastNumbers renditionNumbers({
  int requests = 5,
  int bytes = 1000000,
  int read = 2000000,
  Duration filmMade = const Duration(seconds: 100),
  Duration madeTo = const Duration(seconds: 160),
  String? contentType = 'video/mp4',
}) => CastNumbers(
  rendition: true,
  contentType: contentType,
  delivery: CastDelivery(
    requests: requests,
    bodiesBegun: 4 + (requests > 5 ? 1 : 0),
    bodiesOpen: 1,
    bytes: bytes,
  ),
  source: CastSource(kind: 'torrent', bytesRead: read, opens: 2, seeks: 14),
  made: RenditionMade(
    videoCopied: true,
    videoCodec: 'hevc',
    soundConverted: true,
    soundCodec: 'aac',
    soundChannels: 2,
    soundBitrate: 192000,
    slots: 3363,
    exact: true,
    runs: const [
      RenditionRun(from: Duration(minutes: 2, seconds: 6), produced: 67),
    ],
    runsStarted: 2,
    slotsMade: 70,
    filmMade: filmMade,
    madeTo: madeTo,
  ),
);

Finder row(String text) => find.descendant(
  of: find.byType(CastStatsOverlay),
  matching: find.text(text),
);

/// A player casting the recorded torrent, as it is, to [livingRoom].
Future<PlayerHarness> casting(
  WidgetTester tester, {
  DateTime Function()? now,
  FakeCastClient? cast,
}) async {
  final harness = PlayerHarness(
    cast: cast ?? FakeCastClient(devices: const [livingRoom]),
    lanMedia: FakeLanMediaControl()
      ..baseUrl = Uri.parse('http://192.168.1.20:39271/'),
    mpvReport: mpvMp4H264Aac,
    now: now,
  );
  await harness.pump(tester);
  harness.engine.emitDuration(const Duration(minutes: 90));
  await pumpEvents(tester);
  await tester.tap(find.byKey(const ValueKey('cast')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('cast-device-${livingRoom.id}')));
  await tester.pumpAndSettle();
  expect(find.byType(CastRemotePanel), findsOneWidget);
  return harness;
}

/// The bar's stats button, as a viewer presses it: the bar is still up
/// from picking the receiver.
Future<void> showStats(WidgetTester tester) async {
  expect(controlsOpacity(tester), 1);
  await tester.tap(find.byKey(const ValueKey('stats')));
  await pumpEvents(tester);
}

Future<void> pressShiftI(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await pumpEvents(tester);
}

/// To the background and back, through the transitions the framework
/// allows.
Future<void> sendApp(WidgetTester tester, List<AppLifecycleState> to) async {
  for (final state in to) {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pump();
  }
}
