import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/dev/dev_streams.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/playback_stats_overlay.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/shell/device_profile.dart';

import '../../support/player_harness.dart';
import '../../support/tv.dart';

/// The swarm rows in the stats OSD: what the panel says about the torrent
/// feeding mpv, and the polling that keeps those numbers moving for as long
/// as the panel is up.
void main() {
  final overlay = find.byType(PlaybackStatsOverlay);

  Finder row(String text) =>
      find.descendant(of: overlay, matching: find.text(text));

  Future<void> pressShiftI(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await pumpEvents(tester);
  }

  /// A player whose stream is playing: the start-up overlay is done and,
  /// with nothing waiting for the torrent, nothing is being polled.
  Future<PlayerHarness> pumpPlaying(
    WidgetTester tester, {
    Map<String, dynamic>? player,
    Map<String, dynamic>? stream,
    DeviceProfile? device,
  }) async {
    final harness = PlayerHarness(
      player: player,
      stream: stream,
      device: device,
    );
    harness.torrentStats.response = const TorrentStats(
      phase: TorrentPhase.ready,
    );
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(minutes: 96));
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);
    return harness;
  }

  const swarm = TorrentStats(
    phase: TorrentPhase.ready,
    downloadSpeed: 1500000,
    peers: 4,
    peerDiscovery: PeerDiscovery(seen: 9, live: 4),
  );

  testWidgets('the panel carries the swarm and keeps it live while up', (
    tester,
  ) async {
    final harness = await pumpPlaying(tester);
    final stats = harness.torrentStats;
    stats.response = swarm;

    // Playing with the panel down: the server is left alone.
    final whileHidden = stats.requests.length;
    await tester.pump(PlayerScreen.torrentStatsOverlayInterval * 2);
    expect(stats.requests, hasLength(whileHidden));

    // Up: asked at once, so the numbers are there rather than five seconds
    // away. A ready torrent spends no row on its phase.
    await pressShiftI(tester);
    expect(overlay, findsOneWidget);
    expect(stats.requests, hasLength(whileHidden + 1));
    expect(row('speed    1.5 MB/s'), findsOneWidget);
    expect(row('peers    4 connected / 9 found'), findsOneWidget);
    expect(find.textContaining('torrent  '), findsNothing);

    // And it keeps up as the answers change, at its own slow cadence.
    stats.response = const TorrentStats(
      phase: TorrentPhase.buffering,
      initialWindowReadyBytes: 1048576,
      initialWindowBytes: 4194304,
      downloadSpeed: 250000,
      peerDiscovery: PeerDiscovery(seen: 12, live: 1),
    );
    await tester.pump(PlayerScreen.torrentStallStatsInterval);
    expect(stats.requests, hasLength(whileHidden + 1));
    await tester.pump(PlayerScreen.torrentStatsOverlayInterval);
    await tester.pump();
    expect(stats.requests, hasLength(whileHidden + 2));
    expect(row('torrent  buffering head 25%'), findsOneWidget);
    expect(row('speed    250 kB/s'), findsOneWidget);
    expect(row('peers    1 connected / 12 found'), findsOneWidget);

    // Down again: the asking stops with the panel.
    await pressShiftI(tester);
    expect(overlay, findsNothing);
    final whileShown = stats.requests.length;
    await tester.pump(PlayerScreen.torrentStatsOverlayInterval * 3);
    expect(stats.requests, hasLength(whileShown));
  });

  testWidgets('a stall under an open panel only changes the pace', (
    tester,
  ) async {
    final harness = await pumpPlaying(tester);
    final stats = harness.torrentStats;
    stats.response = swarm;
    await pressShiftI(tester);
    expect(row('speed    1.5 MB/s'), findsOneWidget);
    final whilePlaying = stats.requests.length;

    // Playback stalls: the pace picks up to the stall cadence, and the
    // numbers on screen stay the ones last measured until the next answer
    // lands -- no blank panel. Holding that answer is what makes the wait
    // a frame the test can look at; the real client takes a round trip.
    stats.holdAnswers = true;
    harness.engine.emitBuffering(true);
    await pumpEvents(tester);
    expect(stats.requests.length, greaterThan(whilePlaying));
    expect(stats.heldCount, 1);
    expect(row('speed    1.5 MB/s'), findsOneWidget);
    expect(row('torrent  waiting for the server'), findsNothing);

    // The answer lands, and only then do the numbers change.
    stats.response = const TorrentStats(
      phase: TorrentPhase.ready,
      peerDiscovery: PeerDiscovery(seen: 9),
    );
    stats.answer();
    await pumpEvents(tester);
    expect(row('speed    0 B/s'), findsOneWidget);
    expect(row('peers    0 connected / 9 found'), findsOneWidget);

    // And the stall cadence keeps them coming.
    stats.holdAnswers = false;
    final whileStalling = stats.requests.length;
    await tester.pump(PlayerScreen.torrentStallStatsInterval);
    await tester.pump();
    expect(stats.requests.length, greaterThan(whileStalling));

    // Playing again: the panel is still up, so the numbers still come.
    harness.engine.emitBuffering(false);
    await pumpEvents(tester);
    expect(overlay, findsOneWidget);
    final whileStalled = stats.requests.length;
    await tester.pump(PlayerScreen.torrentStatsOverlayInterval);
    await tester.pump();
    expect(stats.requests.length, greaterThan(whileStalled));
  });

  testWidgets('a direct stream has no swarm rows and asks nothing', (
    tester,
  ) async {
    final harness = await pumpPlaying(
      tester,
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
    );
    await pressShiftI(tester);
    expect(overlay, findsOneWidget);
    expect(find.textContaining('speed'), findsNothing);
    expect(find.textContaining('peers'), findsNothing);
    expect(find.textContaining('torrent'), findsNothing);
    await tester.pump(PlayerScreen.torrentStatsOverlayInterval * 2);
    expect(harness.torrentStats.requests, isEmpty);
  });

  testWidgets('a television reads it from the sofa, opened by the remote', (
    tester,
  ) async {
    useWideViewport(tester);
    final harness = await pumpPlaying(tester, device: tv);
    harness.torrentStats.response = swarm;

    // The remote reaches the same top-bar button a pointer does.
    await tester.tap(find.byKey(const ValueKey('stats')));
    await pumpEvents(tester);
    final line = row('peers    4 connected / 9 found');
    expect(line, findsOneWidget);
    expect(
      tester.widget<Text>(line).style?.fontSize,
      PlaybackStatsOverlay.tvFontSize,
    );
  });
}
