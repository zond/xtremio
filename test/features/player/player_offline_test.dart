import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/torrent_startup_overlay.dart';

import '../../support/fixtures.dart';
import '../../support/player_harness.dart';

/// Playing a download off the device: the player is handed a `file://`
/// stream, which stremio-core passes through untouched, and everything that
/// keeps continue-watching moving has to keep working with no server and no
/// network in the picture.
void main() {
  const url = 'file:///downloads/abc/Night%20of%20the%20Living%20Dead.mkv';

  /// The `player` state for a file on this device: the same recorded state,
  /// with the torrent swapped for the `url` stream the Downloads screen
  /// synthesizes and the engine's resolved URL swapped for the file.
  Map<String, dynamic> offlineState() {
    final fixture = loadPlayerFixture();
    final stream = <String, dynamic>{
      'url': url,
      'name': '1080p',
      'behaviorHints': {'filename': 'Night of the Living Dead.mkv'},
    };
    (fixture['selected'] as Map<String, dynamic>)['stream'] = stream;
    fixture['stream'] = {
      'type': 'Ready',
      'content': [
        {'streaming_url': url},
        stream,
      ],
    };
    return fixture;
  }

  /// The addon requests the download was taken with, which `Load Player`
  /// needs to record progress at all.
  final streamRequest = ResourceRequest.fromJson(const {
    'base': 'https://publicdomain.invalid/manifest.json',
    'path': {
      'resource': 'stream',
      'type': 'movie',
      'id': 'tt0063350',
      'extra': <Object>[],
    },
  });
  final metaRequest = ResourceRequest.fromJson(const {
    'base': 'https://v3-cinemeta.strem.io/manifest.json',
    'path': {
      'resource': 'meta',
      'type': 'movie',
      'id': 'tt0063350',
      'extra': <Object>[],
    },
  });

  PlayerHarness harness() => PlayerHarness(
    player: offlineState(),
    streamRequest: streamRequest,
    metaRequest: metaRequest,
  );

  testWidgets('opens the file itself, with no server in between', (
    tester,
  ) async {
    final player = harness();
    await player.pump(tester);

    expect(player.engine.opened.single.$1, Uri.parse(url));
    expect(player.calls, [
      'open',
    ], reason: 'nothing polls a torrent for a file that is already whole');
    expect(find.byType(TorrentStartupOverlay), findsNothing);
  });

  testWidgets('reports the file name, so subtitle addons can match it', (
    tester,
  ) async {
    final player = harness();
    await player.pump(tester);

    expect(
      player.lastPlayerArgs('VideoParamsChanged')?['videoParams'],
      containsPair('filename', 'Night of the Living Dead.mkv'),
    );
  });

  testWidgets('still reports time, so continue-watching keeps moving', (
    tester,
  ) async {
    final player = harness();
    await player.pump(tester);

    // `Load Player` gets both requests back: without the stream request the
    // core's `TimeChanged` updates nothing, and without the meta request it
    // never finds the library item -- which offline comes out of the ctx
    // bucket, since the meta fetch cannot answer.
    final load =
        (player.core.dispatched.first.action['args']
                as Map<String, dynamic>)['args']
            as Map<String, dynamic>;
    expect(load['streamRequest'], isNotNull);
    expect(load['metaRequest'], isNotNull);
    expect((load['stream'] as Map<String, dynamic>)['url'], url);

    player.engine
      ..emitDuration(const Duration(minutes: 96))
      ..emitPosition(const Duration(minutes: 12));
    await pumpEvents(tester);

    expect(player.playerActions(), contains('TimeChanged'));
    final reported = player.lastPlayerArgs('TimeChanged');
    expect(reported?['time'], const Duration(minutes: 12).inMilliseconds);
    expect(reported?['duration'], const Duration(minutes: 96).inMilliseconds);
  });
}
