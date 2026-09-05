import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'device_profile.dart';

/// Asks the display to present the picture at the rate the picture is.
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
abstract interface class DisplayFrameRate {
  /// Asks for a mode that presents [fps] frames a second evenly.
  Future<void> request(double fps);

  /// Gives the rate back, whatever was asked for and whether or not the
  /// platform ever acted on it.
  Future<void> clear();
}

/// [DisplayFrameRate] over the `xtremio/device` channel, which
/// `MainActivity` answers (`Surface.setFrameRate` on Android 12 and up,
/// the window's `preferredDisplayModeId` below it; see ANDROID.md).
///
/// Only a television is ever asked, and that gate is the caller's --
/// [DeviceProfile.isTv], which no platform but Android ever reports. So
/// every other platform's answer here is the same one a missing handler
/// gives, and both are swallowed: a display that will not switch is the
/// display every build had until now, and there is nothing for a viewer
/// to do about it.
class ChannelDisplayFrameRate implements DisplayFrameRate {
  const ChannelDisplayFrameRate({this.channel = DeviceProfile.channel});

  final MethodChannel channel;

  @override
  Future<void> request(double fps) => _call('setFrameRate', {'fps': fps});

  @override
  Future<void> clear() => _call('clearFrameRate', null);

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
