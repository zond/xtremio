import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/addons/addons_screen.dart';
import 'package:xtremio/features/diagnostics/diagnostics_screen.dart';
import 'package:xtremio/features/downloads/downloads_screen.dart';
import 'package:xtremio/features/settings/settings_screen.dart';

import '../support/fake_core_client.dart';
import '../support/fake_downloads_client.dart';
import '../support/fixtures.dart';

void main() {
  testWidgets(
    'the Developer section, Diagnostics first, ships in every build',
    (tester) async {
      // It used to be `if (!kReleaseMode)`, which is exactly the build the
      // owner is testing on a phone: the entries that reproduce a playback
      // failure, and the log that explains one, were missing from the only
      // build that could hit it. They ship now.
      final core = FakeCoreClient(
        state: {CoreField.ctx: loadCtxLoggedOutFixture()},
      );
      await tester.pumpWidget(
        CoreScope(
          client: core,
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // To the bottom of the list: the section is the last thing in it.
      await tester.scrollUntilVisible(
        find.text('Download test torrent'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Developer'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Diagnostics'), findsOneWidget);
      expect(
        find.widgetWithText(ListTile, 'Play test torrent'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(ListTile, 'Play test HTTP stream'),
        findsOneWidget,
      );
      // Clearly test content, not something that looks like a real title.
      expect(find.textContaining('Big Buck Bunny (torrent)'), findsOneWidget);

      await tester.tap(find.widgetWithText(ListTile, 'Diagnostics'));
      await tester.pumpAndSettle();
      expect(find.byType(DiagnosticsScreen), findsOneWidget);
      expect(core.dispatched, isEmpty, reason: 'the engine is not involved');
    },
  );

  testWidgets('the Downloads tile opens the Downloads screen', (tester) async {
    final core = FakeCoreClient(
      state: {CoreField.ctx: loadCtxLoggedOutFixture()},
    );
    final downloads = FakeDownloadsClient();
    addTearDown(downloads.dispose);
    await tester.pumpWidget(
      CoreScope(
        client: core,
        child: DownloadsScope(
          client: downloads,
          child: const MaterialApp(home: SettingsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ListTile, 'Downloads'));
    await tester.pumpAndSettle();

    expect(find.byType(DownloadsScreen), findsOneWidget);
    expect(core.dispatched, isEmpty, reason: 'the engine has no downloads');
  });

  testWidgets('the Addons tile opens the Addons screen', (tester) async {
    final core = FakeCoreClient(
      state: {
        CoreField.installedAddons: loadInstalledAddonsFixture(),
        CoreField.remoteAddons: loadRemoteAddonsFixture(),
        CoreField.ctx: loadCtxLoggedOutFixture(),
      },
    );
    await tester.pumpWidget(
      CoreScope(
        client: core,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(core.dispatched, isEmpty);

    await tester.tap(find.widgetWithText(ListTile, 'Addons'));
    await tester.pumpAndSettle();

    expect(find.byType(AddonsScreen), findsOneWidget);
    expect(
      [for (final action in core.dispatched) action.field],
      [CoreField.installedAddons, CoreField.remoteAddons],
    );
  });

  testWidgets('re-opening Addons during its pop does not unload the lists', (
    tester,
  ) async {
    final core = FakeCoreClient(
      state: {
        CoreField.installedAddons: loadInstalledAddonsFixture(),
        CoreField.remoteAddons: loadRemoteAddonsFixture(),
        CoreField.ctx: loadCtxLoggedOutFixture(),
      },
    );
    await tester.pumpWidget(
      CoreScope(
        client: core,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ListTile, 'Addons'));
    await tester.pumpAndSettle();
    // Back, and the tile again while the Addons route is still animating
    // out: the new screen's Loads must not be followed by the old one's
    // Unloads.
    Navigator.of(tester.element(find.byType(AddonsScreen))).pop();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(ListTile, 'Addons'));
    await tester.pumpAndSettle();

    expect(find.byType(AddonsScreen), findsOneWidget);
    expect(
      [for (final action in core.dispatched) action.action['action']],
      ['Load', 'Load', 'Load', 'Load'],
    );

    // The surviving screen still unloads both fields on its own exit.
    await tester.pumpWidget(const SizedBox());
    expect(
      [for (final action in core.dispatched.skip(4)) action.field],
      [CoreField.installedAddons, CoreField.remoteAddons],
    );
    for (final action in core.dispatched.skip(4)) {
      expect(action.action, CoreActions.unload(action.field!).action);
    }
  });

  testWidgets('the developer download tile keeps the test torrent on the '
      'device', (tester) async {
    final core = FakeCoreClient(
      state: {CoreField.ctx: loadCtxLoggedOutFixture()},
    );
    final downloads = FakeDownloadsClient();
    addTearDown(downloads.dispose);
    await tester.pumpWidget(
      CoreScope(
        client: core,
        child: DownloadsScope(
          client: downloads,
          child: const MaterialApp(home: SettingsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Download test torrent'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Download test torrent'));
    await tester.pumpAndSettle();

    expect(downloads.added, hasLength(1));
    expect(
      downloads.added.single.stream.infoHash,
      'dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c',
    );
    expect(find.text('Downloading the test torrent.'), findsOneWidget);
  });

  group('the Peer discovery row', () {
    /// Pumps a [SettingsScreen] over [core], with [dhtStatus] wired in as
    /// the injected reader, and scrolls the Streaming server section into
    /// view (it sits below the Account form, off the test viewport).
    Future<void> pumpSettings(
      WidgetTester tester, {
      required FakeCoreClient core,
      DhtStatus Function()? dhtStatus,
    }) async {
      await tester.pumpWidget(
        CoreScope(
          client: core,
          child: MaterialApp(home: SettingsScreen(dhtStatus: dhtStatus)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Peer discovery'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
    }

    /// The row's own [ListTile], found by its fixed title so a coincidental
    /// duplicate of its subtitle text elsewhere (the server-status row can
    /// show `Unknown` too) never makes a test ambiguous.
    ListTile peerDiscoveryTile(WidgetTester tester) => tester.widget<ListTile>(
      find.widgetWithText(ListTile, 'Peer discovery'),
    );

    String subtitleOf(WidgetTester tester) =>
        (peerDiscoveryTile(tester).subtitle! as Text).data!;

    FakeCoreClient loggedOutCore() =>
        FakeCoreClient(state: {CoreField.ctx: loadCtxLoggedOutFixture()});

    testWidgets('shows the node count once the DHT has bootstrapped', (
      tester,
    ) async {
      await pumpSettings(
        tester,
        core: loggedOutCore(),
        dhtStatus: () => const DhtStatus(
          enabled: true,
          nodes: 312,
          nodesV6: 9,
          everBootstrapped: true,
        ),
      );

      expect(subtitleOf(tester), 'Connected, 312 nodes');
    });

    testWidgets(
      'shows the tracker-only wording, in the ordinary text style, once '
      'enabled but never bootstrapped',
      (tester) async {
        await pumpSettings(
          tester,
          core: loggedOutCore(),
          dhtStatus: () => const DhtStatus(
            enabled: true,
            nodes: 0,
            nodesV6: 0,
            everBootstrapped: false,
          ),
        );

        expect(subtitleOf(tester), DhtStatus.unavailableMessage);
        // Information, not a warning: same icon as every other state, no
        // warning/error glyph, and the default (non-error) text color.
        final tile = peerDiscoveryTile(tester);
        expect((tile.leading! as Icon).icon, Icons.hub_outlined);
        expect(find.byIcon(Icons.warning_amber_outlined), findsNothing);
        expect(find.byIcon(Icons.error_outline), findsNothing);
        final subtitleFinder = find.text(DhtStatus.unavailableMessage);
        final errorColor = Theme.of(tester.element(subtitleFinder))
            .colorScheme
            .error;
        expect(
          tester.widget<Text>(subtitleFinder).style?.color,
          isNot(errorColor),
        );
      },
    );

    testWidgets('says so plainly when the DHT is disabled', (tester) async {
      await pumpSettings(
        tester,
        core: loggedOutCore(),
        dhtStatus: () => const DhtStatus(
          enabled: false,
          nodes: 0,
          nodesV6: 0,
          everBootstrapped: false,
        ),
      );

      expect(subtitleOf(tester), 'Disabled');
    });

    testWidgets(
      'says so plainly when the server is not running (indistinguishable '
      'from disabled, over this API)',
      (tester) async {
        await pumpSettings(
          tester,
          core: loggedOutCore(),
          // What `ServerClient().dhtStatus` answers when nothing is
          // running: "no DHT to ask" reads the same as "disabled".
          dhtStatus: () => const DhtStatus(
            enabled: false,
            nodes: 0,
            nodesV6: 0,
            everBootstrapped: false,
          ),
        );

        expect(subtitleOf(tester), 'Disabled');
      },
    );

    testWidgets('degrades to a quiet Unknown when the read fails', (
      tester,
    ) async {
      await pumpSettings(
        tester,
        core: loggedOutCore(),
        dhtStatus: () => throw StateError('no server'),
      );

      expect(subtitleOf(tester), 'Unknown');
      expect(find.byIcon(Icons.warning_amber_outlined), findsNothing);
      expect(find.byIcon(Icons.error_outline), findsNothing);
    });

    testWidgets('reads again when the streaming-server section refreshes, '
        'never on a timer of its own', (tester) async {
      var calls = 0;
      final core = loggedOutCore();
      await pumpSettings(
        tester,
        core: core,
        dhtStatus: () {
          calls++;
          return calls == 1
              ? const DhtStatus(
                  enabled: true,
                  nodes: 1,
                  nodesV6: 0,
                  everBootstrapped: true,
                )
              : const DhtStatus(
                  enabled: true,
                  nodes: 2,
                  nodesV6: 0,
                  everBootstrapped: true,
                );
        },
      );
      expect(calls, 1);
      expect(subtitleOf(tester), 'Connected, 1 nodes');

      // Time passing alone must never trigger another read.
      await tester.pump(const Duration(seconds: 30));
      await tester.pump(const Duration(minutes: 5));
      expect(calls, 1);
      expect(subtitleOf(tester), 'Connected, 1 nodes');

      // The section's own refresh affordance -- a `NewState` for the
      // streaming-server field -- is what piggybacks the next read.
      core.setState(CoreField.streamingServer, {
        'baseUrl': null,
        'settings': {'type': 'Ready', 'content': {}},
      });
      await tester.pumpAndSettle();

      expect(calls, 2);
      expect(subtitleOf(tester), 'Connected, 2 nodes');
    });

    testWidgets('leaves the server-status row above it unchanged', (
      tester,
    ) async {
      final core = FakeCoreClient(
        state: {
          CoreField.ctx: loadCtxLoggedOutFixture(),
          CoreField.streamingServer: {
            'baseUrl': 'http://127.0.0.1:11470/',
            'settings': {'type': 'Ready', 'content': {}},
          },
        },
      );
      await pumpSettings(
        tester,
        core: core,
        dhtStatus: () => const DhtStatus(
          enabled: true,
          nodes: 5,
          nodesV6: 0,
          everBootstrapped: true,
        ),
      );

      expect(
        find.text('Ready · http://127.0.0.1:11470/'),
        findsOneWidget,
        reason:
            'the Status row keeps its own wording, untouched by the '
            'new Peer discovery row next to it',
      );
      expect(subtitleOf(tester), 'Connected, 5 nodes');
    });
  });
}
