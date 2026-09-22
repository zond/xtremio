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
final existenz = suggestion('tt0120907', 'eXistenZ', 1999);

void main() {
  late Completer<List<SimilarTitle>> answer;

  /// One entry per ask, saying whether it was a re-ask.
  late List<bool> asked;

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
    asked = [];
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
                    bool afresh = false,
                  }) {
                    asked.add(afresh);
                    return answer.future;
                  },
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
  ///
  /// A fresh completer is left behind it, so the next ask -- a re-ask --
  /// has one of its own to wait on.
  Future<void> land(WidgetTester tester, List<SimilarTitle> titles) async {
    final landing = answer;
    answer = Completer<List<SimilarTitle>>();
    landing.complete(titles);
    await tester.pump();
    await tester.pumpAndSettle();
  }

  /// Presses the ask-again control. Not settled: while the ask is out the
  /// control is a spinner, and a spinner never stops.
  Future<void> askAgain(WidgetTester tester) async {
    await tester.tap(find.byTooltip(kAskAgainHint), warnIfMissed: false);
    await tester.pump();
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

  testWidgets('with no key configured there is no section, and so no way '
      'to ask again either', (tester) async {
    await mount(tester, apiKey: null);

    expect(find.text(kMoreLikeThisLabel), findsNothing);
    expect(find.byType(SimilarSection), findsNothing);
    expect(find.byTooltip(kAskAgainHint), findsNothing);
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

  /// A bad row is a bad row for the life of the install without this, so
  /// what is asserted is that the press really does go out -- an answer is
  /// remembered by the time it is pressed -- and that a press can only
  /// ever cost the viewer a call, never the row they were looking at.
  group('asking again', () {
    testWidgets('the control is in the heading, and is not there until '
        'there is an answer to be unhappy with', (tester) async {
      await mount(tester);
      expect(find.byTooltip(kAskAgainHint), findsNothing, reason: 'looking');

      await land(tester, [stalker]);

      expect(find.byTooltip(kAskAgainHint), findsOneWidget);
    });

    testWidgets('pressing it asks again although an answer is remembered, '
        'and the new answer is what is shown', (tester) async {
      await mount(tester);
      await land(tester, [stalker]);
      expect(asked, [false]);

      await askAgain(tester);

      expect(asked, [false, true], reason: 'past everything remembered');
      expect(
        find.text('Stalker'),
        findsOneWidget,
        reason: 'the old row stands while the new ask is out',
      );

      await land(tester, [existenz]);

      expect(find.text('eXistenZ'), findsOneWidget);
      expect(find.text('Stalker'), findsNothing);
    });

    testWidgets('a re-ask that comes back with nothing leaves the viewer '
        'exactly where they were, and says so', (tester) async {
      await mount(tester);
      await land(tester, [stalker]);

      await askAgain(tester);
      await land(tester, const []);

      expect(find.text('Stalker'), findsOneWidget, reason: 'not blanked');
      expect(find.text(kNothingNewSimilar), findsOneWidget);
    });

    testWidgets('and pressing it four times while the ask is out costs one '
        'call', (tester) async {
      await mount(tester);
      await land(tester, [stalker]);

      for (var i = 0; i < 4; i++) {
        await askAgain(tester);
      }

      expect(asked, [false, true]);
    });
  });
}
