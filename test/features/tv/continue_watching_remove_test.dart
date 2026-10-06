import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/widgets/library_item_tile.dart';
import 'package:xtremio/widgets/poster_tile.dart';
import 'package:xtremio/widgets/remote_press.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_sharing.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

const String first = 'Night of the Living Dead';
const String second = 'Carnival of Souls';

/// The recorded Continue watching, with [extra] more titles after its one.
Map<String, dynamic> continueWatching({bool withSecond = true}) {
  final preview = loadContinueWatchingFixture();
  final items = preview['items'] as List<dynamic>;
  if (withSecond) {
    final copy = Map<String, dynamic>.of(items.single as Map<String, dynamic>)
      ..['_id'] = 'tt0055830'
      ..['name'] = second;
    items.add(copy);
  }
  return preview;
}

Future<FakeCoreClient> pumpApp(
  WidgetTester tester,
  Map<String, dynamic> preview,
) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final core = FakeCoreClient(
    state: {
      CoreField.ctx: loadCtxLoggedOutFixture(),
      CoreField.board: loadBoardFixture(),
      CoreField.continueWatchingPreview: preview,
    },
  );
  await tester.pumpWidget(
    XtremioApp(core: core, device: tv, sharingActivity: FakeSharingActivity()),
  );
  await tester.pumpAndSettle();
  return core;
}

/// The title-level actions sent so far: the app's own start-up ones (a
/// pull of the addons) left out.
List<Map<String, dynamic>> ctxActions(FakeCoreClient core) => [
  for (final action in core.dispatched)
    if (action.action['action'] == 'Ctx' &&
        const {
          'RewindLibraryItem',
          'DismissNotificationItem',
          'RemoveFromLibrary',
          'LibraryItemMarkAsWatched',
        }.contains((action.action['args'] as Map<String, dynamic>)['action']))
      action.action,
];

/// The remote's long press: select held past Android's timeout.
Future<void> holdSelect(WidgetTester tester) => hold(
  tester,
  LogicalKeyboardKey.select,
  RemotePress.holdDuration + const Duration(milliseconds: 100),
);

/// Holds select on the focused tile and confirms the removal.
Future<void> removeFocused(WidgetTester tester) async {
  await holdSelect(tester);
  await press(tester, LogicalKeyboardKey.arrowUp);
  expect(focusedLabel(tester), 'Remove from Continue watching');
  await press(tester, LogicalKeyboardKey.select);
}

void main() {
  testWidgets('the confirmation opens on Cancel, and Cancel sends nothing', (
    tester,
  ) async {
    final core = await pumpApp(tester, continueWatching());
    expect(focusedTileName(tester), first);

    await holdSelect(tester);
    expect(find.text('Remove from Continue watching'), findsOneWidget);
    expect(focusedLabel(tester), 'Cancel', reason: 'the harmless choice');
    await press(tester, LogicalKeyboardKey.select);

    expect(find.byType(BottomSheet), findsNothing);
    expect(ctxActions(core), isEmpty);
    expect(focusedTileName(tester), first, reason: 'back where it was');
  });

  testWidgets('a real remote\'s hold -- down, repeats while it is held, up -- '
      'leaves the confirmation open with nothing chosen', (tester) async {
    // Android sends a held key's repeats every 50 ms or so. The sheet opens
    // at the long press, half a second into the hold, and takes the remote
    // onto Cancel; the repeats still coming must not press it.
    final core = await pumpApp(tester, continueWatching());
    expect(focusedTileName(tester), first);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(
      RemotePress.holdDuration + const Duration(milliseconds: 50),
    );
    await tester.pumpAndSettle();
    expect(find.text('Remove from Continue watching'), findsOneWidget);
    expect(focusedLabel(tester), 'Cancel');

    for (var i = 0; i < 5; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(find.text('Remove from Continue watching'), findsOneWidget);
    expect(focusedLabel(tester), 'Cancel');

    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('Remove from Continue watching'), findsOneWidget);
    expect(ctxActions(core), isEmpty);

    // And the next press is an ordinary one again.
    await press(tester, LogicalKeyboardKey.select);
    expect(find.byType(BottomSheet), findsNothing);
    expect(focusedTileName(tester), first);
  });

  testWidgets('the last tile of the row hands the remote to the one before '
      'it', (tester) async {
    final core = await pumpApp(tester, continueWatching());
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTileName(tester), second);

    await removeFocused(tester);
    expect(ctxActions(core), [
      CoreActions.rewindLibraryItem('tt0055830').action,
      CoreActions.dismissNotificationItem('tt0055830').action,
    ]);
    // The engine's answer: the row without it.
    core.setState(
      CoreField.continueWatchingPreview,
      continueWatching(withSecond: false),
    );
    await tester.pumpAndSettle();

    expect(find.text(second), findsNothing);
    expect(focusIn<LibraryItemTile>(), isTrue);
    expect(focusedTileName(tester), first);
  });

  testWidgets('a tile with one after it hands the remote to that one', (
    tester,
  ) async {
    final core = await pumpApp(tester, continueWatching());
    expect(focusedTileName(tester), first);

    await removeFocused(tester);
    final preview = continueWatching();
    (preview['items'] as List<dynamic>).removeAt(0);
    core.setState(CoreField.continueWatchingPreview, preview);
    await tester.pumpAndSettle();

    expect(find.text(first), findsNothing);
    expect(focusedTileName(tester), second);
  });

  testWidgets('the row\'s only tile hands the remote to the row that takes '
      'its place', (tester) async {
    final core = await pumpApp(tester, continueWatching(withSecond: false));
    expect(focusedTileName(tester), first);

    await removeFocused(tester);
    core.setState(CoreField.continueWatchingPreview, {'items': <Object>[]});
    await tester.pumpAndSettle();

    expect(find.text('Continue watching'), findsNothing);
    expect(tester.takeException(), isNull);
    expect(focusIn<PosterTile>(), isTrue);
    final popular = CatalogsWithExtraState.fromJson(loadBoardFixture())
        .rows
        .first
        .items
        .first
        .name;
    expect(focusedTileName(tester), popular);
  });
}
