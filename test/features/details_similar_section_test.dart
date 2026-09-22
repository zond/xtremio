import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/similar_row.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/similar/similar_resolver.dart';

import '../support/fake_core_client.dart';
import '../support/fake_playback_engine.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_torrent_stats_client.dart';
import '../support/fixtures.dart';

/// "More like this" where there is no ladder: the same films as one more
/// section of the phone's scroll.
///
/// The television's rung is `tv/details_similar_test.dart`, and everything
/// worth arguing about -- when there is a row at all, what a late answer
/// may disturb -- is argued there. This is that the other layout draws it.
const movieId = 'tt0063350';

SimilarTitle suggestion(String id, String name, int year) => SimilarTitle(
  item: MetaItemPreview({
    'id': id,
    'type': 'movie',
    'name': name,
    'releaseInfo': '$year',
  }),
  why: 'the same grey and the same pace',
);

final stalker = suggestion('tt0079944', 'Stalker', 1979);

void main() {
  late Completer<List<SimilarTitle>> answer;

  Future<void> mount(
    WidgetTester tester, {
    String? apiKey = 'not-a-real-key',
  }) async {
    // Tall enough that the whole column is laid out: a sliver below the
    // fold is never built, and the section is the last of them.
    tester.view.physicalSize = const Size(600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    answer = Completer<List<SimilarTitle>>();
    final prefs = AppPrefs(
      client: FakePrefsClient({AppPrefs.similarApiKeyKey: ?apiKey}),
    );
    addTearDown(prefs.dispose);
    await prefs.load();
    await tester.pumpWidget(
      CoreScope(
        client: FakeCoreClient(
          state: {CoreField.metaDetails: loadMetaDetailsFixture()},
        ),
        child: PrefsScope(
          prefs: prefs,
          child: PlaybackScope(
            createEngine: FakePlaybackEngine.new,
            torrentStats: FakeTorrentStatsClient(),
            child: SimilarScope(
              askFor: (prefs) =>
                  ({
                    required String type,
                    required String id,
                    required String name,
                    int? year,
                  }) => answer.future,
              child: const MaterialApp(
                home: MetaDetailsScreen(type: 'movie', id: movieId),
              ),
            ),
          ),
        ),
      ),
    );
    // Not settled: while the answer is out the section holds a spinner,
    // and a spinner never stops. It is pumped a frame at a time instead,
    // the way the sources rung's tests do it.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// The completion is a microtask the fake clock's `pump` does not run
  /// before its first frame; see the television file.
  Future<void> land(WidgetTester tester, List<SimilarTitle> titles) async {
    answer.complete(titles);
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets('the section says it is looking, and then holds the films', (
    tester,
  ) async {
    await mount(tester);

    expect(find.text(kMoreLikeThisLabel), findsOneWidget);
    expect(find.text(kLookingForSimilar), findsOneWidget);

    await land(tester, [stalker]);

    expect(find.text(kLookingForSimilar), findsNothing);
    expect(find.text('Stalker'), findsOneWidget);
    expect(find.text('1979'), findsOneWidget);
  });

  testWidgets('with no key configured there is no section', (tester) async {
    await mount(tester, apiKey: null);

    expect(find.text(kMoreLikeThisLabel), findsNothing);
    expect(find.byType(SimilarSection), findsNothing);
  });

  testWidgets('and an answer of nothing takes it away again', (tester) async {
    await mount(tester);

    await land(tester, const []);

    expect(find.text(kMoreLikeThisLabel), findsNothing);
    expect(find.byType(SimilarSection), findsNothing);
  });

  testWidgets('a poster opens that title', (tester) async {
    await mount(tester);
    await land(tester, [stalker]);

    await tester.tap(find.text('Stalker'));
    // Not settled: the screen pushed over this one is loading a title the
    // fake core has no state for, and a spinner never settles.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(
      tester
          .widgetList<MetaDetailsScreen>(
            find.byType(MetaDetailsScreen, skipOffstage: false),
          )
          .map((screen) => screen.id),
      contains('tt0079944'),
    );
  });
}
