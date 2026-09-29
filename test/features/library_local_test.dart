import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/library/library_screen.dart';
import 'package:xtremio/features/local/local_media.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/widgets/library_item_tile.dart';

import '../support/fake_core_client.dart';
import '../support/fake_downloads_client.dart';
import '../support/fake_local_media_source.dart';
import '../support/fake_playback_engine.dart';
import '../support/fake_prefs_client.dart';
import '../support/fixtures.dart';

/// The Library's **Local** pill: this device's own videos, beside Remote's
/// Drive files and in the same shapes -- a matched one is its title's card,
/// one nothing matched is a card of its own that plays when pressed.
void main() {
  const holidayUri = 'content://media/external/video/media/8';
  const arrivalUri = 'content://media/external/video/media/7';

  const arrival = LinkedDriveMatch(
    cinemetaId: 'tt2543164',
    type: 'movie',
    name: 'Arrival',
    year: 2016,
  );

  Future<(LocalMedia, FakeLocalMediaSource)> localMedia({
    LocalMediaAccess access = LocalMediaAccess.granted,
    List<LocalMediaFacts> files = const [],
  }) async {
    final prefs = AppPrefs(client: FakePrefsClient());
    addTearDown(prefs.dispose);
    await prefs.load();
    final source = FakeLocalMediaSource(accessNow: access, files: [...files]);
    final media = LocalMedia(
      prefs: prefs,
      source: source,
      search: (type, query) async => query.toLowerCase() == 'arrival'
          ? [
              {
                'id': arrival.cinemetaId,
                'type': 'movie',
                'name': 'Arrival',
                'releaseInfo': '2016',
              },
            ]
          : const [],
    );
    addTearDown(media.dispose);
    await media.refresh();
    return (media, source);
  }

  final core = FakeCoreClient(
    state: {
      CoreField.library: loadLibraryFixture(),
      CoreField.ctx: loadCtxLoggedOutFixture(),
    },
  );

  Widget harness(LocalMedia? media, {NavigatorObserver? observer}) {
    final downloads = FakeDownloadsClient();
    addTearDown(downloads.dispose);
    return LocalMediaScope(
      media: media,
      child: CoreScope(
        client: core,
        child: DownloadsScope(
          client: downloads,
          child: PlaybackScope(
            createEngine: FakePlaybackEngine.new,
            child: MaterialApp(
              home: const LibraryScreen(),
              navigatorObservers: [?observer],
            ),
          ),
        ),
      ),
    );
  }

  Finder localChip() =>
      find.widgetWithText(FilterChip, LibraryScreen.localLabel);

  Future<void> tapLocal(WidgetTester tester) async {
    await tester.tap(localChip());
    await tester.pumpAndSettle();
  }

  testWidgets('no pill where this build finds no videos', (tester) async {
    await tester.pumpWidget(harness(null));
    await tester.pumpAndSettle();
    expect(localChip(), findsNothing);
  });

  testWidgets('a video nothing matched is a card under Local only, and '
      'plays at its own address', (tester) async {
    final (media, _) = await localMedia(
      files: [localFacts(holidayUri, 'Holiday Party.mkv')],
    );
    final pushed = _Pushed();
    await tester.pumpWidget(harness(media, observer: pushed));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(LibraryItemTile, 'Holiday Party.mkv'),
      findsNothing,
      reason: 'not in the library at large: it has no title',
    );

    await tapLocal(tester);
    final card = find.widgetWithText(LibraryItemTile, 'Holiday Party.mkv');
    expect(card, findsOneWidget);
    pushed.names.clear();
    core.dispatched.clear();
    await tester.tap(card);
    await tester.pump();

    expect(pushed.names, [PlayerScreen.routeName]);
    final load = core.dispatched.firstWhere((a) => a.field == CoreField.player);
    final args =
        (load.action['args'] as Map<String, dynamic>)['args']
            as Map<String, dynamic>;
    expect(args['stream']['url'], holidayUri);
    expect(
      args['streamRequest'],
      isNull,
      reason: 'no title to keep progress on',
    );
  });

  testWidgets('a matched video is its title\'s card, in the library and '
      'under Local', (tester) async {
    final (media, _) = await localMedia(
      files: [localFacts(arrivalUri, 'Arrival.2016.1080p.mkv')],
    );
    expect(media.files.forUri(arrivalUri)!.match, arrival);
    await tester.pumpWidget(harness(media));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(LibraryItemTile, 'Arrival'), findsOneWidget);

    await tapLocal(tester);
    expect(find.widgetWithText(LibraryItemTile, 'Arrival'), findsOneWidget);
    expect(
      find.widgetWithText(LibraryItemTile, 'Arrival.2016.1080p.mkv'),
      findsNothing,
      reason: 'the title, not the file',
    );
  });

  testWidgets('Local asks for access where it may, and then lists what it '
      'finds', (tester) async {
    final (media, source) = await localMedia(access: LocalMediaAccess.askable);
    source
      ..afterRequest = LocalMediaAccess.askable
      ..files = [localFacts(holidayUri, 'Holiday Party.mkv')];
    await tester.pumpWidget(harness(media));
    await tester.pumpAndSettle();

    // Opening the pill asks once; refused, it offers to ask again.
    await tapLocal(tester);
    expect(source.requests, 1);
    expect(find.text('Allow access to your videos'), findsOneWidget);

    source.afterRequest = LocalMediaAccess.granted;
    await tester.tap(find.widgetWithText(FilledButton, 'Allow'));
    await tester.pumpAndSettle();
    expect(source.requests, 2);
    expect(
      find.widgetWithText(LibraryItemTile, 'Holiday Party.mkv'),
      findsOneWidget,
    );
  });

  testWidgets('refused for good, Local says where to allow it', (tester) async {
    final (media, source) = await localMedia(
      access: LocalMediaAccess.unavailable,
    );
    await tester.pumpWidget(harness(media));
    await tester.pumpAndSettle();
    await tapLocal(tester);
    expect(find.text(source.setupTitle), findsOneWidget);
    expect(find.text(source.setupDetail), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Allow'), findsNothing);
  });

  testWidgets('allowed, with nothing on the device, Local says so', (
    tester,
  ) async {
    final (media, _) = await localMedia();
    await tester.pumpWidget(harness(media));
    await tester.pumpAndSettle();
    await tapLocal(tester);
    expect(find.text('No videos found'), findsOneWidget);
  });
}

class _Pushed extends NavigatorObserver {
  final List<String?> names = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      names.add(route.settings.name);
}
