import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';

import 'support/fake_core_client.dart';

void main() {
  testWidgets('app boots into the Board section with navigation', (
    tester,
  ) async {
    await tester.pumpWidget(XtremioApp(core: FakeCoreClient()));

    // The default section renders.
    expect(find.text('Board'), findsWidgets);

    // All primary destinations are reachable from the shell.
    expect(find.text('Discover'), findsWidgets);
    expect(find.text('Library'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
  });

  testWidgets('Settings shows the embedded server status from core state', (
    tester,
  ) async {
    final core = FakeCoreClient(
      state: {
        CoreField.streamingServer: {
          'baseUrl': 'http://127.0.0.1:11470/',
          'settings': {'type': 'Loading'},
        },
      },
      initInfo: CoreInitInfo(
        serverBaseUrl: Uri.parse('http://127.0.0.1:11470/'),
        schemaVersion: 25,
      ),
    );
    await tester.pumpWidget(XtremioApp(core: core, initInfo: core.initInfo));

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    expect(find.text('http://127.0.0.1:11470/'), findsOneWidget);
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.text('v25'), findsOneWidget);

    // A NewState for streaming_server re-pulls the field.
    core.setState(CoreField.streamingServer, {
      'baseUrl': 'http://127.0.0.1:11470/',
      'settings': {'type': 'Ready', 'content': {}},
    });
    await tester.pumpAndSettle();
    expect(find.text('Ready'), findsOneWidget);
  });
}
