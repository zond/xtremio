import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/sharing/idle_sharing.dart';
import 'package:xtremio/shell/device_profile.dart';

import '../support/fake_core_client.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_sharing.dart';

/// Whether the embedded server may keep a title in the swarm after the
/// viewer has finished with it: the default a device gets, and the choice
/// reaching the server.
void main() {
  const tv = DeviceProfile(isTv: true, hasTouch: false);

  /// Lets the policy's writes land.
  Future<void> settle(IdleSharingPolicy policy) async {
    await Future<void>.delayed(Duration.zero);
    await policy.settled;
  }

  /// A started policy over fakes, torn down with the test.
  IdleSharingPolicy started({
    required AppPrefs prefs,
    required RecordingServerSettings server,
  }) {
    final policy = IdleSharingPolicy(prefs: prefs, server: server);
    addTearDown(policy.dispose);
    policy.start();
    return policy;
  }

  group('the default', () {
    test('is to share, on any device nobody has asked', () async {
      // The same answer everywhere, which is the point: the default used
      // to be the device's, and what decided it was a guess about a cost
      // this app cannot see.
      final server = RecordingServerSettings();
      final policy = started(prefs: AppPrefs.inMemory(), server: server);
      await settle(policy);

      expect(server.patches, [
        {IdleSharing.seedingEnabledKey: true},
      ]);
    });

    test('gives way to a stored refusal', () async {
      // Turning it off is a decision, and it reads back as one rather than
      // falling through to the default that says on.
      final prefs = AppPrefs(
        client: FakePrefsClient({AppPrefs.shareWhileIdleKey: false}),
      );
      await prefs.load();
      final server = RecordingServerSettings();
      final policy = started(prefs: prefs, server: server);
      await settle(policy);

      expect(server.patches, [
        {IdleSharing.seedingEnabledKey: false},
      ]);
    });
  });

  group('the setting', () {
    test('reaches the server under the key the server reads', () async {
      final prefs = AppPrefs(client: FakePrefsClient());
      final server = RecordingServerSettings();
      final policy = started(prefs: prefs, server: server);
      await settle(policy);
      expect(server.patches.single, {IdleSharing.seedingEnabledKey: true});

      await prefs.setShareWhileIdle(false);
      await settle(policy);

      // Spelled the way `POST /settings` reads it, and sent as a patch of
      // that one key: everything else the server holds is left alone.
      expect(server.patches.last, {'seedingEnabled': false});
      expect(server.patches, hasLength(2));
    });

    test('writes nothing when the answer has not moved', () async {
      final prefs = AppPrefs.inMemory();
      final server = RecordingServerSettings();
      final policy = started(prefs: prefs, server: server);
      await settle(policy);

      // Every preference shares one notification, so most of what reaches
      // this policy is somebody changing something else entirely -- and a
      // settings write is the other end of every one of them.
      await prefs.setBufferAhead(BufferAhead.wholeFile);
      await prefs.setStreamsSectioned(false);
      await settle(policy);

      expect(server.patches, hasLength(1));
    });
  });

  group('the policy watches', () {
    test('only while the app is up', () async {
      final prefs = AppPrefs.inMemory();
      final server = RecordingServerSettings();
      final policy = IdleSharingPolicy(prefs: prefs, server: server);
      policy.start();
      await settle(policy);
      expect(server.patches, hasLength(1));

      policy.dispose();
      await prefs.setShareWhileIdle(false);
      await settle(policy);

      // The watch goes with the app, which is also what ends the sharing:
      // the server it is telling goes down in the same process.
      expect(server.patches, hasLength(1));
    });
  });

  group('a write that failed', () {
    test('is made again on the next change', () async {
      // The server may not be up yet, or may refuse. Nothing retries on a
      // timer; the next press carries the policy.
      final prefs = AppPrefs.inMemory();
      final server = RecordingServerSettings(failWhile: 1);
      final policy = started(prefs: prefs, server: server);
      await settle(policy);
      expect(server.patches, isEmpty);

      await prefs.setShareWhileIdle(false);
      await settle(policy);

      expect(server.patches, [
        {IdleSharing.seedingEnabledKey: false},
      ]);
    });
  });

  group('the app', () {
    testWidgets('starts one policy, on the preferences it has loaded', (
      tester,
    ) async {
      // The stored choice arrives a moment after start-up, and starting
      // the policy before it would have the server hear the default first
      // and the answer second.
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
          device: tv,
          prefs: AppPrefs(
            client: FakePrefsClient({AppPrefs.shareWhileIdleKey: false}),
          ),
          serverSettings: server,
        ),
      );
      await tester.pumpAndSettle();

      expect(server.patches, [
        {IdleSharing.seedingEnabledKey: false},
      ]);
    });
  });
}
