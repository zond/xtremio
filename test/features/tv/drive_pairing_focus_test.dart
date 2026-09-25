import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/board/board_screen.dart';
import 'package:xtremio/features/drive/drive_pairing_screen.dart';
import 'package:xtremio/features/drive/remote_files.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/tv_density.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_drive_pairing_service.dart';
import '../../support/fake_secret_store.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

/// Reaching the link button on a television, and coming back.
///
/// The board is the one screen in this app with something to press *above*
/// its rows, and that is the arrangement geometric focus is worst at: up
/// from a poster takes the nearest node in that direction, and coming back
/// down out of a control with nothing in its own vertical band, Flutter
/// re-sorts every node below by horizontal distance and can land three rows
/// into the page. Two rungs of a [TvLadder] are what make it an answer
/// about regions instead. This walks it.
void main() {
  /// The board fixture with nothing to continue, so the topmost row is a
  /// catalog with more than one card in it -- which is what makes "down
  /// came back to the card it left" say anything.
  FakeCoreClient board({bool continueWatching = false}) => FakeCoreClient(
    state: {
      CoreField.board: loadBoardFixture(),
      CoreField.continueWatchingPreview: continueWatching
          ? loadContinueWatchingFixture()
          : {'items': <Object>[]},
    },
  );

  /// The names in catalog row [index] of the board fixture.
  List<String> rowNames(int index) => [
    for (final item in CatalogsWithExtraState.fromJson(
      loadBoardFixture(),
    ).rows[index].items)
      item.name,
  ];

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
          home: const BoardScreen(),
        ),
      ),
    ),
  );

  testWidgets('up from the top row reaches the link button, and down comes '
      'back to the card it left', (tester) async {
    useScreen(tester, tvSize);
    await tester.pumpWidget(harness(board(), await account()));
    await tester.pumpAndSettle();
    final movies = rowNames(0);
    expect(focusedTileName(tester), movies[0]);

    // Two steps along the top row, so "came back" is a claim about the
    // card and not about the row.
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTileName(tester), movies[2]);

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedTooltip(), RemoteFilesButton.label);
    expect(
      focusMarks(),
      isNotEmpty,
      reason:
          'the remote is standing on the link button with nothing drawn '
          'to say so',
    );

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTileName(tester), movies[2]);
  });

  testWidgets('and nothing is stepped over: down out of the bar walks the '
      'rows in the order they are drawn', (tester) async {
    useScreen(tester, tvSize);
    await tester.pumpWidget(harness(board(), await account()));
    await tester.pumpAndSettle();

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedTooltip(), RemoteFilesButton.label);

    // The first press out of the bar lands on the topmost row and not on
    // whatever happened to be horizontally nearest further down; the
    // presses after it are directional traversal, unchanged.
    for (var row = 0; row < 3; row++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(
        rowNames(row),
        contains(focusedTileName(tester)),
        reason: 'the walk down the board skipped row $row',
      );
    }
  });

  testWidgets('the same holds when continue watching is the topmost row', (
    tester,
  ) async {
    // Which row is on top is a property of the state, not of the code, so
    // the rung is keyed on being drawn first rather than on being a
    // catalog.
    useScreen(tester, tvSize);
    await tester.pumpWidget(
      harness(board(continueWatching: true), await account()),
    );
    await tester.pumpAndSettle();
    expect(focusedTileName(tester), 'Night of the Living Dead');

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedTooltip(), RemoteFilesButton.label);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTileName(tester), 'Night of the Living Dead');
  });

  testWidgets('select opens the list of services, and the remote can reach '
      'the one row on it', (tester) async {
    useScreen(tester, tvSize);
    await tester.pumpWidget(harness(board(), await account()));
    await tester.pumpAndSettle();

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedTooltip(), RemoteFilesButton.label);
    await press(tester, LogicalKeyboardKey.select);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Google Drive'), findsOneWidget);

    await pressUntil(
      tester,
      LogicalKeyboardKey.tab,
      () => focusedLabel(tester) == 'Google Drive',
      target: 'the Google Drive row',
      limit: 8,
    );
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
    // what the board hands it is the deployed one, and a widget test must
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

/// Presses [key] until [reached] answers true, or fails naming [target].
Future<void> pressUntil(
  WidgetTester tester,
  LogicalKeyboardKey key,
  bool Function() reached, {
  required String target,
  int limit = 30,
}) async {
  for (var i = 0; i < limit; i++) {
    if (reached()) return;
    await press(tester, key);
  }
  expect(reached(), isTrue, reason: 'never reached $target');
}
