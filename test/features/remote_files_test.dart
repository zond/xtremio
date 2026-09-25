import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/board/board_screen.dart';
import 'package:xtremio/features/drive/drive_pairing_screen.dart';
import 'package:xtremio/features/drive/remote_files.dart';
import 'package:xtremio/features/library/library_screen.dart';
import 'package:xtremio/shell/device_profile.dart';

import '../support/fake_core_client.dart';
import '../support/fake_downloads_client.dart';
import '../support/fake_secret_store.dart';
import '../support/fixtures.dart';

/// Where the link button is, and whether the dialog it opens looks like
/// something to press.
void main() {
  const tv = DeviceProfile(isTv: true, hasTouch: false);

  Future<DriveAccount> account() async {
    final prefs = AppPrefs.inMemory();
    await prefs.load();
    final drive = DriveAccount(prefs: prefs, secrets: FakeSecretStore());
    await drive.load();
    addTearDown(() {
      drive.dispose();
      prefs.dispose();
    });
    return drive;
  }

  FakeCoreClient libraryCore() => FakeCoreClient(
    state: {
      CoreField.library: loadLibraryFixture(),
      CoreField.ctx: loadCtxLoggedOutFixture(),
    },
  );

  FakeCoreClient boardCore() => FakeCoreClient(
    state: {
      CoreField.board: loadBoardFixture(),
      CoreField.continueWatchingPreview: loadContinueWatchingFixture(),
    },
  );

  Widget harness(
    Widget home, {
    required FakeCoreClient core,
    DriveAccount? drive,
    bool isTv = false,
  }) {
    final downloads = FakeDownloadsClient();
    addTearDown(downloads.dispose);
    Widget app = CoreScope(
      client: core,
      child: DownloadsScope(
        client: downloads,
        child: MaterialApp(home: home),
      ),
    );
    if (drive != null) app = DriveAccountScope(account: drive, child: app);
    return isTv ? DeviceScope(profile: tv, child: app) : app;
  }

  group('where the button is', () {
    testWidgets('the library has it', (tester) async {
      await tester.pumpWidget(
        harness(const LibraryScreen(), core: libraryCore()),
      );
      await tester.pumpAndSettle();

      final button = find.byTooltip(RemoteFilesButton.label);
      expect(button, findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byIcon(Icons.cloud_outlined),
        ),
        findsOneWidget,
      );
    });

    testWidgets('and the board does not, nor anything else in its bar', (
      tester,
    ) async {
      // The board is what an addon catalogue offers; a file on the viewer's
      // own Drive is not that. Its app bar is a title and nothing else now,
      // which is also why the two rungs of a TvLadder it carried for this
      // one button went with it.
      await tester.pumpWidget(harness(const BoardScreen(), core: boardCore()));
      await tester.pumpAndSettle();

      expect(find.byTooltip(RemoteFilesButton.label), findsNothing);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(IconButton),
        ),
        findsNothing,
      );
    });
  });

  group('the list of services', () {
    testWidgets('its row is a button, not a sentence with a Cancel beside it', (
      tester,
    ) async {
      // **This is the fix, stated.** The row was a [ListTile]: no edge, no
      // fill, no arrow, and the only control on screen shaped like a button
      // was the one that closes the dialog. A viewer who had not seen it
      // before had to guess that the sentence was tappable.
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        harness(const LibraryScreen(), core: libraryCore()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(RemoteFilesButton.label));
      await tester.pumpAndSettle();

      final row = find.widgetWithText(OutlinedButton, 'Google Drive');
      expect(row, findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
      expect(
        find.descendant(of: row, matching: find.byIcon(Icons.chevron_right)),
        findsOneWidget,
        reason: 'and it says it leads somewhere',
      );
      handle.dispose();
    });

    testWidgets('and a television is told it is pressable', (tester) async {
      // The readout is the other half of looking like a control, and the one
      // a viewer three metres away actually gets: a [ListTile] with an
      // `onTap` reads out as a line of prose.
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        harness(const LibraryScreen(), core: libraryCore(), isTv: true),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(RemoteFilesButton.label));
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(
          find.widgetWithText(OutlinedButton, 'Google Drive'),
        ),
        isSemantics(isButton: true, hasTapAction: true),
      );
      handle.dispose();
    });

    testWidgets('on a television it opens with the remote on the row and not '
        'on Cancel', (tester) async {
      await tester.pumpWidget(
        harness(const LibraryScreen(), core: libraryCore(), isTv: true),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(RemoteFilesButton.label));
      await tester.pumpAndSettle();

      final focused = primaryFocus?.context?.widget;
      expect(focused, isNotNull);
      expect(
        find.descendant(
          of: find.byWidget(focused!),
          matching: find.text('Google Drive'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('off a television nothing takes focus on its own', (
      tester,
    ) async {
      // A phone has a finger, and a dialog that grabs focus on a phone is a
      // dialog that opens the keyboard's outline round something nobody
      // pointed at.
      await tester.pumpWidget(
        harness(const LibraryScreen(), core: libraryCore()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(RemoteFilesButton.label));
      await tester.pumpAndSettle();

      expect(primaryFocus?.context?.widget, isNot(isA<OutlinedButton>()));
    });

    testWidgets('pressing the row closes the dialog and opens the pairing', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          const LibraryScreen(),
          core: libraryCore(),
          drive: await account(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(RemoteFilesButton.label));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Google Drive'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(DrivePairingScreen), findsOneWidget);
    });

    testWidgets('and Cancel is still the way out', (tester) async {
      await tester.pumpWidget(
        harness(const LibraryScreen(), core: libraryCore()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(RemoteFilesButton.label));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(DrivePairingScreen), findsNothing);
    });
  });
}
