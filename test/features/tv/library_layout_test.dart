import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/drive/remote_files.dart';
import 'package:xtremio/features/library/library_screen.dart';
import 'package:xtremio/shell/device_profile.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_downloads_client.dart';
import '../../support/fake_sharing.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

/// The band a television may crop, at 960x540.
const double bandTop = 540 * 0.05;
const double safeRight = 960 * 0.95;

/// The app on [device], signed in (so the bar has its sync button), on the
/// Library tab.
Future<void> pumpLibrary(
  WidgetTester tester, {
  DeviceProfile device = tv,
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
          CoreField.ctx: loadCtxLoggedInFixture(),
          CoreField.board: loadBoardFixture(),
          CoreField.continueWatchingPreview: loadContinueWatchingFixture(),
          CoreField.library: loadLibraryFixture(),
        },
      ),
      device: device,
      downloads: downloads,
      sharingActivity: FakeSharingActivity(),
    ),
  );
  await tester.pumpAndSettle();
  final nav = device.isTv
      ? find.byType(NavigationRail)
      : find.byType(NavigationBar);
  await tester.tap(find.descendant(of: nav, matching: find.text('Library')));
  await tester.pumpAndSettle();
}

Finder inLibrary(Finder matching) =>
    find.descendant(of: find.byType(LibraryScreen), matching: matching);

Rect tooltipped(WidgetTester tester, String message) => tester.getRect(
  find.byWidgetPredicate((w) => w is Tooltip && w.message == message),
);

void main() {
  testWidgets('on a television there is no title: the types, the sort and '
      'the bar\'s buttons are one band at the top, inside the safe area', (
    tester,
  ) async {
    await pumpLibrary(tester);

    expect(inLibrary(find.byType(AppBar)), findsNothing);
    expect(inLibrary(find.text('Library')), findsNothing);

    final types = tester.getRect(find.byType(SegmentedButton<int>));
    expect(types.top, bandTop, reason: 'at the edge of the band, not in it');
    final sort = tooltipped(tester, 'Sort: Last watched');
    final sync = tooltipped(tester, 'Sync now');
    final link = tooltipped(tester, RemoteFilesButton.label);
    for (final (name, rect) in [
      ('sort', sort),
      ('sync', sync),
      ('link', link),
    ]) {
      expect(rect.center.dy, closeTo(types.center.dy, 1), reason: name);
      expect(rect.right, lessThanOrEqualTo(safeRight), reason: name);
    }
    expect(sort.left, greaterThan(types.right), reason: 'the sort, then');
    expect(sync.left, greaterThan(sort.right), reason: 'the bar\'s buttons');
    expect(
      link.left,
      greaterThanOrEqualTo(sync.right),
      reason: 'at the band\'s end',
    );
  });

  testWidgets('a phone keeps its title and its bar', (tester) async {
    await pumpLibrary(tester, device: DeviceProfile.fallback);

    final bar = inLibrary(find.byType(AppBar));
    expect(bar, findsOneWidget);
    expect(
      find.descendant(of: bar, matching: find.text('Library')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: bar,
        matching: find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == RemoteFilesButton.label,
        ),
      ),
      findsOneWidget,
    );
    // The sort keeps its words.
    expect(inLibrary(find.byType(DropdownMenu<int>)), findsOneWidget);
  });
}
