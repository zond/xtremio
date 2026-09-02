import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/shell/root_shell.dart';

import 'support/fake_core_client.dart';

/// A core whose board is loaded but plans no catalogs, so the Board section
/// renders its static empty state (a still-loading board spins forever,
/// which `pumpAndSettle` cannot wait out).
FakeCoreClient emptyBoardCore() => FakeCoreClient(
  state: {
    CoreField.board: {
      'selected': {'type': null, 'extra': <Object>[]},
      'catalogs': <Object>[],
      'catalogLabels': <Object>[],
    },
  },
);

void main() {
  testWidgets('app boots into the Board section with navigation', (
    tester,
  ) async {
    await tester.pumpWidget(XtremioApp(core: emptyBoardCore()));
    await tester.pumpAndSettle();

    // The default section renders.
    expect(find.text('Board'), findsWidgets);

    // All primary destinations are reachable from the shell.
    expect(find.text('Discover'), findsWidgets);
    expect(find.text('Library'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
  });

  group('back at the root', () {
    /// Records `SystemNavigator.pop` requests, which is what the framework
    /// sends when a back reaches a navigator with nothing left to pop (and
    /// what quits the app on desktop).
    List<String> recordPlatformCalls(WidgetTester tester) {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      return calls;
    }

    testWidgets('does not pop the shell or ask the platform to exit', (
      tester,
    ) async {
      final calls = recordPlatformCalls(tester);
      await tester.pumpWidget(XtremioApp(core: emptyBoardCore()));

      // The platform's back button / key arrives here.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(RootShell), findsOneWidget);
      expect(calls, isNot(contains('SystemNavigator.pop')));
    });

    testWidgets('still pops a route pushed on top of the shell', (
      tester,
    ) async {
      final calls = recordPlatformCalls(tester);
      await tester.pumpWidget(XtremioApp(core: emptyBoardCore()));

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'player'),
          builder: (_) => const Scaffold(body: Text('pushed screen')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('pushed screen'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('pushed screen'), findsNothing);
      expect(find.byType(RootShell), findsOneWidget);

      // One more back, now at the root: still no exit.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(RootShell), findsOneWidget);
      expect(calls, isNot(contains('SystemNavigator.pop')));
    });
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
