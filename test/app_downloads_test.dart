import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/downloads/downloads_screen.dart';
import 'package:xtremio/features/downloads/downloads_service.dart';
import 'package:xtremio/shell/root_shell.dart';

import 'support/fake_core_client.dart';
import 'support/fake_downloads_client.dart';

/// A core whose board plans no catalogs, so the shell settles.
FakeCoreClient emptyBoardCore() => FakeCoreClient(
  state: {
    CoreField.board: {
      'selected': {'type': null, 'extra': <Object>[]},
      'catalogs': <Object>[],
      'catalogLabels': <Object>[],
    },
  },
);

/// The client every screen under the shell would reach for.
DownloadsClient downloadsOf(WidgetTester tester) =>
    DownloadsScope.of(tester.element(find.byType(RootShell)));

void main() {
  testWidgets('every screen reaches the downloads client the app was given', (
    tester,
  ) async {
    final downloads = FakeDownloadsClient();
    addTearDown(downloads.dispose);

    await tester.pumpWidget(
      XtremioApp(core: emptyBoardCore(), downloads: downloads),
    );
    await tester.pumpAndSettle();

    expect(downloadsOf(tester), same(downloads));
  });

  testWidgets('a client handed in is not the app\'s to dispose', (
    tester,
  ) async {
    final downloads = FakeDownloadsClient();
    addTearDown(downloads.dispose);

    await tester.pumpWidget(
      XtremioApp(core: emptyBoardCore(), downloads: downloads),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());

    expect(downloads.disposed, isFalse);
  });

  testWidgets('with none given the app runs the real one, and lets go of it '
      'when it goes away', (tester) async {
    await tester.pumpWidget(XtremioApp(core: emptyBoardCore()));
    await tester.pumpAndSettle();

    final client = downloadsOf(tester);
    expect(client, isA<RustDownloadsClient>());

    await tester.pumpWidget(const SizedBox());

    // A disposed client has let go of the Rust progress stream and answers
    // a closed one; a live client would try to open a sink over FFI here.
    await expectLater(client.updates, emitsDone);
  });

  group('the downloads notification', () {
    /// The platform side of `xtremio/downloads`, answering the little the
    /// app asks of it at start-up, and able to call in the way the
    /// notification does.
    TestDefaultBinaryMessenger install(WidgetTester tester) {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        DownloadsForegroundService.defaultChannel,
        (call) async => call.method == 'takePendingOpen' ? false : null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          DownloadsForegroundService.defaultChannel,
          null,
        ),
      );
      return messenger;
    }

    Future<void> tapNotification(
      WidgetTester tester,
      TestDefaultBinaryMessenger messenger,
    ) async {
      await messenger.handlePlatformMessage(
        DownloadsForegroundService.defaultChannel.name,
        const StandardMethodCodec().encodeMethodCall(const MethodCall('open')),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    testWidgets('tapping it opens the Downloads screen', (tester) async {
      final downloads = FakeDownloadsClient();
      addTearDown(downloads.dispose);
      final messenger = install(tester);

      await tester.pumpWidget(
        XtremioApp(core: emptyBoardCore(), downloads: downloads),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DownloadsScreen), findsNothing);

      await tapNotification(tester, messenger);

      expect(find.byType(DownloadsScreen), findsOneWidget);
    });

    testWidgets('tapping it again does not stack a second one', (tester) async {
      final downloads = FakeDownloadsClient();
      addTearDown(downloads.dispose);
      final messenger = install(tester);

      await tester.pumpWidget(
        XtremioApp(core: emptyBoardCore(), downloads: downloads),
      );
      await tester.pumpAndSettle();
      await tapNotification(tester, messenger);
      await tapNotification(tester, messenger);

      expect(find.byType(DownloadsScreen), findsOneWidget);
    });
  });

  group('where the downloads go', () {
    // What start-up does with the answer lives in
    // `features/downloads_destination_test.dart`; this is that it is asked
    // at all, with the platform's own default and the app's one client.
    testWidgets('start-up settles it, once, on the client the app runs', (
      tester,
    ) async {
      final downloads = FakeDownloadsClient();
      addTearDown(downloads.dispose);

      await tester.pumpWidget(
        XtremioApp(
          core: emptyBoardCore(),
          downloads: downloads,
          defaultDestination: () async => '/sdcard/files/downloads',
        ),
      );
      await tester.pumpAndSettle();

      expect(downloads.defaultsApplied, ['/sdcard/files/downloads']);
      expect(
        downloads.registry.destination,
        const DownloadDestination.platformDefault('/sdcard/files/downloads'),
      );
    });

    testWidgets('a platform with no default of its own asks nothing', (
      tester,
    ) async {
      final downloads = FakeDownloadsClient();
      addTearDown(downloads.dispose);

      await tester.pumpWidget(
        XtremioApp(
          core: emptyBoardCore(),
          downloads: downloads,
          defaultDestination: () async => null,
        ),
      );
      await tester.pumpAndSettle();

      expect(downloads.directories, isEmpty);
    });
  });
}
