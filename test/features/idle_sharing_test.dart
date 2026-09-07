import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/sharing/idle_sharing.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/network_cost.dart';

import '../support/fake_core_client.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_sharing.dart';

/// Whether the embedded server may keep a title in the swarm after the
/// viewer has finished with it: the default a device gets, the choice
/// reaching the server, and the connection's veto over both.
void main() {
  const tv = DeviceProfile(isTv: true, hasTouch: false);

  /// Lets the readings reach the policy and its writes land.
  Future<void> settle(IdleSharingPolicy policy) async {
    await Future<void>.delayed(Duration.zero);
    await policy.settled;
  }

  /// A started policy over fakes, torn down with the test.
  IdleSharingPolicy started({
    required AppPrefs prefs,
    required FakeNetworkCost network,
    required RecordingServerSettings server,
    bool isTv = false,
  }) {
    final policy = IdleSharingPolicy(
      prefs: prefs,
      isTv: isTv,
      network: network,
      server: server,
    );
    addTearDown(policy.dispose);
    addTearDown(network.close);
    policy.start();
    return policy;
  }

  group('the default', () {
    test('differs by what the device is', () {
      // A television is in a wall socket on the house's own line; a phone
      // is neither, and the same bytes there come out of a battery and a
      // bill.
      expect(IdleSharing.defaultFor(isTv: true), isTrue);
      expect(IdleSharing.defaultFor(isTv: false), isFalse);
    });

    test('is what a device nobody has asked shares', () async {
      final unmetered = FakeNetworkCost(NetworkCost.unmetered);
      final phone = RecordingServerSettings();
      final onAPhone = started(
        prefs: AppPrefs.inMemory(),
        network: unmetered,
        server: phone,
      );
      await settle(onAPhone);

      final television = RecordingServerSettings();
      final onATv = started(
        prefs: AppPrefs.inMemory(),
        network: FakeNetworkCost(NetworkCost.unmetered),
        server: television,
        isTv: true,
      );
      await settle(onATv);

      expect(phone.patches, [
        {IdleSharing.seedingEnabledKey: false},
      ]);
      expect(television.patches, [
        {IdleSharing.seedingEnabledKey: true},
      ]);
    });

    test('gives way to a choice, either way round', () async {
      // A stored false on a television is a decision, and reads back as
      // one rather than falling through to the default.
      final prefs = AppPrefs(
        client: FakePrefsClient({AppPrefs.shareWhileIdleKey: false}),
      );
      await prefs.load();
      final server = RecordingServerSettings();
      final policy = started(
        prefs: prefs,
        network: FakeNetworkCost(NetworkCost.unmetered),
        server: server,
        isTv: true,
      );
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
      final policy = started(
        prefs: prefs,
        network: FakeNetworkCost(NetworkCost.unmetered),
        server: server,
      );
      await settle(policy);
      expect(server.patches.single, {IdleSharing.seedingEnabledKey: false});

      await prefs.setShareWhileIdle(true);
      await settle(policy);

      // Spelled the way `POST /settings` reads it, and sent as a patch of
      // that one key: everything else the server holds is left alone.
      expect(server.patches.last, {'seedingEnabled': true});
      expect(server.patches, hasLength(2));
    });

    test('writes nothing when the answer has not moved', () async {
      final network = FakeNetworkCost(NetworkCost.unmetered);
      final server = RecordingServerSettings();
      final policy = started(
        prefs: AppPrefs.inMemory(),
        network: network,
        server: server,
        isTv: true,
      );
      await settle(policy);

      // A network reports its capabilities for reasons this app does not
      // care about -- a signal strength, a validation result -- and every
      // one of them would otherwise be a settings write.
      network.report(NetworkCost.unmetered);
      network.report(NetworkCost.unmetered);
      await settle(policy);

      expect(server.patches, hasLength(1));
    });
  });

  group('a metered connection', () {
    test('refuses whatever the setting says', () async {
      final prefs = AppPrefs(
        client: FakePrefsClient({AppPrefs.shareWhileIdleKey: true}),
      );
      await prefs.load();
      final server = RecordingServerSettings();
      final policy = started(
        prefs: prefs,
        network: FakeNetworkCost(NetworkCost.metered),
        server: server,
        isTv: true,
      );
      await settle(policy);

      // Turned on, on the device whose default is on, and still refused:
      // a bill is the one cost here nobody can see coming.
      expect(server.patches, [
        {IdleSharing.seedingEnabledKey: false},
      ]);
    });

    test('is what an unreadable reading counts as', () async {
      final network = FakeNetworkCost(NetworkCost.unmetered);
      final server = RecordingServerSettings();
      final policy = started(
        prefs: AppPrefs.inMemory(),
        network: network,
        server: server,
        isTv: true,
      );
      await settle(policy);
      expect(server.patches.single, {IdleSharing.seedingEnabledKey: true});

      network.fail(StateError('the platform gave up'));
      await settle(policy);

      expect(server.patches.last, {IdleSharing.seedingEnabledKey: false});
    });
  });

  group('the policy watches', () {
    test('and answers a change nothing else asked about', () async {
      final prefs = AppPrefs(
        client: FakePrefsClient({AppPrefs.shareWhileIdleKey: true}),
      );
      await prefs.load();
      final network = FakeNetworkCost(NetworkCost.unmetered);
      final server = RecordingServerSettings();
      final policy = started(prefs: prefs, network: network, server: server);
      await settle(policy);
      expect(server.patches.single, {IdleSharing.seedingEnabledKey: true});

      // The whole decision, pinned: nothing here ends a session, opens a
      // screen or asks anything. The owner has walked out of the house
      // with the app untouched, and the sharing stops on the reading
      // alone. Asked instead of watched, the phone would still be
      // uploading on the train under an answer given at home.
      network.report(NetworkCost.metered);
      await settle(policy);

      expect(server.patches.last, {IdleSharing.seedingEnabledKey: false});

      // And back, when the link is free again.
      network.report(NetworkCost.unmetered);
      await settle(policy);

      expect(server.patches.last, {IdleSharing.seedingEnabledKey: true});
      expect(server.patches, hasLength(3));
    });

    test('only while the app is up', () async {
      final network = FakeNetworkCost(NetworkCost.unmetered);
      final server = RecordingServerSettings();
      final policy = IdleSharingPolicy(
        prefs: AppPrefs.inMemory(),
        network: network,
        server: server,
        isTv: true,
      );
      addTearDown(network.close);
      policy.start();
      await settle(policy);
      expect(network.watched, isTrue);

      policy.dispose();
      await settle(policy);

      // The watch goes with the app, which is also what ends the sharing:
      // the server it is telling goes down in the same process.
      expect(network.watched, isFalse);
      network.report(NetworkCost.metered);
      await settle(policy);
      expect(server.patches, hasLength(1));
    });
  });

  group('nothing is pushed', () {
    test('before a reading has arrived', () async {
      // The server's own default is to share, so silence here is not
      // neutral -- but neither is a guess. The first reading is what
      // starts this off, and a source that has heard nothing gives none.
      final server = RecordingServerSettings();
      final policy = started(
        prefs: AppPrefs.inMemory(),
        network: FakeNetworkCost(),
        server: server,
        isTv: true,
      );
      await settle(policy);

      expect(server.patches, isEmpty);
    });

    test('and a write that failed is made again on the next change', () async {
      // The server may not be up yet, or may refuse. Nothing retries on a
      // timer; the next reading or the next press carries the policy.
      final network = FakeNetworkCost(NetworkCost.unmetered);
      final server = RecordingServerSettings(failWhile: 1);
      final policy = started(
        prefs: AppPrefs.inMemory(),
        network: network,
        server: server,
        isTv: true,
      );
      await settle(policy);
      expect(server.patches, isEmpty);

      network.report(NetworkCost.unmetered);
      await settle(policy);

      expect(server.patches, [
        {IdleSharing.seedingEnabledKey: true},
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
      final network = FakeNetworkCost(NetworkCost.unmetered);
      final server = RecordingServerSettings();
      addTearDown(network.close);
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
          network: network,
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
