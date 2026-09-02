import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/src/rust/api/hello.dart';

import '../support/rust_lib.dart';

void main() {
  setUpAll(initRustForTests);

  test('Dart and Rust agree on the pinned flutter_rust_bridge version', () {
    expect(bridgeVersion(), '2.13.0');
  });
}
