import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xtremio/features/player/playback_engine.dart';

import '../../support/player_harness.dart';
import '../../support/tv.dart';

/// Telling mpv when the screen refreshes.
///
/// Asking the television for the film's own rate removed the cadence and
/// did not remove the drops: on the owner's Chromecast, a 23.976 fps film
/// on a projector confirmed at 23.976 Hz still read `2779 vo / 0 decoder`
/// -- every frame decoded on time and one in five thrown away at
/// presentation. mpv was timing against the audio clock with no idea when
/// the screen refreshes, because the Android video output answers
/// `VO_NOTIMPL` to `VOCTRL_GET_DISPLAY_FPS`. So it is told
/// (`MediaKitEngine.displaySyncProperties`), and the three things that has
/// to get right are what this file is about: the rate is measured rather
/// than asked for, the override is Android's alone, and both properties
/// come back off.
void main() {
  /// The rate libmpv reports for the owner's film (`container-fps`), and
  /// the rate his projector settled on for it.
  const filmRate = 23.976025;

  group('the properties', () {
    test('are the pair, on the measured rate, with the rate first', () {
      final properties = MediaKitEngine.displaySyncProperties(
        filmRate,
        platform: TargetPlatform.android,
      );
      expect(properties, {
        'override-display-fps': '23.976025',
        'video-sync': 'display-resample',
      });
      // Neither is any use alone: the override is the only display-rate
      // gate in `handle_display_sync_frame`, and `video-sync` is what asks
      // for display sync at all. And the rate goes on first -- resampling
      // asked for while the override is still 0 is display sync with no
      // display rate, which is the state being escaped.
      expect(properties.keys.first, 'override-display-fps');
    });

    test('are nothing at all off Android', () {
      // Every other VO measures the rate itself and is right about it, so
      // an override there replaces a true number with ours -- which is the
      // whole of what this does.
      for (final platform in TargetPlatform.values) {
        if (platform == TargetPlatform.android) continue;
        expect(
          MediaKitEngine.displaySyncProperties(filmRate, platform: platform),
          isEmpty,
          reason: '$platform measures its own rate',
        );
      }
    });

    test('are nothing when the rate is not a rate', () {
      // Nothing measured, nothing to claim. mpv reads a zero override as
      // "no display rate" and goes quietly back to the audio clock, so a
      // bad number looks exactly like the fault this exists to remove.
      for (final hz in <double?>[null, 0, -60, double.nan, double.infinity]) {
        expect(
          MediaKitEngine.displaySyncProperties(
            hz,
            platform: TargetPlatform.android,
          ),
          isEmpty,
          reason: '$hz is not a refresh rate',
        );
      }
    });

    test('come back off to mpv own defaults', () {
      // A zero override is what mpv reads as "no display rate", which is
      // where this started, and `audio` is its own `video-sync` default.
      expect(MediaKitEngine.displaySyncOff, {
        'override-display-fps': '0',
        'video-sync': 'audio',
      });
      // The same two keys either way: half a reset leaves mpv resampling
      // to a mode nobody is in.
      expect(
        MediaKitEngine.displaySyncOff.keys,
        MediaKitEngine.displaySyncProperties(
          filmRate,
          platform: TargetPlatform.android,
        ).keys,
      );
    });

    test('are still not among the properties set once per player', () {
      // They belong to a playback and to a display, not to the player: the
      // rate is not known when it is built, it changes underneath, and it
      // has to be given back.
      expect(MediaKitEngine.mpvOverrides.containsKey('video-sync'), isFalse);
      expect(
        MediaKitEngine.mpvOverrides.containsKey('override-display-fps'),
        isFalse,
      );
    });
  });

  testWidgets('mpv is given the rate the display settled on, not the rate it '
      'was asked for', (tester) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv);
    await harness.pump(tester);

    harness.engine.emitVideoFrameRate(filmRate);
    await pumpEvents(tester);
    expect(harness.displayFrameRate.requested, [filmRate]);

    // The mode switch is asynchronous and neither platform path reports
    // back, so this is the display arriving somewhere else -- a 24.0 Hz
    // mode for a 23.976 fps film, which is a mode every television offers
    // and a rate mpv must resample against rather than assume away.
    harness.displayFrameRate.reportRefreshRate(24);
    await pumpEvents(tester);

    expect(harness.engine.displayRefreshRates.last, 24);
    expect(harness.engine.displayRefreshRates, isNot(contains(filmRate)));
  });

  testWidgets('a rate reported before anything was asked for sets nothing', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv);
    await harness.pump(tester);

    // The display reports once as soon as it is listened to, which is
    // before any film has said what rate it is. Nothing is being presented
    // yet, so there is nothing for mpv to sync to.
    harness.displayFrameRate.reportRefreshRate(59.94);
    await pumpEvents(tester);

    expect(harness.engine.displayRefreshRates, isEmpty);
  });

  testWidgets('a display already on the right rate still reaches mpv', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv);
    await harness.pump(tester);

    // The panel is on 23.976 before the film opens -- the last film left
    // it there. Nothing changes, so nothing more is reported, and the ask
    // is where the rate already in hand has to reach the engine.
    harness.displayFrameRate.reportRefreshRate(filmRate);
    await pumpEvents(tester);
    harness.engine.emitVideoFrameRate(filmRate);
    await pumpEvents(tester);

    expect(harness.engine.displayRefreshRates.last, filmRate);
  });

  testWidgets('both come off when the film ends', (tester) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv);
    await harness.pump(tester);
    harness.engine.emitVideoFrameRate(filmRate);
    harness.displayFrameRate.reportRefreshRate(filmRate);
    await pumpEvents(tester);
    expect(harness.engine.displayRefreshRates.last, filmRate);

    harness.engine.emitEnd();
    await pumpEvents(tester);

    // The platform takes the mode back at the same moment, so an override
    // left standing describes a display nobody is looking at.
    expect(harness.displayFrameRate.clears, 1);
    expect(harness.engine.displayRefreshRates.last, isNull);
  });

  testWidgets('both come off when the player is left', (tester) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv);
    await harness.pump(tester);
    harness.engine.emitVideoFrameRate(filmRate);
    harness.displayFrameRate.reportRefreshRate(filmRate);
    await pumpEvents(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.mediaStop);
    await pumpEvents(tester);

    expect(harness.engine.displayRefreshRates.last, isNull);
  });

  testWidgets('a phone tells mpv nothing, either way', (tester) async {
    usePhoneViewport(tester);
    final harness = PlayerHarness();
    await harness.pump(tester);

    harness.engine.emitVideoFrameRate(filmRate);
    harness.displayFrameRate.reportRefreshRate(60);
    await pumpEvents(tester);
    harness.engine.emitEnd();
    await pumpEvents(tester);

    // Nothing asks for a rate off a television, so nothing holds one, so
    // there is nothing to say to mpv -- not even a reset for a claim that
    // was never made.
    expect(harness.engine.displayRefreshRates, isEmpty);
  });
}
