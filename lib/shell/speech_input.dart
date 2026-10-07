import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'device_profile.dart';

/// How a press of the microphone started (`SpeechInput.kt`, `startSpeech`).
enum SpeechStart {
  /// The recognizer is listening; what it hears arrives on
  /// [SpeechInput.events].
  listening,

  /// Nothing on this device recognizes speech for an app.
  unavailable,

  /// The microphone permission was refused.
  denied,

  /// The permission dialog from an earlier press is still up.
  busy;

  static SpeechStart parse(Object? name) => SpeechStart.values.firstWhere(
    (value) => value.name == name,
    orElse: () => SpeechStart.unavailable,
  );
}

/// What went wrong while listening, in the words the viewer is told: one
/// per thing they could do something about, never Android's code.
enum SpeechError {
  /// `ERROR_NO_MATCH`, `ERROR_SPEECH_TIMEOUT`: nothing was understood.
  noMatch("Didn't catch that."),

  /// `ERROR_AUDIO`: the recognizer could not record. A remote's microphone
  /// may be the system's alone; the keyboard's is the way in then.
  audio('No microphone.'),

  /// `ERROR_INSUFFICIENT_PERMISSIONS`, or the permission refused.
  permission('Voice search needs the microphone permission (Settings).'),

  /// The recognizer's service could not be reached.
  network('No connection for voice.'),

  /// Anything else.
  other('Voice search stopped.');

  const SpeechError(this.message);

  final String message;

  /// Ends in the keyboard screen rather than in nothing: its own
  /// microphone does not need ours.
  bool get opensKeyboard =>
      this == SpeechError.audio || this == SpeechError.permission;

  static SpeechError parse(Object? name) => SpeechError.values.firstWhere(
    (value) => value.name == name,
    orElse: () => SpeechError.other,
  );
}

/// One thing the recognizer said (`SpeechEvents` in `SpeechInput.kt`).
sealed class SpeechEvent {
  const SpeechEvent();

  /// Null for a map this build does not know.
  static SpeechEvent? fromMap(Object? event) {
    if (event is! Map) return null;
    final text = event['text'];
    return switch (event['type']) {
      'partial' when text is String => SpeechPartial(text),
      'final' when text is String => SpeechFinal(text),
      'error' => SpeechFailed(SpeechError.parse(event['error'])),
      _ => null,
    };
  }
}

/// What has been heard so far, while the viewer is still speaking.
class SpeechPartial extends SpeechEvent {
  const SpeechPartial(this.text);
  final String text;
}

/// The transcript; listening is over.
class SpeechFinal extends SpeechEvent {
  const SpeechFinal(this.text);
  final String text;
}

/// Listening ended without one.
class SpeechFailed extends SpeechEvent {
  const SpeechFailed(this.error);
  final SpeechError error;
}

/// Typing by voice, recognized in the app (`SpeechInput.kt`): Android's
/// `SpeechRecognizer`, on-device where Android offers it. The app receives
/// only the text.
///
/// A press is: listen to [events], then [start]; the stream carries partial
/// transcripts, then one final transcript or an error, after which the
/// recognizer is gone. [stop], or cancelling the subscription, ends it
/// early. [TvTextField] is the only caller.
abstract final class SpeechInput {
  static const String startMethod = 'startSpeech';
  static const String stopMethod = 'stopSpeech';

  /// What is heard; subscribe before [start].
  static const EventChannel channel = EventChannel('xtremio/speech');

  static Stream<SpeechEvent> get events => channel
      .receiveBroadcastStream()
      .map(SpeechEvent.fromMap)
      .where((event) => event != null)
      .cast<SpeechEvent>();

  /// Starts listening, asking for the microphone permission first where it
  /// has not been given. Unavailable where there is no platform side or
  /// the call fails.
  static Future<SpeechStart> start({
    MethodChannel device = DeviceProfile.channel,
  }) async {
    try {
      return SpeechStart.parse(await device.invokeMethod<String>(startMethod));
    } on PlatformException catch (error) {
      if (kDebugMode) debugPrint('speech unavailable: ${error.code}');
      return SpeechStart.unavailable;
    } on MissingPluginException {
      return SpeechStart.unavailable;
    }
  }

  /// Stops listening; nothing more arrives.
  static Future<void> stop({
    MethodChannel device = DeviceProfile.channel,
  }) async {
    try {
      await device.invokeMethod<void>(stopMethod);
    } on PlatformException {
      // Nothing was listening.
    } on MissingPluginException {
      // Nothing could have been.
    }
  }
}
