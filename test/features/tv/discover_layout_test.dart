import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/discover/catalog_rows.dart';
import 'package:xtremio/features/discover/discover_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/library_item_tile.dart';
import 'package:xtremio/widgets/poster_tile.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_sharing.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

/// A Google TV: a 1920x1080 panel at a pixel ratio of 2, so the app lays
/// out on 960x540.
const Size panel = Size(1920, 1080);
const double tvPixelRatio = 2;
const Size logical = Size(960, 540);

/// The band a television may crop, top and bottom, in logical pixels.
const double band = 540 * 0.05;

/// The app on [device], on the recorded board, with Continue watching.
Future<FakeCoreClient> pumpApp(
  WidgetTester tester, {
  DeviceProfile device = tv,
}) async {
  final core = FakeCoreClient(
    state: {
      CoreField.ctx: loadCtxLoggedOutFixture(),
      CoreField.board: loadBoardFixture(),
      CoreField.continueWatchingPreview: loadContinueWatchingFixture(),
    },
  );
  await tester.pumpWidget(
    XtremioApp(
      core: core,
      device: device,
      sharingActivity: FakeSharingActivity(),
    ),
  );
  await tester.pumpAndSettle();
  return core;
}

void useTv(WidgetTester tester) {
  tester.view.physicalSize = panel;
  tester.view.devicePixelRatio = tvPixelRatio;
  addTearDown(tester.view.reset);
}

/// Discover's own [T]s, the rail's left out.
Finder inDiscover(Finder matching) =>
    find.descendant(of: find.byType(DiscoverScreen), matching: matching);

/// The board fixture's first catalog row: Cinemeta's Popular movies.
CatalogRow firstCatalog() =>
    CatalogsWithExtraState.fromJson(loadBoardFixture()).rows.first;

/// The rect of the text that reads [text], rich or plain.
Rect textRect(WidgetTester tester, String text) =>
    tester.getRect(find.textContaining(text, findRichText: true).first);

/// Where the board is, on screen.
Rect board(WidgetTester tester) =>
    tester.getRect(find.byKey(const Key('board-rows')));

void main() {
  group('on a television', () {
    testWidgets('there is no title: the types are the top of the screen, '
        'inside the band', (tester) async {
      useTv(tester);
      await pumpApp(tester);

      expect(inDiscover(find.byType(AppBar)), findsNothing);
      expect(inDiscover(find.text('Discover')), findsNothing);
      // The rail still says where the remote is.
      expect(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text('Discover'),
        ),
        findsOneWidget,
      );

      final types = tester.getRect(find.byType(SegmentedButton<int>));
      expect(types.top, band, reason: 'at the edge of the band, not in it');
      expect(
        board(tester).top,
        greaterThanOrEqualTo(types.bottom),
        reason: 'the rows are under the types',
      );
    });

    testWidgets('two whole rows show at rest, headings and captions, inside '
        'the band', (tester) async {
      useTv(tester);
      await pumpApp(tester);
      final safeBottom = logical.height - band;
      final types = tester.getRect(find.byType(SegmentedButton<int>));

      // Row one: Continue watching. Row two: the first catalog.
      final first = textRect(tester, 'Continue watching');
      final second = textRect(tester, firstCatalog().title);
      expect(first.top, greaterThanOrEqualTo(types.bottom));
      expect(second.top, greaterThan(first.bottom));

      final watching = tester.getRect(find.byType(LibraryItemTile).first);
      expect(watching.top, greaterThan(first.bottom));
      expect(watching.bottom, lessThanOrEqualTo(second.top));

      // Every tile of the second row that is on the panel at all is on it
      // whole, caption included.
      final row = firstCatalog().items;
      for (final item in row.take(5)) {
        final tile = tester.getRect(find.widgetWithText(PosterTile, item.name));
        final caption = tester.getRect(find.text(item.name));
        expect(tile.top, greaterThan(second.bottom), reason: item.name);
        expect(tile.bottom, lessThanOrEqualTo(safeBottom), reason: item.name);
        expect(caption.bottom, lessThanOrEqualTo(tile.bottom));
      }
      expect(board(tester).bottom, safeBottom);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a row\'s heading is one line and its posters are the '
        'television\'s size', (tester) async {
      useTv(tester);
      await pumpApp(tester);

      final heading = find.textContaining(
        firstCatalog().title,
        findRichText: true,
      );
      expect(
        tester.widget<RichText>(heading.first).text.toPlainText(),
        contains(firstCatalog().subtitle),
        reason: 'the subtitle is on the title\'s line',
      );
      // Two-thirds of the height, across: the poster keeps its shape.
      expect(
        tester.getSize(find.byType(PosterTile).first).width,
        PosterTile.tvImageWidth,
      );
      expect(
        tester.getSize(find.byType(LibraryItemTile).first).width,
        PosterTile.tvImageWidth,
        reason: 'Continue watching is the same size',
      );
      // Six whole tiles inside the band, and the seventh runs on into it,
      // as a row always has.
      final band = logical.width * 0.95;
      expect(
        tester.getRect(find.byType(PosterTile).at(5)).right,
        lessThan(band),
      );
      expect(
        tester.getRect(find.byType(PosterTile).at(6)).right,
        greaterThan(band),
      );
    });

    testWidgets('a caption is one line, cut short at its end, never broken '
        'inside a word', (tester) async {
      useTv(tester);
      await pumpApp(tester);
      // bodySmall's one line at the television's 1.15.
      const line = 16 * 1.15;
      for (final item in firstCatalog().items.take(6)) {
        final caption = find.text(item.name);
        final text = tester.widget<Text>(caption);
        expect(text.maxLines, 1, reason: item.name);
        expect(text.softWrap, isFalse, reason: item.name);
        expect(text.overflow, TextOverflow.ellipsis, reason: item.name);
        expect(
          tester.getSize(caption).height,
          lessThanOrEqualTo(line + 0.5),
          reason: item.name,
        );
        // Close under its poster.
        final tile = find.widgetWithText(PosterTile, item.name);
        final poster = tester.getRect(
          find.descendant(of: tile, matching: find.byType(PosterImage)),
        );
        expect(
          tester.getRect(caption).top - poster.bottom,
          closeTo(PosterTile.tvCaptionGap, 0.5),
          reason: item.name,
        );
      }
    });

    testWidgets('the remote walks between the types, the rows and the rail', (
      tester,
    ) async {
      useTv(tester);
      final core = await pumpApp(tester);
      // Focus starts where it always has: the first tile.
      expect(focusIn<LibraryItemTile>(), isTrue);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIn<SegmentedButton<int>>(), isTrue, reason: 'up: types');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<LibraryItemTile>(), isTrue, reason: 'down: the rows');

      // Left from a row's first tile is the rail.
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focusIn<NavigationRail>(), isTrue);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusIn<LibraryItemTile>(), isTrue);

      // Left from the first type is the rail too.
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(tester), DiscoverScreen.allTypesLabel);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focusIn<NavigationRail>(), isTrue);

      // Choosing a type filters the rows and leaves the remote on it.
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIn<SegmentedButton<int>>(), isTrue);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(tester), 'Movies');
      await press(tester, LogicalKeyboardKey.select);
      expect(
        core.dispatched
            .lastWhere(
              (action) =>
                  action.field == CoreField.board &&
                  action.action['action'] == 'Load',
            )
            .action,
        CoreActions.loadBoard(type: 'movie').action,
      );
      expect(focusedLabel(tester), 'Movies');
    });

    testWidgets('a focused tile further down is scrolled to where it is '
        'whole, under the types and clear of the band', (tester) async {
      useTv(tester);
      await pumpApp(tester);
      final types = tester.getRect(find.byType(SegmentedButton<int>));
      final safeBottom = logical.height - band;

      // Down the first column, three rows past the two that show.
      for (var row = 1; row <= 3; row++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
        final box =
            FocusManager.instance.primaryFocus!.context!.findRenderObject()!
                as RenderBox;
        final tile = box.localToGlobal(Offset.zero) & box.size;
        expect(focusIn<PosterTile>(), isTrue, reason: 'row $row');
        expect(tile.top, greaterThanOrEqualTo(types.bottom), reason: '$row');
        expect(tile.bottom, lessThanOrEqualTo(safeBottom), reason: '$row');
      }
      expect(pageScrollOffset(tester), greaterThan(0), reason: 'it scrolled');
    });
  });

  testWidgets('a phone keeps its title, its types under it and its posters', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpApp(tester, device: DeviceProfile.fallback);

    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('Discover')),
      findsOneWidget,
    );
    final title = tester.getRect(find.byType(AppBar));
    final types = tester.getRect(find.byType(ChoiceChip).first);
    expect(types.top, title.bottom + 4);

    final extent = tester
        .widget<SliverFixedExtentList>(find.byType(SliverFixedExtentList))
        .itemExtent;
    expect(extent, CatalogRows.rowExtentFor(400));
    expect(extent, 200);
    // 200 less the two-line heading (52), the gap (8) and the caption box
    // and its inset (38 + 8): 94 of poster, two-thirds of that across.
    expect(tester.getSize(find.byType(PosterTile).first).width, 63);
    // The subtitle under the title, not beside it.
    expect(
      textRect(tester, firstCatalog().subtitle).top,
      greaterThan(textRect(tester, firstCatalog().title).bottom - 1),
    );
  });
}
