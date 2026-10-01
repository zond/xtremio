import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../../support/fixtures.dart';
import '../../support/player_harness.dart';

/// Where continue-watching resumes: the core's `time_offset`, which only
/// two actions move.
///
/// stremio-core (`models/player.rs`) takes a `Seek`'s time as it is, and a
/// `TimeChanged`'s only when it is *later* than the offset it holds -- "if
/// we seek forward, time will be < time_offset, this is the only thing we
/// can guard against", and for a seek back it expects the app to have
/// said `Seek`. So a seek back that reached the core only as `TimeChanged`
/// left the library on the old timeline: on a phone, a seek from 30:32 to
/// 15:45 played on correctly and resumed at 30:3x next time.
void main() {
  const resume = Duration(minutes: 30, seconds: 28);
  const back = Duration(minutes: 15, seconds: 45);
  const total = Duration(hours: 2, minutes: 4);

  Map<String, dynamic> resumable() {
    final fixture = loadPlayerFixture();
    (fixture['libraryItem'] as Map<String, dynamic>)['state'] = {
      'timeOffset': resume.inMilliseconds,
      'duration': total.inMilliseconds,
    };
    return fixture;
  }

  /// The core's offset after everything the screen has dispatched, by the
  /// core's own rule, from the library's [resume].
  Duration coreOffset(PlayerHarness harness) {
    var offset = resume.inMilliseconds;
    for (final action in harness.core.dispatched) {
      if (action.action['action'] != 'Player') continue;
      final args = action.action['args'] as Map<String, dynamic>;
      final time = (args['args'] as Map<String, dynamic>?)?['time'] as int?;
      if (time == null) continue;
      switch (args['action']) {
        case 'Seek':
          offset = time;
        case 'TimeChanged':
          if (time > offset) offset = time;
      }
    }
    return Duration(milliseconds: offset);
  }

  PlayerProbe probe(WidgetTester tester) =>
      tester.state(find.byType(PlayerScreen)) as PlayerProbe;

  /// The film playing on from [from] for [seconds], one report a second.
  Future<void> plays(
    WidgetTester tester,
    PlayerHarness harness,
    Duration from,
    int seconds,
  ) async {
    for (var s = 1; s <= seconds; s++) {
      await tester.pump(const Duration(seconds: 1));
      harness.engine.emitPosition(from + Duration(seconds: s));
      await pumpEvents(tester);
    }
  }

  testWidgets('a seek back once the film plays moves continue-watching', (
    tester,
  ) async {
    useWideViewport(tester);
    final harness = PlayerHarness(player: resumable());
    await harness.pump(tester);
    harness.engine.emitPlaying(true);
    harness.engine.emitPosition(resume);
    harness.engine.emitDuration(total);
    await pumpEvents(tester);
    await plays(tester, harness, resume, 4);
    expect(coreOffset(harness), resume + const Duration(seconds: 4));

    probe(tester).seekTo(back);
    await pumpEvents(tester);
    await plays(tester, harness, back, 14);
    expect(coreOffset(harness), back + const Duration(seconds: 14));
    // Said once: the positions after it are the film going on from there.
    expect(harness.playerActions().where((a) => a == 'Seek'), hasLength(1));
  });

  testWidgets('a seek back before the duration is known still reaches the '
      'core', (tester) async {
    // The phone showed a duration of 00:00 for the first seconds, and a
    // `Seek` needs one: the seek went unsaid, and every later `TimeChanged`
    // was behind the offset the core held.
    useWideViewport(tester);
    final harness = PlayerHarness(player: resumable());
    await harness.pump(tester);
    harness.engine.emitPlaying(true);
    harness.engine.emitPosition(resume);
    await pumpEvents(tester);
    await plays(tester, harness, resume, 4);

    probe(tester).seekTo(back);
    await pumpEvents(tester);
    await plays(tester, harness, back, 3);
    harness.engine.emitDuration(total);
    await pumpEvents(tester);
    await plays(tester, harness, back + const Duration(seconds: 3), 5);

    expect(coreOffset(harness), back + const Duration(seconds: 8));
  });

  testWidgets('a rewind the screen never made reaches the core too', (
    tester,
  ) async {
    // The remote's rewind key reaches mpv directly; the screen only sees
    // the position go back.
    useWideViewport(tester);
    final harness = PlayerHarness(player: resumable());
    await harness.pump(tester);
    harness.engine.emitPlaying(true);
    harness.engine.emitPosition(resume);
    harness.engine.emitDuration(total);
    await pumpEvents(tester);
    await plays(tester, harness, resume, 3);

    harness.engine.emitPosition(back);
    await pumpEvents(tester);
    await plays(tester, harness, back, 3);
    expect(coreOffset(harness), back + const Duration(seconds: 3));
  });

  testWidgets('leaving tells the core the last position, not the last '
      'one a throttled report sent', (tester) async {
    final harness = PlayerHarness(player: resumable());
    await harness.pumpPushed(tester);
    harness.engine.emitPlaying(true);
    harness.engine.emitPosition(resume);
    harness.engine.emitDuration(total);
    await pumpEvents(tester);
    await plays(tester, harness, resume, 3);
    // Within the report interval of the last one, so not sent yet.
    const last = Duration(minutes: 30, seconds: 31, milliseconds: 600);
    harness.engine.emitPosition(last);
    await pumpEvents(tester);
    expect(coreOffset(harness), resume + const Duration(seconds: 3));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(coreOffset(harness), last);
  });
}
