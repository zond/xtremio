import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Lets the current test talk to a real server on the loopback.
///
/// The test binding installs [HttpOverrides] that answer every request with
/// a 400 of their own. This takes them off and puts back whatever was there
/// when the test ends. Call it from `setUp` or from the test itself.
void useRealHttp() {
  final overrides = HttpOverrides.current;
  HttpOverrides.global = null;
  addTearDown(() => HttpOverrides.global = overrides);
}
