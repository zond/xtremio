import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/speech_input.dart';

/// The Dart half of the speech channel, against the words `SpeechEvents`
/// in `SpeechInput.kt` sends (its own test pins that half).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('every event the Kotlin side sends reads back', () {
    expect(
      SpeechEvent.fromMap({'type': 'partial', 'text': 'the'}),
      isA<SpeechPartial>().having((e) => e.text, 'text', 'the'),
    );
    expect(
      SpeechEvent.fromMap({'type': 'final', 'text': 'the thing'}),
      isA<SpeechFinal>().having((e) => e.text, 'text', 'the thing'),
    );
    for (final error in SpeechError.values) {
      expect(
        SpeechEvent.fromMap({'type': 'error', 'error': error.name}),
        isA<SpeechFailed>().having((e) => e.error, 'error', error),
      );
    }
  });

  test('an error word this build does not know is still an error', () {
    expect(
      SpeechEvent.fromMap({'type': 'error', 'error': 'something new'}),
      isA<SpeechFailed>().having((e) => e.error, 'error', SpeechError.other),
    );
  });

  test('anything else is no event at all', () {
    expect(SpeechEvent.fromMap(null), isNull);
    expect(SpeechEvent.fromMap('partial'), isNull);
    expect(SpeechEvent.fromMap({'type': 'partial'}), isNull);
    expect(SpeechEvent.fromMap({'type': 'ready'}), isNull);
  });

  group('start', () {
    tearDown(
      () => messenger.setMockMethodCallHandler(DeviceProfile.channel, null),
    );

    test('reads every answer, and an unknown one as unavailable', () async {
      for (final answer in SpeechStart.values) {
        messenger.setMockMethodCallHandler(
          DeviceProfile.channel,
          (call) async => answer.name,
        );
        expect(await SpeechInput.start(), answer);
      }
      messenger.setMockMethodCallHandler(
        DeviceProfile.channel,
        (call) async => 'something new',
      );
      expect(await SpeechInput.start(), SpeechStart.unavailable);
    });

    test('is unavailable when the call fails or nobody answers', () async {
      messenger.setMockMethodCallHandler(
        DeviceProfile.channel,
        (call) async => throw PlatformException(code: 'boom'),
      );
      expect(await SpeechInput.start(), SpeechStart.unavailable);
      await SpeechInput.stop();

      messenger.setMockMethodCallHandler(DeviceProfile.channel, null);
      expect(await SpeechInput.start(), SpeechStart.unavailable);
      await SpeechInput.stop();
    });
  });
}
