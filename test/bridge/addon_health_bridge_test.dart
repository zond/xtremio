import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/src/rust/api/addon_health.dart';

import '../support/rust_lib.dart';

void main() {
  setUpAll(initRustForTests);

  test('reading the record never blocks the caller', () async {
    // The reader takes the same lock the flush holds across a whole
    // preferences rewrite -- read, re-serialize, fsync, rename. Handed to
    // Dart synchronously it would run that wait on the UI thread, so a
    // flush landing as the viewer opens Addons would cost frames. It has
    // to come back as a `Future`, like the forget beside it.
    final pending = addonHealthReport();
    expect(pending, isA<Future<String>>());

    // Before `core_init` there is no state, and no state is an empty
    // record rather than an error: nothing has been observed yet.
    expect(jsonDecode(await pending), {
      'addons': <String, dynamic>{},
      'everyAnswerFailed': false,
    });
  });
}
