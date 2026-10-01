import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../../support/fixtures.dart';
import '../../support/player_harness.dart';

/// The recorded torrent fixture rewritten into a `url` stream whose
/// `streaming_url` is [url], named [filename] -- what the core publishes for
/// a link, a Drive file, a file on this device or a kept download.
Map<String, dynamic> urlStreamFixture(String url, {String? filename}) {
  final fixture = loadPlayerFixture();
  final stream = <String, dynamic>{
    'url': url,
    'name': 'Direct',
    if (filename != null) 'behaviorHints': {'filename': filename},
  };
  (fixture['selected'] as Map<String, dynamic>)['stream'] = stream;
  fixture['stream'] = {
    'type': 'Ready',
    'content': [
      {'stream': stream, 'streaming_url': url},
      stream,
    ],
  };
  return fixture;
}

/// A torrent is played by its media id: registered with the server,
/// resolved there, and only then handed to mpv as `xtremio://<id>`.
///
/// The resolve is the app's and not mpv's because it can take as long as a
/// magnet's metadata, and an open inside mpv's `stream_cb` cannot be
/// cancelled -- so what these hold is what the screen does with that wait
/// and with the server's answer.
void main() {
  /// Half a minute of retries.
  Future<void> waitOutTheRetries(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
    }
  }

  testWidgets('a refusal is the server\'s sentence, and mpv is never asked', (
    tester,
  ) async {
    final harness = PlayerHarness();
    harness.mediaIds.refusal = const MediaRefusal(
      'noSuchFile',
      'the torrent has no file 7',
    );
    harness.torrentStats.response = const TorrentStats(
      phase: TorrentPhase.ready,
    );
    await harness.pump(tester);
    await waitOutTheRetries(tester);

    expect(harness.engine.opened, isEmpty);
    expect(find.textContaining('the torrent has no file 7'), findsOneWidget);
  });

  testWidgets('a refusal while the torrent starts is tried again, same id', (
    tester,
  ) async {
    final harness = PlayerHarness();
    harness.mediaIds.refusal = const MediaRefusal(
      'torrentUnavailable',
      'the torrent\'s metadata did not arrive',
    );
    harness.torrentStats.response = const TorrentStats(
      phase: TorrentPhase.resolvingMetadata,
    );
    // Not `harness.pump`, which settles -- through every retry.
    await tester.pumpWidget(harness.build());
    await tester.pump();
    await tester.pump();
    expect(harness.engine.opened, isEmpty);
    expect(find.textContaining('Playback failed'), findsNothing);

    harness.mediaIds.refusal = null;
    await waitOutTheRetries(tester);

    expect(harness.engine.opened.single.$1, mediaIdUrl('m1'));
    expect(harness.mediaIds.registered, hasLength(1));
    expect(harness.mediaIds.resolved, ['m1', 'm1']);
    expect(harness.hints.mediaOpened, ['m1']);
  });

  testWidgets('a metadata timeout is waited out for as long as it takes', (
    tester,
  ) async {
    // The server gave up on the magnet's metadata for now (a dead swarm);
    // the player asks again, and keeps asking, until the viewer leaves.
    final harness = PlayerHarness();
    harness.mediaIds.refusal = const MediaRefusal(
      'torrentUnavailable',
      'the torrent\'s metadata did not arrive',
    );
    harness.torrentStats.response = const TorrentStats(
      phase: TorrentPhase.error,
      error: 'metadata not received in time',
    );
    await tester.pumpWidget(harness.build());
    for (var i = 0; i < 40; i++) {
      await tester.pump(PlayerScreen.openRetryBackoffCap);
      await tester.pump();
    }

    expect(harness.mediaIds.resolved.length, greaterThan(20));
    expect(harness.mediaIds.registered, hasLength(1));
    expect(find.textContaining('Playback failed'), findsNothing);
  });

  testWidgets('a wait for bytes goes on whatever phase the torrent reports', (
    tester,
  ) async {
    final harness = PlayerHarness();
    harness.mediaIds.refusal = const MediaRefusal(
      'torrentUnavailable',
      'the torrent\'s metadata did not arrive',
    );
    harness.torrentStats.response = const TorrentStats(
      phase: TorrentPhase.unknown,
    );
    await tester.pumpWidget(harness.build());
    for (var i = 0; i < 10; i++) {
      await tester.pump(PlayerScreen.openRetryBackoffCap);
      await tester.pump();
    }

    expect(harness.mediaIds.resolved.length, greaterThan(5));
    expect(find.textContaining('Playback failed'), findsNothing);
  });

  testWidgets('a refusal that is an answer fails at once, even while the '
      'torrent starts', (tester) async {
    final harness = PlayerHarness();
    harness.mediaIds.refusal = const MediaRefusal(
      'noSuchFile',
      'the torrent has no file 7',
    );
    harness.torrentStats.response = const TorrentStats(
      phase: TorrentPhase.resolvingMetadata,
    );
    await tester.pumpWidget(harness.build());
    await tester.pump();
    await tester.pump();
    await waitOutTheRetries(tester);

    expect(harness.mediaIds.resolved, ['m1']);
    expect(find.textContaining('the torrent has no file 7'), findsOneWidget);
  });

  testWidgets('a torrent the backend refused fails at once, whatever its '
      'phase', (tester) async {
    // Not the dead swarm that is waited for (`torrentUnavailable`): the
    // server says asking again gets the same answer.
    final harness = PlayerHarness();
    harness.mediaIds.refusal = const MediaRefusal(
      'torrentRefused',
      'backend refused the torrent; see server logs',
    );
    harness.torrentStats.response = const TorrentStats(
      phase: TorrentPhase.error,
      error: 'backend refused the torrent; see server logs',
    );
    await tester.pumpWidget(harness.build());
    await tester.pump();
    await tester.pump();
    await waitOutTheRetries(tester);

    expect(harness.mediaIds.resolved, ['m1']);
    expect(harness.engine.opened, isEmpty);
    expect(find.textContaining('Playback failed'), findsOneWidget);
    expect(
      find.textContaining('backend refused the torrent; see server logs'),
      findsOneWidget,
    );
  });

  testWidgets('a screen left while the server resolves opens nothing', (
    tester,
  ) async {
    final resolving = Completer<void>();
    final harness = PlayerHarness();
    harness.mediaIds.resolvePending = resolving.future;
    await harness.pump(tester);
    expect(harness.mediaIds.resolved, ['m1']);

    await tester.pumpWidget(const SizedBox());
    resolving.complete();
    await tester.pump();
    await tester.pump();

    expect(harness.engine.opened, isEmpty);
    expect(harness.hints.mediaOpened, isEmpty);
  });

  group('every kind of stream is played by id', () {
    testWidgets('a linked Drive file, by its file id and name', (tester) async {
      final harness = PlayerHarness(
        player: urlStreamFixture('xtremio-drive:1AbC', filename: 'Film.mkv'),
      );
      await harness.pump(tester);

      expect(harness.mediaIds.registered, [Uri.parse('xtremio-drive:1AbC')]);
      expect(harness.mediaIds.names, ['Film.mkv']);
      expect(harness.engine.opened.single.$1, mediaIdUrl('m1'));
      expect(harness.mediaIds.plays.single.id, 'm1');
    });

    testWidgets('a document on this device, by its descriptor', (tester) async {
      const document = 'content://media/external/video/media/42';
      final harness = PlayerHarness(
        player: urlStreamFixture(document, filename: 'Holiday.mp4'),
      );
      await harness.pump(tester);

      expect(harness.mediaIds.registered, [Uri.parse(document)]);
      expect(harness.mediaIds.names, ['Holiday.mp4']);
      expect(harness.engine.opened.single.$1, mediaIdUrl('m1'));
    });

    testWidgets('an archive member and a kept torrent, as the server URL '
        'they are', (tester) async {
      for (final url in [
        'http://127.0.0.1:39661/rar/create?lz=N4Ig',
        'http://127.0.0.1:39661/11ea02584fa6351956f35671962ab46354d99060/0',
      ]) {
        final harness = PlayerHarness(player: urlStreamFixture(url));
        await harness.pump(tester);

        expect(harness.mediaIds.registered, [Uri.parse(url)], reason: url);
        expect(harness.engine.opened.single.$1, mediaIdUrl('m1'));
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('a route the server serves only over HTTP is handed as it is', (
      tester,
    ) async {
      // `/ftp`, YouTube: the server recognises no id in them (yet), and
      // they play as they did before ids.
      const url = 'http://127.0.0.1:39661/yt/dQw4w9WgXcQ';
      final harness = PlayerHarness(player: urlStreamFixture(url));
      harness.mediaIds.refusal = const MediaRefusal(
        'unrecognisedUrl',
        'not a URL this server serves by id',
      );
      await harness.pump(tester);

      expect(harness.engine.opened.single.$1, Uri.parse(url));
      expect(find.textContaining('Playback failed'), findsNothing);
    });

    testWidgets('an id the server let go is registered again, once', (
      tester,
    ) async {
      final harness = PlayerHarness();
      harness.mediaIds.nextRefusals.add(
        const MediaRefusal('unknownId', 'gone'),
      );
      await harness.pump(tester);

      expect(harness.mediaIds.registered, hasLength(2));
      expect(harness.mediaIds.registered[0], harness.mediaIds.registered[1]);
      expect(harness.engine.opened.single.$1, mediaIdUrl('m2'));
    });
  });
}
