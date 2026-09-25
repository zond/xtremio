import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/diagnostics/diagnostics_trace.dart';
import 'package:xtremio/features/sharing/idle_sharing.dart';

import '../support/fake_core_client.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_sharing.dart';

/// "Verbose diagnostics" reaching the embedded server: pushed at start,
/// pushed on every change, under the key the server reads, and again after
/// a push the server was not there for.
void main() {
  Future<void> settle(DiagnosticsTraceSync sync) async {
    await Future<void>.delayed(Duration.zero);
    await sync.settled;
  }

  DiagnosticsTraceSync started({
    required AppPrefs prefs,
    required RecordingServerSettings server,
  }) {
    final sync = DiagnosticsTraceSync(prefs: prefs, server: server);
    addTearDown(sync.dispose);
    sync.start();
    return sync;
  }

  test("the app's own log keeps URLs whole exactly while it is on", () async {
    addTearDown(() => DiagnosticsLog.unredacted = false);
    final prefs = AppPrefs.inMemory();
    final sync = started(prefs: prefs, server: RecordingServerSettings());
    await settle(sync);
    expect(DiagnosticsLog.unredacted, isFalse);

    await prefs.setVerboseDiagnostics(true);
    await settle(sync);
    expect(DiagnosticsLog.unredacted, isTrue);

    await prefs.setVerboseDiagnostics(false);
    await settle(sync);
    expect(DiagnosticsLog.unredacted, isFalse);
  });

  test('and verbose logging no longer buys a line per picture', () async {
    // It used to. A line per image is a hundred for one screen of posters,
    // and it drowned the log of somebody who had turned verbose logging on
    // to read something else -- which is what it was doing while a Drive
    // pairing was being debugged through it. The line answered the question
    // it was built for (what a poster costs resident on the television) and
    // nothing is asking it now, so the machinery stays and the switch lets
    // go of it.
    addTearDown(() => ImageCacheLog.perImage = false);
    final prefs = AppPrefs.inMemory();
    final sync = started(prefs: prefs, server: RecordingServerSettings());
    await settle(sync);
    expect(ImageCacheLog.perImage, isFalse);

    await prefs.setVerboseDiagnostics(true);
    await settle(sync);
    expect(
      ImageCacheLog.perImage,
      isFalse,
      reason: 'verbose logging is about the log, not about posters',
    );
    // And the half of the switch that is still its own is untouched.
    expect(DiagnosticsLog.unredacted, isTrue);
  });

  test('the default is off, and the server is told so at start', () async {
    final server = RecordingServerSettings();
    final sync = started(prefs: AppPrefs.inMemory(), server: server);
    await settle(sync);

    expect(server.patches, [
      {DiagnosticsTraceSync.serverKey: false},
    ]);
  });

  test('a stored choice is what the server hears first', () async {
    final prefs = AppPrefs(
      client: FakePrefsClient({AppPrefs.verboseDiagnosticsKey: true}),
    );
    await prefs.load();
    final server = RecordingServerSettings();
    final sync = started(prefs: prefs, server: server);
    await settle(sync);

    expect(server.patches, [
      {DiagnosticsTraceSync.serverKey: true},
    ]);
  });

  test(
    'a change reaches the server, and the same value again does not',
    () async {
      final prefs = AppPrefs.inMemory();
      final server = RecordingServerSettings();
      final sync = started(prefs: prefs, server: server);
      await settle(sync);

      await prefs.setVerboseDiagnostics(true);
      await settle(sync);
      await prefs.setVerboseDiagnostics(true);
      await settle(sync);
      await prefs.setVerboseDiagnostics(false);
      await settle(sync);

      expect(server.patches, [
        {DiagnosticsTraceSync.serverKey: false},
        {DiagnosticsTraceSync.serverKey: true},
        {DiagnosticsTraceSync.serverKey: false},
      ]);
    },
  );

  test(
    'a push the server was not up for is made again at the next change',
    () async {
      final prefs = AppPrefs.inMemory();
      final server = RecordingServerSettings(failWhile: 1);
      final sync = started(prefs: prefs, server: server);
      await settle(sync);
      expect(server.patches, isEmpty);

      await prefs.setVerboseDiagnostics(true);
      await settle(sync);
      expect(server.patches, [
        {DiagnosticsTraceSync.serverKey: true},
      ]);
    },
  );

  testWidgets('the app starts one, on the preferences it has loaded', (
    tester,
  ) async {
    // The stored choice arrives a moment after start-up; the server must
    // hear it, not the default it overrides.
    final server = RecordingServerSettings();
    await tester.pumpWidget(
      XtremioApp(
        core: FakeCoreClient(
          state: {
            CoreField.board: {
              'selected': {'type': null, 'extra': <Object>[]},
              'catalogs': <Object>[],
              'catalogLabels': <Object>[],
            },
          },
        ),
        prefs: AppPrefs(
          client: FakePrefsClient({AppPrefs.verboseDiagnosticsKey: true}),
        ),
        serverSettings: server,
        sharingActivity: FakeSharingActivity(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      server.patches,
      unorderedEquals([
        {IdleSharing.seedingEnabledKey: true},
        {DiagnosticsTraceSync.serverKey: true},
      ]),
    );
  });

  test('nothing is written after dispose', () async {
    final prefs = AppPrefs.inMemory();
    final server = RecordingServerSettings();
    final sync = started(prefs: prefs, server: server);
    await settle(sync);
    sync.dispose();

    await prefs.setVerboseDiagnostics(true);
    await settle(sync);
    expect(server.patches, [
      {DiagnosticsTraceSync.serverKey: false},
    ]);
  });
}
