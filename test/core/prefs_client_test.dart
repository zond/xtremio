import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/rust_lib.dart';

/// The Dart half of the preferences file against the real FFI: what
/// `rust/src/prefs.rs` tests is that the file round-trips, and this is that
/// the client's JSON encoding survives the crossing.
void main() {
  setUpAll(initRustForTests);

  test('a preference round-trips through the Rust side', () async {
    final tmp = await Directory.systemTemp.createTemp('xtremio-prefs-test-');
    final core = RustCoreClient();
    addTearDown(() async {
      await core.shutdown();
      await tmp.delete(recursive: true);
    });
    // The preferences live in the storage directory, which `core_init` is
    // what points anywhere. No server: prefs are a file, not a route.
    await core.init(
      support: Directory('${tmp.path}/support'),
      cache: Directory('${tmp.path}/cache'),
      embeddedServer: false,
    );

    const client = RustPrefsClient();
    expect(await client.getAll(), isEmpty);

    await client.set(AppPrefs.streamsFlatKey, true);
    expect(await client.getAll(), {AppPrefs.streamsFlatKey: true});
    expect(
      File('${tmp.path}/support/core/xtremio_prefs.json').existsSync(),
      isTrue,
    );

    // A fresh AppPrefs over the same directory is what a restart sees.
    final prefs = AppPrefs(client: client);
    addTearDown(prefs.dispose);
    await prefs.load();
    expect(prefs.streamsFlat, isTrue);

    await client.set(AppPrefs.streamsFlatKey, null);
    expect(await client.getAll(), isEmpty);
  });
}
