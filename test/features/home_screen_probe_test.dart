import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/dev/home_screen_probe.dart';
import 'package:xtremio/features/settings/settings_screen.dart';

import '../support/fake_core_client.dart';
import '../support/fixtures.dart';

void main() {
  const channel = MethodChannel('xtremio/watch_next');
  void answer(
    WidgetTester tester,
    Future<Object?> Function(MethodCall call) handler,
  ) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, handler);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  Future<void> pumpSettings(WidgetTester tester) async {
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
  }

  Future<void> press(WidgetTester tester, String title) async {
    await tester.scrollUntilVisible(
      find.text(title),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text(title));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  testWidgets('the two Developer rows ask the channel and show its answer', (
    tester,
  ) async {
    final asked = <String>[];
    answer(tester, (call) async {
      asked.add(call.method);
      return switch (call.method) {
        'insertProbe' => 'Inserted the probe as Watch Next row 7.',
        'removeProbe' => 'Removed the probe.',
        _ => null,
      };
    });
    await pumpSettings(tester);

    await press(tester, HomeScreenProbeTiles.insertTitle);
    expect(asked, ['insertProbe']);
    expect(
      find.text('Inserted the probe as Watch Next row 7.'),
      findsOneWidget,
    );

    ScaffoldMessenger.of(tester.element(find.byType(SettingsScreen)))
        .removeCurrentSnackBar();
    await tester.pumpAndSettle();

    await press(tester, HomeScreenProbeTiles.removeTitle);
    expect(asked, ['insertProbe', 'removeProbe']);
    expect(find.text('Removed the probe.'), findsOneWidget);
  });

  testWidgets('a channel that is not there, or fails, says so rather than '
      'throwing', (tester) async {
    // What a build without WatchNextChannel answers, then a failure.
    var missing = true;
    answer(tester, (call) async {
      if (missing) throw MissingPluginException();
      throw PlatformException(code: 'refused');
    });
    await pumpSettings(tester);
    await press(tester, HomeScreenProbeTiles.insertTitle);
    expect(find.text('This build has no home-screen probe.'), findsOneWidget);

    ScaffoldMessenger.of(tester.element(find.byType(SettingsScreen)))
        .removeCurrentSnackBar();
    await tester.pumpAndSettle();
    missing = false;
    await press(tester, HomeScreenProbeTiles.removeTitle);
    expect(find.text('The probe failed: refused.'), findsOneWidget);
  });

  testWidgets('only Android offers the probe', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pumpSettings(tester);
    await tester.scrollUntilVisible(
      find.text('Download test torrent'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(
      find.text(HomeScreenProbeTiles.insertTitle, skipOffstage: false),
      findsNothing,
    );
    expect(
      find.text(HomeScreenProbeTiles.removeTitle, skipOffstage: false),
      findsNothing,
    );
    // Reset before the framework's own end-of-test check of the override.
    debugDefaultTargetPlatformOverride = null;
  });
}
