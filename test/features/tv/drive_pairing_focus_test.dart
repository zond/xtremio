import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/drive/drive_pairing_screen.dart';
import 'package:xtremio/features/drive/remote_files.dart';
import 'package:xtremio/features/library/library_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/tv_density.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_drive_pairing_service.dart';
import '../../support/fake_secret_store.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

/// Reaching the link button on a television, and getting from it to a code to
/// scan.
///
/// **This file used to walk the board**, because that is where the button was:
/// three of its tests were about the two rungs of a [TvLadder] the board hung
/// on for this one control, and the fourth was the press that opens the list
/// of services. The button is in the library's app bar now, and so is the
/// walk. The rung tests did not come with it and are not replaced here:
/// there is no ladder to test on the library (`library_screen.dart` says
/// why), and the claim they were making about regions -- up out of the row
/// reaches the bar, down out of the bar does not land in the grid -- is made
/// against the library in `library_focus_test.dart`, where the rest of that
/// screen's walk already lives.
///
/// What is here is the part that is about this feature rather than about the
/// screen under it: the button, the dialog it opens, the one row on that
/// dialog, and the pairing screen beyond it.
void main() {
  /// The anonymous library of the fixture: two titles, every type, last
  /// watched first. Its contents matter only in that the app bar is drawn
  /// whatever the engine says.
  FakeCoreClient library() => FakeCoreClient(
    state: {
      CoreField.library: loadLibraryFixture(),
      CoreField.ctx: loadCtxLoggedOutFixture(),
    },
  );

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

  Widget harness(FakeCoreClient core, DriveAccount drive) => DeviceScope(
    profile: tv,
    child: DriveAccountScope(
      account: drive,
      child: CoreScope(
        client: core,
        child: MaterialApp(
          theme: XtremioApp.themeFor(isTv: true),
          builder: TvMediaQuery.builder,
          home: const LibraryScreen(),
        ),
      ),
    ),
  );

  /// Presses down until the link button has the remote.
  Future<void> reachTheButton(WidgetTester tester) async {
    for (var i = 0; i < 4 && focusedTooltip() != RemoteFilesButton.label; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(focusedTooltip(), RemoteFilesButton.label);
  }

  testWidgets('the link button is in the library, and the remote finds it', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    await tester.pumpWidget(harness(library(), await account()));
    await tester.pumpAndSettle();

    await reachTheButton(tester);
    expect(
      focusMarks(),
      isNotEmpty,
      reason:
          'the remote is standing on the link button with nothing drawn '
          'to say so',
    );
  });

  testWidgets('select opens the list of services, and its row is a control '
      'a remote can land on', (tester) async {
    useScreen(tester, tvSize);
    await tester.pumpWidget(harness(library(), await account()));
    await tester.pumpAndSettle();

    await reachTheButton(tester);
    await press(tester, LogicalKeyboardKey.select);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Google Drive'), findsOneWidget);

    // The row takes the remote on arrival, so a dialog whose only
    // button-shaped control used to be Cancel now opens with the remote on
    // the thing to do.
    expect(focusedLabel(tester), 'Google Drive');
    expect(
      focusMarks(),
      isNotEmpty,
      reason:
          'a row on the services dialog the remote can land on with '
          'nothing drawn on it',
    );

    await press(tester, LogicalKeyboardKey.select);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(DrivePairingScreen), findsOneWidget);
  });

  testWidgets('and the pairing screen it opens draws a QR on a television', (
    tester,
  ) async {
    // Mounted with a fake service rather than reached through the dialog:
    // what the library hands it is the deployed one, and a widget test must
    // not be pointed at that.
    useScreen(tester, tvSize);
    final drive = await account();
    final service = FakeDrivePairingService();
    await tester.pumpWidget(
      DeviceScope(
        profile: tv,
        child: DriveAccountScope(
          account: drive,
          child: MaterialApp(
            theme: XtremioApp.themeFor(isTv: true),
            builder: TvMediaQuery.builder,
            home: DrivePairingScreen(service: service, now: () => pairingNow),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(PairingQrCode), findsOneWidget);
    expect(find.text(service.session.code), findsOneWidget);
  });
}
