import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/addons/addons_screen.dart';
import 'package:xtremio/features/downloads/downloads_screen.dart';
import 'package:xtremio/features/settings/settings_screen.dart';

import '../support/fake_core_client.dart';
import '../support/fake_downloads_client.dart';
import '../support/fixtures.dart';

void main() {
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
}
