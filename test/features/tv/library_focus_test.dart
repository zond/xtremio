import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/drive/remote_files.dart';
import 'package:xtremio/features/library/library_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/root_shell.dart';
import 'package:xtremio/widgets/remote_press.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_downloads_client.dart';
import '../../support/fake_drive_file_lister.dart';
import '../../support/fake_drive_file_opener.dart';
import '../../support/fake_secret_store.dart';
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

/// [theme] is for the one test that cares what the app's own theme draws
/// on a control; the rest get Material's default, which has no focus floor
/// and no ten-foot density in it.
/// The library, with a device that has something to show every control it
/// draws.
///
/// **Downloads are seeded by default**, because the Downloaded pill and the
/// button that cleans downloads up are only drawn when there is something on
/// disk -- a control with nothing to act on is not drawn, and a walk over a
/// row is a walk over the controls that are really there.
Widget harness(
  FakeCoreClient core, {
  Widget home = const LibraryScreen(),
  ThemeData? theme,
  DownloadsClient? downloads,
  DriveAccount? drive,
}) {
  final client = downloads ?? FakeDownloadsClient(registry: someDownloads());
  final app = DeviceScope(
    profile: tv,
    child: CoreScope(
      client: core,
      child: DownloadsScope(
        client: client,
        child: MaterialApp(theme: theme, home: home),
      ),
    ),
  );
  return drive == null ? app : DriveAccountScope(account: drive, child: app);
}

/// A registry with something in it: what makes the two download controls
/// exist at all.
DownloadsRegistry someDownloads() =>
    DownloadsRegistry.fromJson(loadDownloadsFixture());

/// A device with one linked file: what makes the Remote pill exist, the way
/// [someDownloads] makes the download controls exist.
Future<DriveAccount> driveWithOneFile(WidgetTester tester) async {
  final prefs = AppPrefs.inMemory();
  await prefs.load();
  final drive = DriveAccount(prefs: prefs, secrets: FakeSecretStore());
  await drive.load();
  addTearDown(() {
    drive.dispose();
    prefs.dispose();
  });
  await drive.link(
    refreshToken: 'a-refresh-token',
    files: [
      LinkedDriveFile(
        fileId: 'drive-file-1',
        name: 'ep6.avi',
        mimeType: 'video/x-matroska',
        linkedAt: DateTime.utc(2026, 9, 20),
      ),
    ],
  );
  return drive;
}

/// Every `Ctx` action dispatched so far, by its `action` name.
List<String> ctxActions(FakeCoreClient core) => [
  for (final action in core.dispatched)
    if (action.action['action'] == 'Ctx')
      (action.action['args'] as Map<String, dynamic>)['action'] as String,
];

/// Mounts the library and walks the D-pad down through the app bar and the
/// filter row into the grid, then left to its first tile.
///
/// Three downs and not two: the bar has a control in it (the link button),
/// and the filter controls are two rows above the grid -- the types with
/// the sort, then the app's own filters -- each a stop on the way in. The
/// walk itself is what
/// `'the D-pad walks the bar, the filter row, then the grid'` asserts
/// step by step; this only has to arrive.
Future<FakeCoreClient> mountOnFirstTile(WidgetTester tester) async {
  useScreen(tester, tvSize);
  final core = fakeCore();
  await tester.pumpWidget(harness(core));
  await tester.pumpAndSettle();
  for (var i = 0; i < 6 && focusedTileName(tester) == null; i++) {
    await press(tester, LogicalKeyboardKey.arrowDown);
  }
  for (var i = 0; i < 2 && focusedTileName(tester) != 'Lanterns'; i++) {
    await press(tester, LogicalKeyboardKey.arrowLeft);
  }
  expect(focusedTileName(tester), 'Lanterns');
  return core;
}

void main() {
  testWidgets('the D-pad walks the bar, the filter row, then the grid', (
    tester,
  ) async {
    // **Before this change the first press down landed on the type
    // segments**, because the anonymous library's app bar had nothing in it
    // to focus. The link button is in it now, which makes the bar a region
    // on the way in rather than a change of behaviour further down: every
    // assertion below the first two is what it was.
    useScreen(tester, tvSize);
    await tester.pumpWidget(
      harness(fakeCore(), drive: await driveWithOneFile(tester)),
    );
    await tester.pumpAndSettle();
    // Nothing takes focus by itself: the tab keeps focus on the rail until
    // the user steps in.
    expect(focusedLabel(tester), isNull);

    // Down from nowhere lands on the topmost control. The bar holds two now
    // -- the way to the downloads and the way to a remote service -- and
    // the leftmost of them is what "down from nowhere" reaches.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTooltip(), RemoteFilesButton.label);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedTooltip(), LibraryScreen.downloadsLabel);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTooltip(), RemoteFilesButton.label);

    // Down again is the first of the filter rows: the engine's types, one
    // segmented button, entered at its first segment -- the rung's doing,
    // since by distance alone the press would land two rows further down.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<SegmentedButton<int>>(), isTrue);
    expect(focusedLabel(tester), 'All');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), 'Movies');
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedLabel(tester), 'All');

    // The sort is the last stop of that row, beside the types where the
    // width allows -- a wide screen spends one line on the engine's half.
    // Each row below is its own stop on the way down: the app's own
    // filters -- Remote, then Downloaded to its right -- so a press down
    // never has to guess where a wrapped row broke.
    for (
      var i = 0;
      i < 4 && focusedLabel(tester) != 'Sort: Last watched';
      i++
    ) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(focusedLabel(tester), 'Sort: Last watched');
    expect(find.byType(DropdownMenu<int>), findsNothing);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(
      focusedLabel(tester),
      LibraryScreen.remoteLabel,
      reason: 'the filters row is entered at its first stop',
    );
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), 'Downloaded');
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedLabel(tester), LibraryScreen.remoteLabel);

    // Down enters the grid -- on whichever tile geometry puts under the
    // chip -- and left and right walk it; up is the filters row again, the
    // row directly above the grid, whichever of its chips geometry picks.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTileName(tester), isNotNull, reason: 'down enters the grid');
    for (var i = 0; i < 3 && focusedTileName(tester) != 'Lanterns'; i++) {
      await press(tester, LogicalKeyboardKey.arrowLeft);
    }
    expect(focusedTileName(tester), 'Lanterns');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTileName(tester), 'The Whisper Man');
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedTileName(tester), 'Lanterns');
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedTileName(tester), 'Lanterns', reason: 'first column');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedTileName(tester), isNull);
    expect(
      focusedLabel(tester),
      anyOf(LibraryScreen.remoteLabel, 'Downloaded'),
      reason: 'up out of the grid is the filters row, not a row past it',
    );
  });

  testWidgets('and up out of the filter rows is the link button, with the '
      'rows in between never stepped over', (tester) async {
    // The press this is about is the one the board needed two rungs of a
    // [TvLadder] for. Here the first filter row spans the width directly
    // under the bar, so it is genuinely the nearest thing in each direction
    // and geometry answers both presses -- which is a claim about the
    // drawing, and so has to be walked rather than reasoned about.
    useScreen(tester, tvSize);
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTooltip(), RemoteFilesButton.label);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(
      focusedTileName(tester),
      isNull,
      reason: 'down out of the bar landed in the grid, past the whole row',
    );
    expect(
      focusIn<SegmentedButton<int>>(),
      isTrue,
      reason: 'the first row under the bar is the types',
    );
    await press(tester, LogicalKeyboardKey.arrowUp);
    // Back into the bar, on whichever of its two buttons is nearest above
    // the chip that was left. Which one is geometry's answer and not this
    // test's business -- what it is about is that the row is not stepped
    // over in either direction.
    expect(
      focusedTooltip(),
      anyOf(RemoteFilesButton.label, LibraryScreen.downloadsLabel),
    );
  });

  testWidgets('the Downloaded chip is marked like every other chip', (
    tester,
  ) async {
    // It sits in the filter row beside chips that are wrapped, and was
    // left out of the wrapping. A chip takes the floor's fill and cannot
    // be given its outline, so the ring is the half that has to be put on
    // by hand.
    useScreen(tester, tvSize);
    await tester.pumpWidget(
      harness(
        fakeCore(),
        theme: XtremioApp.themeFor(isTv: true, emphasis: FocusEmphasis.bold),
      ),
    );
    await tester.pumpAndSettle();
    // Three downs: the bar, the types and the sort, and then the filters
    // row, which with nothing linked holds this chip alone.
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedLabel(tester), 'Downloaded');
    expect(focusMarks(), {FocusMark.ring, FocusMark.fill});
  });

  testWidgets('and so is the Remote pill, which is the local one', (
    tester,
  ) async {
    // A [FilterChip] rather than the [ChoiceChip]s beside it, so it is worth
    // proving separately that the floor and the ring both reach it: a pill
    // the remote can stand on with nothing drawn on it is unfindable from
    // three metres whichever widget it is built out of.
    useScreen(tester, tvSize);
    await tester.pumpWidget(
      harness(
        fakeCore(),
        drive: await driveWithOneFile(tester),
        theme: XtremioApp.themeFor(isTv: true, emphasis: FocusEmphasis.bold),
      ),
    );
    await tester.pumpAndSettle();
    // The bar, the types and the sort, and then the filters row, whose
    // first chip this is.
    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    for (
      var i = 0;
      i < 8 && focusedLabel(tester) != LibraryScreen.remoteLabel;
      i++
    ) {
      await press(tester, LogicalKeyboardKey.arrowLeft);
    }
    expect(focusedLabel(tester), LibraryScreen.remoteLabel);
    expect(focusMarks(), {FocusMark.ring, FocusMark.fill});
  });

  testWidgets('select on a segment dispatches its type', (tester) async {
    useScreen(tester, tvSize);
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();
    // Down twice for the bar and the types row, entered at its first
    // segment; right along it to Movies.
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<SegmentedButton<int>>(), isTrue);
    for (var i = 0; i < 6 && focusedLabel(tester) != 'Movies'; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(focusedLabel(tester), 'Movies');

    await press(tester, LogicalKeyboardKey.select);
    final request =
        core.dispatched.last.action['args']['args']['request']
            as Map<String, dynamic>;
    expect(request['type'], 'movie');
  });

  testWidgets('a remote reaches the Remote pill, selects it, and walks to a '
      'linked file', (tester) async {
    // The whole of the local option from a remote: the pill is a stop on the
    // row, select turns it on, and what it puts in the body is reachable
    // from there without anything in between being stepped over.
    useScreen(tester, tvSize);
    final prefs = AppPrefs.inMemory();
    await prefs.load();
    final drive = DriveAccount(prefs: prefs, secrets: FakeSecretStore());
    await drive.load();
    addTearDown(() {
      drive.dispose();
      prefs.dispose();
    });
    await drive.link(
      refreshToken: 'a-refresh-token',
      files: [
        LinkedDriveFile(
          fileId: 'drive-file-1',
          name: 'ep6.avi',
          mimeType: 'video/x-matroska',
          linkedAt: DateTime.utc(2026, 9, 20),
        ),
      ],
    );
    await tester.pumpWidget(
      DriveAccountScope(
        account: drive,
        child: harness(
          fakeCore(),
          home: LibraryScreen(
            driveOpener: FakeDriveFileOpener(),
            driveSearch: (type, query) async => const [],
            driveLister: FakeDriveFileLister(
              answers: [
                FakeDriveFileLister.listing({'drive-file-1': 'ep6.avi'}),
              ],
            ),
          ),
          theme: XtremioApp.themeFor(isTv: true, emphasis: FocusEmphasis.bold),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Down into the bar, down past the types and the sort onto the filters
    // row, then left along it to the pill.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTooltip(), RemoteFilesButton.label);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    for (
      var i = 0;
      i < 8 && focusedLabel(tester) != LibraryScreen.remoteLabel;
      i++
    ) {
      await press(tester, LogicalKeyboardKey.arrowLeft);
    }
    expect(focusedLabel(tester), LibraryScreen.remoteLabel);
    expect(focusMarks(), isNotEmpty);

    await press(tester, LogicalKeyboardKey.select);
    expect(find.text('ep6.avi'), findsOneWidget);

    // Selecting it keeps the remote where it is, on the pill, which now
    // carries the reload arrow: the control the note above the list tells
    // a viewer to press again is the one they are already standing on, so
    // a second select reloads and answers in a line, like every refusal.
    expect(focusedLabel(tester), LibraryScreen.remoteLabel);
    expect(
      find.descendant(
        of: find.widgetWithText(FilterChip, LibraryScreen.remoteLabel),
        matching: find.byIcon(LibraryScreen.reloadGlyph),
      ),
      findsOneWidget,
    );
    await press(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(
      find.text(
        driveReloadMessage(const DriveReloadDone(renamed: 0, removed: 0)),
      ),
      findsOneWidget,
      reason: 'a press from a remote answers in a line, like every refusal',
    );
    expect(
      find.text('ep6.avi'),
      findsOneWidget,
      reason: 'the second press did not turn the list off',
    );
    // And down from the pill straight into the list it put there, onto a
    // tile the remote can see it is standing on.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTileName(tester), 'ep6.avi');
    expect(
      focusMarks(),
      isNotEmpty,
      reason: 'a linked file the remote can land on with nothing drawn on it',
    );
    // Up comes back to the pill it belongs to, so the pill and its list
    // are not a one-way trip.
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedTileName(tester), isNull);
    expect(focusedLabel(tester), LibraryScreen.remoteLabel);
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
    // Which tile geometry lands on from the last filter row is its own
    // business; the second tile is the one this test is about.
    if (focusedTileName(tester) != 'The Whisper Man') {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
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
