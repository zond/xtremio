import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/drive/drive_pairing_screen.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/external_link.dart';

import '../support/fake_drive_file_opener.dart';
import '../support/fake_drive_pairing_service.dart';
import '../support/fake_link_opener.dart';
import '../support/fake_secret_store.dart';
import '../support/player_harness.dart';

const DeviceProfile _tv = DeviceProfile(isTv: true, hasTouch: false);

/// A [DriveAccount] over fakes, optionally already linked -- which is the
/// state a viewer who paired last week comes back in.
Future<DriveAccount> _account({bool linked = false}) async {
  final prefs = AppPrefs.inMemory();
  await prefs.load();
  final account = DriveAccount(
    prefs: prefs,
    secrets: FakeSecretStore(),
    now: () => pairingNow,
  );
  await account.load();
  addTearDown(() {
    account.dispose();
    prefs.dispose();
  });
  if (linked) {
    await account.linkFile(
      refreshToken: fakeRefreshToken,
      fileId: 'drive-file-1',
      name: 'Arrival (2016) 2160p.mkv',
      mimeType: 'video/x-matroska',
    );
  }
  return account;
}

/// The pairing screen under the scopes the *player* needs, because pressing
/// Play pushes one: the whole point of these tests is the path from a linked
/// file to a player, so nothing here stubs the push out.
///
/// [PlayerHarness] is what supplies the fake core, the fake engine and the
/// playback scope; the Drive screen goes inside its `MaterialApp` with the
/// two scopes of its own above it.
Widget _harness({
  required DriveAccount account,
  required DriveFileOpener opener,
  DrivePairingService? service,
}) => PlayerHarness(device: _tv).build(
  home: ExternalLinkScope(
    opener: FakeLinkOpener(),
    child: DriveAccountScope(
      account: account,
      child: DrivePairingScreen(
        service: service ?? FakeDrivePairingService(),
        opener: opener,
        now: () => pairingNow,
      ),
    ),
  ),
);

void main() {
  group('the list a pairing built', () {
    testWidgets('a linked device opens on its files rather than on a '
        'code', (tester) async {
      final service = FakeDrivePairingService();
      await tester.pumpWidget(
        _harness(
          account: await _account(linked: true),
          opener: FakeDriveFileOpener(),
          service: service,
        ),
      );
      await tester.pump();

      expect(find.text(DrivePairingScreen.linkedFilesHeading), findsOneWidget);
      expect(find.text('Arrival (2016) 2160p.mkv'), findsOneWidget);
      expect(find.byType(PairingQrCode), findsNothing);
      // And the call the service rate-limits was not spent on a code
      // nobody asked for.
      expect(service.opens, 0);

      // The way on is still there.
      expect(find.text(DrivePairingScreen.linkAnotherLabel), findsOneWidget);
    });

    testWidgets('a device with nothing linked still opens on a code', (
      tester,
    ) async {
      final service = FakeDrivePairingService();
      await tester.pumpWidget(
        _harness(
          account: await _account(),
          opener: FakeDriveFileOpener(),
          service: service,
        ),
      );
      await tester.pump();

      expect(find.byType(PairingQrCode), findsOneWidget);
      expect(find.text(DrivePairingScreen.linkedFilesHeading), findsNothing);
      expect(service.opens, 1);
    });

    testWidgets('pressing a file opens it with the account\'s own grant and '
        'plays it', (tester) async {
      final account = await _account(linked: true);
      final opener = FakeDriveFileOpener();
      await tester.pumpWidget(_harness(account: account, opener: opener));
      await tester.pump();

      await tester.tap(find.byKey(const Key('drive-file-drive-file-1')));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(opener.asked, hasLength(1));
      expect(opener.asked.single.fileId, 'drive-file-1');
      expect(opener.asked.single.refreshToken, fakeRefreshToken);
      // The player is on top of the pairing screen, which is the whole
      // point of the button.
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(find.text(DrivePairingScreen.linkedFilesHeading), findsNothing);
    });

    testWidgets('a dead pairing sends the viewer back to a code, with a '
        'sentence', (tester) async {
      final account = await _account(linked: true);
      final opener = FakeDriveFileOpener(
        answers: const [DriveFileRefused(DriveOpenFailure.pairAgain)],
      );
      final service = FakeDrivePairingService();
      await tester.pumpWidget(
        _harness(account: account, opener: opener, service: service),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('drive-file-drive-file-1')));
      await tester.pump();
      await tester.pump();

      // The account knows, so every screen that reads it knows.
      expect(account.state, DriveLinkState.pairAgain);
      // And this screen offers the one thing that fixes it.
      expect(
        find.text(driveFailureMessage(DriveOpenFailure.pairAgain)),
        findsOneWidget,
      );
      expect(find.text(DrivePairingScreen.freshCodeLabel), findsOneWidget);
      expect(find.text('Arrival (2016) 2160p.mkv'), findsNothing);
    });

    testWidgets('a failure that might pass says so and leaves the list '
        'alone', (tester) async {
      final account = await _account(linked: true);
      final opener = FakeDriveFileOpener(
        answers: const [DriveFileRefused(DriveOpenFailure.unreachable)],
      );
      await tester.pumpWidget(_harness(account: account, opener: opener));
      await tester.pump();

      await tester.tap(find.byKey(const Key('drive-file-drive-file-1')));
      await tester.pump();
      await tester.pump();

      expect(
        find.text(driveFailureMessage(DriveOpenFailure.unreachable)),
        findsOneWidget,
      );
      // Still linked, and the file still there to try again.
      expect(account.state, DriveLinkState.linked);
      expect(find.text('Arrival (2016) 2160p.mkv'), findsOneWidget);
    });
  });

  group('straight from the pairing', () {
    testWidgets('the screen that linked a file offers to play it', (
      tester,
    ) async {
      final account = await _account();
      final service = FakeDrivePairingService(answers: [fakeCollected()]);
      final opener = FakeDriveFileOpener();
      await tester.pumpWidget(
        _harness(account: account, opener: opener, service: service),
      );
      await tester.pump();
      // One poll brings the pairing back.
      await tester.pump(DrivePairingScreen.defaultPollEvery);
      await tester.pump();
      await tester.pump();

      expect(find.text(DrivePairingScreen.playLabel), findsOneWidget);
      await tester.tap(find.text(DrivePairingScreen.playLabel));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(opener.asked, hasLength(1));
      expect(opener.asked.single.fileId, 'drive-file-1');
      expect(opener.asked.single.refreshToken, fakeRefreshToken);
      expect(find.byType(PlayerScreen), findsOneWidget);
    });
  });
}
