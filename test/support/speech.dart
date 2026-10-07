/// The platform's speech recognizer, faked: what a television's microphone
/// button talks to (`SpeechInput.kt`).
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/speech_input.dart';
import 'package:xtremio/shell/tv_text_entry.dart';

/// Answers `startSpeech` with [answer], `editText` (the keyboard screen)
/// with [typed], and lets a test say what the recognizer heard while the
/// stream is listened to. Records the `xtremio/device` methods called.
///
/// Both channels are put back on tear-down.
class FakeSpeech {
  FakeSpeech({this.answer = SpeechStart.listening, this.typed, this.gate}) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(DeviceProfile.channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        SpeechInput.startMethod => await _started(),
        TvTextEntry.method => typed,
        _ => null,
      };
    });
    messenger.setMockStreamHandler(
      SpeechInput.channel,
      MockStreamHandler.inline(
        onListen: (_, sink) {
          _sink = sink;
        },
        onCancel: (_) {
          _sink = null;
          cancels++;
        },
      ),
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(DeviceProfile.channel, null);
      messenger.setMockStreamHandler(SpeechInput.channel, null);
    });
  }

  SpeechStart answer;
  String? typed;

  /// Holds `startSpeech`'s answer until the test completes it: the
  /// permission dialog being up.
  final Completer<void>? gate;

  Future<String> _started() async {
    await gate?.future;
    return answer.name;
  }

  /// Every method called on `xtremio/device`, in order.
  final List<String> calls = [];

  /// How many times the events stream was let go of.
  int cancels = 0;

  MockStreamHandlerEventSink? _sink;

  /// Somebody is listening to what is heard.
  bool get listenedTo => _sink != null;

  void partial(String text) =>
      _sink!.success({'type': 'partial', 'text': text});

  void finish(String text) => _sink!.success({'type': 'final', 'text': text});

  void fail(SpeechError error) =>
      _sink!.success({'type': 'error', 'error': error.name});
}
