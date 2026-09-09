import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/dev/dev_streams.dart';
import 'package:xtremio/features/player/playback_stats.dart';
import 'package:xtremio/features/player/playback_stats_overlay.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/torrent_stats.dart';

import '../../support/player_harness.dart';

/// The cache and sharing rows in the stats OSD: what this server holds of
/// the stream on screen, asked for while the panel is up and dropped when
/// it goes.
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

  /// A bitrate on the panel, so the two halves of the window read in
  /// minutes as well as bytes: 8 Mbps is a megabyte of video a second.
  const playing = PlaybackStats(
    videoBitrate: 8000000,
    cacheDuration: Duration(seconds: 12),
  );

  /// The panel up, with a sample on it: the engine only samples while
  /// somebody is subscribed, so the sample goes out after the panel is
  /// there to receive it.
  Future<void> openPanel(WidgetTester tester, PlayerHarness harness) async {
    await pressShiftI(tester);
    harness.engine.emitStats(playing);
    await pumpEvents(tester);
  }

  const held = StreamNumbers(
    window: CacheWindow(behindBytes: 1200000000, aheadBytes: 340000000),
    sharing: SharingNumbers(
      committedBytes: 820000000,
      transfer: SessionTransfer(
        downloadedBytes: 4800000000,
        uploadedBytes: 2100000000,
        ratio: 0.4375,
      ),
    ),
  );

  /// A player whose stream is playing, with the engine reporting [playing].
  Future<PlayerHarness> pumpPlaying(
    WidgetTester tester, {
    Map<String, dynamic>? player,
    Map<String, dynamic>? stream,
  }) async {
    final harness = PlayerHarness(player: player, stream: stream);
    harness.torrentStats.response = const TorrentStats(
      phase: TorrentPhase.ready,
    );
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(minutes: 96));
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);
    return harness;
  }

  testWidgets('the panel asks about the stream on screen, and only while up', (
    tester,
  ) async {
    final harness = await pumpPlaying(tester);
    final server = harness.streamNumbers;
    server.response = held;

    // Playing with the panel down: nothing is asked. The ask costs the
    // server a listing of this stream's directories, and nothing but the
    // panel reads the answer.
    expect(server.requests, isEmpty);
    await tester.pump(PlayerScreen.streamNumbersInterval * 3);
    expect(server.requests, isEmpty);

    // Up: asked at once, about the URL the player was handed -- the whole
    // of the question this server takes.
    await openPanel(tester, harness);
    expect(overlay, findsOneWidget);
    expect(server.requests, hasLength(1));
    // The URL the core published, `tr=` and `f=` filters and all -- which
    // is what the server dispatches on -- and not the one mpv was handed:
    // the player adds its own `buffer=` to that, and the file a `-1` URL
    // names is decided by the filters in the query.
    final published = PlayerState.fromJson(
      harness.core.stateOf(CoreField.player) ?? const {},
    ).streamingUrl;
    expect(server.requests.single, published);
    expect(server.requests.single, isNot(harness.engine.opened.last.$1));

    expect(
      row('cache    12.0s mpv · behind 1.2 GB/20 min · ahead 340.0 MB/5 min'),
      findsOneWidget,
    );
    expect(
      row(
        'sharing  820.0 MB committed · ↑ 2.1 GB ↓ 4.8 GB · 0.44 this session',
      ),
      findsOneWidget,
    );

    // And it keeps up as the answers change, on its own slow cadence.
    server.response = const StreamNumbers(
      window: CacheWindow(behindBytes: 500000000, aheadBytes: 900000000),
      sharing: SharingNumbers(committedBytes: 820000000),
    );
    await tester.pump(PlayerScreen.streamNumbersInterval);
    await tester.pump();
    expect(server.requests, hasLength(2));
    expect(
      row('cache    12.0s mpv · behind 500.0 MB/8 min · ahead 900.0 MB/15 min'),
      findsOneWidget,
    );
    // The counters went unreadable -- the torrent paused, or is checking.
    // The committed set stands; the bytes moved go absent together rather
    // than reading as a session that has shared nothing.
    expect(row('sharing  820.0 MB committed'), findsOneWidget);

    // Down again: the asking stops with the panel.
    await pressShiftI(tester);
    expect(overlay, findsNothing);
    final whileShown = server.requests.length;
    await tester.pump(PlayerScreen.streamNumbersInterval * 3);
    expect(server.requests, hasLength(whileShown));
  });

  testWidgets(
    'numbers nobody was watching are not what the panel comes back to',
    (tester) async {
      final harness = await pumpPlaying(tester);
      final server = harness.streamNumbers;
      server.response = held;

      // Measured with the panel up, then the panel goes down and the polling
      // with it.
      await openPanel(tester, harness);
      expect(
        row(
          'sharing  820.0 MB committed · ↑ 2.1 GB ↓ 4.8 GB · 0.44 this session',
        ),
        findsOneWidget,
      );
      await pressShiftI(tester);
      expect(overlay, findsNothing);

      // Back up some time later, with the next ask still out: a window and a
      // ratio describe the moment they were read in, so the panel shows
      // neither until this server answers again.
      server.holdAnswers = true;
      await openPanel(tester, harness);
      expect(overlay, findsOneWidget);
      expect(server.heldCount, 1);
      expect(find.textContaining('sharing'), findsNothing);
      expect(row('cache    12.0s mpv'), findsOneWidget);

      // The answer lands, and only then are there rows again.
      server.answer();
      await pumpEvents(tester);
      expect(
        row(
          'sharing  820.0 MB committed · ↑ 2.1 GB ↓ 4.8 GB · 0.44 this session',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('the next video does not inherit the last one\'s numbers', (
    tester,
  ) async {
    final harness = await pumpPlaying(tester);
    final server = harness.streamNumbers;
    server.response = held;
    await openPanel(tester, harness);
    expect(find.textContaining('sharing'), findsOneWidget);

    // The core publishes another stream under the open panel (the up-next
    // hand-over, a stream picked from the menu). What was measured belongs
    // to the film that was playing; drawn over this one it is a window
    // into a cache nobody has read.
    server.holdAnswers = true;
    final next = Map<String, dynamic>.from(harness.fixture);
    final stream = Map<String, dynamic>.from(next['stream'] as Map);
    final content = List<Object?>.from(stream['content'] as List);
    content[0] = {
      ...content[0]! as Map<String, dynamic>,
      'streaming_url': 'http://127.0.0.1:39661/next/0?',
    };
    next['stream'] = {...stream, 'content': content};
    harness.core.setState(CoreField.player, next);
    await pumpEvents(tester);
    harness.engine.emitStats(playing);
    await pumpEvents(tester);

    expect(find.textContaining('sharing'), findsNothing);
    expect(find.textContaining('behind'), findsNothing);
    // And the ask that is out is about the video now playing.
    expect(server.requests.last.path, '/next/0');
  });

  testWidgets('a server that cannot be asked draws no rows and no error', (
    tester,
  ) async {
    final harness = await pumpPlaying(tester);
    final server = harness.streamNumbers;
    server.failure = StateError('embedded server is not running');

    await openPanel(tester, harness);
    expect(server.requests, hasLength(1));
    expect(overlay, findsOneWidget);
    // The whole of it: mpv's own buffer, unaccompanied. Not a dash, which
    // would say a cache of nothing had been measured, and not an error --
    // the playback this panel is over is fine.
    expect(row('cache    12.0s mpv'), findsOneWidget);
    expect(find.textContaining('behind'), findsNothing);
    expect(find.textContaining('sharing'), findsNothing);
  });

  testWidgets('a direct stream is asked about too, and has no sharing row', (
    tester,
  ) async {
    // The window is both kinds of stream's: a proxied response has one off
    // the proxy cache. What it does not have is a swarm, so the sharing
    // row is the server's own absence and not this player's guess.
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
    harness.streamNumbers.response = const StreamNumbers(
      window: CacheWindow(behindBytes: 60000000, aheadBytes: 30000000),
    );

    await openPanel(tester, harness);
    expect(harness.streamNumbers.requests, hasLength(1));
    expect(
      row('cache    12.0s mpv · behind 60.0 MB/1 min · ahead 30.0 MB/30 s'),
      findsOneWidget,
    );
    expect(find.textContaining('sharing'), findsNothing);
    // Nothing about the swarm either: there is none to describe.
    expect(find.textContaining('speed    '), findsNothing);
  });
}
