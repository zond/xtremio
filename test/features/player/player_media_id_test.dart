import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../../support/player_harness.dart';

/// A torrent is played by its media id: registered with the server,
/// resolved there, and only then handed to mpv as `xtremio://<id>`.
///
/// The resolve is the app's and not mpv's because it can take as long as a
/// magnet's metadata, and an open inside mpv's `stream_cb` cannot be
/// cancelled -- so what these hold is what the screen does with that wait
/// and with the server's answer.
void main() {
  /// Long enough for every retry the player will make.
  Future<void> waitOutTheRetries(WidgetTester tester) async {
    for (var i = 0; i < PlayerScreen.torrentOpenRetries + 2; i++) {
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
}
