import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart' show CoreField;
import 'package:xtremio/features/cast/cast_client.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../../support/fake_cast_client.dart';
import '../../support/fake_playback_engine.dart';
import '../../support/fixtures.dart';
import '../../support/player_harness.dart';
import 'player_cast_test.dart' show castTo, lanBase, livingRoom;

/// A seek made before the file is in belongs to the viewer, not to the
/// resume point the open started from.
///
/// mpv refuses a `seek` until it has opened the file, and media_kit drops
/// the refusal. What it does apply, once the file is open, is the open's
/// `start` -- the library's resume point. So a seek in the first seconds
/// (media_kit reports `playing` at the `loadfile`, and the bar shows the
/// resume point while the duration still reads zero) was lost, and the
/// film played on from where it had been left: on a phone, a seek to 15:35
/// answered 15:35 and was back at 1:05:47 fifteen seconds later.
///
/// The fake engine records every seek and drops none, so each test plays
/// the real engine's order of events: the open's own stop (`0`, `0`),
/// `playing`, the viewer's seek, and only then the file -- a position at
/// the resume point, the duration late, buffering ending.
void main() {
  const resumeAt = Duration(hours: 1, minutes: 5, seconds: 38);
  const total = Duration(hours: 2, minutes: 4);
  const sought = Duration(minutes: 15, seconds: 35);

  /// The recorded player state, saved at [resumeAt] of [total].
  Map<String, dynamic> resumable([Map<String, dynamic>? player]) {
    final fixture = player ?? loadPlayerFixture();
    (fixture['libraryItem'] as Map<String, dynamic>)['state'] = {
      'timeOffset': resumeAt.inMilliseconds,
      'duration': total.inMilliseconds,
    };
    return fixture;
  }

  PlayerProbe probe(WidgetTester tester) =>
      tester.state(find.byType(PlayerScreen)) as PlayerProbe;

  Duration shown(WidgetTester tester) =>
      Duration(milliseconds: probe(tester).probe()['positionMs']! as int);

  /// The screen up and its open on the way, the file not in yet: the
  /// engine has reported the open's stop and `playing`, nothing else.
  Future<PlayerHarness> opening(
    WidgetTester tester, {
    PlayerHarness? harness,
  }) async {
    useWideViewport(tester);
    harness ??= PlayerHarness(player: resumable());
    await harness.pump(tester);
    expect(harness.engine.opened.single.$2, resumeAt);
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);
    expect(probe(tester).probe()['mediaLoaded'], isTrue);
    expect(probe(tester).probe()['durationMs'], 0);
    return harness;
  }

  /// The file comes in where mpv's `start` put it, as the phone showed it.
  Future<void> fileComesIn(WidgetTester tester, PlayerHarness harness) async {
    harness.engine.emitPosition(resumeAt);
    await pumpEvents(tester);
    harness.engine.emitPosition(resumeAt + const Duration(seconds: 1));
    harness.engine.emitDuration(total);
    harness.engine.emitBuffering(true);
    await pumpEvents(tester);
    harness.engine.emitBuffering(false);
    await pumpEvents(tester);
  }

  testWidgets('a seek before the file is in is made again once it is', (
    tester,
  ) async {
    final harness = await opening(tester);
    probe(tester).seekTo(sought);
    await pumpEvents(tester);
    expect(shown(tester), sought);

    final before = harness.engine.seeks.length;
    await fileComesIn(tester, harness);

    // mpv dropped the first one; this is the one it takes.
    expect(harness.engine.seeks.skip(before), [sought]);
    expect(harness.engine.seeks.last, sought);
    // And the resume point's reports never reached the bar or the core.
    expect(shown(tester), sought);
    final told = harness.lastPlayerArgs('TimeChanged')?['time'] as int?;
    expect(told == null || told < resumeAt.inMilliseconds, isTrue);

    // The seek lands, and the bar and the core follow the film from there.
    harness.engine.emitPosition(sought);
    await pumpEvents(tester);
    harness.engine.emitPosition(sought + const Duration(seconds: 12));
    await pumpEvents(tester);
    expect(shown(tester), sought + const Duration(seconds: 12));
    expect(
      harness.lastPlayerArgs('TimeChanged')?['time'],
      (sought + const Duration(seconds: 12)).inMilliseconds,
    );
    expect(harness.engine.seeks.last, sought, reason: 'nothing seeks back');
    await tester.pump(PlayerScreen.seekCheckDelay * 2);
  });

  testWidgets('a step before the file is in is a seek, held the same way', (
    tester,
  ) async {
    // A relative step is relative to where mpv is, and mpv is nowhere yet.
    final harness = await opening(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await pumpEvents(tester);
    final target = shown(tester);
    expect(target, lessThan(resumeAt));
    expect(harness.engine.scans, isEmpty);

    final before = harness.engine.seeks.length;
    await fileComesIn(tester, harness);
    expect(harness.engine.seeks.skip(before), [target]);
    await tester.pump(PlayerScreen.seekCheckDelay * 2);
  });

  testWidgets('a seek that lands at once is not made twice', (tester) async {
    final harness = await opening(tester);
    probe(tester).seekTo(sought);
    await pumpEvents(tester);
    final before = harness.engine.seeks.length;

    harness.engine.emitPosition(sought);
    harness.engine.emitDuration(total);
    await pumpEvents(tester);
    harness.engine.emitPosition(sought + const Duration(seconds: 1));
    await pumpEvents(tester);

    expect(harness.engine.seeks.length, before);
    expect(shown(tester), sought + const Duration(seconds: 1));
    await tester.pump(PlayerScreen.seekCheckDelay * 2);
  });

  testWidgets('a seek mpv will not make lets the bar go after a while', (
    tester,
  ) async {
    // An unseekable file: mpv restores its position whatever is asked. The
    // bar is held for the seek check's length, never for good.
    final harness = await opening(tester);
    probe(tester).seekTo(sought);
    await pumpEvents(tester);
    await fileComesIn(tester, harness);
    await tester.pump(PlayerScreen.seekCheckDelay);
    harness.engine.emitPosition(resumeAt + const Duration(seconds: 4));
    await pumpEvents(tester);
    expect(shown(tester), resumeAt + const Duration(seconds: 4));
    await tester.pump(PlayerScreen.seekCheckDelay * 2);
  });

  testWidgets('leaving while a seek is held leaves nothing running', (
    tester,
  ) async {
    final harness = await opening(tester);
    probe(tester).seekTo(sought);
    await pumpEvents(tester);
    await fileComesIn(tester, harness);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('a retry before the file is in opens where the viewer sought', (
    tester,
  ) async {
    useWideViewport(tester);
    final harness = PlayerHarness(
      player: resumable(),
      configureEngine: (engine) => engine.openError = 'Failed to open',
    );
    harness.torrentStats.response = const TorrentStats(
      phase: TorrentPhase.resolvingMetadata,
    );
    await tester.pumpWidget(harness.build());
    await pumpEvents(tester);
    expect(harness.engine.opened.single.$2, resumeAt);

    probe(tester).seekTo(sought);
    harness.engine.openError = null;
    await tester.pump(PlayerScreen.openRetryBackoffCap);
    await pumpEvents(tester);

    expect(harness.engine.opened.length, greaterThan(1));
    expect(harness.engine.opened.last.$2, sought);
  });

  testWidgets('a re-open after a false end opens where playback is now', (
    tester,
  ) async {
    // The second false end waits before it re-opens; a seek in that wait
    // is where the viewer is, and the re-open must not take them back to
    // where the end happened.
    useWideViewport(tester);
    final harness = PlayerHarness(player: resumable());
    await harness.pump(tester);
    final engine = harness.engine;
    const stopped = Duration(minutes: 70);
    for (var end = 0; end < 2; end++) {
      engine.emitDuration(total);
      engine.emitPosition(stopped);
      engine.emitPlaying(false);
      engine.emitCompleted();
      await pumpEvents(tester);
    }
    final opens = engine.opened.length;
    expect(opens, 2, reason: 'the first false end re-opens at once');

    probe(tester).seekTo(sought);
    await pumpEvents(tester);
    await tester.pump(PlayerScreen.openRetryBackoffCap);
    await pumpEvents(tester);

    expect(engine.opened.length, opens + 1);
    expect(engine.opened.last.$2, sought);
    await tester.pump(PlayerScreen.seekCheckDelay * 2);
  });

  testWidgets('a seek while a re-open loads is held like the first one', (
    tester,
  ) async {
    // The file before the re-open did report positions; they say nothing
    // about whether the re-opened one is in.
    useWideViewport(tester);
    final harness = PlayerHarness(player: resumable());
    await harness.pump(tester);
    final engine = harness.engine;
    const stopped = Duration(minutes: 70);
    engine.emitDuration(total);
    engine.emitPosition(stopped);
    engine.emitPlaying(false);
    engine.emitCompleted();
    await pumpEvents(tester);
    expect(engine.opened.last.$2, stopped, reason: 're-opened at once');

    probe(tester).seekTo(sought);
    await pumpEvents(tester);
    final before = engine.seeks.length;
    engine.emitPosition(stopped);
    await pumpEvents(tester);

    expect(engine.seeks.skip(before), [sought]);
    expect(shown(tester), sought);
    await tester.pump(PlayerScreen.seekCheckDelay * 2);
  });

  testWidgets('another stream drops a seek held for the last one', (
    tester,
  ) async {
    final harness = await opening(tester);
    probe(tester).seekTo(sought);
    await pumpEvents(tester);

    // The core moves on to another file (the next episode, another
    // source) before the first one came in.
    final next = resumable();
    final content =
        (next['stream'] as Map<String, dynamic>)['content'] as List<dynamic>;
    final urls = content[0] as Map<String, dynamic>;
    urls['streaming_url'] = (urls['streaming_url'] as String).replaceFirst(
      RegExp(r'/0(?=\?|$)'),
      '/1',
    );
    harness.core.setState(CoreField.player, next);
    await pumpEvents(tester);
    expect(harness.engine.opened, hasLength(2));
    final before = harness.engine.seeks.length;

    harness.engine.emitPosition(resumeAt);
    await pumpEvents(tester);
    expect(harness.engine.seeks.length, before);
    expect(shown(tester), resumeAt);
  });

  testWidgets('a cast started after an early seek starts where the viewer '
      'sought', (tester) async {
    useWideViewport(tester);
    final cast = FakeCastClient(devices: const [livingRoom]);
    final harness = await opening(
      tester,
      harness: PlayerHarness(
        player: resumable(),
        cast: cast,
        lanMedia: FakeLanMediaControl()..baseUrl = lanBase,
        mpvReport: mpvMp4H264Aac,
      ),
    );
    probe(tester).seekTo(sought);
    await pumpEvents(tester);
    harness.engine.emitPosition(resumeAt);
    harness.engine.emitDuration(total);
    await pumpEvents(tester);

    await castTo(tester, livingRoom);
    expect(cast.loads.single.$2, sought);
  });

  testWidgets('a cast stopped before the file is in seeks it once it is', (
    tester,
  ) async {
    useWideViewport(tester);
    final cast = FakeCastClient(devices: const [livingRoom]);
    final harness = await opening(
      tester,
      harness: PlayerHarness(
        player: resumable(),
        cast: cast,
        lanMedia: FakeLanMediaControl()..baseUrl = lanBase,
        mpvReport: mpvMp4H264Aac,
      ),
    );
    await castTo(tester, livingRoom);
    cast.emitStatus(
      const CastStatus(state: CastPlayerState.playing, position: sought),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cast-stop-button')));
    await tester.pumpAndSettle();

    final before = harness.engine.seeks.length;
    await fileComesIn(tester, harness);
    expect(harness.engine.seeks.skip(before), [sought]);
    expect(shown(tester), sought);
    await tester.pump(PlayerScreen.seekCheckDelay * 2);
  });
}
