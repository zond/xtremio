import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xtremio/features/player/playback_engine.dart';

import '../../support/player_harness.dart';
import '../../support/tv.dart';

/// Telling mpv what the screen refreshes at.
///
/// mpv cannot measure it on Android -- the video output answers
/// `VO_NOTIMPL` to `VOCTRL_GET_DISPLAY_FPS` -- so it is told
/// (`MediaKitEngine.displayRateProperties`), and the three things that has
/// to get right are what this file is about: the rate is measured rather
/// than asked for, the override is Android's alone, and it comes back off.
///
/// It used to set `video-sync=display-resample` as well, against 2779 vo
/// drops at a matched 23.976 Hz. That was the wrong culprit: display sync
/// never once engaged (`display-sync-active` read `no` throughout) and the
/// drops were the copying decoder delivering frames late. What the option
/// did do was drift the audio against a rate mpv cannot verify. It is gone
/// and the override is on its own; `MediaKitEngine.mpvOverrides` carries
/// the measurements.
void main() {
  /// The rate libmpv reports for the owner's film (`container-fps`), and
  /// the rate his projector settled on for it.
  const filmRate = 23.976025;

  group('the properties', () {
    test('are the measured rate, and nothing else', () {
      expect(
        MediaKitEngine.displayRateProperties(
          filmRate,
          platform: TargetPlatform.android,
        ),
        {'override-display-fps': '23.976025'},
      );
    });

    test('leave video-sync at mpv own default', () {
      // Naming `audio` here would write mpv's own default over itself.
      // What matters is that nothing asks for display sync on any path,
      // because the mode never engages on this VO and asking for it puts
      // the audio on a correction loop against a rate it cannot verify.
      for (final map in [
        MediaKitEngine.displayRateProperties(
          filmRate,
          platform: TargetPlatform.android,
        ),
        MediaKitEngine.displayRateOff,
        MediaKitEngine.mpvOverrides,
      ]) {
        expect(map.containsKey('video-sync'), isFalse);
      }
    });

    test('are nothing at all off Android', () {
      // Every other VO measures the rate itself and is right about it, so
      // an override there replaces a true number with ours -- which is the
      // whole of what this does.
      for (final platform in TargetPlatform.values) {
        if (platform == TargetPlatform.android) continue;
        expect(
          MediaKitEngine.displayRateProperties(filmRate, platform: platform),
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
          MediaKitEngine.displayRateProperties(
            hz,
            platform: TargetPlatform.android,
          ),
          isEmpty,
          reason: '$hz is not a refresh rate',
        );
      }
    });

    test('come back off to mpv own default', () {
      // A zero override is what mpv reads as "no display rate", which is
      // where this started.
      expect(MediaKitEngine.displayRateOff, {'override-display-fps': '0'});
      // The same keys either way: a reset that does not name everything
      // the claim set leaves part of the claim standing.
      expect(
        MediaKitEngine.displayRateOff.keys,
        MediaKitEngine.displayRateProperties(
          filmRate,
          platform: TargetPlatform.android,
        ).keys,
      );
    });

    test('are still not among the properties set once per player', () {
      // The rate belongs to a playback and to a display, not to the
      // player: it is not known when the player is built, it changes
      // underneath, and it has to be given back.
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
    // and a number mpv has to be given rather than have assumed away.
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
