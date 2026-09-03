import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/library/library_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/root_shell.dart';
import 'package:xtremio/widgets/remote_press.dart';

import '../../support/fake_core_client.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

/// The anonymous library of the fixture: Lanterns (a series) and The
/// Whisper Man (a movie), every type, last watched first.
FakeCoreClient fakeCore() => FakeCoreClient(
  state: {
    CoreField.library: loadLibraryFixture(),
    CoreField.ctx: loadCtxLoggedOutFixture(),
    CoreField.board: loadBoardFixture(),
    CoreField.continueWatchingPreview: loadContinueWatchingFixture(),
  },
);

Widget harness(FakeCoreClient core, {Widget home = const LibraryScreen()}) =>
    DeviceScope(
      profile: tv,
      child: CoreScope(
        client: core,
        child: MaterialApp(home: home),
      ),
    );

/// Every `Ctx` action dispatched so far, by its `action` name.
List<String> ctxActions(FakeCoreClient core) => [
  for (final action in core.dispatched)
    if (action.action['action'] == 'Ctx')
      (action.action['args'] as Map<String, dynamic>)['action'] as String,
];

/// Mounts the library and walks the D-pad down into the filter row, down
/// again into the grid and left to its first tile.
Future<FakeCoreClient> mountOnFirstTile(WidgetTester tester) async {
  useScreen(tester, tvSize);
  final core = fakeCore();
  await tester.pumpWidget(harness(core));
  await tester.pumpAndSettle();
  await press(tester, LogicalKeyboardKey.arrowDown);
  await press(tester, LogicalKeyboardKey.arrowDown);
  for (var i = 0; i < 2 && focusedTileName(tester) != 'Lanterns'; i++) {
    await press(tester, LogicalKeyboardKey.arrowLeft);
  }
  expect(focusedTileName(tester), 'Lanterns');
  return core;
}

void main() {
  testWidgets('the D-pad walks the filter row, then the grid', (tester) async {
    useScreen(tester, tvSize);
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();
    // Nothing takes focus by itself: the tab keeps focus on the rail until
    // the user steps in.
    expect(focusedLabel(tester), isNull);

    // Down from nowhere lands on the topmost control: the type segments.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<SegmentedButton<int>>(), isTrue);
    expect(focusedLabel(tester), 'All');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), 'Movies');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), 'Series');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), 'Sort: Last watched');
    expect(find.byType(DropdownMenu<int>), findsNothing);

    // Down enters the grid (the filter row is centred, so on the tile
    // under the sort button); left and right walk it; up is the filters.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTileName(tester), 'The Whisper Man');
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedTileName(tester), 'Lanterns');
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedTileName(tester), 'Lanterns', reason: 'first column');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTileName(tester), 'The Whisper Man');
    // Traversal is geometric: with nothing beside the last tile, right goes
    // up to the nearest filter control that is further right.
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTileName(tester), isNull);
    expect(focusIn<SegmentedButton<int>>(), isTrue);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTileName(tester), 'The Whisper Man');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusIn<SegmentedButton<int>>(), isTrue);
    expect(focusedTileName(tester), isNull);
  });

  testWidgets('select on a segment dispatches its type', (tester) async {
    useScreen(tester, tvSize);
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), 'Movies');

    await press(tester, LogicalKeyboardKey.select);
    final request =
        core.dispatched.last.action['args']['args']['request']
            as Map<String, dynamic>;
    expect(request['type'], 'movie');
  });

  testWidgets('select on a tile opens its details', (tester) async {
    await mountOnFirstTile(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    // (The details' spinner never settles: the fake has no meta for it.)
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(MetaDetailsScreen), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('the menu key opens the actions with the first one focused; '
      'select runs it and focus comes back to the tile', (tester) async {
    final core = await mountOnFirstTile(tester);

    await press(tester, LogicalKeyboardKey.contextMenu);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(MetaDetailsScreen), findsNothing);
    expect(focusIn<BottomSheet>(), isTrue);
    expect(focusedLabel(tester), 'Mark as watched');

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedLabel(tester), 'Mark as watched', reason: 'title is text');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedLabel(tester), 'Rewind');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedLabel(tester), 'Disable notifications');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedLabel(tester), 'Remove from library');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedLabel(tester), 'Remove from library', reason: 'the end');
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedLabel(tester), 'Rewind');

    await press(tester, LogicalKeyboardKey.select);
    expect(find.byType(BottomSheet), findsNothing);
    expect(ctxActions(core), ['RewindLibraryItem']);
    expect(focusedTileName(tester), 'Lanterns');
  });

  testWidgets('a held select opens the actions too, and BACK closes them', (
    tester,
  ) async {
    final core = await mountOnFirstTile(tester);

    await hold(tester, LogicalKeyboardKey.select, RemotePress.holdDuration * 2);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(MetaDetailsScreen), findsNothing);
    expect(focusedLabel(tester), 'Mark as watched');

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(ctxActions(core), isEmpty);
    expect(focusedTileName(tester), 'Lanterns');
  });

  testWidgets('off a TV the sheet takes no focus of its own', (tester) async {
    final core = fakeCore();
    await tester.pumpWidget(
      CoreScope(
        client: core,
        child: const MaterialApp(home: LibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Lanterns'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(focusedLabel(tester), isNull);
  });

  testWidgets('coming back to the Library tab restores the focused tile', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    final core = fakeCore();
    core.setState(CoreField.search, {
      'selected': null,
      'catalogs': <Object>[],
      'catalogLabels': <Object>[],
    });
    await tester.pumpWidget(harness(core, home: const RootShell()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryScreen), findsOneWidget);
    // Right from the rail enters the filter row; down and right reach the
    // second tile.
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusIn<LibraryScreen>(), isTrue);
    while (focusedTileName(tester) == null) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTileName(tester), 'The Whisper Man');

    await tester.tap(find.text('Board'));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryScreen), findsNothing);
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();

    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(focusedTileName(tester), 'The Whisper Man');
  });
}
