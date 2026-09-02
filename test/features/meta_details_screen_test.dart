import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../support/fake_core_client.dart';
import '../support/fake_playback_engine.dart';
import '../support/fixtures.dart';

void main() {
  // Scopes sit above MaterialApp, as in the app, so pushed routes see them.
  Widget harness(FakeCoreClient core, FakePlaybackEngine engine) => CoreScope(
    client: core,
    child: PlaybackScope(
      createEngine: () => engine,
      child: const MaterialApp(
        home: MetaDetailsScreen(type: 'movie', id: 'tt0063350'),
      ),
    ),
  );

  /// The stream list is a lazy sliver below the header; give it room so
  /// every fixture stream is built without scrolling.
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('loads the title on mount and lists streams per addon', (
    tester,
  ) async {
    useTallViewport(tester);
    final core = FakeCoreClient(
      state: {CoreField.metaDetails: loadMetaDetailsFixture()},
    );
    await tester.pumpWidget(harness(core, FakePlaybackEngine()));
    await tester.pumpAndSettle();

    expect(core.dispatched, hasLength(1));
    expect(
      core.dispatched.single.action,
      CoreActions.loadMetaDetails(type: 'movie', id: 'tt0063350').action,
    );

    expect(find.text('Night of the Living Dead'), findsWidgets);
    expect(find.text('1968 · 96 min · movie'), findsOneWidget);
    // Addon groups, a playable torrent, disabled externals, a failed addon.
    expect(find.text('caching.stremio.net'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);
    expect(find.text('Amazon Prime Video'), findsOneWidget);
    final external = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('Amazon Prime Video'),
        matching: find.byType(ListTile),
      ),
    );
    expect(external.enabled, isFalse);
    expect(find.text('EmptyContent'), findsOneWidget);

    // Leaving unloads the field.
    await tester.pumpWidget(const SizedBox());
    expect(
      core.dispatched.last.action,
      CoreActions.unload(CoreField.metaDetails).action,
    );
  });

  testWidgets('tapping a stream opens the player with it', (tester) async {
    useTallViewport(tester);
    final core = FakeCoreClient(
      state: {
        CoreField.metaDetails: loadMetaDetailsFixture(),
        CoreField.player: loadPlayerFixture(),
      },
    );
    final engine = FakePlaybackEngine();
    await tester.pumpWidget(harness(core, engine));
    await tester.pumpAndSettle();

    await tester.tap(find.text('1080p'));
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen), findsOneWidget);
    final load = core.dispatched.firstWhere((a) => a.field == CoreField.player);
    final args = load.action['args']['args'] as Map<String, dynamic>;
    expect(
      args['stream']['infoHash'],
      '11ea02584fa6351956f35671962ab46354d99060',
    );
    expect(
      args['streamRequest']['base'],
      'https://caching.stremio.net/publicdomainmovies.now.sh/manifest.json',
    );
    expect(args['metaRequest']['base'], kCinemetaManifestUrl);
    expect(engine.opened, hasLength(1), reason: 'the player opened the URL');
  });

  testWidgets('shows a spinner while the meta loads and the error otherwise', (
    tester,
  ) async {
    Map<String, dynamic> withMeta(Map<String, dynamic> content) => {
      'selected': {
        'metaPath': {
          'resource': 'meta',
          'type': 'movie',
          'id': 'tt0063350',
          'extra': <Object>[],
        },
        'streamPath': null,
        'guessStream': true,
      },
      'metaItems': [
        {
          'request': ResourceRequest(
            base: kCinemetaManifestUrl,
            path: const ResourcePath(
              resource: 'meta',
              type: 'movie',
              id: 'tt0063350',
            ),
          ).toJson(),
          'content': content,
        },
      ],
      'metaStreams': <Object>[],
      'streams': <Object>[],
    };
    final core = FakeCoreClient(
      state: {
        CoreField.metaDetails: withMeta({'type': 'Loading'}),
      },
    );
    await tester.pumpWidget(harness(core, FakePlaybackEngine()));
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    core.setState(
      CoreField.metaDetails,
      withMeta({
        'type': 'Err',
        'content': {
          'type': 'Env',
          'content': {'code': 2, 'message': 'HTTP 404'},
        },
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('Could not load this title: HTTP 404'), findsOneWidget);
  });
}
