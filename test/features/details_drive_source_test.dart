import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/stream_facts.dart';
import 'package:xtremio/features/downloads/download_labels.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/shell/device_profile.dart';

import '../support/fake_core_client.dart';
import '../support/fake_downloads_client.dart';
import '../support/fake_drive_file_opener.dart';
import '../support/fake_playback_engine.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_secret_store.dart';
import '../support/fake_torrent_stats_client.dart';
import '../support/fixtures.dart';
import '../support/tv.dart';

/// A linked Google Drive file that Cinemeta matched to a title is **one more
/// source on that title's ordinary details page** -- beside whatever the
/// addons answered, in whichever of the two layouts the viewer chose, and
/// played by a press like anything else there.
///
/// Before this, pressing a matched file in the library's Remote list opened
/// this screen and the file was nowhere on it, so matching a file made it
/// *harder* to play than leaving it unmatched.
///
/// **What it is not** is an addon. It has no manifest, no transport URL and
/// no health; it is not counted among the addons that answered with nothing,
/// it is not a torrent the server can pin, and nothing about it is written
/// anywhere the engine reads addons. The tests below hold both halves: the
/// row is an ordinary row, and the accounting around it never mentions it.
const movieId = 'tt0063350';
const seriesId = 'tt0903747';
const episodeId = 'tt0903747:1:1';
const alphaUrl = 'https://alpha.example/manifest.json';

/// The file the tests link: a name shaped like a release, so the ordinary
/// parser has something to read out of it.
const driveRelease = 'Arrival.2016.1080p.BluRay.x264-GROUP';
const driveFileName = '$driveRelease.mkv';

/// A second episode of the same series, so a lookup that asked with the
/// title alone would be caught offering it under the wrong episode.
const nextEpisodeRelease = 'Breaking.Bad.S01E02.1080p.WEB-DL.x264-GROUP';
const nextEpisodeFileName = '$nextEpisodeRelease.mkv';

Map<String, dynamic> ready(String base, List<Map<String, dynamic>> streams) => {
  'request': {
    'base': base,
    'path': {
      'resource': 'stream',
      'type': 'movie',
      'id': movieId,
      'extra': <Object>[],
    },
  },
  'content': {'type': 'Ready', 'content': streams},
};

Map<String, dynamic> emptyGroup(String base) => {
  'request': {
    'base': base,
    'path': {
      'resource': 'stream',
      'type': 'movie',
      'id': movieId,
      'extra': <Object>[],
    },
  },
  'content': {
    'type': 'Err',
    'content': {'type': 'EmptyContent'},
  },
};

/// One addon, one 1080p release, so the Drive file lands in a section that
/// already has something in it.
List<Map<String, dynamic>> oneAddon() => [
  ready(alphaUrl, [
    {
      'infoHash': 'a' * 40,
      'name': 'Alpha 1080p',
      'description': '👤 42 💾 1.51 GB',
    },
  ]),
];

/// Every string the sources list is drawing, in the order it draws them.
List<String> drawn(WidgetTester tester) => [
  for (final text in tester.widgetList<Text>(find.byType(Text))) ?text.data,
];

/// Every string drawn *inside the row headed [title]*: its lead, the lines
/// under it and its pills.
///
/// The row and not the screen, because what has to agree between the two
/// layouts is the row -- the headings around it are what the layouts are.
List<String> rowTexts(WidgetTester tester, String title) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(
      of: find.widgetWithText(ListTile, title),
      matching: find.byType(Text),
    ),
  ))
    ?text.data,
];

Future<void> toggleSection(
  WidgetTester tester,
  StreamResolution? resolution,
) async {
  await tester.tap(find.byKey(streamSectionKey(resolution)));
  await tester.pumpAndSettle();
}

Future<void> toggleGroup(WidgetTester tester, String storageLabel) async {
  await tester.tap(find.byKey(streamAddonKey(storageLabel)));
  await tester.pumpAndSettle();
}

void main() {
  /// A paired device holding [files]. The refresh token is a made-up string
  /// and stays in the [FakeSecretStore]: nothing in these tests asserts on
  /// it beyond that the opener was the only thing handed it.
  Future<DriveAccount> pairedWith(List<LinkedDriveFile> files) async {
    final prefs = AppPrefs(client: FakePrefsClient());
    await prefs.load();
    final drive = DriveAccount(prefs: prefs, secrets: FakeSecretStore());
    await drive.load();
    addTearDown(() {
      drive.dispose();
      prefs.dispose();
    });
    if (files.isNotEmpty) {
      await drive.link(refreshToken: 'a-refresh-token', files: files);
    }
    return drive;
  }

  LinkedDriveFile file({
    String id = 'file-1',
    String name = driveFileName,
    LinkedDriveMatch? match,
    int? height,
  }) => LinkedDriveFile(
    fileId: id,
    name: name,
    mimeType: 'video/x-matroska',
    linkedAt: DateTime.utc(2026, 9, 20),
    height: height,
    match: match,
  );

  const movieMatch = LinkedDriveMatch(
    cinemetaId: movieId,
    type: 'movie',
    name: 'Night of the Living Dead',
    year: 1968,
  );
  const episodeMatch = LinkedDriveMatch(
    cinemetaId: seriesId,
    type: 'series',
    name: 'Breaking Bad',
    year: 2008,
    season: 1,
    episode: 1,
  );
  const nextEpisodeMatch = LinkedDriveMatch(
    cinemetaId: seriesId,
    type: 'series',
    name: 'Breaking Bad',
    year: 2008,
    season: 1,
    episode: 2,
  );

  FakeCoreClient coreWith(
    List<Map<String, dynamic>> streams, {
    Map<String, dynamic>? details,
    Map<CoreField, Map<String, dynamic>> also = const {},
  }) => FakeCoreClient(
    state: {
      CoreField.metaDetails: (details ?? loadMetaDetailsFixture())
        ..['streams'] = streams,
      CoreField.ctx: loadCtxLoggedOutFixture(),
      ...also,
    },
  );

  Widget harness(
    FakeCoreClient core, {
    DriveAccount? drive,
    DriveFileOpener? opener,
    AppPrefs? prefs,
    DownloadsClient? downloads,
    String type = 'movie',
    String id = movieId,
    String? videoId,
  }) {
    Widget screen = PrefsScope(
      prefs: prefs ?? AppPrefs.inMemory(),
      child: PlaybackScope(
        createEngine: FakePlaybackEngine.new,
        torrentStats: FakeTorrentStatsClient(),
        child: MaterialApp(
          home: MetaDetailsScreen(
            type: type,
            id: id,
            videoId: videoId,
            driveOpener: opener ?? FakeDriveFileOpener(),
          ),
        ),
      ),
    );
    if (downloads != null) {
      screen = DownloadsScope(client: downloads, child: screen);
    }
    if (drive != null) {
      screen = DriveAccountScope(account: drive, child: screen);
    }
    return CoreScope(client: core, child: screen);
  }

  void useWideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(ChoiceChip, label));
    await tester.pumpAndSettle();
  }

  group('nothing appears where nothing is linked', () {
    testWidgets('no pairing at all, and a pairing whose files matched other '
        'titles, draw exactly what the screen drew before', (tester) async {
      useWideViewport(tester);
      await tester.pumpWidget(harness(coreWith(oneAddon())));
      await tester.pumpAndSettle();
      final withoutDrive = drawn(tester);

      // A device that is paired, and holds a file, and the file is matched
      // -- to a different title. Not an empty group, not a heading: the
      // same screen, string for string.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        harness(
          coreWith(oneAddon()),
          drive: await pairedWith([file(match: episodeMatch)]),
        ),
      );
      await tester.pumpAndSettle();
      expect(drawn(tester), withoutDrive);

      // And an unmatched file is nothing here either: it has no title to
      // be a source of.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        harness(coreWith(oneAddon()), drive: await pairedWith([file()])),
      );
      await tester.pumpAndSettle();
      expect(drawn(tester), withoutDrive);
      expect(find.text(driveSourceLabel), findsNothing);
    });

    testWidgets('a series shows an episode\'s file under that episode and '
        'nowhere else', (tester) async {
      useWideViewport(tester);
      // Two episodes of the same series linked, which is what a viewer who
      // linked a season has. The lookup is asked with the *video* id, so
      // only one of them is a source of the episode on screen -- a lookup
      // asked with the title alone would offer both, under the one
      // episode, and the viewer would press the wrong file.
      final drive = await pairedWith([
        file(match: episodeMatch),
        file(id: 'file-2', name: nextEpisodeFileName, match: nextEpisodeMatch),
      ]);

      // S1E1 selected: its file is one of its sources, and S1E2's is not.
      await tester.pumpWidget(
        harness(
          coreWith(const [], details: loadSeriesEpisodeMetaDetailsFixture()),
          drive: drive,
          type: 'series',
          id: seriesId,
          videoId: episodeId,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(driveRelease), findsNothing, reason: 'sections shut');
      await toggleSection(tester, StreamResolution.fhd1080);
      expect(find.text(driveRelease), findsOneWidget);
      expect(find.text(nextEpisodeRelease), findsNothing);
      expect(
        find.text(driveSourceLabel),
        findsOneWidget,
        reason: 'one row, and so one line saying where it came from',
      );

      // The series with no episode chosen asks with the meta id, which an
      // episode's match is not: there is no section at all, never mind a
      // shut one.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        harness(
          coreWith(const [], details: loadSeriesMetaDetailsFixture()),
          drive: drive,
          type: 'series',
          id: seriesId,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(streamSectionKey(StreamResolution.fhd1080)),
        findsNothing,
      );
      expect(find.text(driveSourceLabel), findsNothing);
    });
  });

  group('one row, whichever way the list is grouped', () {
    testWidgets('the Drive source is in both layouts, drawn from the same '
        'reading, and differs only in the fact its heading already said', (
      tester,
    ) async {
      useWideViewport(tester);
      await tester.pumpWidget(
        harness(
          coreWith(oneAddon()),
          drive: await pairedWith([file(match: movieMatch)]),
        ),
      );
      await tester.pumpAndSettle();

      // Sectioned: the file's own name says 1080p, so that is the section
      // it is in -- beside the addon's release, not in a place of its own.
      await toggleSection(tester, StreamResolution.fhd1080);
      expect(find.text(driveRelease), findsOneWidget);
      final sectionedRow = rowTexts(tester, driveRelease);
      final sectionedScreen = drawn(tester);

      await choose(tester, kStreamsGroupedLabel);
      // The group is shut like every other group, and it is headed by the
      // three words a viewer reads, not by anything URL-shaped.
      expect(find.text(driveSourceLabel), findsOneWidget);
      expect(find.text(driveRelease), findsNothing);
      await toggleGroup(tester, driveSourceStorageLabel);
      expect(find.text(driveRelease), findsOneWidget);
      final groupedRow = rowTexts(tester, driveRelease);
      final groupedScreen = drawn(tester);

      // **The agreement.** Both rows exist, and the sectioned one is the
      // grouped one plus the single line its heading did not already say
      // -- where the file came from. Nothing else differs: not the lead,
      // not the pills, not their order.
      expect(groupedRow, isNotEmpty, reason: 'the grouped layout has the row');
      expect(sectionedRow, isNotEmpty, reason: 'and so does the sectioned');
      expect(
        sectionedRow.where((line) => line != driveSourceLabel).toList(),
        groupedRow,
      );
      expect(sectionedRow, contains(driveSourceLabel));
      expect(groupedRow, isNot(contains(driveSourceLabel)));

      // Said once on each screen: the row's provenance line in one, the
      // heading in the other, and never both.
      for (final screen in [sectionedScreen, groupedScreen]) {
        expect(screen.where((line) => line == driveSourceLabel), hasLength(1));
        expect(screen.where((line) => line.contains(driveRelease)), [
          driveRelease,
        ], reason: 'the release leads, whole, and is said once');
        expect(screen, contains('1080p'), reason: 'the pill it was read');
      }
    });

    testWidgets('a file nothing can be read out of draws no pills at all, in '
        'either layout', (tester) async {
      useWideViewport(tester);
      await tester.pumpWidget(
        harness(
          coreWith(oneAddon()),
          drive: await pairedWith([
            file(name: 'holiday video 2.avi', match: movieMatch),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      // No resolution in the name, so it is in the section that says so
      // rather than in one guessed for it.
      await toggleSection(tester, null);
      expect(rowTexts(tester, 'holiday video 2'), [
        'holiday video 2',
        driveSourceLabel,
      ], reason: 'the lead and where it came from; no pills invented');

      await choose(tester, kStreamsGroupedLabel);
      await toggleGroup(tester, driveSourceStorageLabel);
      expect(rowTexts(tester, 'holiday video 2'), ['holiday video 2']);
    });

    testWidgets('the Drive group is first, above the addons', (tester) async {
      useWideViewport(tester);
      await tester.pumpWidget(
        harness(
          coreWith(oneAddon()),
          drive: await pairedWith([file(match: movieMatch)]),
        ),
      );
      await tester.pumpAndSettle();
      await choose(tester, kStreamsGroupedLabel);

      expect(
        tester
            .getTopLeft(find.byKey(streamAddonKey(driveSourceStorageLabel)))
            .dy,
        lessThan(tester.getTopLeft(find.byKey(streamAddonKey(alphaUrl))).dy),
      );
    });

    testWidgets('its open state is remembered under a label that is not an '
        'addon', (tester) async {
      useWideViewport(tester);
      final client = FakePrefsClient({'streamsSectioned': false});
      final prefs = AppPrefs(client: client);
      addTearDown(prefs.dispose);
      await prefs.load();
      await tester.pumpWidget(
        harness(
          coreWith(oneAddon()),
          drive: await pairedWith([file(match: movieMatch)]),
          prefs: prefs,
        ),
      );
      await tester.pumpAndSettle();
      await toggleGroup(tester, driveSourceStorageLabel);

      expect(prefs.openStreamAddons, {driveSourceStorageLabel});
      expect(
        client.stored[AppPrefs.openStreamAddonsKey],
        ['drive'],
        reason:
            'a plain word, never a transport URL for an addon that is '
            'not installed and does not exist',
      );
    });
  });

  group('pressing it plays it', () {
    testWidgets('through the same open the Remote list uses, with this '
        'title\'s meta and no addon request', (tester) async {
      useWideViewport(tester);
      final opener = FakeDriveFileOpener();
      final core = coreWith(
        oneAddon(),
        also: {CoreField.player: loadPlayerFixture()},
      );
      await tester.pumpWidget(
        harness(
          core,
          drive: await pairedWith([file(match: movieMatch)]),
          opener: opener,
        ),
      );
      await tester.pumpAndSettle();
      await toggleSection(tester, StreamResolution.fhd1080);

      await tester.tap(find.text(driveRelease));
      await tester.pumpAndSettle();

      // The grant went to the opener and nowhere else, with the file's own
      // id and name.
      expect(opener.asked, hasLength(1));
      expect(opener.asked.single.fileId, 'file-1');
      expect(opener.asked.single.refreshToken, 'a-refresh-token');
      expect(opener.asked.single.name, driveFileName);

      expect(find.byType(PlayerScreen), findsOneWidget);
      final load = core.dispatched.firstWhere(
        (a) => a.field == CoreField.player,
      );
      final args =
          (load.action['args'] as Map<String, dynamic>)['args']
              as Map<String, dynamic>;
      expect(
        args['stream']['url'],
        startsWith('http://127.0.0.1:'),
        reason:
            'the URL the server minted, not the placeholder the row is '
            'identified by',
      );
      expect(args['stream']['url'], isNot(contains(driveSourceScheme)));
      expect(args['stream']['name'], driveFileName);
      expect(
        args['streamRequest'],
        isNull,
        reason: 'there is no addon this came from to record',
      );
      expect(
        args['metaRequest'],
        isNotNull,
        reason: 'it is still this title being watched',
      );
    });

    testWidgets('a refusal is one sentence and nothing else', (tester) async {
      useWideViewport(tester);
      final opener = FakeDriveFileOpener(
        answers: const [DriveFileRefused(DriveOpenFailure.unreachable)],
      );
      await tester.pumpWidget(
        harness(
          coreWith(oneAddon()),
          drive: await pairedWith([file(match: movieMatch)]),
          opener: opener,
        ),
      );
      await tester.pumpAndSettle();
      await toggleSection(tester, StreamResolution.fhd1080);

      await tester.tap(find.text(driveRelease));
      await tester.pump();
      await tester.pump();

      expect(find.byType(PlayerScreen), findsNothing);
      expect(
        find.text(driveFailureMessage(DriveOpenFailure.unreachable)),
        findsOneWidget,
      );
      // The row is still a row: nothing about it went into a state.
      expect(find.text(driveRelease), findsOneWidget);
    });

    testWidgets('and it plays from the grouped layout too, by the same call', (
      tester,
    ) async {
      useWideViewport(tester);
      final opener = FakeDriveFileOpener();
      await tester.pumpWidget(
        harness(
          coreWith(oneAddon(), also: {CoreField.player: loadPlayerFixture()}),
          drive: await pairedWith([file(match: movieMatch)]),
          opener: opener,
        ),
      );
      await tester.pumpAndSettle();
      await choose(tester, kStreamsGroupedLabel);
      await toggleGroup(tester, driveSourceStorageLabel);

      await tester.tap(find.text(driveRelease));
      await tester.pumpAndSettle();

      expect(opener.asked.single.fileId, 'file-1');
      expect(find.byType(PlayerScreen), findsOneWidget);
    });
  });

  group('it is a source and not an addon', () {
    testWidgets('it is offered a download like any link, and the pin is '
        'recorded with no addon request', (tester) async {
      useWideViewport(tester);
      final downloads = FakeDownloadsClient();
      addTearDown(downloads.dispose);
      await tester.pumpWidget(
        harness(
          coreWith(oneAddon()),
          drive: await pairedWith([file(match: movieMatch)]),
          downloads: downloads,
        ),
      );
      await tester.pumpAndSettle();
      await toggleSection(tester, StreamResolution.fhd1080);

      final onDriveRow = find.descendant(
        of: find.widgetWithText(ListTile, driveRelease),
        matching: find.byTooltip(kDownloadTooltip),
      );
      expect(
        onDriveRow,
        findsOneWidget,
        reason:
            'a linked Drive file is a file the server keeps, in its proxy '
            'cache, exactly as a web link is',
      );
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Alpha 1080p'),
          matching: find.byTooltip(kDownloadTooltip),
        ),
        findsOneWidget,
      );

      await tester.tap(onDriveRow);
      await tester.pumpAndSettle();

      // What was asked for: the Drive source itself -- its
      // `xtremio-drive:` URL, which the Rust side keys through the server
      // as `ProxyPinKey::Drive` -- under this title, and with no addon
      // request, because there is no addon. The grant is not in the
      // request either: Rust holds it (`DriveAccount.grantSink`).
      final request = downloads.added.single;
      expect(request.metaId, movieId);
      expect(request.videoId, movieId);
      expect(request.stream.url, driveSourceUrl(file(match: movieMatch)));
      expect(request.stream.infoHash, isNull);
      expect(request.streamRequest, isNull);
      expect(request.name, isNotEmpty);
      expect(request.toJson().toString(), isNot(contains('a-refresh-token')));

      // And the tile has moved on from offering it: the pin is on its way.
      expect(onDriveRow, findsNothing);
      expect(find.text('Downloading ${request.name}'), findsOneWidget);
    });

    testWidgets('the addons that answered with nothing are counted without '
        'it, and the "no streams" notice gives way to it', (tester) async {
      useWideViewport(tester);
      const betaUrl = 'https://beta.example/manifest.json';
      final empties = [emptyGroup(alphaUrl), emptyGroup(betaUrl)];

      // Without the file: every addon had nothing, and the screen says so.
      await tester.pumpWidget(harness(coreWith(empties)));
      await tester.pumpAndSettle();
      expect(find.text(_NoStreams.title), findsOneWidget);
      expect(find.textContaining('2 addons had nothing'), findsOneWidget);

      // With it: the same two addons are still counted, and the notice --
      // "None of your sources had anything to play" -- is gone, because one
      // of them did.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        harness(
          coreWith(empties),
          drive: await pairedWith([file(match: movieMatch)]),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(_NoStreams.title), findsNothing);
      expect(
        find.textContaining('2 addons had nothing'),
        findsOneWidget,
        reason: 'a Drive file is not an addon that answered',
      );
      await toggleSection(tester, StreamResolution.fhd1080);
      expect(find.text(driveRelease), findsOneWidget);
    });

    testWidgets('the television counts it apart from what the addons '
        'offered', (tester) async {
      // The sources rung says what is behind it before anything is opened.
      // "2 from 1 addon" would credit that addon with a file off the
      // viewer's own Drive; "1 from 1 addon" over two cards would be short
      // of what the row holds. So the two counts are said as two.
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        DeviceScope(
          profile: tv,
          child: harness(
            coreWith(oneAddon()),
            drive: await pairedWith([file(match: movieMatch)]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('1 from 1 addon · 1 from Google Drive'), findsOneWidget);
    });

    testWidgets('a match landing while the screen is up puts the row on it', (
      tester,
    ) async {
      useWideViewport(tester);
      final drive = await pairedWith([file()]);
      await tester.pumpWidget(harness(coreWith(oneAddon()), drive: drive));
      await tester.pumpAndSettle();
      await toggleSection(tester, StreamResolution.fhd1080);
      expect(find.text(driveRelease), findsNothing);

      await drive.noteMatch(fileId: 'file-1', match: movieMatch);
      await tester.pumpAndSettle();

      expect(
        find.text(driveRelease),
        findsOneWidget,
        reason:
            'the derivation is keyed on the files by value, so a match '
            'landing is a change it notices',
      );
    });
  });

  group('what Drive measured decides the section', () {
    // A Drive row is the only row in the app that knows how tall its video
    // actually is, because Drive measures an upload once it has processed
    // it. `driveFileName` claims 1080p; these files are measured otherwise.
    testWidgets('so a file measured at 720 sits under 720p, and not in the '
        '1080p section its name asks for', (tester) async {
      useWideViewport(tester);
      await tester.pumpWidget(
        harness(
          coreWith(oneAddon()),
          drive: await pairedWith([file(match: movieMatch, height: 720)]),
        ),
      );
      await tester.pumpAndSettle();

      // The addon's own 1080p release is what holds that section open, so
      // the section exists either way and its being the wrong home for the
      // Drive file is the thing under test -- not whether it is drawn.
      await toggleSection(tester, StreamResolution.fhd1080);
      expect(
        find.text(driveRelease),
        findsNothing,
        reason: 'the name said 1080p and the file is not 1080p',
      );

      await toggleSection(tester, StreamResolution.hd720);
      expect(find.text(driveRelease), findsOneWidget);
      // And the pill agrees with the section, because both read the one
      // fact: a viewer can see what the sorting used.
      expect(rowTexts(tester, driveRelease), contains('720p'));
    });

    testWidgets('and a file Drive never measured is read from its name, as '
        'every other row is', (tester) async {
      useWideViewport(tester);
      await tester.pumpWidget(
        harness(
          coreWith(oneAddon()),
          drive: await pairedWith([file(match: movieMatch)]),
        ),
      );
      await tester.pumpAndSettle();

      await toggleSection(tester, StreamResolution.fhd1080);
      expect(
        find.text(driveRelease),
        findsOneWidget,
        reason: 'no measurement is the ordinary case, not a broken one',
      );
    });
  });
}

/// The notice's own words, kept here so the test names what it is looking
/// for rather than reaching into the screen for it.
abstract final class _NoStreams {
  static const String title = 'No streams for this title';
}
