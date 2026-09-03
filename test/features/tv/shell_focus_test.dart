import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/board/board_screen.dart';
import 'package:xtremio/features/library/library_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/root_shell.dart';

import '../../support/fake_core_client.dart';
import '../../support/fixtures.dart';

const tv = DeviceProfile(isTv: true, hasTouch: false);

/// A core with the Board, Library and Search tabs all able to settle.
FakeCoreClient fakeCore() => FakeCoreClient(
  state: {
    CoreField.board: loadBoardFixture(),
    CoreField.continueWatchingPreview: loadContinueWatchingFixture(),
    CoreField.library: loadLibraryFixture(),
    CoreField.ctx: loadCtxLoggedOutFixture(),
    CoreField.search: {
      'selected': null,
      'catalogs': <Object>[],
      'catalogLabels': <Object>[],
    },
  },
);

/// The shell as the app mounts it, on [device].
Widget harness(FakeCoreClient core, {DeviceProfile device = tv}) => DeviceScope(
  profile: device,
  child: CoreScope(
    client: core,
    child: const MaterialApp(home: RootShell()),
  ),
);

/// The widget with primary focus sits under a [T].
bool focusIn<T extends Widget>() =>
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<T>() !=
    null;

void useScreen(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a TV gets the rail whatever its width', (tester) async {
    useScreen(tester, const Size(400, 800));
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('a phone at the same width keeps the bottom bar', (tester) async {
    useScreen(tester, const Size(400, 800));
    await tester.pumpWidget(
      harness(fakeCore(), device: DeviceProfile.fallback),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
  });

  testWidgets('right from the rail enters the body, left from its first '
      'column returns to the rail', (tester) async {
    useScreen(tester, const Size(1280, 720));
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();

    // Tab reaches the rail first: it is a traversal group of its own.
    await press(tester, LogicalKeyboardKey.tab);
    expect(focusIn<NavigationRail>(), isTrue);
    expect(focusIn<BoardScreen>(), isFalse);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusIn<BoardScreen>(), isTrue);
    expect(focusIn<NavigationRail>(), isFalse);

    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusIn<NavigationRail>(), isTrue);
    expect(focusIn<BoardScreen>(), isFalse);
  });

  testWidgets('select on a rail destination switches the tab and right '
      'enters the new body', (tester) async {
    useScreen(tester, const Size(1280, 720));
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();

    await press(tester, LogicalKeyboardKey.tab);
    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(focusIn<NavigationRail>(), isTrue);
    await press(tester, LogicalKeyboardKey.select);
    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(find.byType(BoardScreen), findsNothing);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusIn<LibraryScreen>(), isTrue);
    expect(focusIn<NavigationRail>(), isFalse);
  });
}
