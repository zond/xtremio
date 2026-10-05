import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/library/library_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/library_item_tile.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_downloads_client.dart';
import '../../support/fake_drive_pairing_service.dart';
import '../../support/fake_prefs_client.dart';
import '../../support/fake_sharing.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

/// The band a television may crop, top and bottom, at 960x540.
const double band = 540 * 0.05;

/// Thirty linked files nothing matched: enough tiles under Remote for the
/// grid to scroll.
Future<DriveAccount> linkedAccount() async {
  final drive = await driveAccount(prefsClient: FakePrefsClient());
  await drive.link(
    refreshToken: 'a-refresh-token',
    files: [
      for (var i = 0; i < 30; i++)
        LinkedDriveFile(
          fileId: 'drive-file-$i',
          name: 'Home video $i.mkv',
          mimeType: 'video/x-matroska',
          linkedAt: DateTime.utc(2026, 9, 20),
        ),
    ],
  );
  return drive;
}

/// The app on [device], on the Library tab, with Remote on unless
/// [remote] is false.
Future<void> pumpRemote(
  WidgetTester tester, {
  DeviceProfile device = tv,
  bool remote = true,
}) async {
  if (device.isTv) {
    // A Google TV: a 1920x1080 panel at a pixel ratio of 2.
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
  } else {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
  }
  addTearDown(tester.view.reset);
  final downloads = FakeDownloadsClient();
  addTearDown(downloads.dispose);
  await tester.pumpWidget(
    XtremioApp(
      core: FakeCoreClient(
        state: {
          CoreField.ctx: loadCtxLoggedOutFixture(),
          CoreField.board: loadBoardFixture(),
          CoreField.continueWatchingPreview: loadContinueWatchingFixture(),
          CoreField.library: loadLibraryFixture(),
        },
      ),
      device: device,
      downloads: downloads,
      drive: await tester.runAsync(linkedAccount),
      sharingActivity: FakeSharingActivity(),
    ),
  );
  await tester.pumpAndSettle();
  final nav = device.isTv
      ? find.byType(NavigationRail)
      : find.byType(NavigationBar);
  await tester.tap(find.descendant(of: nav, matching: find.text('Library')));
  await tester.pumpAndSettle();
  if (!remote) return;
  await tester.tap(find.widgetWithText(FilterChip, LibraryScreen.remoteLabel));
  await tester.pumpAndSettle();
}

Finder note() => find.text(LibraryScreen.matchedByNameNote);

/// The grid's scroll view.
Finder grid() => find.descendant(
  of: find.byType(LibraryScreen),
  matching: find.byType(CustomScrollView),
);

ScrollPosition gridPosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(of: grid(), matching: find.byType(Scrollable)).first,
    )
    .position;

/// How many rows of tiles are on screen whole, captions and all, inside
/// the grid and clear of the band.
int wholeRows(WidgetTester tester, double bottom) {
  final view = tester.getRect(grid());
  final tops = <double>{};
  for (final element in find.byType(LibraryItemTile).evaluate()) {
    final tile = tester.getRect(find.byElementPredicate((e) => e == element));
    if (tile.top >= view.top && tile.bottom <= bottom) tops.add(tile.top);
  }
  return tops.length;
}

void main() {
  group('on a television, under Remote', () {
    testWidgets('the note on matching is the grid\'s first item, and '
        'scrolls away with it', (tester) async {
      await pumpRemote(tester);
      expect(note(), findsOneWidget);
      expect(
        find.descendant(of: grid(), matching: note()),
        findsOneWidget,
        reason: 'inside the scroll, not fixed above it',
      );
      final view = tester.getRect(grid());
      final atRest = tester.getRect(note());
      expect(atRest.top, greaterThanOrEqualTo(view.top));
      expect(
        tester.getRect(find.byType(LibraryItemTile).first).top,
        greaterThan(atRest.bottom),
        reason: 'above the first row at rest',
      );

      gridPosition(tester).jumpTo(40);
      await tester.pumpAndSettle();
      expect(tester.getRect(note()).top, atRest.top - 40);
    });

    testWidgets('scrolled away, it leaves the posters the whole height', (
      tester,
    ) async {
      await pumpRemote(tester);
      final safeBottom = 540 - band;
      final noteHeight = tester
          .getRect(find.byKey(const Key('library-notes')))
          .height;

      gridPosition(tester).jumpTo(noteHeight + 8);
      await tester.pumpAndSettle();
      // The first row moves up into the room the note had.
      final firstRow = tester.getRect(find.byType(LibraryItemTile).first);
      expect(firstRow.top, lessThan(tester.getRect(grid()).top + 16));
      // One whole row, captions and all. Not two: under the app bar and
      // the two filter rows the grid is 246 dp tall, and two rows of the
      // television's tiles are 319.
      expect(wholeRows(tester, safeBottom), 1);
    });

    testWidgets('the remote walking down into the posters scrolls the note '
        'away, and back up to the first row shows that row whole', (
      tester,
    ) async {
      await pumpRemote(tester);
      final view = tester.getRect(grid());
      final safeBottom = 540 - band;
      Rect focusedRect() {
        final box =
            FocusManager.instance.primaryFocus!.context!.findRenderObject()!
                as RenderBox;
        return box.localToGlobal(Offset.zero) & box.size;
      }

      // Selecting the tab left the remote on the rail: right into the
      // screen, then down to the first row.
      expect(focusIn<NavigationRail>(), isTrue);
      await press(tester, LogicalKeyboardKey.arrowRight);
      for (var i = 0; i < 8 && !focusIn<LibraryItemTile>(); i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(focusIn<LibraryItemTile>(), isTrue);
      final seen = {focusedTileName(tester)};
      for (var row = 1; row <= 3; row++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(seen.add(focusedTileName(tester)), isTrue, reason: 'row $row');
        final tile = focusedRect();
        expect(tile.top, greaterThanOrEqualTo(view.top), reason: 'row $row');
        expect(tile.bottom, lessThanOrEqualTo(safeBottom), reason: 'row $row');
      }
      expect(
        note().evaluate().isEmpty || tester.getRect(note()).bottom <= view.top,
        isTrue,
        reason: 'scrolled away, as far as out of the list',
      );

      for (var row = 2; row >= 0; row--) {
        await press(tester, LogicalKeyboardKey.arrowUp);
      }
      expect(focusIn<LibraryItemTile>(), isTrue);
      final tile = focusedRect();
      expect(tile.top, greaterThanOrEqualTo(view.top));
      expect(tile.bottom, lessThanOrEqualTo(safeBottom));
    });
  });

  testWidgets('signed out, the line that says so scrolls with the grid as '
      'well', (tester) async {
    await pumpRemote(tester, remote: false);
    expect(
      find.descendant(
        of: grid(),
        matching: find.textContaining('Sign in to sync'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a phone scrolls the note with the grid too', (tester) async {
    await pumpRemote(tester, device: DeviceProfile.fallback);
    expect(find.descendant(of: grid(), matching: note()), findsOneWidget);
  });
}
