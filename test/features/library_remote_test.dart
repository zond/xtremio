import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/drive/linked_files.dart';
import 'package:xtremio/features/drive/remote_files.dart';
import 'package:xtremio/features/library/library_screen.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/similar/similar_resolver.dart';
import 'package:xtremio/widgets/filter_controls.dart';
import 'package:xtremio/widgets/library_item_tile.dart';
import 'package:xtremio/widgets/tv_ladder.dart';
import 'package:xtremio/widgets/poster_tile.dart';

import '../support/fake_core_client.dart';
import '../support/fake_downloads_client.dart';
import '../support/fake_drive_file_lister.dart';
import '../support/fake_drive_pairing_service.dart';
import '../support/fake_drive_file_opener.dart';
import '../support/fake_playback_engine.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_secret_store.dart';
import '../support/fixtures.dart';

/// The **Remote** option on the library's filter row: an option of the app's
/// own, living beside options that are the engine's.
///
/// The thing under test is the seam. The type pills come out of
/// `library.selectable.types`, each carrying the request that selects it, and
/// pressing one dispatches that request and then redraws from the flags the
/// engine answers with. Remote is not one of them and must not behave as
/// though it were: it dispatches nothing, it leaves the engine's selection
/// exactly where it was, and it survives the field arriving again.
void main() {
  /// A linked Drive file, matched or not.
  /// One linked file, which is now what makes the Remote pill exist: a
  /// control with nothing to act on is not drawn.
  const linkedOne = [
    (id: 'drive-file-1', name: 'A Film 2019.mkv', match: null),
  ];

  Future<DriveAccount> account({
    List<({String id, String name, LinkedDriveMatch? match})> files = const [],
  }) async {
    final prefs = AppPrefs(client: FakePrefsClient());
    await prefs.load();
    final drive = DriveAccount(prefs: prefs, secrets: FakeSecretStore());
    await drive.load();
    addTearDown(() {
      drive.dispose();
      prefs.dispose();
    });
    for (final file in files) {
      await drive.link(
        refreshToken: 'a-refresh-token',
        files: [
          LinkedDriveFile(
            fileId: file.id,
            name: file.name,
            mimeType: 'video/x-matroska',
            linkedAt: DateTime.utc(2026, 9, 20),
            match: file.match,
          ),
        ],
      );
    }
    return drive;
  }

  const LinkedDriveMatch arrival = LinkedDriveMatch(
    cinemetaId: 'tt2543164',
    type: 'movie',
    name: 'Arrival',
    year: 2016,
  );
  const LinkedDriveMatch episode = LinkedDriveMatch(
    cinemetaId: 'tt0903747',
    type: 'series',
    name: 'Breaking Bad',
    year: 2008,
    season: 1,
    episode: 1,
  );

  FakeCoreClient fakeCore({Map<String, dynamic>? library}) => FakeCoreClient(
    state: {
      CoreField.library: library ?? loadLibraryFixture(),
      CoreField.ctx: loadCtxLoggedOutFixture(),
    },
  );

  /// The library with every scope the Remote option needs. [opener] is what
  /// stands in for the embedded server and [search] for Cinemeta: nothing
  /// here reaches either.
  Widget harness(
    FakeCoreClient core, {
    DriveAccount? drive,
    DriveFileOpener? opener,
    CatalogueSearch? search,
    DriveFileLister? lister,
    NavigatorObserver? observer,
    DownloadsRegistry? downloaded,
  }) {
    final downloads = FakeDownloadsClient(registry: downloaded);
    addTearDown(downloads.dispose);
    final screen = LibraryScreen(
      driveOpener: opener ?? FakeDriveFileOpener(),
      driveSearch: search ?? (type, query) async => const [],
      // Nothing in this file reaches the pairing service or Google; a test
      // that presses Reload says what Drive answered.
      driveLister: lister ?? FakeDriveFileLister(),
    );
    final app = CoreScope(
      client: core,
      child: DownloadsScope(
        client: downloads,
        // A fake engine, because pressing an unmatched row pushes a real
        // [PlayerScreen] and a real one builds libmpv.
        child: PlaybackScope(
          createEngine: FakePlaybackEngine.new,
          child: MaterialApp(home: screen, navigatorObservers: [?observer]),
        ),
      ),
    );
    return drive == null ? app : DriveAccountScope(account: drive, child: app);
  }

  /// Every `Load LibraryWithFilters` dispatched so far.
  List<CoreAction> loads(FakeCoreClient core) => [
    for (final action in core.dispatched)
      if (action.action['action'] == 'Load') action,
  ];

  Future<void> tapRemote(WidgetTester tester) async {
    await tester.tap(
      find.widgetWithText(FilterChip, LibraryScreen.remoteLabel),
    );
    await tester.pumpAndSettle();
  }

  bool remoteIsOn(WidgetTester tester) => tester
      .widget<FilterChip>(
        find.widgetWithText(FilterChip, LibraryScreen.remoteLabel),
      )
      .selected;

  /// A second press on the Remote pill: what reloads. Asserts the pill is
  /// on first, so a test that meant to reload and turned the pill on
  /// instead fails here and not somewhere downstream.
  Future<void> tapReload(WidgetTester tester) async {
    expect(remoteIsOn(tester), isTrue, reason: 'reload is the second press');
    await tapRemote(tester);
  }

  /// The way off Remote: any of the engine's pills. "All" is drawn as
  /// not-current while Remote is on, so a press on it fires in either
  /// layout (a chip when narrow, a segment when wide) and dispatches the
  /// engine's own request, which the fake core records and does nothing
  /// with -- so what is drawn afterwards is the flags the engine held.
  Future<void> leaveRemote(WidgetTester tester) async {
    final chip = find.widgetWithText(ChoiceChip, LibraryScreen.allTypesLabel);
    await tester.tap(
      chip.evaluate().isNotEmpty
          ? chip
          : find.text(LibraryScreen.allTypesLabel),
    );
    await tester.pumpAndSettle();
  }

  /// The reload arrow drawn on the Remote pill while it is on.
  Finder reloadGlyph() => find.descendant(
    of: find.widgetWithText(FilterChip, LibraryScreen.remoteLabel),
    matching: find.byIcon(LibraryScreen.reloadGlyph),
  );

  Set<String> selectedTypes(WidgetTester tester) => {
    for (final chip in tester.widgetList<ChoiceChip>(find.byType(ChoiceChip)))
      if (chip.selected) ((chip.label as Text).data ?? ''),
  };

  /// Phone width, so the engine's types are chips rather than one segmented
  /// button and each one's `selected` can be read off it.
  void useNarrowScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  group('the pill itself', () {
    testWidgets('the controls are two rows, in the order a viewer narrows: '
        'the types with the sort beside them, and the app\'s own filters '
        'under them', (tester) async {
      Future<void> mount(Size size) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          harness(
            fakeCore(),
            drive: await account(files: linkedOne),
            // Any download at all is what makes the Downloaded pill exist.
            downloaded: DownloadsRegistry.fromJson(loadDownloadsFixture()),
          ),
        );
        await tester.pumpAndSettle();
      }

      double top(Finder finder) => tester.getTopLeft(finder).dy;
      final sortMenu = find.byWidgetPredicate((w) => w is FilterMenu);
      final remoteChip = find.widgetWithText(
        FilterChip,
        LibraryScreen.remoteLabel,
      );
      final downloadedChip = find.widgetWithText(FilterChip, 'Downloaded');

      // Wide: the sort sits on the types' own row, and the filters under
      // both.
      await mount(const Size(1200, 900));
      final types = top(find.byType(SegmentedButton<int>));
      // Centred on the same line as the segments, whose control is a few
      // pixels taller than the menu button.
      expect(
        top(sortMenu),
        closeTo(types, 8),
        reason: 'the sort shares the wide row',
      );
      expect(top(remoteChip), greaterThan(types));
      expect(
        top(remoteChip),
        top(downloadedChip),
        reason: 'Remote and Downloaded share a row',
      );
      // Turning Remote on adds no row: the reload moved onto the pill.
      final rowsOff = find.byType(TvLadderRow).evaluate().length;
      await tester.tap(remoteChip);
      await tester.pumpAndSettle();
      expect(
        find.byType(TvLadderRow).evaluate().length,
        rowsOff,
        reason: 'no row comes and goes with the pill',
      );

      // Narrow: the same order, with the sort wrapped under the types
      // where the width forces it -- never above them, and never below
      // the filters.
      await tester.pumpWidget(const SizedBox());
      await mount(const Size(400, 900));
      final firstChip = top(find.byType(ChoiceChip).first);
      expect(top(sortMenu), greaterThanOrEqualTo(firstChip));
      expect(top(remoteChip), greaterThan(top(sortMenu)));
    });

    testWidgets('is drawn under the engine\'s types, and is not one of them', (
      tester,
    ) async {
      useNarrowScreen(tester);
      await tester.pumpWidget(
        harness(fakeCore(), drive: await account(files: linkedOne)),
      );
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(FilterChip, LibraryScreen.remoteLabel),
        findsOneWidget,
      );
      expect(
        find.byType(ChoiceChip),
        findsNWidgets(3),
        reason: "the engine's three types, and Remote is not a fourth",
      );
    });

    testWidgets('is drawn with a file linked and no engine state at all', (
      tester,
    ) async {
      // The other half of not vanishing. The row used to appear only once a
      // non-empty library had loaded, which is fine for controls that are the
      // engine's and is exactly how a local one disappears -- and a viewer
      // with an empty library is the most likely to be looking for the file
      // they just linked. What the pill now waits for is a linked *file*,
      // not a loaded library: the engine having nothing to say is not a
      // reason to hide a control that is not the engine's.
      useNarrowScreen(tester);
      await tester.pumpWidget(
        harness(
          FakeCoreClient(
            state: {
              CoreField.library: {
                'selected': null,
                'selectable': {'types': [], 'sorts': [], 'next_page': null},
                'catalog': <Object>[],
              },
              CoreField.ctx: loadCtxLoggedOutFixture(),
            },
          ),
          drive: await account(files: linkedOne),
        ),
      );
      // `pump` and not `pumpAndSettle`: an unloaded library draws a
      // spinner, which never settles -- and the row above it is the point.
      await tester.pump();

      expect(
        find.widgetWithText(FilterChip, LibraryScreen.remoteLabel),
        findsOneWidget,
      );
      expect(
        find.byType(ChoiceChip),
        findsNothing,
        reason: 'nothing to filter',
      );
    });

    testWidgets('and is not drawn at all with nothing linked', (tester) async {
      // A control with nothing to act on is not drawn. Pressing a Remote
      // pill on a device that has linked nothing shows an empty list and
      // takes a second press to escape -- so the cloud button in the bar,
      // which is always there, is the whole way in until there is something
      // to come back to.
      useNarrowScreen(tester);
      await tester.pumpWidget(harness(fakeCore(), drive: await account()));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(FilterChip, LibraryScreen.remoteLabel),
        findsNothing,
      );
      // And the engine's own controls are untouched by its absence.
      expect(find.byType(ChoiceChip), findsWidgets);
    });

    testWidgets('selecting it dispatches nothing to the engine', (
      tester,
    ) async {
      useNarrowScreen(tester);
      final core = fakeCore();
      await tester.pumpWidget(
        harness(core, drive: await account(files: linkedOne)),
      );
      await tester.pumpAndSettle();
      final before = core.dispatched.length;

      await tapRemote(tester);

      expect(remoteIsOn(tester), isTrue);
      expect(
        core.dispatched,
        hasLength(before),
        reason: 'the engine has never heard of Google Drive',
      );
    });

    testWidgets('and leaves the engine\'s own selection where it was', (
      tester,
    ) async {
      useNarrowScreen(tester);
      await tester.pumpWidget(
        harness(fakeCore(), drive: await account(files: linkedOne)),
      );
      await tester.pumpAndSettle();
      expect(selectedTypes(tester), {LibraryScreen.allTypesLabel});

      await tapRemote(tester);

      // Drawn as not-current, because the body is not the engine's list --
      // but nothing was sent to make that so.
      expect(selectedTypes(tester), isEmpty);

      // And turning it off -- by the engine's own pill, since a second
      // press on Remote reloads -- shows the engine's flags again: the
      // engine held them the whole time, and the fake does nothing with
      // the request the press dispatched.
      await leaveRemote(tester);
      expect(remoteIsOn(tester), isFalse, reason: "the engine's pill is off");
      expect(selectedTypes(tester), {LibraryScreen.allTypesLabel});
    });

    testWidgets('a type dispatched while Remote is on turns Remote off and is '
        'dispatched verbatim', (tester) async {
      useNarrowScreen(tester);
      final core = fakeCore();
      final fixture = loadLibraryFixture();
      await tester.pumpWidget(
        harness(core, drive: await account(files: linkedOne)),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Movies'));
      await tester.pumpAndSettle();

      expect(remoteIsOn(tester), isFalse);
      expect(
        loads(core).last.action['args']['args']['request'],
        (fixture['selectable']!
            as Map<String, dynamic>)['types']![1]['request'],
        reason: 'an engine control means "show me the engine\'s list"',
      );
    });

    testWidgets('and the core publishing the field again does not take it '
        'away or turn it off', (tester) async {
      // The failure this is for: an option kept in the engine's state
      // vanishes the moment the engine recomputes that state. This one is
      // not in the field, so a reload cannot touch it -- and it cannot
      // touch the engine's either.
      useNarrowScreen(tester);
      final core = fakeCore();
      await tester.pumpWidget(
        harness(core, drive: await account(files: linkedOne)),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);
      expect(remoteIsOn(tester), isTrue);

      // The engine reloads with a different type selected, as it would after
      // a sync.
      final fixture = loadLibraryFixture();
      final selectable = {
        ...fixture['selectable'] as Map<String, dynamic>,
        'types': [
          for (final (index, type)
              in ((fixture['selectable'] as Map<String, dynamic>)['types']
                      as List<dynamic>)
                  .indexed)
            {...type as Map<String, dynamic>, 'selected': index == 1},
        ],
      };
      core.setState(CoreField.library, {...fixture, 'selectable': selectable});
      await tester.pumpAndSettle();

      expect(remoteIsOn(tester), isTrue, reason: 'the flag is the screen\'s');
      expect(
        find.widgetWithText(FilterChip, LibraryScreen.remoteLabel),
        findsOneWidget,
      );
      // The engine's new selection is held, not lost, and is what is drawn
      // the moment Remote is turned off (the fake ignores the request the
      // press on "All" dispatched, so the flags it shows are the held ones).
      await leaveRemote(tester);
      expect(selectedTypes(tester), {'Movies'});
    });
  });

  group('what Remote shows', () {
    testWidgets('a list emptied under the viewer is a line saying so, not an '
        'empty grid', (tester) async {
      // The pill only exists while something is linked, so the empty list is
      // reached the one way it still can be: the files go away *while* it is
      // open. A reload that finds the grant revoked or the files deleted
      // does exactly that, and leaving the viewer looking at an empty grid
      // with no word about it is the case this line is for.
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(files: linkedOne),
          lister: FakeDriveFileLister(
            answers: [FakeDriveFileLister.listing(const {})],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);
      expect(find.text('A Film 2019.mkv'), findsOneWidget);

      await tapReload(tester);

      // The pill goes with the last file, and the filter goes with the pill:
      // a grid still narrowed to linked files, with no control left on
      // screen to widen it, is a page a viewer cannot get out of.
      expect(find.text('A Film 2019.mkv'), findsNothing);
      expect(
        find.widgetWithText(FilterChip, LibraryScreen.remoteLabel),
        findsNothing,
      );
      expect(
        find.text('Lanterns'),
        findsOneWidget,
        reason: 'the library is back, unfiltered',
      );
    });

    testWidgets('a matched file is drawn as its title, a poster and its '
        'episode', (tester) async {
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [
              (
                id: 'drive-file-1',
                name: 'Breaking.Bad.S01E01.1080p.mkv',
                match: episode,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);

      expect(find.text('Breaking Bad'), findsOneWidget);
      expect(
        find.text('Breaking.Bad.S01E01.1080p.mkv'),
        findsNothing,
        reason: 'the point of matching is not to show the filename',
      );
      expect(find.byType(PosterImage), findsOneWidget);
      // No episode under the poster: the card is the *show*, and a season
      // of linked episodes is one card, so naming one of them would be a
      // claim the card cannot make. The press still carries the episode.
      expect(find.text('S1E1 · 2008'), findsNothing);
      expect(find.byIcon(LinkedDriveFilesView.unmatchedIcon), findsNothing);
    });

    testWidgets('a file nothing matched is a generic video icon and the raw '
        'name', (tester) async {
      // The owner's decision, and the whole of it: no "pick the title"
      // screen, no guess, no blank tile.
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [(id: 'drive-file-1', name: 'ep6.avi', match: null)],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);

      expect(find.text('ep6.avi'), findsOneWidget);
      // A card of its own, drawn from the only thing known about it: its
      // name. It has no title, so it has nothing to be filtered *by* -- and
      // without a card of its own it would be linked, would have cost a
      // grant, and would be reachable from nowhere in the app.
      expect(find.byType(LibraryItemTile), findsOneWidget);
      // No poster on the card, rather than a poster of something else: the
      // tile draws its own fallback, which is what "nothing is known about
      // this" should look like.
      expect(
        tester
            .widget<LibraryItemTile>(find.byType(LibraryItemTile))
            .item
            .poster,
        isNull,
      );
    });

    testWidgets('and the note above the list says the name is what is '
        'matched', (tester) async {
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [(id: 'drive-file-1', name: 'ep6.avi', match: null)],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);

      expect(find.text(LinkedDriveFilesView.matchedByNameNote), findsOneWidget);
      for (final example in LinkedDriveFilesView.nameExamples) {
        expect(find.text(example), findsOneWidget);
      }
    });

    testWidgets('both kinds are listed together: it is what has been linked, '
        'not what could not be placed', (tester) async {
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [
              (id: 'drive-file-1', name: 'ep6.avi', match: null),
              (id: 'drive-file-2', name: 'Arrival.2016.mkv', match: arrival),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);

      expect(find.text('ep6.avi'), findsOneWidget);
      expect(find.text('Arrival'), findsOneWidget);
    });

    testWidgets('the sign-in hint goes with the engine\'s grid: it is about '
        'the library, not about this list', (tester) async {
      // "Sign in to sync" is a sentence about the engine's library, which is
      // not what is on screen while Remote is on -- and a linked Drive file
      // is not going to be synced to a Stremio account by signing in.
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [(id: 'drive-file-1', name: 'ep6.avi', match: null)],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Sign in to sync'), findsOneWidget);

      await tapRemote(tester);
      expect(find.textContaining('Sign in to sync'), findsNothing);

      await leaveRemote(tester);
      expect(find.textContaining('Sign in to sync'), findsOneWidget);
    });

    testWidgets('the engine\'s grid comes back when Remote is turned off', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [(id: 'drive-file-1', name: 'ep6.avi', match: null)],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LibraryItemTile), findsNWidgets(2));

      await tapRemote(tester);
      // Narrowed to what is linked: the engine's own two titles have no
      // linked file, so what is left is the one card the file itself is.
      expect(find.text('Lanterns'), findsNothing);
      expect(find.text('ep6.avi'), findsOneWidget);
      expect(find.byType(LibraryItemTile), findsOneWidget);

      await leaveRemote(tester);
      expect(find.byType(LibraryItemTile), findsNWidgets(2));
      expect(find.text('ep6.avi'), findsNothing);
    });

    testWidgets('with no Drive scope above it at all there is no pill, which '
        'is the same picture as nothing linked', (tester) async {
      // A build of the app that cannot link anything is not a failure to
      // report; it is a device with no linked files, and a device with no
      // linked files has no Remote pill.
      await tester.pumpWidget(harness(fakeCore()));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(FilterChip, LibraryScreen.remoteLabel),
        findsNothing,
      );
      expect(find.byType(LibraryItemTile), findsWidgets, reason: 'the engine');
    });
  });

  group('what a press on a row does', () {
    testWidgets('a matched film opens its details, the way a search result '
        'does', (tester) async {
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [
              (id: 'drive-file-1', name: 'Arrival.2016.mkv', match: arrival),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);

      await tester.tap(find.widgetWithText(LibraryItemTile, 'Arrival'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      final details = tester.widget<MetaDetailsScreen>(
        find.byType(MetaDetailsScreen),
      );
      expect(details.type, 'movie');
      expect(details.id, 'tt2543164');
      expect(details.videoId, isNull, reason: "a film's video is the film");
      expect(find.byType(PlayerScreen), findsNothing);
    });

    testWidgets('a matched episode opens its details at that episode', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [
              (
                id: 'drive-file-1',
                name: 'Breaking.Bad.S01E01.mkv',
                match: episode,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);

      await tester.tap(find.widgetWithText(LibraryItemTile, 'Breaking Bad'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      final details = tester.widget<MetaDetailsScreen>(
        find.byType(MetaDetailsScreen),
      );
      expect(details.type, 'series');
      expect(details.id, 'tt0903747');
      expect(details.videoId, 'tt0903747:1:1');
    });

    testWidgets('an unmatched file plays, because there is no page to send '
        'anybody to', (tester) async {
      // The route and not the screen: [PlayerScreen] builds a real libmpv
      // player, which a widget test has no business starting. What is under
      // test is where the press went and what was handed to the server.
      final opener = FakeDriveFileOpener();
      final pushed = _Pushed();
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [(id: 'drive-file-1', name: 'ep6.avi', match: null)],
          ),
          opener: opener,
          observer: pushed,
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);
      pushed.names.clear();

      await tester.tap(find.widgetWithText(LibraryItemTile, 'ep6.avi'));
      await tester.pump();

      expect(opener.asked.single.fileId, 'drive-file-1');
      expect(
        opener.asked.single.refreshToken,
        'a-refresh-token',
        reason: 'the account holds the credential, and hands it to the server',
      );
      expect(pushed.names, [PlayerScreen.routeName]);
      expect(find.byType(MetaDetailsScreen), findsNothing);
    });

    testWidgets('a refusal is a line to read, not a screen', (tester) async {
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [(id: 'drive-file-1', name: 'ep6.avi', match: null)],
          ),
          opener: FakeDriveFileOpener(
            answers: const [DriveFileRefused(DriveOpenFailure.unreachable)],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);

      await tester.tap(find.widgetWithText(LibraryItemTile, 'ep6.avi'));
      await tester.pumpAndSettle();

      expect(find.byType(PlayerScreen), findsNothing);
      expect(
        find.text(driveFailureMessage(DriveOpenFailure.unreachable)),
        findsOneWidget,
      );
    });
  });

  /// The pass itself belongs to `LibraryScreen` and is driven from there
  /// whether this pill is ever pressed -- `library_merge_test.dart` is what
  /// holds that. What these say is the half this list owns: the rows are
  /// drawn without waiting for a catalogue, and each one is redrawn when its
  /// match is written down.
  group('the search behind the list', () {
    testWidgets('runs without the list waiting for it, and writes the match '
        'down where the row can read it', (tester) async {
      final asked = <String>[];
      final drive = await account(
        files: [
          (id: 'drive-file-1', name: 'Arrival.2016.1080p.mkv', match: null),
        ],
      );
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: drive,
          search: (type, query) async {
            asked.add('$type/$query');
            return [
              {'id': 'tt2543164', 'name': 'Arrival', 'releaseInfo': '2016'},
            ];
          },
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);

      // Drawn before the answer, as the raw name, and then redrawn as the
      // title once the account has written the match down.
      await tester.pumpAndSettle();
      expect(asked, ['movie/Arrival']);
      expect(drive.files.entries.single.match?.cinemetaId, 'tt2543164');
      expect(find.text('Arrival'), findsOneWidget);
    });

    testWidgets('and is not run again for a file that already matched', (
      tester,
    ) async {
      final asked = <String>[];
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [
              (id: 'drive-file-1', name: 'Arrival.2016.mkv', match: arrival),
            ],
          ),
          search: (type, query) async {
            asked.add('$type/$query');
            return const [];
          },
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);
      await tapRemote(tester);
      await tapRemote(tester);

      expect(asked, isEmpty);
    });

    testWidgets('and a file linked while the list is open is matched too', (
      tester,
    ) async {
      // The account notifies when the file is linked, which brings the
      // screen's `didChangeDependencies` round again and the pass with it --
      // so a file that arrives while this list is already open is matched
      // and its row redrawn without anything being pressed.
      final asked = <String>[];
      final drive = await account(
        files: [(id: 'drive-file-1', name: 'ep6.avi', match: null)],
      );
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: drive,
          search: (type, query) async {
            asked.add('$type/$query');
            return const [];
          },
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);
      await tester.pumpAndSettle();
      expect(asked, ['movie/ep6']);

      await drive.link(
        refreshToken: 'a-refresh-token',
        files: [
          LinkedDriveFile(
            fileId: 'drive-file-2',
            name: 'Arrival.2016.mkv',
            mimeType: 'video/x-matroska',
            linkedAt: DateTime.utc(2026, 9, 21),
          ),
        ],
      );
      await tester.pumpAndSettle();

      expect(asked, ['movie/ep6', 'movie/Arrival']);
    });

    testWidgets('a search that fails leaves the row as the raw name and says '
        'nothing about it', (tester) async {
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [
              (id: 'drive-file-1', name: 'Arrival.2016.mkv', match: null),
            ],
          ),
          search: (type, query) async => throw StateError('no network'),
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);
      await tester.pumpAndSettle();

      expect(find.text('Arrival.2016.mkv'), findsOneWidget);
      // Still just the file, drawn as itself: a search that failed leaves a
      // card with the raw name and no poster, which is the same picture as a
      // file nothing could match.
      expect(
        tester
            .widget<LibraryItemTile>(find.byType(LibraryItemTile))
            .item
            .poster,
        isNull,
      );
      expect(find.byType(SnackBar), findsNothing);
      expect(find.textContaining('could not'), findsNothing);
    });
  });

  group('Reload', () {
    testWidgets('is the Remote pill\'s second press: the glyph turns to the '
        'reload arrow while it is on, and pressing it then reloads rather '
        'than turning it off', (tester) async {
      useNarrowScreen(tester);
      final lister = FakeDriveFileLister(
        answers: [
          FakeDriveFileLister.listing({'drive-file-1': 'ep6.avi'}),
        ],
      );
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [(id: 'drive-file-1', name: 'ep6.avi', match: null)],
          ),
          lister: lister,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        reloadGlyph(),
        findsNothing,
        reason: 'a reload beside the engine\'s types has no subject',
      );
      expect(lister.asked, isEmpty);

      await tapRemote(tester);
      expect(remoteIsOn(tester), isTrue);
      expect(reloadGlyph(), findsOneWidget);
      expect(lister.asked, isEmpty, reason: 'the first press only shows');

      await tapRemote(tester);
      expect(remoteIsOn(tester), isTrue, reason: 'the pill does not let go');
      expect(reloadGlyph(), findsOneWidget);
      expect(lister.asked, hasLength(1), reason: 'the second press reloads');

      // Off is any other pill, and the glyph goes back with it.
      await tester.tap(find.widgetWithText(ChoiceChip, 'Movies'));
      await tester.pumpAndSettle();
      expect(remoteIsOn(tester), isFalse);
      expect(reloadGlyph(), findsNothing);
    });

    testWidgets('the note above the list names it, and the two are on screen '
        'together', (tester) async {
      // The note tells a viewer to press this. Two constants held against
      // each other, and then both found on the one screen: either half
      // alone would let the sentence go on naming a control that is gone.
      expect(
        LinkedDriveFilesView.matchedByNameNote,
        contains('press ${LibraryScreen.remoteLabel} again'),
      );
      useNarrowScreen(tester);
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [(id: 'drive-file-1', name: 'ep6.avi', match: null)],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);

      expect(find.text(LinkedDriveFilesView.matchedByNameNote), findsOneWidget);
      expect(reloadGlyph(), findsOneWidget);
    });

    testWidgets('a renamed file is redrawn under its new name, and matched '
        'again from it', (tester) async {
      // The whole promise of the note, end to end: rename in Drive, press
      // Reload, and the row that said `ep6.avi` is the episode it is.
      final asked = <String>[];
      final drive = await account(
        files: [(id: 'drive-file-1', name: 'ep6.avi', match: null)],
      );
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: drive,
          lister: FakeDriveFileLister(
            answers: [
              FakeDriveFileLister.listing({
                'drive-file-1': 'Breaking.Bad.S01E01.mkv',
              }),
            ],
          ),
          search: (type, query) async {
            asked.add('$type/$query');
            return const [
              {
                'id': 'tt0903747',
                'name': 'Breaking Bad',
                'type': 'series',
                'releaseInfo': '2008',
              },
            ];
          },
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);
      await tester.pumpAndSettle();
      expect(asked, ['movie/ep6']);

      await tapReload(tester);

      expect(find.text('Breaking Bad'), findsOneWidget);
      expect(find.text('ep6.avi'), findsNothing);
      expect(asked, ['movie/ep6', 'series/Breaking Bad']);
      expect(drive.files.entries.single.match?.videoId, 'tt0903747:1:1');
    });

    testWidgets('a file Drive no longer shares leaves the list, and the line '
        'says how many', (tester) async {
      final drive = await account(
        files: [
          (id: 'drive-file-1', name: 'ep6.avi', match: null),
          (id: 'drive-file-2', name: 'Arrival.2016.mkv', match: arrival),
        ],
      );
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: drive,
          lister: FakeDriveFileLister(
            answers: [
              FakeDriveFileLister.listing({'drive-file-2': 'Arrival.2016.mkv'}),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);

      await tapReload(tester);

      expect(find.text('ep6.avi'), findsNothing);
      expect(find.text('Arrival'), findsOneWidget);
      expect(
        find.text(
          driveReloadMessage(const DriveReloadDone(renamed: 0, removed: 1)),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a reload that found nothing to do says so out loud', (
      tester,
    ) async {
      // A button that answers with silence is a button pressed again.
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [(id: 'drive-file-1', name: 'ep6.avi', match: null)],
          ),
          lister: FakeDriveFileLister(
            answers: [
              FakeDriveFileLister.listing({'drive-file-1': 'ep6.avi'}),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);

      await tapReload(tester);

      expect(
        find.text(
          driveReloadMessage(const DriveReloadDone(renamed: 0, removed: 0)),
        ),
        findsOneWidget,
      );
      expect(find.text('ep6.avi'), findsOneWidget);
    });

    testWidgets('a listing that did not arrive is one line and no row moves', (
      tester,
    ) async {
      final drive = await account(
        files: [
          (id: 'drive-file-1', name: 'ep6.avi', match: null),
          (id: 'drive-file-2', name: 'Arrival.2016.mkv', match: arrival),
        ],
      );
      final before = drive.files;
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: drive,
          lister: FakeDriveFileLister(
            answers: const [
              DriveListingFailed(DriveListingFailure.unreachable),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);

      await tapReload(tester);

      expect(drive.files, before, reason: 'a failure is not a shorter list');
      expect(find.text('ep6.avi'), findsOneWidget);
      expect(find.text('Arrival'), findsOneWidget);
      expect(
        find.text(
          driveReloadMessage(
            const DriveReloadRefused(DriveListingFailure.unreachable),
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('it is asked with the account\'s own credential', (
      tester,
    ) async {
      final lister = FakeDriveFileLister(
        answers: [
          FakeDriveFileLister.listing({'drive-file-1': 'ep6.avi'}),
        ],
      );
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [(id: 'drive-file-1', name: 'ep6.avi', match: null)],
          ),
          lister: lister,
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);

      await tapReload(tester);

      expect(lister.asked, ['a-refresh-token']);
    });

    testWidgets('and it asks the catalogue again about a file that matched '
        'nothing, even with its name unchanged', (tester) async {
      // The other half of "re-match what changed, or what never matched".
      // A rename re-matches because the rename dropped the match; this one
      // would otherwise be remembered as hopeless for the life of the run.
      final asked = <String>[];
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [(id: 'drive-file-1', name: 'ep6.avi', match: null)],
          ),
          lister: FakeDriveFileLister(
            answers: [
              FakeDriveFileLister.listing({'drive-file-1': 'ep6.avi'}),
            ],
          ),
          search: (type, query) async {
            asked.add('$type/$query');
            return const [];
          },
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);
      await tester.pumpAndSettle();
      expect(asked, ['movie/ep6']);

      await tapReload(tester);

      expect(asked, ['movie/ep6', 'movie/ep6']);
    });

    testWidgets('a refused listing does not send the matching round again', (
      tester,
    ) async {
      // Nothing changed, so there is nothing new to ask about -- and a
      // press that failed should not spend a search on every row.
      final asked = <String>[];
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [(id: 'drive-file-1', name: 'ep6.avi', match: null)],
          ),
          lister: FakeDriveFileLister(
            answers: const [
              DriveListingFailed(DriveListingFailure.unreachable),
            ],
          ),
          search: (type, query) async {
            asked.add('$type/$query');
            return const [];
          },
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);
      await tester.pumpAndSettle();
      expect(asked, ['movie/ep6']);

      await tapReload(tester);

      expect(asked, ['movie/ep6']);
    });

    testWidgets('a second press while the first is in flight is dropped', (
      tester,
    ) async {
      // The service allows sixty refreshes an hour per credential, and a
      // chip on a television gets pressed twice by anybody who is not sure
      // it registered. The answer to that is the sentence at the end, not
      // a second listing.
      final lister = FakeDriveFileLister(
        answers: [
          FakeDriveFileLister.listing({'drive-file-1': 'ep6.avi'}),
        ],
      )..gate = Completer<void>();
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [(id: 'drive-file-1', name: 'ep6.avi', match: null)],
          ),
          lister: lister,
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);

      final remoteChip = find.widgetWithText(
        FilterChip,
        LibraryScreen.remoteLabel,
      );
      await tester.tap(remoteChip);
      await tester.pump();
      await tester.tap(remoteChip);
      await tester.pump();
      expect(lister.asked, hasLength(1));

      lister.gate!.complete();
      await tester.pumpAndSettle();
      expect(lister.asked, hasLength(1));
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('with no Drive scope above it at all there is nothing to '
        'press: no pill, and so nothing to reload with', (tester) async {
      await tester.pumpWidget(harness(fakeCore()));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(FilterChip, LibraryScreen.remoteLabel),
        findsNothing,
      );
      expect(reloadGlyph(), findsNothing);
    });

    testWidgets('and a linked device whose grant is gone says so in one line, '
        'not a crash', (tester) async {
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(files: linkedOne),
          lister: FakeDriveFileLister(
            answers: [const DriveListingFailed(DriveListingFailure.notLinked)],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapRemote(tester);

      await tapReload(tester);

      expect(
        find.text(
          driveReloadMessage(
            const DriveReloadRefused(DriveListingFailure.notLinked),
          ),
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('a pairing the service still holds is collected on the next '
      'library, without anybody asking', (tester) async {
    // What survives the app being killed. The id of a pairing that reached
    // the service and was never taken is written down; the next library asks
    // for it. Three pairings were lost in one afternoon for want of this --
    // each a Google sign-in, a consent and a list of files, gone with no
    // error anywhere because nothing had failed.
    final service = FakeDrivePairingService(
      answers: [
        DrivePairingCollected(
          refreshToken: 'a-refresh-token',
          files: [
            (
              fileId: 'drive-file-9',
              name: 'Left Behind 2019.mkv',
              mimeType: 'video/x-matroska',
            ),
          ],
        ),
      ],
    );
    final prefs = AppPrefs(client: FakePrefsClient());
    await prefs.load();
    await prefs.setDrivePendingSession('a-session-nobody-collected');
    final drive = DriveAccount(
      prefs: prefs,
      secrets: FakeSecretStore(),
      pairingService: service,
    );
    await drive.load();
    addTearDown(() {
      drive.dispose();
      prefs.dispose();
    });
    expect(drive.files.entries, isEmpty);

    await tester.pumpWidget(harness(fakeCore(), drive: drive));
    await tester.pumpAndSettle();

    expect(service.collects, ['a-session-nobody-collected']);
    expect(drive.files.entries.single.name, 'Left Behind 2019.mkv');
    expect(
      prefs.drivePendingSession,
      isNull,
      reason: 'and it stops being remembered once it is in',
    );
  });

  testWidgets('a pairing left behind is collected when the job that left it '
      'wakes the library, and is not asked for for ever', (tester) async {
    // The gap that made the recovery useless: the id was written to the
    // preferences and the job told its own listeners, and neither of those
    // is what the library depends on. Coming back from the pairing screen
    // changed nothing the library was watching, so it never looked, and a
    // pairing with seventeen files sat on the service until it expired.
    //
    // And bounded, because the waking is circular by construction: a collect
    // that fails wakes the library, which asks again.
    var collects = 0;
    final service = FakeDrivePairingService(
      answers: [const DrivePairingUnreachable()],
    )..onCollect = () => collects++;
    final prefs = AppPrefs(client: FakePrefsClient());
    await prefs.load();
    await prefs.setDrivePendingSession('left-behind');
    final drive = DriveAccount(
      prefs: prefs,
      secrets: FakeSecretStore(),
      pairingService: service,
    );
    await drive.load();
    addTearDown(() {
      drive.dispose();
      prefs.dispose();
    });

    await tester.pumpWidget(harness(fakeCore(), drive: drive));
    await tester.pumpAndSettle();

    expect(
      collects,
      DrivePairingJob.maxTries,
      reason: 'it kept trying, and then stopped',
    );
    expect(
      prefs.drivePendingSession,
      'left-behind',
      reason: 'and it is still written down, for the next start',
    );
  });

  testWidgets('the link button is above the list that button fills', (
    tester,
  ) async {
    // The two halves of the same job on one screen: the button links a file
    // and Remote is where it turns up. The button is in the bar whether or
    // not anything is linked -- it is the only way to link a first file, so
    // it cannot be the thing that waits for one.
    await tester.pumpWidget(harness(fakeCore(), drive: await account()));
    await tester.pumpAndSettle();
    expect(find.byTooltip(RemoteFilesButton.label), findsOneWidget);
    expect(
      find.widgetWithText(FilterChip, LibraryScreen.remoteLabel),
      findsNothing,
      reason: 'nothing linked yet',
    );

    await tester.pumpWidget(
      harness(fakeCore(), drive: await account(files: linkedOne)),
    );
    await tester.pumpAndSettle();
    await tapRemote(tester);

    expect(find.byTooltip(RemoteFilesButton.label), findsOneWidget);
    expect(find.text('A Film 2019.mkv'), findsOneWidget);
  });
}

/// The names of the routes pushed, in order.
class _Pushed extends NavigatorObserver {
  final List<String?> names = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previous) {
    names.add(route.settings.name);
  }
}
