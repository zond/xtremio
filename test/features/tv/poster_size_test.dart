import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/discover/discover_screen.dart';
import 'package:xtremio/features/library/library_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/root_shell.dart';
import 'package:xtremio/widgets/library_item_tile.dart';
import 'package:xtremio/widgets/poster_tile.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_downloads_client.dart';
import '../../support/fake_sharing.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

/// The app on [device], every tab able to settle; a Google TV is a
/// 1920x1080 panel at a pixel ratio of 2.
Future<void> pumpApp(WidgetTester tester, {DeviceProfile device = tv}) async {
  if (device.isTv) {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
  } else {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
  }
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    XtremioApp(
      core: FakeCoreClient(
        state: {
          CoreField.ctx: loadCtxLoggedOutFixture(),
          CoreField.board: loadBoardFixture(),
          CoreField.continueWatchingPreview: loadContinueWatchingFixture(),
          CoreField.library: loadLibraryFixture(),
          CoreField.discover: loadDiscoverFixture(),
        },
      ),
      device: device,
      downloads: FakeDownloadsClient(),
      sharingActivity: FakeSharingActivity(),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> showTab(WidgetTester tester, String tab) async {
  final nav = find.byType(NavigationRail).evaluate().isEmpty
      ? find.byType(NavigationBar)
      : find.byType(NavigationRail);
  await tester.tap(find.descendant(of: nav, matching: find.text(tab)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('on a television a poster is one size: Discover\'s rows, '
      'its catalog grid and the Library\'s grid', (tester) async {
    await pumpApp(tester);
    final row = tester.getSize(find.byType(LibraryItemTile).first);
    final rowPoster = tester.getSize(find.byType(PosterTile).first);
    expect(row.width, PosterTile.tvImageHeight * 2 / 3);
    expect(rowPoster, row);

    await showTab(tester, 'Library');
    final library = find.descendant(
      of: find.byType(LibraryScreen),
      matching: find.byType(LibraryItemTile),
    );
    expect(library, findsWidgets);
    expect(tester.getSize(library.first), row);

    // A catalog as a grid, as a genre chip opens it.
    unawaited(
      Navigator.of(tester.element(find.byType(RootShell))).push(
        MaterialPageRoute<void>(
          builder: (_) => DiscoverScreen(
            request: ResourceRequest.cinemetaCatalog(type: 'movie', id: 'top'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final grid = find.descendant(
      of: find.byType(GridView),
      matching: find.byType(PosterTile),
    );
    expect(grid, findsWidgets);
    expect(tester.getSize(grid.first), row);
  });

  testWidgets('a phone\'s grids keep the width they divide into', (
    tester,
  ) async {
    await pumpApp(tester, device: DeviceProfile.fallback);
    await showTab(tester, 'Library');

    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    expect(grid.gridDelegate, same(posterGridDelegate));
  });
}
