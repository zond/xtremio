/// The platform's text-entry screen, faked: what a television types with.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/tv_text_entry.dart';

/// Answers every [TvTextEntry.edit] with [typed] -- null being a screen
/// that was cancelled -- and returns the calls as they are made.
///
/// The channel is put back on tear-down. Nothing else in a widget test
/// speaks to `xtremio/device`: the device profile is handed down by a
/// `DeviceScope`, never detected.
List<MethodCall> answerTextEntry(String? typed) {
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(DeviceProfile.channel, (call) async {
    calls.add(call);
    return call.method == TvTextEntry.method ? typed : null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(DeviceProfile.channel, null),
  );
  return calls;
}

/// Lets the reply to a text-entry call arrive and be rendered.
///
/// Deliberately not `pumpAndSettle`: confirming a field submits it, and
/// what a submit starts (a search's progress bar, a sign-in's spinner)
/// never settles.
Future<void> settleTextEntry(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump();
  }
}
