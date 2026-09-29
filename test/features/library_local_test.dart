import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/library/library_screen.dart';
import 'package:xtremio/features/local/local_media.dart';
import 'package:xtremio/features/local/local_thumbnail.dart';
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

  testWidgets('an unmatched video\'s card is a frame of it, and its icon '
      'where the system has none', (tester) async {
    final (media, source) = await localMedia(
      files: [
        localFacts(holidayUri, 'Holiday Party.mkv'),
        localFacts(arrivalUri, 'Some Home Video.mkv'),
      ],
    );
    final png = (await tester.runAsync(() async {
      final image = await createTestImage(width: 16, height: 9);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    }))!;
    source.thumbnails = {holidayUri: png};
    // An earlier test's card may have left this address's load in the
    // image cache, unfinished on that test's clock.
    imageCache
      ..clear()
      ..clearLiveImages();
    // Decoding is real engine work, which a test's clock never runs: done
    // here, outside it, the card finds the frame in the image cache.
    await tester.runAsync(() async {
      final done = Completer<void>();
      LocalThumbnail(holidayUri, source: source)
          .resolve(ImageConfiguration.empty)
          .addListener(
            ImageStreamListener(
              (_, _) => done.complete(),
              onError: (error, _) => done.completeError(error),
            ),
          );
      await done.future;
    });
    addTearDown(imageCache.clear);
    await tester.pumpWidget(harness(media));
    await tester.pumpAndSettle();
    await tapLocal(tester);

    Finder imageIn(String name) => find.descendant(
      of: find.widgetWithText(LibraryItemTile, name),
      matching: find.byWidgetPredicate(
        (widget) => widget is Image && widget.image is LocalThumbnail,
      ),
    );
    expect(imageIn('Holiday Party.mkv'), findsOneWidget);
    expect(
      tester.widget<Image>(imageIn('Holiday Party.mkv')).image,
      LocalThumbnail(holidayUri, source: source),
    );

    await tester.pumpAndSettle();
    RawImage? drawn(String name) => tester
        .widgetList<RawImage>(
          find.descendant(
            of: find.widgetWithText(LibraryItemTile, name),
            matching: find.byType(RawImage),
          ),
        )
        .firstOrNull;
    expect(drawn('Holiday Party.mkv')?.image, isNotNull);
    expect(
      find.descendant(
        of: find.widgetWithText(LibraryItemTile, 'Some Home Video.mkv'),
        matching: find.byIcon(Icons.movie_outlined),
      ),
      findsOneWidget,
      reason: 'no frame to show: the icon, as for a missing poster',
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

  group('with only picked videos allowed', () {
    testWidgets('what was picked is listed -- a camera clip too, since it '
        'was chosen -- and a button beside Local picks more', (tester) async {
      final (media, source) = await localMedia(
        access: LocalMediaAccess.partial,
        files: [localFacts(holidayUri, 'VID_20260927_163226235.mp4')],
      );
      source.afterRequest = LocalMediaAccess.partial;
      await tester.pumpWidget(harness(media));
      await tester.pumpAndSettle();
      final choose = find.byTooltip(LibraryScreen.chooseVideosLabel);
      expect(choose, findsNothing, reason: 'only while Local is on');

      await tapLocal(tester);
      expect(source.requests, 0, reason: 'opening Local does not re-ask');
      expect(
        find.widgetWithText(LibraryItemTile, 'VID_20260927_163226235.mp4'),
        findsOneWidget,
      );

      source.files = [
        ...source.files,
        localFacts(arrivalUri, 'Some Home Video.mkv'),
      ];
      await tester.tap(choose);
      await tester.pumpAndSettle();
      expect(source.requests, 1);
      expect(
        find.widgetWithText(LibraryItemTile, 'Some Home Video.mkv'),
        findsOneWidget,
        reason: 'looked again after the picker',
      );
    });

    testWidgets('with none picked, Local says so and offers the picker', (
      tester,
    ) async {
      final (media, source) = await localMedia(
        access: LocalMediaAccess.partial,
      );
      source.afterRequest = LocalMediaAccess.granted;
      await tester.pumpWidget(harness(media));
      await tester.pumpAndSettle();
      await tapLocal(tester);
      expect(find.text('No videos chosen'), findsOneWidget);

      source.files = [localFacts(holidayUri, 'Holiday Party.mkv')];
      await tester.tap(
        find.widgetWithText(FilledButton, LibraryScreen.chooseVideosLabel),
      );
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(LibraryItemTile, 'Holiday Party.mkv'),
        findsOneWidget,
      );
      expect(
        find.byTooltip(LibraryScreen.chooseVideosLabel),
        findsNothing,
        reason: 'every video allowed now: nothing left to pick',
      );
    });
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
