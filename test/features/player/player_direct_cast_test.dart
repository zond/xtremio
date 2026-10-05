import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart'
    show CoreField, MediaResolution, mediaIdUrl;
import 'package:xtremio/features/cast/cast_client.dart';
import 'package:xtremio/features/cast/cast_widgets.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../../support/diagnostics_capture.dart';
import '../../support/fake_cast_client.dart';
import '../../support/fake_playback_engine.dart';
import '../../support/fixtures.dart';
import '../../support/player_harness.dart';

const livingRoom = CastDevice(
  id: 'device-1',
  name: 'Living Room TV',
  model: 'Chromecast',
);

final lanBase = Uri.parse('http://192.168.1.20:39271/');

/// A debrid link with its key in the path: what this exists for, and what
/// must never reach the log.
const debridHost = 'dl.debrid.example';
const link = 'https://$debridHost/d/KEY123/Night.of.the.Living.Dead.mp4';

/// The recorded player state with its selected stream replaced by the
/// addon link [url] with [hints], played as stremio-core publishes a link
/// without request headers: its `streaming_url` is the link itself.
Map<String, dynamic> playerWithLink({
  String url = link,
  String? streamingUrl,
  Map<String, dynamic> hints = const {},
}) {
  final fixture = loadPlayerFixture();
  final stream = {
    'url': url,
    'name': 'Debrid',
    'behaviorHints': {'filename': Uri.parse(url).pathSegments.last, ...hints},
  };
  (fixture['selected'] as Map<String, dynamic>)['stream'] = stream;
  fixture['stream'] = {
    'type': 'Ready',
    'content': [
      {'stream': stream, 'streaming_url': streamingUrl ?? url},
      stream,
    ],
  };
  return fixture;
}

class DirectCast {
  DirectCast(this.harness, this.cast, this.lan);

  final PlayerHarness harness;
  final FakeCastClient cast;
  final FakeLanMediaControl lan;
}

Future<DirectCast> pumpLink(
  WidgetTester tester, {
  Map<String, dynamic>? player,
  MediaResolution resolution = const MediaResolution(),
  PlaybackStats stats = mpvMp4H264Aac,
  DateTime Function()? now,
}) async {
  useWideViewport(tester);
  final cast = FakeCastClient(devices: const [livingRoom]);
  final lan = FakeLanMediaControl()..baseUrl = lanBase;
  final harness = PlayerHarness(
    player: player ?? playerWithLink(),
    cast: cast,
    lanMedia: lan,
    mpvReport: stats,
    now: now,
  );
  harness.mediaIds.resolution = resolution;
  await harness.pump(tester);
  harness.engine.emitDuration(const Duration(minutes: 90));
  harness.engine.emitPosition(const Duration(minutes: 12));
  await pumpEvents(tester);
  await tester.tap(find.byKey(const ValueKey('cast')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('cast-device-${livingRoom.id}')));
  await tester.pumpAndSettle();
  return DirectCast(harness, cast, lan);
}

void main() {
  _anotherStream();
  testWidgets('a link the receiver plays as it is goes to it as it is: '
      'no listener, no publication', (tester) async {
    final lines = captureDiagnostics();
    final run = await pumpLink(tester);

    // Played here by id, through the server's proxy, as every link is.
    expect(run.harness.engine.opened.last.$1, mediaIdUrl('m1'));
    final (media, start) = run.cast.loads.single;
    expect(media.url, Uri.parse(link));
    expect(media.contentType, 'video/mp4');
    expect(start, const Duration(minutes: 12));
    expect(run.lan.toggles, isEmpty);
    expect(run.harness.mediaIds.published, isEmpty);
    expect(find.text('Casting to Living Room TV'), findsOneWidget);
    expect(find.text('Playing directly from the source'), findsOneWidget);
    // The link -- its key, even its host -- is never written down.
    expect(lines, anyElement(contains('straight from its source')));
    for (final line in lines) {
      expect(line, isNot(contains('KEY123')));
      expect(line, isNot(contains(debridHost)));
    }
  });

  testWidgets('the fetch watchdog does not judge a direct cast', (
    tester,
  ) async {
    // Nothing is served from here, so a listener count of zero says nothing
    // about how the cast is going.
    final run = await pumpLink(tester);

    await tester.pump(PlayerScreen.castFetchTimeout);
    await tester.pump(PlayerScreen.castFetchTimeout);
    await tester.pumpAndSettle();

    expect(find.byType(CastRefusedDialog), findsNothing);
    expect(find.byType(CastRemotePanel), findsOneWidget);
    expect(run.cast.disconnects, 0);
  });

  testWidgets('a seek is the receiver\'s and Stop brings the film back at '
      'the receiver\'s position', (tester) async {
    final run = await pumpLink(tester);
    run.cast.emitStatus(
      const CastStatus(
        state: CastPlayerState.playing,
        position: Duration(minutes: 20),
        duration: Duration(minutes: 90),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('cast-forward')));
    await tester.pumpAndSettle();
    expect(run.cast.seeks, [const Duration(minutes: 20, seconds: 10)]);
    // The receiver reports where the seek took it.
    run.cast.emitStatus(
      const CastStatus(
        state: CastPlayerState.playing,
        position: Duration(minutes: 21),
        duration: Duration(minutes: 90),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('cast-stop-button')));
    await tester.pumpAndSettle();

    expect(run.cast.disconnects, 1);
    expect(find.byType(CastRemotePanel), findsNothing);
    expect(run.harness.engine.seeks.last, const Duration(minutes: 21));
    expect(run.harness.engine.playCalls, greaterThan(0));
    expect(run.lan.toggles, isEmpty);
  });

  group('a receiver that refuses the link', () {
    testWidgets('is handed the same cast through this device, at the same '
        'position, once', (tester) async {
      final lines = captureDiagnostics();
      final run = await pumpLink(tester);
      expect(run.cast.loads.single.$1.url, Uri.parse(link));

      // A debrid link bound to the phone's address: the receiver's fetch
      // is turned away and it gives up before playing any of it -- its
      // last word a zero it does mean, having ticked once while loading.
      run.cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.buffering,
          position: Duration(minutes: 12, seconds: 1),
        ),
      );
      run.cast.emitStatus(
        const CastStatus(state: CastPlayerState.idle, failed: true),
      );
      // And says it again with a position tick, as the SDK's second stream
      // does, while the relay is still being set up: still one fallback.
      run.cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.idle,
          position: Duration(seconds: 1),
          failed: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(run.cast.loads, hasLength(2));
      final (media, start) = run.cast.loads.last;
      expect(media.url, lanBase.resolve('cast/t1'));
      expect(start, const Duration(minutes: 12));
      expect(run.harness.mediaIds.published, ['m1']);
      expect(run.lan.toggles, [true]);
      // The same session: nothing was ended or started for it.
      expect(run.cast.connectAttempts, hasLength(1));
      expect(run.cast.disconnects, 0);
      expect(find.text('Playing directly from the source'), findsNothing);
      expect(find.byType(CastRemotePanel), findsOneWidget);
      expect(
        lines,
        anyElement(contains('could not load the stream from its source')),
      );
      for (final line in lines) {
        expect(line, isNot(contains('KEY123')));
        expect(line, isNot(contains(debridHost)));
      }

      // The relay refused too: no third try, and nothing direct again.
      run.cast.emitStatus(
        const CastStatus(state: CastPlayerState.idle, failed: true),
      );
      await tester.pumpAndSettle();
      expect(run.cast.loads, hasLength(2));

      // Cast again, the stream is relayed from the start: a link refused
      // once is refused by every receiver alike.
      await tester.tap(find.byKey(const ValueKey('cast')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('cast-device-${livingRoom.id}')));
      await tester.pumpAndSettle();
      expect(run.cast.loads, hasLength(3));
      expect(run.cast.loads.last.$1.url, lanBase.resolve('cast/t2'));
    });

    testWidgets('is one cast in the log, from the link to the relay\'s end', (
      tester,
    ) async {
      final lines = captureDiagnostics();
      var now = DateTime(2026, 10, 5, 20);
      final run = await pumpLink(tester, now: () => now);
      now = now.add(const Duration(seconds: 30));
      run.cast.emitStatus(
        const CastStatus(state: CastPlayerState.idle, failed: true),
      );
      await tester.pumpAndSettle();
      expect(run.cast.loads, hasLength(2), reason: 'relayed');
      expect(lines.where((line) => line.contains('the cast ended')), isEmpty);

      now = DateTime(2026, 10, 5, 20, 5);
      await tester.tap(find.byKey(const ValueKey('cast-stop-button')));
      await tester.pumpAndSettle();
      expect(lines.where((line) => line.contains('the cast ended')), [
        'info player the cast ended after 5 min: the receiver never '
            'buffered; no numbers from this device',
      ]);
    });

    testWidgets('after it has played is not second-guessed', (tester) async {
      // An error once the film is under way is the film's, not the link's.
      final run = await pumpLink(tester);
      run.cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.playing,
          position: Duration(minutes: 13),
        ),
      );
      run.cast.emitStatus(
        const CastStatus(
          state: CastPlayerState.idle,
          position: Duration(minutes: 13),
          failed: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(run.cast.loads, hasLength(1));
      expect(run.lan.toggles, isEmpty);
    });

    testWidgets('a platform refusing the load is relayed the same way', (
      tester,
    ) async {
      useWideViewport(tester);
      final cast = FakeCastClient(devices: const [livingRoom])
        ..loadError = StateError('refused $link');
      final lan = FakeLanMediaControl()..baseUrl = lanBase;
      final lines = captureDiagnostics();
      final harness = PlayerHarness(
        player: playerWithLink(),
        cast: cast,
        lanMedia: lan,
        mpvReport: mpvMp4H264Aac,
      );
      await harness.pump(tester);
      await tester.tap(find.byKey(const ValueKey('cast')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('cast-device-${livingRoom.id}')));
      await tester.pumpAndSettle();

      // Direct, then relayed, which the platform refuses as well: that one
      // ends the cast as any refused load does.
      expect(cast.loads.map((load) => load.$1.url), [
        Uri.parse(link),
        lanBase.resolve('cast/t1'),
      ]);
      expect(
        find.text('Living Room TV did not accept the stream.'),
        findsOneWidget,
      );
      for (final line in lines) {
        expect(line, isNot(contains('KEY123')));
      }
    });
  });

  group('is relayed through this device as before', () {
    Future<void> expectRelayed(DirectCast run) async {
      expect(run.cast.loads.single.$1.url, isNot(Uri.parse(link)));
      expect(run.harness.mediaIds.published, isNotEmpty);
      expect(run.lan.toggles, [true]);
      expect(find.text('Playing directly from the source'), findsNothing);
    }

    testWidgets('a link with request headers', (tester) async {
      // stremio-core sends such a link through the server's `/proxy`, which
      // adds the headers the receiver could not.
      const proxied =
          'http://127.0.0.1:39661/proxy/d=https%3A%2F%2F$debridHost'
          '/d/KEY123/Night.of.the.Living.Dead.mp4';
      final run = await pumpLink(
        tester,
        player: playerWithLink(
          streamingUrl: proxied,
          hints: {
            'proxyHeaders': {
              'request': {'Referer': 'https://addon.example/'},
            },
          },
        ),
      );
      await expectRelayed(run);
      expect(run.cast.loads.single.$1.url, lanBase.resolve('cast/t1'));
    });

    testWidgets('a link the addon says is not web ready', (tester) async {
      final run = await pumpLink(
        tester,
        player: playerWithLink(hints: {'notWebReady': true}),
      );
      await expectRelayed(run);
    });

    testWidgets('a link mpv reads as Matroska, which is repackaged here', (
      tester,
    ) async {
      // Named `.mp4`, which counts for nothing: mpv reads a Matroska.
      final run = await pumpLink(tester, stats: mpvMkvH264Aac);
      // Not handed over as it is; with no renditions on this "device" it
      // is refused as the Matroska it is, and nothing went to the receiver
      // directly.
      expect(find.textContaining('Matroska'), findsOneWidget);
      expect(run.cast.loads, isEmpty);
      expect(run.lan.toggles, isEmpty);
    });

    testWidgets('a link to an archive, cast as the film inside it', (
      tester,
    ) async {
      final run = await pumpLink(
        tester,
        resolution: const MediaResolution(
          name: 'Night.of.the.Living.Dead.mp4',
          memberName: 'Feature/Night.of.the.Living.Dead.mp4',
        ),
      );
      await expectRelayed(run);
    });
  });
}

void _anotherStream() {
  testWidgets('a direct cast after a relayed one closes the listener', (
    tester,
  ) async {
    // The relayed stream's listener is still up when the next stream on
    // this screen -- a link the receiver can fetch itself -- is cast.
    final run = await pumpLink(
      tester,
      player: playerWithLink(hints: {'notWebReady': true}),
    );
    expect(run.lan.toggles, [true]);

    run.harness.core.setState(CoreField.player, playerWithLink(url: next));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cast')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('cast-device-${livingRoom.id}')));
    await tester.pumpAndSettle();

    expect(run.cast.loads.last.$1.url, Uri.parse(next));
    expect(run.lan.toggles, [true, false]);
    expect(run.lan.running, isFalse);
  });
}

const next = 'https://$debridHost/d/KEY123/Night.of.the.Living.Dead.2.mp4';
