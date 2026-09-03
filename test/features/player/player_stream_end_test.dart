import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/up_next_card.dart';
import 'package:xtremio/features/player/track_menus.dart';

import '../../support/diagnostics_capture.dart';
import '../../support/fake_prefs_client.dart';
import '../../support/fixtures.dart';
import '../../support/player_harness.dart';

/// What the player does when the stream stops instead of ending.
///
/// libmpv is started by media_kit with `network-timeout=5` and
/// `keep-open=yes`: a read that makes no progress for five seconds arrives
/// as an end of file rather than an error, and our own server routinely
/// takes longer than that to produce the next piece of a torrent on a thin
/// swarm. Believed, that "ending" marks a film watched ten seconds in and
/// media_kit's next `play()` seeks back to 0 -- which is what "it plays ten
/// seconds and starts over" was.
void main() {
  /// Every `Ended` the core was told about.
  int endings(PlayerHarness harness) => harness.core.dispatched
      .where((action) => action.action['args']?['action'] == 'Ended')
      .length;

  test('the mpv properties this app overrides', () {
    // media_kit 1.2.6 sets `network-timeout=5`; a torrent legitimately
    // takes minutes. The value is not asserted exactly, only that it is
    // long enough to outlast a slow swarm.
    final timeout = MediaKitEngine.mpvOverrides['network-timeout'];
    expect(timeout, isNotNull);
    expect(int.parse(timeout!), greaterThanOrEqualTo(120));
  });

  testWidgets('an end of file early in the film is not the end of the film', (
    tester,
  ) async {
    final lines = captureDiagnostics();
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(hours: 2));
    harness.engine.emitPosition(const Duration(seconds: 10));
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);

    harness.engine.emitCompleted();
    await pumpEvents(tester);

    // Nothing is reported to the core: `Ended` writes the library item to
    // the end of the film, and no later correction takes that back.
    expect(endings(harness), 0);
    expect(find.byType(UpNextCard), findsNothing);
    // The stream is re-opened where playback stopped -- mpv sits at the end
    // of the file and will not go on by itself -- and the report says so.
    expect(harness.engine.opened, hasLength(2));
    expect(harness.engine.opened[1].$2, const Duration(seconds: 10));
    expect(lines, contains('info player completed at 10s of 7200s'));
    expect(
      lines.where((line) => line.contains('is not the end of the media')),
      hasLength(1),
    );
  });

  testWidgets('an end of file at the end of the film is the end of it', (
    tester,
  ) async {
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(hours: 2));
    harness.engine.emitPosition(
      const Duration(hours: 2) - const Duration(seconds: 4),
    );
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);

    harness.engine.emitCompleted();
    await pumpEvents(tester);

    expect(endings(harness), 1);
    expect(harness.engine.opened, hasLength(1));
  });

  testWidgets('a stream that ends early every time is a failure in the end', (
    tester,
  ) async {
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(hours: 2));
    harness.engine.emitPosition(const Duration(seconds: 10));
    await pumpEvents(tester);

    for (var i = 0; i <= PlayerScreen.falseEndRecoveries; i++) {
      harness.engine.emitCompleted();
      await pumpEvents(tester);
    }
    expect(endings(harness), 0);
    expect(
      harness.engine.opened,
      hasLength(1 + PlayerScreen.falseEndRecoveries),
    );
    expect(find.textContaining('stopped sending data'), findsOneWidget);
  });

  testWidgets('mpv\'s own error log is captured for the report', (
    tester,
  ) async {
    final lines = captureDiagnostics();
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitEngineLog('ffmpeg/demuxer: tcp: Connection timed out');
    await pumpEvents(tester);
    expect(
      lines,
      contains('warn mpv ffmpeg/demuxer: tcp: Connection timed out'),
    );
  });

  testWidgets('a re-open before the media loaded keeps the resume point', (
    tester,
  ) async {
    // media_kit reports `position: 0` as soon as an open is issued, so the
    // position means nothing until the media is in: a buffer change while
    // the start-up card is still up must not restart the film.
    final prefs = AppPrefs(client: FakePrefsClient());
    await prefs.load();
    final fixture = loadPlayerFixture();
    (fixture['libraryItem'] as Map<String, dynamic>)['state'] = {
      'timeOffset': 720000,
      'duration': 5760000,
    };
    final harness = PlayerHarness(player: fixture, prefs: prefs);
    useWideViewport(tester);
    await harness.pump(tester);
    expect(harness.engine.opened.single.$2, const Duration(minutes: 12));

    // No duration yet: the torrent is still starting up. media_kit says 0.
    harness.engine.emitPosition(Duration.zero);
    await pumpEvents(tester);
    await tester.tap(find.byTooltip('Playback settings'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(PlayerSettingsSheet.bufferChipKey(BufferAhead.maximum)),
    );
    await tester.pumpAndSettle();

    expect(harness.engine.opened, hasLength(2));
    expect(harness.engine.opened[1].$2, const Duration(minutes: 12));
  });
}
