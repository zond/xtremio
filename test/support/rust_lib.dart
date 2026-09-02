import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:xtremio/src/rust/frb_generated.dart';

/// Candidate locations of the host-built Rust library, relative to the
/// package root (`Directory.current` under `flutter test`).
///
/// `cargokit` only builds the crate for `flutter run`/`flutter build`, so
/// tests that touch FFI need a plain `cargo build` (debug or release) first.
const _candidateDirs = ['rust/target/debug', 'rust/target/release'];

String get _libraryFileName {
  if (Platform.isWindows) return 'xtremio_core.dll';
  if (Platform.isMacOS) return 'libxtremio_core.dylib';
  return 'libxtremio_core.so';
}

/// Resolves the host-built `xtremio_core` library, preferring a debug build.
File findHostRustLibrary() {
  final override =
      Platform.environment['FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR'];
  final dirs = [?override, ..._candidateDirs];
  for (final dir in dirs) {
    final file = File('$dir/$_libraryFileName');
    if (file.existsSync()) return file;
  }
  throw StateError(
    'Host Rust library not found (looked in ${dirs.join(', ')}). '
    'Run `cargo build --manifest-path rust/Cargo.toml` before `flutter test`.',
  );
}

bool _initialized = false;

/// Loads the host-built Rust library into `RustLib` exactly once per test
/// isolate. Safe to call from every `setUpAll`.
Future<void> initRustForTests() async {
  if (_initialized) return;
  final lib = findHostRustLibrary();
  await RustLib.init(externalLibrary: ExternalLibrary.open(lib.absolute.path));
  _initialized = true;
}
