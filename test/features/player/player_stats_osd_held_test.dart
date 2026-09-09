import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/dev/dev_streams.dart';
import 'package:xtremio/features/player/playback_stats.dart';
import 'package:xtremio/features/player/playback_stats_overlay.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/torrent_stats.dart';

import '../../support/fixtures.dart';
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
      transfer: LiveTransfer(
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

  /// The same, on a build with no embedded server: what the player runs
  /// under where there is nothing of ours to ask.
  Future<PlayerHarness> pumpPlayingWithoutServer(WidgetTester tester) async {
    final harness = PlayerHarness(embeddedServer: false);
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

    // Up: asked at once, about the URL the *engine* was handed -- which is
    // the whole of the question this server takes, because it is the URL
    // the bytes are held under. Not the one the core published: the player
    // rewrites that on the way to mpv (`buffer=` here, the `/proxy` route
    // for anything that is not a torrent), and the server dispatches on
    // the path and the `f=` filters of the URL it is asked with.
    await openPanel(tester, harness);
    expect(overlay, findsOneWidget);
    expect(server.requests, hasLength(1));
    expect(server.requests.single, harness.engine.opened.last.$1);
    final published = PlayerState.fromJson(
      harness.core.stateOf(CoreField.player) ?? const {},
    ).streamingUrl;
    expect(server.requests.single, isNot(published));
    expect(server.requests.single.queryParameters['buffer'], 'normal');

    expect(
      row(
        'cache    12.0s mpv · behind 1.2 GB (20 min) · ahead 340.0 MB (5 min)',
      ),
      findsOneWidget,
    );
    expect(
      row(
        'sharing  820.0 MB committed · ↑ 2.1 GB ↓ 4.8 GB · 0.44 since it last went live',
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
      row(
        'cache    12.0s mpv · behind 500.0 MB (8 min) · ahead 900.0 MB (15 min)',
      ),
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

  testWidgets('what is on the disk is drawn while mpv is still collecting', (
    tester,
  ) async {
    final harness = await pumpPlaying(tester);
    harness.streamNumbers.response = held;

    // The panel up with no sample on it. mpv reports nothing until it has
    // opened the media, and a stream that has not started is exactly when
    // somebody opens this panel -- so the wait was drawn over the whole of
    // it, including two rows mpv has nothing to do with. The player does
    // not wait for the media before asking for them, because what they
    // report is what is on the disk.
    await pressShiftI(tester);
    expect(overlay, findsOneWidget);
    expect(harness.streamNumbers.requests, hasLength(1));
    expect(row(PlaybackStatsOverlay.collecting), findsOneWidget);
    // In bytes alone: the watching each half is worth comes from mpv's
    // bitrate, which is one of the readings still missing.
    expect(row('cache    behind 1.2 GB · ahead 340.0 MB'), findsOneWidget);
    expect(
      row(
        'sharing  820.0 MB committed · ↑ 2.1 GB ↓ 4.8 GB'
        ' · 0.44 since it last went live',
      ),
      findsOneWidget,
    );

    // mpv's first sample fills in its own rows and joins the cache row,
    // and the wait is over for the rows that were waiting.
    harness.engine.emitStats(playing);
    await pumpEvents(tester);
    expect(row(PlaybackStatsOverlay.collecting), findsNothing);
    expect(row('bitrate  8.0 Mbps'), findsOneWidget);
    expect(
      row(
        'cache    12.0s mpv · behind 1.2 GB (20 min) · ahead 340.0 MB (5 min)',
      ),
      findsOneWidget,
    );
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
          'sharing  820.0 MB committed · ↑ 2.1 GB ↓ 4.8 GB · 0.44 since it last went live',
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
          'sharing  820.0 MB committed · ↑ 2.1 GB ↓ 4.8 GB · 0.44 since it last went live',
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
    // Asked about the `/proxy/...` URL mpv was handed and not the addon's
    // origin URL the core published. This is the whole of why the ask uses
    // the engine's URL: the bytes of a proxied stream are in this server's
    // cache under its own route, and the origin URL names a stream it has
    // never heard of -- which is the answer it would give.
    final asked = harness.streamNumbers.requests.single;
    expect(asked, harness.engine.opened.last.$1);
    expect(asked.host, PlayerHarness.recordedServerBaseUrl.host);
    expect(asked.pathSegments.first, 'proxy');
    expect(asked, isNot(Uri.parse(DevStreams.bigBuckBunnyHttp['url']!)));
    expect(
      row('cache    12.0s mpv · behind 60.0 MB (1 min) · ahead 30.0 MB (30 s)'),
      findsOneWidget,
    );
    expect(find.textContaining('sharing'), findsNothing);
    // Nothing about the swarm either: there is none to describe.
    expect(find.textContaining('speed    '), findsNothing);
  });

  testWidgets('a stream off another machine is not asked about here', (
    tester,
  ) async {
    // A streaming server configured elsewhere. A torrent goes straight
    // there -- an info hash needs no proxy -- so the URL the engine is
    // handed is that machine's, while the server this app can ask is the
    // embedded one.
    final fixture = loadPlayerFixture();
    final stream = Map<String, dynamic>.from(fixture['stream'] as Map);
    final content = List<Object?>.from(stream['content'] as List);
    final hash = PlayerState.fromJson(fixture).streamingUrl!.pathSegments[0];
    content[0] = {
      ...content[0]! as Map<String, dynamic>,
      'streaming_url': 'http://192.168.7.20:11470/$hash/0',
    };
    final harness = await pumpPlaying(
      tester,
      player: {
        ...fixture,
        'stream': {...stream, 'content': content},
      },
    );
    expect(harness.engine.opened.last.$1.host, '192.168.7.20');
    harness.streamNumbers.response = held;

    // The server answers on the path and the `f=` query alone and says so
    // deliberately: the host is not part of the question, so nothing stops
    // it answering about *its* engine for this info hash -- one this
    // device has downloaded, or seeded from an earlier viewing. Those
    // would be this device's committed set and this device's ratio, drawn
    // over a film coming off somebody else's box. Not asking is the only
    // place that can be decided.
    await openPanel(tester, harness);
    expect(overlay, findsOneWidget);
    expect(harness.streamNumbers.requests, isEmpty);
    await tester.pump(PlayerScreen.streamNumbersInterval * 3);
    expect(harness.streamNumbers.requests, isEmpty);
    expect(row('cache    12.0s mpv'), findsOneWidget);
    expect(find.textContaining('sharing'), findsNothing);
  });

  testWidgets('a stream off another server on this host is not ours either', (
    tester,
  ) async {
    // A streaming server configured on this very machine: the standard
    // `http://127.0.0.1:11470/`, while the embedded server here is on the
    // ephemeral port it bound at start-up. The host is the same host, and
    // the stream is still not one this server is serving -- the bytes are
    // held by that other server, under its own engine for this info hash,
    // and the embedded one would answer about an engine of its own. So the
    // port is as much of the answer as the host is.
    final fixture = loadPlayerFixture();
    final stream = Map<String, dynamic>.from(fixture['stream'] as Map);
    final content = List<Object?>.from(stream['content'] as List);
    final hash = PlayerState.fromJson(fixture).streamingUrl!.pathSegments[0];
    content[0] = {
      ...content[0]! as Map<String, dynamic>,
      'streaming_url': 'http://127.0.0.1:11470/$hash/0',
    };
    final harness = await pumpPlaying(
      tester,
      player: {
        ...fixture,
        'stream': {...stream, 'content': content},
      },
    );
    final opened = harness.engine.opened.last.$1;
    expect(opened.host, PlayerHarness.recordedServerBaseUrl.host);
    expect(opened.port, isNot(PlayerHarness.recordedServerBaseUrl.port));
    harness.streamNumbers.response = held;

    await openPanel(tester, harness);
    expect(overlay, findsOneWidget);
    expect(harness.streamNumbers.requests, isEmpty);
    await tester.pump(PlayerScreen.streamNumbersInterval * 3);
    expect(harness.streamNumbers.requests, isEmpty);
    expect(row('cache    12.0s mpv'), findsOneWidget);
    expect(find.textContaining('sharing'), findsNothing);

    // And nothing asked of the stats route either, which is the half that
    // does harm by being asked: it takes a bare info hash and creates the
    // engine it is asked about, so the swarm rows and the start-up card
    // would be drawn off an add this device started for a film playing off
    // the other server.
    await tester.pump(PlayerScreen.torrentStatsInterval * 3);
    expect(harness.torrentStats.requests, isEmpty);
  });

  testWidgets('a build with no server of its own is asked nothing', (
    tester,
  ) async {
    // No embedded server at all (`CoreInitInfo.serverBaseUrl` null). The
    // recorded fixture's stream URL is still a loopback one -- it was taken
    // against a server that was running then -- so the URL alone cannot
    // say there is one now, and the rule that does is "no server here, so
    // nothing here served this".
    final harness = await pumpPlayingWithoutServer(tester);
    harness.streamNumbers.response = held;

    await openPanel(tester, harness);
    expect(overlay, findsOneWidget);
    expect(harness.streamNumbers.requests, isEmpty);
    await tester.pump(PlayerScreen.streamNumbersInterval * 3);
    expect(harness.streamNumbers.requests, isEmpty);
    // mpv's own cache row and nothing else: no window, no sharing.
    expect(row('cache    12.0s mpv'), findsOneWidget);
    expect(find.textContaining('sharing'), findsNothing);
  });

  testWidgets('an answer that lands after the video changed is dropped', (
    tester,
  ) async {
    final harness = await pumpPlaying(tester);
    final server = harness.streamNumbers;
    server.response = held;

    // The panel opens and the first ask goes out, and is still out when
    // the core publishes the next stream under it -- the up-next
    // hand-over lands mid-poll far more often than between polls.
    server.holdAnswers = true;
    await openPanel(tester, harness);
    expect(server.heldCount, 1);
    final askedAbout = server.requests.single;

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

    // The new video restarted the timer, so nothing else says this answer
    // is stale -- and the ask that was already out kept the poll from
    // making a fresh one, which leaves the old answer the next thing to
    // arrive.
    expect(server.requests.single, askedAbout);
    server.answer();
    await pumpEvents(tester);

    // It was a reading of the film that has stopped playing. Drawn here it
    // would be a window into a cache nobody has read and a ratio for a
    // torrent nobody is watching.
    expect(overlay, findsOneWidget);
    expect(row('cache    12.0s mpv'), findsOneWidget);
    expect(find.textContaining('sharing'), findsNothing);
    expect(find.textContaining('behind'), findsNothing);
  });

  testWidgets('an answer that lands after the panel closed is dropped', (
    tester,
  ) async {
    final harness = await pumpPlaying(tester);
    final server = harness.streamNumbers;
    server.response = held;

    // An ask out when the panel goes down -- the ordinary case, since the
    // panel is closed by a keypress and the ask takes a directory listing.
    server.holdAnswers = true;
    await openPanel(tester, harness);
    expect(server.heldCount, 1);
    await pressShiftI(tester);
    expect(overlay, findsNothing);
    server.answer();
    await pumpEvents(tester);

    // Nothing was watching when it landed, so there is nothing for it to
    // have described. Back up, with the new ask still out: the panel draws
    // mpv's buffer and waits, rather than showing a reading taken while it
    // was not on screen as the present.
    await openPanel(tester, harness);
    expect(overlay, findsOneWidget);
    expect(server.heldCount, 1);
    expect(row('cache    12.0s mpv'), findsOneWidget);
    expect(find.textContaining('sharing'), findsNothing);
    expect(find.textContaining('behind'), findsNothing);
  });

  testWidgets('an app behind the others stops asking', (tester) async {
    final harness = await pumpPlaying(tester);
    final server = harness.streamNumbers;
    server.response = held;
    await openPanel(tester, harness);
    expect(server.requests, hasLength(1));
    expect(find.textContaining('sharing'), findsOneWidget);

    // Home, with the panel still pinned. A panel nobody can see is no
    // reason to list the stream's directories every few seconds.
    for (final state in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    final whileInFront = server.requests.length;
    await tester.pump(PlayerScreen.streamNumbersInterval * 3);
    expect(server.requests, hasLength(whileInFront));

    // And back: the panel is where it was left, and asking starts again at
    // once -- what was drawn on it was dropped when the polling stopped.
    for (final state in const [
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    await pumpEvents(tester);
    expect(server.requests.length, greaterThan(whileInFront));
    expect(find.textContaining('sharing'), findsOneWidget);
  });
}
