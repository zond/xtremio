import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'device_profile.dart';

/// Asks the display to present the picture at the rate the picture is, and
/// reports back what the display is really doing.
///
/// A 23.976 fps film on a 59.94 Hz output is shown on a 3:2 cadence --
/// two refreshes for one frame, three for the next -- which is what a
/// viewer sees as the picture jumping, and the frames that miss their
/// vsync are dropped at the video output while the decoder drops none.
/// Asking removes the cadence rather than covering it up: the panel runs
/// at the film's own rate and every frame is shown for the same length of
/// time.
///
/// [request] while a film is playing and [clear] the moment it is not.
/// Whatever the state of the display, that pair is the whole contract: a
/// television left at 24 Hz makes the system UI judder, which is a worse
/// fault than the one being asked about.
///
/// [refreshRate] is the other direction and is *not* the answer to a
/// request: it is what the display arrived at, which can be the rate asked
/// for, a neighbouring mode, or the rate it was already on. Both platform
/// paths are votes that report nothing back, so the only honest source for
/// "what is the screen doing now" is the display itself, afterwards.
abstract interface class DisplayFrameRate {
  /// Asks for a mode that presents [fps] frames a second evenly.
  Future<void> request(double fps);

  /// Gives the rate back, whatever was asked for and whether or not the
  /// platform ever acted on it.
  Future<void> clear();

  /// What the display is refreshing at, in hertz, re-emitted whenever it
  /// changes -- and once as soon as it is listened to, since a display
  /// that never changes would otherwise never report anything.
  ///
  /// The consumer is libmpv, which cannot measure this on Android and so
  /// has to be told (`MediaKitEngine.displayRateProperties`). Nothing is
  /// emitted where the platform has no such reading, which is everywhere
  /// but Android.
  Stream<double> get refreshRate;
}

/// [DisplayFrameRate] over the `xtremio/device` channel, which
/// `MainActivity` answers (`Surface.setFrameRate` on Android 12 and up,
/// the window's `preferredDisplayModeId` below it; see ANDROID.md), and
/// the `xtremio/display` event channel, which it pushes the live rate on.
///
/// Only a television is ever asked, and that gate is the caller's --
/// [DeviceProfile.isTv], which no platform but Android ever reports. So
/// every other platform's answer here is the same one a missing handler
/// gives, and both are swallowed: a display that will not switch is the
/// display every build had until now, and there is nothing for a viewer
/// to do about it.
class ChannelDisplayFrameRate implements DisplayFrameRate {
  const ChannelDisplayFrameRate({
    this.channel = DeviceProfile.channel,
    this.rates = refreshRateChannel,
  });

  final MethodChannel channel;

  /// Where `MainActivity` pushes the display's live rate from, registering
  /// its `DisplayManager.DisplayListener` for exactly as long as this is
  /// subscribed to.
  final EventChannel rates;

  static const EventChannel refreshRateChannel = EventChannel(
    'xtremio/display',
  );

  @override
  Future<void> request(double fps) => _call('setFrameRate', {'fps': fps});

  @override
  Future<void> clear() => _call('clearFrameRate', null);

  /// A stream rather than a call because the reading changes on its own:
  /// the mode switch a [request] provokes lands a moment after the ask,
  /// and the viewer's own settings can move it later still.
  ///
  /// A rate that is not a rate is dropped rather than passed on. mpv reads
  /// a zero `override-display-fps` as "no rate at all" and goes quietly
  /// back to timing against the audio clock, so a bad number would look
  /// exactly like the fault this exists to remove.
  ///
  /// An error is swallowed for the reason the calls above are: on a
  /// platform with no such channel the stream simply never emits, and
  /// there is nothing a viewer could do about it if it said so.
  @override
  Stream<double> get refreshRate => rates
      .receiveBroadcastStream()
      .handleError((Object error) {
        if (kDebugMode) debugPrint('display refresh rate unavailable: $error');
      })
      .map((rate) => rate is num ? rate.toDouble() : double.nan)
      .where((hz) => hz.isFinite && hz > 0);

  Future<void> _call(String method, Map<String, Object?>? arguments) async {
    try {
      await channel.invokeMethod<void>(method, arguments);
    } on PlatformException catch (error) {
      if (kDebugMode) debugPrint('display frame rate refused: $error');
    } on MissingPluginException catch (error) {
      if (kDebugMode) debugPrint('display frame rate unavailable: $error');
    }
  }
}
