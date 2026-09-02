import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/addons/addons_screen.dart';
import 'package:xtremio/features/settings/settings_screen.dart';

import '../support/fake_core_client.dart';
import '../support/fixtures.dart';

void main() {
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
}
