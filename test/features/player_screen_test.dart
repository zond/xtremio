import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/dev/dev_streams.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/torrent_startup_overlay.dart';

import '../support/fake_core_client.dart';
import '../support/fake_playback_engine.dart';
import '../support/fake_torrent_stats_client.dart';
import '../support/fixtures.dart';

void main() {
  Widget harness(
    FakeCoreClient core,
    FakePlaybackEngine engine, {
    required Map<String, dynamic> stream,
    ResourceRequest? streamRequest,
    ResourceRequest? metaRequest,
  }) => CoreScope(
    client: core,
    child: PlaybackScope(
      createEngine: () => engine,
      torrentStats: FakeTorrentStatsClient(),
      child: MaterialApp(
        home: PlayerScreen(
          stream: stream,
          streamRequest: streamRequest,
          metaRequest: metaRequest,
        ),
      ),
    ),
  );

  Map<String, dynamic> argsOf(CoreAction action) =>
      action.action['args']['args'] as Map<String, dynamic>;

  testWidgets(
    'loads the stream, opens the URL the core resolved and reports progress',
    (tester) async {
      final fixture = loadPlayerFixture();
      final selected = fixture['selected'] as Map<String, dynamic>;
      final stream = selected['stream'] as Map<String, dynamic>;
      final core = FakeCoreClient(state: {CoreField.player: fixture});
      final engine = FakePlaybackEngine();
      await tester.pumpWidget(
        harness(
          core,
          engine,
          stream: stream,
          streamRequest: ResourceRequest.fromJson(
            selected['streamRequest'] as Map<String, dynamic>,
          ),
          metaRequest: ResourceRequest.fromJson(
            selected['metaRequest'] as Map<String, dynamic>,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Load Player carried the raw stream and both requests.
      final load = core.dispatched.first;
      expect(load.field, CoreField.player);
      expect(argsOf(load)['stream'], stream);
      expect(argsOf(load)['streamRequest']['path']['id'], 'tt0063350');
      expect(argsOf(load)['metaRequest']['base'], kCinemetaManifestUrl);

      // Once open, the video parameters go to the core so it asks the
      // subtitle addons; the torrent URL's last segment is a file index and
      // the stream carries no filename, so none is sent (never the name).
      expect(core.dispatched, hasLength(2));
      final params = core.dispatched[1];
      expect(params.action['args']['action'], 'VideoParamsChanged');
      expect(argsOf(params)['videoParams'], {
        'hash': null,
        'size': null,
        'filename': null,
      });

      // The torrent resolved to the embedded server; that is what got opened.
      final expectedUrl = Uri.parse(
        (fixture['stream']['content'][0]
                as Map<String, dynamic>)['streaming_url']
            as String,
      );
      expect(engine.opened, [(expectedUrl, Duration.zero)]);
      expect(find.text('video surface'), findsOneWidget);
      expect(find.text('Night of the Living Dead'), findsOneWidget);
      // A torrent shows its start-up overlay (not a bare spinner) until the
      // engine reports the media loaded; see player_torrent_startup_test.
      expect(find.byType(TorrentStartupOverlay), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      // Progress goes back to the core, throttled to one report per second.
      engine.emitDuration(const Duration(minutes: 96));
      await tester.pump();
      await tester.pump();
      expect(find.byType(TorrentStartupOverlay), findsNothing);
      engine.emitPosition(const Duration(seconds: 5));
      engine.emitPosition(const Duration(milliseconds: 5500));
      engine.emitPosition(const Duration(milliseconds: 6200));
      await tester.pump();
      final timeReports = core.dispatched
          .where((a) => a.action['args']?['action'] == 'TimeChanged')
          .map((a) => argsOf(a))
          .toList();
      expect(timeReports.map((r) => r['time']), [5000, 6200]);
      expect(timeReports.first['duration'], 96 * 60 * 1000);
      expect(timeReports.first['device'], isNotEmpty);

      // (Separate controllers deliver in separate microtasks; pump between
      // them to keep the order deterministic.)
      engine.emitPlaying(true);
      engine.emitPlaying(true);
      engine.emitPlaying(false);
      await tester.pump();
      engine.emitCompleted();
      await tester.pump();
      final tail = core.dispatched
          .skipWhile((a) => a.action['args']?['action'] != 'PausedChanged')
          .map((a) => a.action['args'])
          .toList();
      expect(tail, [
        {
          'action': 'PausedChanged',
          'args': {'paused': false},
        },
        {
          'action': 'PausedChanged',
          'args': {'paused': true},
        },
        {'action': 'Ended'},
      ]);

      // Buffering shows a status over the video (one pump delivers the
      // event, the next draws the frame).
      engine.emitBuffering(true);
      await tester.pump();
      await tester.pump();
      expect(find.text('Buffering from the torrent…'), findsOneWidget);

      // Leaving unloads the field at once but releases the engine only two
      // frames later, after the raster thread is done with the video texture.
      await tester.pumpWidget(const SizedBox());
      expect(engine.disposed, isFalse);
      await tester.pump();
      await tester.pump();
      expect(engine.disposed, isTrue);
      expect(
        core.dispatched.last.action,
        CoreActions.unload(CoreField.player).action,
      );
    },
  );

  testWidgets('resumes from the library position', (tester) async {
    final fixture = loadPlayerFixture();
    (fixture['libraryItem'] as Map<String, dynamic>)['state'] = {
      'timeOffset': 90000,
      'duration': 5760000,
    };
    final core = FakeCoreClient(state: {CoreField.player: fixture});
    final engine = FakePlaybackEngine();
    await tester.pumpWidget(
      harness(core, engine, stream: DevStreams.bigBuckBunnyTorrent),
    );
    await tester.pumpAndSettle();
    expect(engine.opened.single.$2, const Duration(seconds: 90));
  });

  testWidgets('shows why a stream cannot be played', (tester) async {
    final core = FakeCoreClient(
      state: {
        CoreField.player: {
          'selected': {'stream': DevStreams.bigBuckBunnyTorrent},
          'stream': {
            'type': 'Err',
            'content': {
              'code': 8,
              'message':
                  "Can't play Torrents because streaming server is not running",
            },
          },
        },
      },
    );
    final engine = FakePlaybackEngine();
    await tester.pumpWidget(
      harness(core, engine, stream: DevStreams.bigBuckBunnyTorrent),
    );
    await tester.pump();
    await tester.pump();
    expect(engine.opened, isEmpty);
    expect(
      find.text("Can't play Torrents because streaming server is not running"),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  testWidgets('waits for the core before opening anything', (tester) async {
    // Unloaded model: nothing selected yet.
    final core = FakeCoreClient(
      state: {
        CoreField.player: {'selected': null, 'stream': null},
      },
    );
    final engine = FakePlaybackEngine();
    await tester.pumpWidget(
      harness(core, engine, stream: DevStreams.bigBuckBunnyHttp),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Loading…'), findsOneWidget);
    expect(engine.opened, isEmpty);

    // Direct HTTP streams resolve to themselves.
    core.setState(CoreField.player, {
      'selected': {'stream': DevStreams.bigBuckBunnyHttp},
      'stream': {
        'type': 'Ready',
        'content': [
          {'streaming_url': DevStreams.bigBuckBunnyHttp['url']},
          DevStreams.bigBuckBunnyHttp,
        ],
      },
    });
    await tester.pumpAndSettle();
    expect(engine.opened.single.$1.host, 'test-videos.co.uk');
    expect(find.text('Big Buck Bunny (HTTP, 720p 10s)'), findsOneWidget);
  });
}
