import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/fake_prefs_client.dart';

/// [AppPrefs.verboseDiagnostics]: off until chosen, read back from
/// storage, written through once.
void main() {
  test(
    'is off until something is loaded, and stays off with nothing stored',
    () async {
      final prefs = AppPrefs(client: FakePrefsClient());
      expect(prefs.verboseDiagnostics, isFalse);
      await prefs.load();
      expect(prefs.verboseDiagnostics, isFalse);
    },
  );

  test('load reads a stored choice and notifies', () async {
    final prefs = AppPrefs(
      client: FakePrefsClient({AppPrefs.verboseDiagnosticsKey: true}),
    );
    var notified = 0;
    prefs.addListener(() => notified++);

    await prefs.load();

    expect(prefs.verboseDiagnostics, isTrue);
    expect(notified, 1);
  });

  test(
    'a change is written through and read back by a fresh AppPrefs',
    () async {
      final client = FakePrefsClient();
      final prefs = AppPrefs(client: client);

      await prefs.setVerboseDiagnostics(true);
      expect(client.stored[AppPrefs.verboseDiagnosticsKey], isTrue);
      expect(client.writes, [AppPrefs.verboseDiagnosticsKey]);
      // The same value again writes nothing.
      await prefs.setVerboseDiagnostics(true);
      expect(client.writes, [AppPrefs.verboseDiagnosticsKey]);

      final restarted = AppPrefs(client: client);
      await restarted.load();
      expect(restarted.verboseDiagnostics, isTrue);
    },
  );
}
