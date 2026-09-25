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
import 'package:xtremio/widgets/library_item_tile.dart';
import 'package:xtremio/widgets/poster_tile.dart';

import '../support/fake_core_client.dart';
import '../support/fake_downloads_client.dart';
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
    NavigatorObserver? observer,
  }) {
    final downloads = FakeDownloadsClient();
    addTearDown(downloads.dispose);
    final screen = LibraryScreen(
      driveOpener: opener ?? FakeDriveFileOpener(),
      driveSearch: search ?? (type, query) async => const [],
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
    testWidgets('is drawn beside the engine\'s types, and is not one of them', (
      tester,
    ) async {
      useNarrowScreen(tester);
      await tester.pumpWidget(harness(fakeCore()));
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

    testWidgets(
      'is drawn with nothing linked and with no engine state at all',
      (tester) async {
        // The other half of not vanishing. The row used to appear only once a
        // non-empty library had loaded, which is fine for controls that are the
        // engine's and is exactly how a local one disappears -- and a viewer
        // with an empty library is the most likely to be looking for the file
        // they just linked.
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
      },
    );

    testWidgets('selecting it dispatches nothing to the engine', (
      tester,
    ) async {
      useNarrowScreen(tester);
      final core = fakeCore();
      await tester.pumpWidget(harness(core));
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
      await tester.pumpWidget(harness(fakeCore()));
      await tester.pumpAndSettle();
      expect(selectedTypes(tester), {LibraryScreen.allTypesLabel});

      await tapRemote(tester);

      // Drawn as not-current, because the body is not the engine's list --
      // but nothing was sent to make that so.
      expect(selectedTypes(tester), isEmpty);

      // And turning it off shows the engine's flags again, still without a
      // dispatch: the engine held them the whole time.
      await tapRemote(tester);
      expect(remoteIsOn(tester), isFalse, reason: 'a second press is off');
      expect(selectedTypes(tester), {LibraryScreen.allTypesLabel});
    });

    testWidgets('a type dispatched while Remote is on turns Remote off and is '
        'dispatched verbatim', (tester) async {
      useNarrowScreen(tester);
      final core = fakeCore();
      final fixture = loadLibraryFixture();
      await tester.pumpWidget(harness(core));
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
      await tester.pumpWidget(harness(core));
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
      // the moment Remote is turned off.
      await tapRemote(tester);
      expect(selectedTypes(tester), {'Movies'});
    });
  });

  group('what Remote shows', () {
    testWidgets('nothing linked is a line saying so, not an empty grid', (
      tester,
    ) async {
      await tester.pumpWidget(harness(fakeCore(), drive: await account()));
      await tester.pumpAndSettle();
      await tapRemote(tester);

      expect(find.text(LinkedDriveFilesView.emptyTitle), findsOneWidget);
      expect(find.byType(LibraryItemTile), findsNothing);
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
      expect(find.text('S1E1 · 2008'), findsOneWidget);
      expect(
        find.text('Breaking.Bad.S01E01.1080p.mkv'),
        findsNothing,
        reason: 'the point of matching is not to show the filename',
      );
      expect(find.byType(PosterImage), findsOneWidget);
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
      expect(find.byIcon(LinkedDriveFilesView.unmatchedIcon), findsOneWidget);
      expect(
        find.byType(PosterImage),
        findsNothing,
        reason: 'no poster, rather than a poster of something else',
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

      await tapRemote(tester);
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
      expect(find.byType(LibraryItemTile), findsNothing);
      expect(find.text('ep6.avi'), findsOneWidget);

      await tapRemote(tester);
      expect(find.byType(LibraryItemTile), findsNWidgets(2));
      expect(find.text('ep6.avi'), findsNothing);
    });

    testWidgets('with no Drive scope above it at all, it is the same picture '
        'as nothing linked', (tester) async {
      // A build of the app that cannot link anything is not a failure to
      // report; it is a device with no linked files.
      await tester.pumpWidget(harness(fakeCore()));
      await tester.pumpAndSettle();
      await tapRemote(tester);

      expect(find.text(LinkedDriveFilesView.emptyTitle), findsOneWidget);
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

      await tester.tap(find.text('Arrival'));
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

      await tester.tap(find.text('Breaking Bad'));
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

      await tester.tap(find.text('ep6.avi'));
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

      await tester.tap(find.text('ep6.avi'));
      await tester.pumpAndSettle();

      expect(find.byType(PlayerScreen), findsNothing);
      expect(
        find.text(driveFailureMessage(DriveOpenFailure.unreachable)),
        findsOneWidget,
      );
    });
  });

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
      // The pass is started from the build as well as on mount, because
      // `didChangeDependencies` does not fire again for a file that arrives
      // while the list is already on screen.
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
      expect(find.byIcon(LinkedDriveFilesView.unmatchedIcon), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.textContaining('could not'), findsNothing);
    });
  });

  testWidgets('the link button is above the list that button fills', (
    tester,
  ) async {
    // The two halves of the same job on one screen: the button links a file
    // and Remote is where it turns up.
    await tester.pumpWidget(harness(fakeCore(), drive: await account()));
    await tester.pumpAndSettle();
    await tapRemote(tester);

    expect(find.byTooltip(RemoteFilesButton.label), findsOneWidget);
    expect(find.text(LinkedDriveFilesView.emptyTitle), findsOneWidget);
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
