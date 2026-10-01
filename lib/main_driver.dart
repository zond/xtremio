// A dev dependency on purpose: only this entrypoint imports it, and the
// release build starts at lib/main.dart, which never reaches this file.
// ignore: depend_on_referenced_packages
import 'package:flutter_driver/driver_extension.dart';

import 'dev/driver/app_driver.dart';
import 'main.dart' as app;

/// The app with Flutter driver's extension installed, for an agent to
/// drive on a device: `tool/drive-start` runs it as a profile build and
/// `tool/drive` sends it commands (docs/DRIVING.md).
///
/// The extension's binding comes up first, so the app's own `main` finds
/// one already there; everything after that is the app exactly as
/// `lib/main.dart` starts it. Text entry emulation stays off: the keyboard
/// still types, and a field is filled through its semantics `setText`.
void main() {
  final driver = AppDriver();
  enableFlutterDriverExtension(
    handler: driver.handle,
    enableTextEntryEmulation: false,
  );
  driver.ensureSemantics();
  app.main();
}
