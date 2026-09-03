import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

/// Catches what the app writes into the core's log ring, without FFI.
///
/// [DiagnosticsLog] is process-wide (the ring it feeds is), so the sink and
/// its repeat counter are put back afterwards; a test that forgot would
/// leak lines into the next one.
List<String> captureDiagnostics() {
  final lines = <String>[];
  DiagnosticsLog.reset();
  DiagnosticsLog.sink = (level, target, message) =>
      lines.add('$level $target $message');
  addTearDown(() {
    DiagnosticsLog.sink = null;
    DiagnosticsLog.reset();
  });
  return lines;
}
