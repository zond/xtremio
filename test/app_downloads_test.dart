import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
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

  group('where the downloads go', () {
    testWidgets('a first run points the server at the platform default', (
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

      expect(downloads.directories, ['/sdcard/files/downloads']);
    });

    testWidgets('a destination already chosen is left where it is', (
      tester,
    ) async {
      final downloads = FakeDownloadsClient()
        ..settings = const {'downloadsDir': '/storage/ABCD-1234/downloads'};
      addTearDown(downloads.dispose);

      await tester.pumpWidget(
        XtremioApp(
          core: emptyBoardCore(),
          downloads: downloads,
          defaultDestination: () async => '/sdcard/files/downloads',
        ),
      );
      await tester.pumpAndSettle();

      expect(downloads.directories, isEmpty);
    });

    testWidgets('a platform with no default of its own asks the server '
        'nothing', (tester) async {
      final downloads = FakeDownloadsClient();
      addTearDown(downloads.dispose);
      final calls = <String>[];
      downloads.callLog = calls;

      await tester.pumpWidget(
        XtremioApp(
          core: emptyBoardCore(),
          downloads: downloads,
          defaultDestination: () async => null,
        ),
      );
      await tester.pumpAndSettle();

      expect(downloads.directories, isEmpty);
      expect(calls, isNot(contains('downloads.directory')));
    });

    testWidgets('a server that cannot be asked changes nothing', (
      tester,
    ) async {
      final downloads = FakeDownloadsClient()
        ..directoryError = StateError('no server');
      addTearDown(downloads.dispose);

      await tester.pumpWidget(
        XtremioApp(
          core: emptyBoardCore(),
          downloads: downloads,
          defaultDestination: () async => '/sdcard/files/downloads',
        ),
      );
      await tester.pumpAndSettle();

      expect(downloads.directories, isEmpty);
    });
  });
}
