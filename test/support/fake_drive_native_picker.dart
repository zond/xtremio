import 'dart:async';

import 'package:xtremio/core/core.dart';

/// A device with no native picker: what every desktop is, what a phone
/// without Play services is, and every device this suite runs on. The
/// browser is the answer there, which is what this app did everywhere
/// before the native path existed.
class NoNativePicker implements DriveNativePicker {
  const NoNativePicker();

  @override
  Future<bool> available() async => false;

  @override
  Future<DriveNativePickResult> pick() async =>
      const DriveNativePickUnavailable();
}

/// A device that picks natively, answering what a test tells it to and
/// counting being asked.
///
/// [answers] are handed out one per pick, the last one repeating forever.
class FakeNativePicker implements DriveNativePicker {
  FakeNativePicker(this.answers, {this.gate});

  final List<DriveNativePickResult> answers;

  /// Held open, so a test can look at the screen *while* the picker is up.
  final Completer<void>? gate;

  int picks = 0;

  @override
  Future<bool> available() async => true;

  @override
  Future<DriveNativePickResult> pick() async {
    picks++;
    if (gate != null) await gate!.future;
    return answers.length > 1 ? answers.removeAt(0) : answers.first;
  }
}
