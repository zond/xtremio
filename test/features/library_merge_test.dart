import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/drive/linked_files.dart';
import 'package:xtremio/features/library/library_screen.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/similar/similar_resolver.dart';
import 'package:xtremio/widgets/library_item_tile.dart';
import 'package:xtremio/widgets/poster_tile.dart';

import '../support/fake_core_client.dart';
import '../support/fake_downloads_client.dart';
import '../support/fake_drive_file_lister.dart';
import '../support/fake_drive_file_opener.dart';
import '../support/fake_playback_engine.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_secret_store.dart';
import '../support/fixtures.dart';

/// A matched linked Drive file under the library's **ordinary** options.
///
/// The thing under test is a merge of the *list* and of nothing else. The
/// engine hands over a page of cards; each matched linked file asks whether
/// the card it belongs to is among them, and only the missing ones are drawn
/// after them. So what has to hold here is: the unit is the card and not the
/// file, the engine is never written to, no pill is invented, and the two
/// "nothing here" pages know that the body is no longer the engine's catalog
/// alone.
///
/// `library_remote_test.dart` is the other half: the **Remote** option, which
/// lists every linked file, matched and unmatched, and is unchanged by any of
/// this.
void main() {
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

  /// The two titles the recorded fixture holds: a series and a film.
  const String lanterns = 'tt26545992';
  const String whisperMan = 'tt11561116';

  /// The engine's field as it would be with [type] selected and only [ids]
  /// left in the catalog.
  ///
  /// Built out of the recorded fixture rather than typed here, so the shape
  /// of an item is the engine's own and the merged card is compared against
  /// a real one.
  Map<String, dynamic> library({
    String? type,
    Set<String> ids = const {lanterns, whisperMan},
  }) {
    final fixture = loadLibraryFixture();
    final selectable = fixture['selectable'] as Map<String, dynamic>;
    return {
      ...fixture,
      'catalog': [
        for (final item in fixture['catalog'] as List<dynamic>)
          if (ids.contains((item as Map<String, dynamic>)['_id'])) item,
      ],
      'selected': {
        'request': {'type': type, 'sort': LibrarySort.lastWatched, 'page': 1},
      },
      'selectable': {
        ...selectable,
        'types': [
          for (final option in selectable['types'] as List<dynamic>)
            {
              ...option as Map<String, dynamic>,
              'selected': option['type'] == type,
            },
        ],
      },
    };
  }

  /// A library the engine has nothing in at all: it recomputes the types
  /// from what is left, so there are none of those either.
  Map<String, dynamic> emptyLibrary() => {
    'selected': {
      'request': {'type': null, 'sort': LibrarySort.lastWatched, 'page': 1},
    },
    'selectable': {'types': [], 'sorts': [], 'next_page': null},
    'catalog': <Object>[],
  };

  FakeCoreClient fakeCore({
    Map<String, dynamic>? library,
    Map<String, dynamic>? ctx,
  }) => FakeCoreClient(
    state: {
      CoreField.library: library ?? loadLibraryFixture(),
      CoreField.ctx: ctx ?? loadCtxLoggedOutFixture(),
    },
  );

  Widget harness(
    FakeCoreClient core, {
    DriveAccount? drive,
    CatalogueSearch? search,
    DownloadsRegistry? downloaded,
  }) {
    final downloads = FakeDownloadsClient(registry: downloaded);
    addTearDown(downloads.dispose);
    final screen = LibraryScreen(
      driveOpener: FakeDriveFileOpener(),
      // Nothing here reaches Cinemeta: every file that is meant to have a
      // match is linked with one.
      driveSearch: search ?? (type, query) async => const [],
      driveLister: FakeDriveFileLister(),
    );
    final app = CoreScope(
      client: core,
      child: DownloadsScope(
        client: downloads,
        child: PlaybackScope(
          createEngine: FakePlaybackEngine.new,
          child: MaterialApp(home: screen),
        ),
      ),
    );
    return drive == null ? app : DriveAccountScope(account: drive, child: app);
  }

  /// The names on the grid's cards, in the order the grid holds them.
  List<String> cards(WidgetTester tester) => [
    for (final tile in tester.widgetList<LibraryItemTile>(
      find.byType(LibraryItemTile),
    ))
      tile.item.name,
  ];

  Future<void> tapRemote(WidgetTester tester) async {
    await tester.tap(
      find.widgetWithText(FilterChip, LibraryScreen.remoteLabel),
    );
    await tester.pumpAndSettle();
  }

  /// The downloads fixture pointed at a title the library fixture holds.
  DownloadsRegistry downloadOf(String metaId) {
    final json = loadDownloadsFixture();
    final items = Map<String, dynamic>.from(json['items'] as Map);
    final key = items.keys.first;
    final entry = Map<String, dynamic>.from(items[key] as Map)
      ..['metaId'] = metaId;
    return DownloadsRegistry.fromJson({
      'version': json['version'],
      'items': {key: entry},
    });
  }

  group('a matched file the library has no card for', () {
    testWidgets('is a card after the engine\'s own, on All', (tester) async {
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

      expect(cards(tester), ['Lanterns', 'The Whisper Man', 'Arrival']);
    });

    testWidgets('is drawn as a library card and not as a Remote row', (
      tester,
    ) async {
      // Same widget as its neighbours, so it cannot drift from them: the
      // poster comes from the id, and nothing about the *file* is on it.
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

      final tile = tester.widget<LibraryItemTile>(
        find.widgetWithText(LibraryItemTile, 'Arrival'),
      );
      expect(
        tile.item.poster,
        'https://images.metahub.space/poster/small/tt2543164/img',
      );
      expect(find.byType(PosterImage), findsNWidgets(3));
      expect(
        find.byIcon(LinkedDriveFilesView.unmatchedIcon),
        findsNothing,
        reason: 'a matched file has a poster, so it is drawn with one',
      );
      expect(
        find.text('Arrival.2016.mkv'),
        findsNothing,
        reason: 'the card is the title, not the file',
      );
    });

    testWidgets('appears on its own type and on no other', (tester) async {
      Future<void> show(String? type) async {
        await tester.pumpWidget(
          harness(
            fakeCore(library: library(type: type)),
            drive: await account(
              files: [
                (id: 'drive-file-1', name: 'Arrival.2016.mkv', match: arrival),
                (
                  id: 'drive-file-2',
                  name: 'Breaking.Bad.S01E01.mkv',
                  match: episode,
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show(null);
      expect(cards(tester), contains('Arrival'));
      expect(cards(tester), contains('Breaking Bad'));

      await show('movie');
      expect(cards(tester), contains('Arrival'));
      expect(cards(tester), isNot(contains('Breaking Bad')));

      await show('series');
      expect(cards(tester), contains('Breaking Bad'));
      expect(cards(tester), isNot(contains('Arrival')));
    });

    testWidgets('and two files of one title are one card, not two', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [
              (id: 'drive-file-1', name: 'Arrival.2016.mkv', match: arrival),
              (
                id: 'drive-file-2',
                name: 'Arrival.2016.720p.mkv',
                match: arrival,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(LibraryItemTile, 'Arrival'), findsOneWidget);
    });

    testWidgets('a file nothing matched is its own card, after the titles: a '
        'file in Drive is in the library, title or not', (tester) async {
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [(id: 'drive-file-1', name: 'ep6.avi', match: null)],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(cards(tester), ['Lanterns', 'The Whisper Man', 'ep6.avi']);
    });
  });

  group('the unit is the card and not the file', () {
    testWidgets('an episode of a series the library already holds adds '
        'nothing', (tester) async {
      // The fixture's series is Lanterns; three of its episodes linked must
      // leave the grid exactly as it was, because the card they belong to is
      // the show and the show is there.
      const lantern = LinkedDriveMatch(
        cinemetaId: lanterns,
        type: 'series',
        name: 'Lanterns',
        season: 1,
        episode: 1,
      );
      await tester.pumpWidget(harness(fakeCore()));
      await tester.pumpAndSettle();
      final before = cards(tester);

      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [
              (id: 'drive-file-1', name: 'Lanterns.S01E01.mkv', match: lantern),
              (
                id: 'drive-file-2',
                name: 'Lanterns.S01E02.mkv',
                match: LinkedDriveMatch(
                  cinemetaId: lanterns,
                  type: 'series',
                  name: 'Lanterns',
                  season: 1,
                  episode: 2,
                ),
              ),
              (
                id: 'drive-file-3',
                name: 'Lanterns.S01E03.mkv',
                match: LinkedDriveMatch(
                  cinemetaId: lanterns,
                  type: 'series',
                  name: 'Lanterns',
                  season: 1,
                  episode: 3,
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(cards(tester), before);
    });

    testWidgets('and the same episode with the show absent is one card, for '
        'the show', (tester) async {
      // The other side of the same rule: the card is added because the show
      // is missing, and it is the show's card -- no episode under the
      // poster, because three of them would be one card.
      await tester.pumpWidget(
        harness(
          fakeCore(library: library(ids: const {whisperMan})),
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

      expect(cards(tester), ['The Whisper Man', 'Breaking Bad']);
      expect(find.text('S1E1'), findsNothing);
    });
  });

  group('nothing reaches the engine', () {
    testWidgets('no action is dispatched for a merged card', (tester) async {
      final core = fakeCore();
      await tester.pumpWidget(
        harness(
          core,
          drive: await account(
            files: [
              (id: 'drive-file-1', name: 'Arrival.2016.mkv', match: arrival),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(LibraryItemTile, 'Arrival'), findsOneWidget);

      expect(
        [for (final action in core.dispatched) action.action['action']],
        everyElement('Load'),
        reason: 'a write would sync a title to a Stremio account',
      );
    });

    testWidgets('and no pill is invented for it', (tester) async {
      // The trap this arrangement exists to avoid: a type option of the
      // app's own is a second notion of which one is current, and two
      // notions is two pills drawn as current the first time they disagree.
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
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

      expect(
        find.byType(ChoiceChip),
        findsNWidgets(3),
        reason: "the engine's three types, and the merge adds none",
      );
    });

    testWidgets('a merged card has no long-press menu, because every action '
        'in that sheet is about a library item', (tester) async {
      // Asserted on the tile rather than by holding it: every action in the
      // sheet is a `Ctx` action naming a library item id, and this title is
      // not one -- "remove from library" on a title the library does not
      // hold is an offer that cannot be kept.
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

      expect(
        tester
            .widget<LibraryItemTile>(
              find.widgetWithText(LibraryItemTile, 'Arrival'),
            )
            .onLongPress,
        isNull,
      );
      expect(
        tester
            .widget<LibraryItemTile>(
              find.widgetWithText(LibraryItemTile, 'Lanterns'),
            )
            .onLongPress,
        isNotNull,
        reason: "the engine's own cards still have theirs",
      );
    });
  });

  testWidgets('pressing a merged card is the press the Remote list makes', (
    tester,
  ) async {
    // Same route, same arguments, no flag -- and the episode, because that
    // is what the file holds even though the card is the show.
    await tester.pumpWidget(
      harness(
        fakeCore(library: library(ids: const {whisperMan})),
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

  group('the pages that say there is nothing here', () {
    testWidgets('an empty library with a linked film shows the film, not the '
        'empty page and not the sign-in hint', (tester) async {
      // The case somebody is most likely hunting in: they linked a film a
      // moment ago and their library is otherwise empty.
      await tester.pumpWidget(
        harness(
          fakeCore(library: emptyLibrary()),
          drive: await account(
            files: [
              (id: 'drive-file-1', name: 'Arrival.2016.mkv', match: arrival),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(cards(tester), ['Arrival']);
      expect(find.text('Your library is empty'), findsNothing);
      expect(find.textContaining('Sign in to sync'), findsNothing);
    });

    testWidgets('and with nothing linked it is the empty page as before', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(fakeCore(library: emptyLibrary()), drive: await account()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Your library is empty'), findsOneWidget);
    });

    testWidgets('a type the engine matched nothing in shows the linked film '
        'rather than the empty-filter page', (tester) async {
      await tester.pumpWidget(
        harness(
          fakeCore(
            library: library(type: 'movie', ids: const {}),
          ),
          drive: await account(
            files: [
              (id: 'drive-file-1', name: 'Arrival.2016.mkv', match: arrival),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(cards(tester), ['Arrival']);
      expect(find.text(_emptyFilterMessage('movie')), findsNothing);
    });

    testWidgets('and the empty-filter page is still what a type with nothing '
        'in it gets', (tester) async {
      // The linked film is a movie, so Series stays empty and says so.
      await tester.pumpWidget(
        harness(
          fakeCore(
            library: library(type: 'series', ids: const {}),
          ),
          drive: await account(
            files: [
              (id: 'drive-file-1', name: 'Arrival.2016.mkv', match: arrival),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(_emptyFilterMessage('series')), findsOneWidget);
      expect(find.byType(LibraryItemTile), findsNothing);
    });
  });

  testWidgets('the grid stays lazy: a merged card does not build the page '
      'nobody has scrolled to', (tester) async {
    final many = {
      ...loadLibraryFixture(),
      'catalog': [
        for (var i = 0; i < 60; i++)
          {
            '_id': 'tt$i',
            'type': 'movie',
            'name': 'Film $i',
            'poster': 'https://images.metahub.space/poster/small/tt$i/img',
            'state': <String, dynamic>{},
          },
      ],
    };
    await tester.pumpWidget(
      harness(
        fakeCore(library: many),
        drive: await account(
          files: [
            (id: 'drive-file-1', name: 'Arrival.2016.mkv', match: arrival),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byType(LibraryItemTile).evaluate().length,
      lessThan(61),
      reason: 'the count grew; the list did not',
    );
    expect(find.text('Film 0'), findsOneWidget);
  });

  group('what the merge reads before it merges anything', () {
    testWidgets('a field that has not loaded is the spinner it always was: '
        'there is no selection to read yet', (tester) async {
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
          drive: await account(
            files: [
              (id: 'drive-file-1', name: 'Arrival.2016.mkv', match: arrival),
            ],
          ),
        ),
      );
      // `pump` and not `pumpAndSettle`: an unloaded library draws a spinner,
      // which never settles.
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(LibraryItemTile), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('and with no Drive scope above it at all the grid is the '
        'engine\'s, unchanged', (tester) async {
      // A build of the app that cannot link anything is not a failure to
      // report; it is a library with nothing to merge.
      await tester.pumpWidget(harness(fakeCore()));
      await tester.pumpAndSettle();

      expect(cards(tester), ['Lanterns', 'The Whisper Man']);
      expect(tester.takeException(), isNull);
    });
  });

  /// What decides whether there is anything to merge at all.
  ///
  /// A card is drawn for a linked file that **matched**, so a file nobody
  /// ever matched is a file that is nowhere: not on Movies, not on Series,
  /// not on All. The pass used to belong to the Remote list, which meant a
  /// viewer who linked a film and went to their library saw an empty page
  /// until they happened to press a pill they had no reason to press. It
  /// belongs to this screen now, and these are the three things that says.
  group('the matching behind the merge', () {
    /// A search that answers with Arrival for anything, and records what it
    /// was asked.
    (List<String>, CatalogueSearch) recordingSearch() {
      final asked = <String>[];
      return (
        asked,
        (type, query) async {
          asked.add('$type/$query');
          return [
            {'id': 'tt2543164', 'name': 'Arrival', 'releaseInfo': '2016'},
          ];
        },
      );
    }

    testWidgets('runs without Remote ever being opened, and the card it '
        'earns is on the grid', (tester) async {
      final (asked, search) = recordingSearch();
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [
              (id: 'drive-file-1', name: 'Arrival.2016.mkv', match: null),
            ],
          ),
          search: search,
        ),
      );
      await tester.pumpAndSettle();

      expect(asked, [
        'movie/Arrival',
      ], reason: 'nothing here pressed Remote, and the pass still ran');
      expect(cards(tester), ['Lanterns', 'The Whisper Man', 'Arrival']);
    });

    testWidgets('and for a file linked while the library is on screen', (
      tester,
    ) async {
      // The account notifies, and this screen depends on the scope, so the
      // pairing that happened somewhere else is what brings the pass round
      // again. Nothing is rebuilt into existence by a pill being pressed.
      final (asked, search) = recordingSearch();
      final drive = await account();
      await tester.pumpWidget(
        harness(fakeCore(), drive: drive, search: search),
      );
      await tester.pumpAndSettle();
      expect(asked, isEmpty);

      await drive.link(
        refreshToken: 'a-refresh-token',
        files: [
          LinkedDriveFile(
            fileId: 'drive-file-1',
            name: 'Arrival.2016.mkv',
            mimeType: 'video/x-matroska',
            linkedAt: DateTime.utc(2026, 9, 21),
          ),
        ],
      );
      await tester.pumpAndSettle();

      expect(asked, ['movie/Arrival']);
      expect(cards(tester), ['Lanterns', 'The Whisper Man', 'Arrival']);
    });

    testWidgets('and opening Remote afterwards does not ask a second time', (
      tester,
    ) async {
      // There is exactly one [DriveMatchRun] in the app and therefore
      // exactly one memory of what has been asked about. A second run
      // started by the Remote list would have an empty memory of its own,
      // and this file would be searched for twice.
      final asked = <String>[];
      await tester.pumpWidget(
        harness(
          fakeCore(),
          drive: await account(
            files: [(id: 'drive-file-1', name: 'ep6.avi', match: null)],
          ),
          // Nothing matches `ep6`, which is the case the store cannot
          // guard: only the run's own memory stops it being asked again.
          search: (type, query) async {
            asked.add('$type/$query');
            return const [];
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(asked, ['movie/ep6']);

      await tapRemote(tester);
      await tester.pumpAndSettle();

      expect(asked, ['movie/ep6']);
    });
  });

  testWidgets('and under Downloaded it is not drawn: a linked file is not on '
      'this device', (tester) async {
    // Downloaded narrows the engine's list, and the merge put every matched
    // remote title straight back after it -- so the pill showed remote and
    // downloaded alike, which is what Remote is for.
    await tester.pumpWidget(
      harness(
        fakeCore(),
        downloaded: downloadOf('tt26545992'),
        drive: await account(
          files: [
            (id: 'drive-file-1', name: 'Arrival.2016.mkv', match: arrival),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(cards(tester), ['Lanterns', 'The Whisper Man', 'Arrival']);

    await tester.tap(find.widgetWithText(FilterChip, 'Downloaded'));
    await tester.pumpAndSettle();
    expect(cards(tester), ['Lanterns'], reason: 'only what is on the device');

    await tester.tap(find.widgetWithText(FilterChip, 'Downloaded'));
    await tester.pumpAndSettle();
    expect(cards(tester), ['Lanterns', 'The Whisper Man', 'Arrival']);
  });

  testWidgets('the Remote list is unchanged: every linked file, matched and '
      'unmatched', (tester) async {
    await tester.pumpWidget(
      harness(
        fakeCore(),
        drive: await account(
          files: [
            (id: 'drive-file-1', name: 'Arrival.2016.mkv', match: arrival),
            (id: 'drive-file-2', name: 'ep6.avi', match: null),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(cards(tester), [
      'Lanterns',
      'The Whisper Man',
      'Arrival',
      'ep6.avi',
    ]);

    await tapRemote(tester);

    // Remote narrows the same grid rather than replacing it: what is left
    // is the titles that have a linked file, plus a card for the file
    // nothing matched -- which has no title to be narrowed by and would
    // otherwise be reachable from nowhere.
    expect(find.text('Arrival'), findsOneWidget);
    expect(find.text('ep6.avi'), findsOneWidget);
    expect(
      cards(tester),
      isNot(contains('Lanterns')),
      reason: 'the engine\'s own titles have no linked file',
    );
  });
}

/// The empty-filter page's sentence for [type], written out rather than
/// built the way the page builds it: an expectation composed by the code
/// under test passes whatever that code says.
String _emptyFilterMessage(String type) => switch (type) {
  'movie' => 'No movies in your library',
  'series' => 'No series in your library',
  _ => throw ArgumentError(type),
};
