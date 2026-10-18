import 'package:flutter/services.dart';

import 'diagnostics_log.dart';

/// **Keeps the phone's processor running while it converts a film's picture
/// for a receiver.** The conversion runs on this phone's hardware codecs for
/// as long as the receiver keeps asking, often with the screen off. The cast
/// already runs a media playback foreground service, which keeps the process
/// alive but not the processor awake.
///
/// One switch, not a count: [hold] twice is one hold, and one [release] lets
/// it go. The player holds it from a successful publish of a rendition whose
/// picture is converted until that publication is withdrawn
/// (`PlayerScreen._unpublishCast`, which every way out of a cast passes).
/// Behind an interface so the player's widget tests can watch it.
abstract interface class KeepAwake {
  Future<void> hold();
  Future<void> release();
}

/// [KeepAwake] over the `xtremio/power` channel (`PowerChannel.kt`: a
/// partial wake lock, not reference counted, with a six-hour safety timeout,
/// let go when the activity is). Where nothing answers the channel (a
/// desktop, a test) it does nothing.
class ChannelKeepAwake implements KeepAwake {
  const ChannelKeepAwake({this.channel = const MethodChannel('xtremio/power')});

  final MethodChannel channel;

  @override
  Future<void> hold() => _call('holdAwake');

  @override
  Future<void> release() => _call('releaseAwake');

  Future<void> _call(String method) async {
    try {
      await channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // No platform side here: nothing to keep awake.
    } catch (error) {
      DiagnosticsLog.warn(
        'player',
        'the wake lock call $method failed: ${error.runtimeType}',
      );
    }
  }
}
